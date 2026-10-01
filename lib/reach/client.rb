require "net/http"
require "uri"
require "json"
require "time"
require "securerandom"
require "fileutils"
require "openssl"

module Reach
  class CircuitBreaker
    def initialize(failure_threshold: 5, cooldown_s: 60)
      @failure_threshold = failure_threshold
      @cooldown_s = cooldown_s
      @failures = 0
      @opened_at = nil
      @mutex = Mutex.new
    end

    def open?
      @mutex.synchronize do
        return false unless @opened_at

        if Time.now - @opened_at >= @cooldown_s
          @opened_at = nil
          @failures = 0
          false
        else
          true
        end
      end
    end

    def record_success
      @mutex.synchronize do
        @failures = 0
        @opened_at = nil
      end
    end

    def record_failure
      @mutex.synchronize do
        @failures += 1
        @opened_at = Time.now if @failures >= @failure_threshold
      end
    end
  end

  module TokenBucket
    CAPACITY = 20.0
    RATE_PER_SECOND = 20.0 / 60.0

    module_function

    def acquire!(quick: false)
      deadline = Time.now + 30
      loop do
        wait = try_take
        return if wait.nil?
        raise Reach::Offline, "reach: rate limit wait exceeded in quick mode" if quick && wait > 0.5
        raise Reach::Offline, "reach: rate limit wait exceeded" if Time.now + wait > deadline

        sleep(wait)
      end
    end

    def try_take
      FileUtils.mkdir_p(Reach::Paths.state_dir)
      path = Reach::Paths.bucket_file
      wait = nil
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        now = Time.now.to_f
        state = read_state(file)
        elapsed = [now - state["updated_at"].to_f, 0].max
        tokens = [CAPACITY, state["tokens"].to_f + (elapsed * RATE_PER_SECOND)].min
        if tokens >= 1.0
          tokens -= 1.0
          write_state(file, "tokens" => tokens, "updated_at" => now)
        else
          write_state(file, "tokens" => tokens, "updated_at" => now)
          wait = (1.0 - tokens) / RATE_PER_SECOND
        end
      end
      wait
    end

    def read_state(file)
      file.rewind
      raw = file.read
      return { "tokens" => CAPACITY, "updated_at" => Time.now.to_f } if raw.nil? || raw.strip.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      { "tokens" => CAPACITY, "updated_at" => Time.now.to_f }
    end

    def write_state(file, state)
      file.rewind
      file.truncate(0)
      file.write(JSON.generate(state))
      file.flush
    end
  end

  class Client
    CONNECT_TIMEOUT_S = 5
    READ_TIMEOUT_S = 30
    QUICK_CONNECT_TIMEOUT_S = 2
    QUICK_READ_TIMEOUT_S = 2
    MAX_RETRIES = 4
    BACKOFF_BASE_S = 1.0
    BACKOFF_CAP_S = 30.0
    RETRYABLE_STATUSES = [408, 425, 429, 500, 502, 503, 504].freeze
    RETRYABLE_EXCEPTIONS = [
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT,
      Errno::ECONNABORTED, Errno::EPIPE, Errno::EADDRNOTAVAIL,
      Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError, EOFError
    ].freeze
    LOG_MAX_BYTES = 5 * 1024 * 1024
    LOG_KEEP = 5
    class Response
      attr_reader :status, :headers, :body

      def initialize(status:, headers:, body:)
        @status = status
        @headers = headers
        @body = body
      end

      def json
        return nil if body.nil? || body.to_s.strip.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end

    @@breaker = CircuitBreaker.new(failure_threshold: 5, cooldown_s: 60)

    def self.breaker
      @@breaker
    end

    def self.for_install(install = Reach::Enroll.current, quick: false)
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

      private_key = Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
      new(base_url: install.fetch("teach_url"), install_id: install["install_id"], install_private_key: private_key, quick: quick)
    end

    def self.anonymous(base_url, quick: false, connect_timeout: nil, read_timeout: nil, max_retries: nil)
      new(base_url: base_url, install_id: nil, install_private_key: nil, quick: quick, connect_timeout: connect_timeout, read_timeout: read_timeout, max_retries: max_retries)
    end

    def initialize(base_url:, install_id:, install_private_key:, quick: false, connect_timeout: nil, read_timeout: nil, max_retries: nil)
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @install_id = install_id
      @install_private_key = install_private_key
      @quick = quick
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @max_retries = max_retries
    end

    def get(path, query: nil, headers: {})
      request(:get, path, query: query, headers: headers)
    end

    def post_json(path, body, idempotency_key: nil, headers: {})
      merged = headers.merge("Content-Type" => "application/json", "Accept" => "application/json")
      merged["Idempotency-Key"] = idempotency_key if idempotency_key
      request(:post, path, body: JSON.generate(body), headers: merged)
    end

    private

    def request(method, path, query: nil, body: nil, headers: {})
      raise Reach::Offline, "reach: REACH_OFFLINE=1, no network calls are made" if ENV["REACH_OFFLINE"] == "1"
      raise Reach::Offline, "reach: too many recent failures talking to Teach; try later" if self.class.breaker.open?

      query_string = (query && !query.empty?) ? URI.encode_www_form(query) : nil
      target = query_string ? "#{path}?#{query_string}" : path

      max_attempts = @max_retries ? (@max_retries + 1) : (@quick ? 1 : (MAX_RETRIES + 1))
      attempt = 0
      loop do
        attempt += 1
        began_at = Time.now
        begin
          TokenBucket.acquire!(quick: @quick)
          response = perform(method, path, query_string, body, headers, target)
          duration_ms = ((Time.now - began_at) * 1000).round
          log_request(method, target, response.status, duration_ms, attempt - 1)

          if response.status < 400
            self.class.breaker.record_success
            return response
          end

          parsed = response.json
          error = (parsed || {})["error"] || {}
          code = error["code"].to_s
          message = error["message"].to_s

          if RETRYABLE_STATUSES.include?(response.status)
            self.class.breaker.record_failure if response.status >= 500
            if attempt >= max_attempts
              raise Reach::NetworkError, "reach: request to #{path} failed with #{response.status} #{code}"
            end

            wait = retry_after_seconds(response) || backoff_seconds(attempt)
            sleep(wait)
            next
          end

          self.class.breaker.record_success
          refusal = Reach::RemoteRefused.new(code, response.status, message)
          refusal.details = error["details"] || (parsed || {})["details"]
          raise refusal
        rescue Reach::Offline, Reach::RemoteRefused
          raise
        rescue *RETRYABLE_EXCEPTIONS => e
          self.class.breaker.record_failure
          duration_ms = ((Time.now - began_at) * 1000).round
          log_request(method, target, 0, duration_ms, attempt - 1)
          if attempt >= max_attempts
            raise Reach::NetworkError, "reach: request to #{path} failed (#{e.class}: #{e.message})"
          end

          sleep(backoff_seconds(attempt))
        end
      end
    end

    def perform(method, path, query_string, body, headers, target)
      uri = URI.parse(@base_url + path)
      uri.query = query_string if query_string
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @connect_timeout || (@quick ? QUICK_CONNECT_TIMEOUT_S : CONNECT_TIMEOUT_S)
      http.read_timeout = @read_timeout || (@quick ? QUICK_READ_TIMEOUT_S : READ_TIMEOUT_S)

      request_class = (method == :get) ? Net::HTTP::Get : Net::HTTP::Post
      req = request_class.new(uri.request_uri)
      headers.each { |key, value| req[key] = value }
      sign!(req, method: method, target: target, body: body)
      req.body = body if body

      http_response = http.request(req)
      Response.new(
        status: http_response.code.to_i,
        headers: http_response.to_hash.each_with_object({}) { |(k, v), acc| acc[k.downcase] = v.first },
        body: http_response.body
      )
    end

    def sign!(req, method:, target:, body:)
      return unless @install_private_key

      timestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      nonce = SecureRandom.hex(16)
      signature = Reach::Crypto.sign_request(
        @install_private_key, method: method, target: target, timestamp: timestamp, nonce: nonce, body: body.to_s
      )
      req["X-Teach-Install"] = @install_id.to_s
      req["X-Teach-Timestamp"] = timestamp
      req["X-Teach-Nonce"] = nonce
      req["X-Teach-Signature"] = signature
    end

    def retry_after_seconds(response)
      value = response.headers["retry-after"]
      return nil unless value

      seconds = Integer(value)
      [seconds, 60].min
    rescue ArgumentError, TypeError
      nil
    end

    def backoff_seconds(attempt)
      capped = [BACKOFF_CAP_S, BACKOFF_BASE_S * (2**(attempt - 1))].min
      rand * capped
    end

    def log_request(method, route, status, duration_ms, retry_count)
      FileUtils.mkdir_p(Reach::Paths.logs_dir)
      record = {
        "method" => method.to_s.upcase,
        "route" => route,
        "status" => status,
        "duration_ms" => duration_ms,
        "retry_count" => retry_count,
        "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
      rotate_log(Reach::Paths.requests_log)
      File.open(Reach::Paths.requests_log, "a") { |f| f.puts(JSON.generate(record)) }
    rescue StandardError
      nil
    end

    def rotate_log(path)
      return unless File.file?(path) && File.size(path) >= LOG_MAX_BYTES

      (LOG_KEEP - 1).downto(1) do |index|
        older = "#{path}.#{index}"
        File.rename(older, "#{path}.#{index + 1}") if File.file?(older)
      end
      File.rename(path, "#{path}.1")
    rescue StandardError
      nil
    end
  end
end
