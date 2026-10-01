require "net/http"
require "openssl"
require "uri"
require "digest"
require "json"
require "time"
require "fileutils"

module Reach
  module Download
    MAX_ATTEMPTS = 3
    MAX_REDIRECTS = 5
    OPEN_TIMEOUT_S = 10
    READ_TIMEOUT_S = 60
    WALL_CAP_S = 1800
    RETRY_AFTER_CAP_S = 300
    CHUNK_BYTES = 1_048_576

    class Retryable < Reach::Error
      attr_reader :retry_after

      def initialize(message, retry_after = nil)
        super(message)
        @retry_after = retry_after
      end
    end

    LOCK = Mutex.new

    module_function

    def get_small(url, max_bytes: 1_048_576)
      LOCK.synchronize do
        attempt_loop(url, "manifest", Time.now) do |_attempt|
          body = +""
          fetch(url) do |response|
            response.read_body do |chunk|
              body << chunk
              raise Reach::Error, "reach: the download is larger than expected (#{max_bytes} bytes)" if body.bytesize > max_bytes
            end
          end
          body
        end
      end
    end

    def get_to_file(url, destination, expected_sha256:, expected_size:)
      LOCK.synchronize do
        FileUtils.mkdir_p(File.dirname(destination))
        part = "#{destination}.part"
        started = Time.now
        attempt_loop(url, File.basename(destination), started) do |_attempt|
          digest = Digest::SHA256.new
          bytes = 0
          File.open(part, "wb") do |file|
            fetch(url) do |response|
              response.read_body do |chunk|
                bytes += chunk.bytesize
                raise Reach::Error, "reach: #{File.basename(destination)} is larger than the manifest says" if bytes > expected_size
                raise Reach::Error, "reach: the download of #{File.basename(destination)} took too long" if Time.now - started > WALL_CAP_S

                digest.update(chunk)
                file.write(chunk)
              end
            end
          end
          raise Reach::Error, "reach: #{File.basename(destination)} has the wrong size (#{bytes}, expected #{expected_size})" unless bytes == expected_size
          raise Reach::Error, "reach: sha256 mismatch for #{File.basename(destination)}; the file was not used" unless digest.hexdigest == expected_sha256

          File.rename(part, destination)
          bytes
        end
      end
    ensure
      begin
        File.delete("#{destination}.part") if File.exist?("#{destination}.part")
      rescue SystemCallError
        nil
      end
    end

    def attempt_loop(url, label, started)
      attempt = 0
      begin
        attempt += 1
        t0 = Time.now
        result = yield(attempt)
        bytes = result.respond_to?(:bytesize) ? result.bytesize : result
        log("event" => "runtime.download", "asset" => label, "bytes" => bytes, "seconds" => (Time.now - t0).round(2), "attempt" => attempt, "ok" => true)
        result
      rescue Retryable => e
        log("event" => "runtime.download", "asset" => label, "bytes" => 0, "seconds" => (Time.now - t0).round(2), "attempt" => attempt, "ok" => false, "error" => e.message)
        raise Reach::NetworkError, "reach: could not download #{label} (#{e.message})" if attempt >= MAX_ATTEMPTS || Time.now - started > WALL_CAP_S

        pause = e.retry_after ? [e.retry_after, RETRY_AFTER_CAP_S].min : rand * (2**attempt)
        sleep(pause)
        retry
      rescue Reach::Error => e
        log("event" => "runtime.download", "asset" => label, "bytes" => 0, "seconds" => (Time.now - t0).round(2), "attempt" => attempt, "ok" => false, "error" => e.message)
        raise
      end
    end

    def fetch(url, redirects = 0, &block)
      uri = URI.parse(url)
      raise Reach::Error, "reach: refusing a non-https address" unless uri.is_a?(URI::HTTPS)

      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT_S, read_timeout: READ_TIMEOUT_S) do |http|
        request = Net::HTTP::Get.new(uri.request_uri, "User-Agent" => "reach/#{Reach::VERSION}")
        http.request(request) do |response|
          code = response.code.to_i
          if [301, 302, 303, 307, 308].include?(code)
            raise Reach::Error, "reach: too many redirects" if redirects >= MAX_REDIRECTS

            location = response["location"].to_s
            raise Reach::Error, "reach: a redirect had no destination" if location.empty?

            response.read_body { |_chunk| nil }
            return fetch(URI.join(url, location).to_s, redirects + 1, &block)
          elsif code == 200
            block.call(response)
          elsif code == 429 || code >= 500 || code == 408
            after = response["retry-after"].to_s =~ /\A\d+\z/ ? response["retry-after"].to_i : nil
            raise Retryable.new("http #{code}", after)
          else
            raise Reach::Error, "reach: the server answered #{code} for #{File.basename(uri.path)}"
          end
        end
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, IOError => e
      raise Retryable.new("#{e.class}")
    end

    def log(record)
      path = Reach::Paths.runtime_logs_file
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |file| file.puts(JSON.generate({ "ts" => Time.now.utc.iso8601 }.merge(record))) }
    rescue StandardError
      nil
    end
  end
end
