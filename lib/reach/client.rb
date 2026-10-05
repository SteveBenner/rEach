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
    BUCKETS = { "live" => { "capacity" => 30.0, "rate" => 30.0 / 60.0 } }.freeze

    module_function

    def acquire!(quick: false, bucket: nil)
      deadline = Time.now + 30
      loop do
        wait = try_take(bucket)
        return if wait.nil?

        pacing_error!("busy") if wait == :busy
        pacing_error!("quick") if quick && wait > 0.5
        pacing_error!("limit") if Time.now + wait > deadline
        pacing_error!("deadline") if Reach::Client.deadline && Time.now + wait > Reach::Client.deadline - 0.5

        sleep(wait)
      end
    end

    def pacing_error!(why)
      error = Reach::Offline.new(Reach::Messages.text("M-TEACH-PACING"))
      error.cause_name = "rate_wait"
      error.detail = "rate limit wait exceeded (#{why})"
      raise error
    end

    def try_take(bucket = nil)
      FileUtils.mkdir_p(Reach::Paths.state_dir)
      named = BUCKETS[bucket.to_s]
      path = named ? File.join(Reach::Paths.state_dir, "bucket-#{bucket}.json") : Reach::Paths.bucket_file
      capacity = named ? named["capacity"] : CAPACITY
      rate = named ? named["rate"] : RATE_PER_SECOND
      wait = nil
      held = Reach::Locks.exclusive(path) do |file|
        now = Time.now.to_f
        state = read_state(file, capacity)
        elapsed = [now - state["updated_at"].to_f, 0].max
        tokens = [capacity, state["tokens"].to_f + (elapsed * rate)].min
        if tokens >= 1.0
          tokens -= 1.0
          write_state(file, "tokens" => tokens, "updated_at" => now)
        else
          write_state(file, "tokens" => tokens, "updated_at" => now)
          wait = (1.0 - tokens) / rate
        end
      end
      held == :busy ? :busy : wait
    end

    def read_state(file, capacity = CAPACITY)
      file.rewind
      raw = file.read
      return { "tokens" => capacity, "updated_at" => Time.now.to_f } if raw.nil? || raw.strip.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      { "tokens" => capacity, "updated_at" => Time.now.to_f }
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
    SCRUB_MARKER = "requests-log-scrubbed.json".freeze
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

    DEADLINE_FLOOR_S = 0.5

    @@breaker = CircuitBreaker.new(failure_threshold: 5, cooldown_s: 60)
    @deadline = nil

    class << self
      attr_accessor :deadline

      def redact_route(route)
        Reach::SetupLog.redact_path(route)
      rescue StandardError
        route.to_s.split("?", 2).first.to_s
      end

      def requests_log_files
        base = Reach::Paths.requests_log
        [base] + (1..LOG_KEEP).map { |index| "#{base}.#{index}" }
      end

      def scrub_requests_log_once!
        marker = File.join(Reach::Paths.state_dir, SCRUB_MARKER)
        return nil if @scrubbed == marker || File.file?(marker)
        return nil unless requests_log_files.any? { |path| File.file?(path) }

        FileUtils.mkdir_p(Reach::Paths.state_dir)
        Reach::Locks.exclusive("#{marker}.lock", wait_s: 1.0) do
          next if File.file?(marker)

          requests_log_files.each { |path| scrub_requests_file(path) if File.file?(path) }
          File.write(marker, JSON.generate("scrubbed_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "version" => 1))
        end
        @scrubbed = marker if File.file?(marker)
        nil
      rescue StandardError
        nil
      end

      def scrub_requests_file(path)
        lines = File.readlines(path, chomp: true).map do |line|
          record = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          next Reach::SetupLog.scrub_text(line) unless record.is_a?(Hash)

          record["route"] = redact_route(record["route"]) if record.key?("route")
          JSON.generate(record)
        end
        tmp = "#{path}.tmp.#{Process.pid}"
        File.write(tmp, lines.map { |line| "#{line}\n" }.join)
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      def with_deadline(seconds)
        previous = @deadline
        @deadline = Time.now + seconds
        yield
      ensure
        @deadline = previous
      end
    end

    def self.breaker
      @@breaker
    end

    def self.for_install(install = Reach::Enroll.current, quick: false, bucket: nil, quiet: false)
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

      private_key = Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
      new(base_url: install.fetch("teach_url"), install_id: install["install_id"], install_private_key: private_key, quick: quick, bucket: bucket, quiet: quiet)
    end

    def self.anonymous(base_url, quick: false, connect_timeout: nil, read_timeout: nil, max_retries: nil, link: true)
      new(base_url: base_url, install_id: nil, install_private_key: nil, quick: quick, connect_timeout: connect_timeout, read_timeout: read_timeout, max_retries: max_retries, link: link)
    end

    def initialize(base_url:, install_id:, install_private_key:, quick: false, connect_timeout: nil, read_timeout: nil, max_retries: nil, bucket: nil, quiet: false, link: true)
      @track_link = link
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @install_id = install_id
      @install_private_key = install_private_key
      @quick = quick
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @max_retries = max_retries
      @bucket = bucket
      @quiet = quiet
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
      if ENV["REACH_OFFLINE"] == "1"
        error = Reach::Offline.new(Reach::Messages.text("M-TEACH-OFFLINE-FLAG"))
        error.cause_name = "offline_flag"
        error.detail = "#{method.to_s.upcase} #{path} offline_flag: REACH_OFFLINE=1"
        raise error
      end
      if Reach::Sandbox.network_blocked?
        error = Reach::Offline.new(Reach::Sandbox.agent_text)
        error.cause_name = "codex_sandbox"
        error.detail = "#{method.to_s.upcase} #{path} codex_sandbox: CODEX_SANDBOX_NETWORK_DISABLED=1"
        raise error
      end
      if self.class.breaker.open?
        error = Reach::Offline.new(Reach::Messages.text("M-TEACH-LINK-LOST"))
        error.cause_name = "breaker_open"
        error.detail = "#{method.to_s.upcase} #{path} breaker_open: circuit breaker open"
        Reach::Link.lost!("breaker_open") if @track_link
        raise error
      end

      query_string = (query && !query.empty?) ? URI.encode_www_form(query) : nil
      target = query_string ? "#{path}?#{query_string}" : path

      max_attempts = @max_retries ? (@max_retries + 1) : (@quick ? 1 : (MAX_RETRIES + 1))
      attempt = 0
      loop do
        attempt += 1
        began_at = Time.now
        begin
          if remaining_s && remaining_s < DEADLINE_FLOOR_S
            raise final_failure(method, path, "deadline", "deadline reached")
          end

          TokenBucket.acquire!(quick: @quick, bucket: @bucket)
          response = perform(method, path, query_string, body, headers, target)
          duration_ms = ((Time.now - began_at) * 1000).round
          log_request(method, target, response.status, duration_ms, attempt - 1) unless @quiet && response.status < 400
          Reach::Debug.response(method, path, response, attempt - 1, duration_ms, body) unless @quiet && response.status < 400

          if response.status < 400
            self.class.breaker.record_success
            Reach::Link.restored! if @track_link
            return response
          end

          parsed = response.json
          error = (parsed || {})["error"] || {}
          code = error["code"].to_s
          message = error["message"].to_s

          if RETRYABLE_STATUSES.include?(response.status)
            self.class.breaker.record_failure if response.status >= 500
            cause = "http_#{response.status}"
            detail = "#{response.status} #{code}".strip
            raise final_failure(method, path, cause, detail) if attempt >= max_attempts

            wait = capped_wait(retry_after_seconds(response) || backoff_seconds(attempt))
            raise final_failure(method, path, cause, detail) if wait.nil?

            sleep(wait)
            next
          end

          self.class.breaker.record_success
          Reach::Link.restored! if @track_link
          refusal = Reach::RemoteRefused.new(code, response.status, message)
          refusal.details = error["details"] || (parsed || {})["details"]
          raise refusal
        rescue Reach::Error
          raise
        rescue *RETRYABLE_EXCEPTIONS => e
          self.class.breaker.record_failure
          duration_ms = ((Time.now - began_at) * 1000).round
          log_request(method, target, 0, duration_ms, attempt - 1)
          Reach::Debug.request(method, path, 0, e.class.name, nil, attempt - 1, duration_ms, body.to_s.bytesize, 0)
          raise final_failure(method, path, e.class.name, e.message) if attempt >= max_attempts

          wait = capped_wait(backoff_seconds(attempt))
          raise final_failure(method, path, e.class.name, e.message) if wait.nil?

          sleep(wait)
        rescue StandardError => e
          self.class.breaker.record_failure
          duration_ms = ((Time.now - began_at) * 1000).round
          log_request(method, target, 0, duration_ms, attempt - 1)
          Reach::Debug.request(method, path, 0, e.class.name, nil, attempt - 1, duration_ms, body.to_s.bytesize, 0)
          raise final_failure(method, path, e.class.name, e.message)
        end
      end
    end

    def remaining_s
      deadline = self.class.deadline
      deadline ? deadline - Time.now : nil
    end

    def capped_wait(wait)
      remaining = remaining_s
      return wait unless remaining

      allowed = remaining - DEADLINE_FLOOR_S
      return nil if allowed <= 0

      [wait, allowed].min
    end

    def final_failure(method, path, cause_name, message)
      deadline = cause_name.to_s == "deadline"
      error = Reach::NetworkError.new(Reach::Messages.text(deadline ? "M-TEACH-DEADLINE" : "M-TEACH-LINK-LOST"))
      error.cause_name = cause_name
      error.detail = "#{method.to_s.upcase} #{path} #{cause_name.to_s.sub(/\Ahttp_/, "")}: #{message}"
      Reach::Link.lost!(cause_name) unless deadline || !@track_link
      error
    end

    def perform(method, path, query_string, body, headers, target)
      uri = URI.parse(@base_url + path)
      uri.query = query_string if query_string
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      open_timeout = @connect_timeout || (@quick ? QUICK_CONNECT_TIMEOUT_S : CONNECT_TIMEOUT_S)
      read_timeout = @read_timeout || (@quick ? QUICK_READ_TIMEOUT_S : READ_TIMEOUT_S)
      remaining = remaining_s
      if remaining
        open_timeout = [open_timeout, [remaining, 0.1].max].min
        read_timeout = [read_timeout, [remaining, 0.1].max].min
      end
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.write_timeout = read_timeout if http.respond_to?(:write_timeout=)
      http.max_retries = 0 if http.respond_to?(:max_retries=)

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
      req["X-Reach-Version"] = Reach::VERSION
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
      self.class.scrub_requests_log_once!
      record = {
        "method" => method.to_s.upcase,
        "route" => self.class.redact_route(route),
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
