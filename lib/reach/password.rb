require "json"
require "openssl"
require "securerandom"
require "fileutils"

module Reach
  module Password
    SCHEMA = "reach.login-verifier/v1".freeze
    ITERATIONS = 600_000
    LENGTH = 32
    VERIFY_ROUTE = "/api/v1/password/verify".freeze
    RESET_ROUTE = "/api/v1/password/reset".freeze
    CONNECT_TIMEOUT_S = 5
    READ_TIMEOUT_S = 10
    PROBE_TTL_S = 60
    PROBE_ANSWERS = %w[allowed not_allowed offline].freeze
    FORGOT_WORDS = [
      "forgot", "forgot password", "forgot my password", "i forgot", "i forgot it", "i forgot my password",
      "reset", "reset password", "reset my password"
    ].freeze
    CANCEL_WORDS = ["cancel", "go back", "back"].freeze

    module_function

    def required?
      return false if Reach::Policy.login["password"] == false

      install = Reach::Enroll.current
      !install.nil? && install["shape"] == "v2"
    rescue StandardError
      true
    end

    def trimmed(text)
      text.to_s.strip
    end

    def range?(password)
      password.length >= 8 && password.length <= 256
    end

    def forgot?(text)
      FORGOT_WORDS.include?(Reach::Login.normalize(text))
    end

    def cancel?(text)
      CANCEL_WORDS.include?(Reach::Login.normalize(text))
    end

    def verifier_file
      File.join(Reach::Login.state_dir, "verifier.json")
    end

    def renewed_file
      File.join(Reach::Login.state_dir, "renewed.json")
    end

    def renewal_due?
      !File.file?(renewed_file)
    rescue StandardError
      false
    end

    def renewed!
      Reach::Login.write_json(renewed_file, "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
    rescue StandardError
      nil
    end

    def derive(password, salt, iterations)
      OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, LENGTH, OpenSSL::Digest::SHA256.new).unpack1("H*")
    end

    def store!(password, install = Reach::Enroll.current)
      return nil unless install

      salt = SecureRandom.hex(16)
      Reach::Login.write_json(
        verifier_file,
        "schema" => SCHEMA, "student_id" => install["student_id"], "install_id" => install["install_id"],
        "salt" => salt, "iterations" => ITERATIONS, "digest" => derive(password, salt, ITERATIONS)
      )
      renewed!
    rescue StandardError
      nil
    end

    def stored(install = Reach::Enroll.current)
      data = Reach::Login.read_json(verifier_file)
      return nil unless install && data.is_a?(Hash) && data["schema"] == SCHEMA
      return nil unless data["student_id"] == install["student_id"] && data["install_id"] == install["install_id"]
      return nil unless data["salt"].is_a?(String) && data["digest"].is_a?(String) && data["iterations"].to_i >= 100_000

      data
    end

    def drop!
      FileUtils.rm_f(verifier_file)
      nil
    end

    def check(password)
      install = Reach::Enroll.current
      held = stored(install)
      if held
        actual = derive(password, held["salt"], held["iterations"].to_i)
        return Reach::EnrollFlow.digest_equal?(actual, held["digest"]) ? :ok : :wrong
      end

      remote_check(password, install)
    end

    def client(install)
      private_key = Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
      Reach::Client.new(
        base_url: install.fetch("teach_url"), install_id: install["install_id"], install_private_key: private_key,
        connect_timeout: CONNECT_TIMEOUT_S, read_timeout: READ_TIMEOUT_S, max_retries: 0, quiet: true
      )
    end

    def remote_check(password, install)
      client(install).post_json(VERIFY_ROUTE, { "password" => password })
      store!(password, install)
      :ok
    rescue Reach::RemoteRefused => e
      case e.code
      when "password_wrong" then :wrong
      when "password_not_set" then :unset
      when "rate_limited" then :limited
      else :offline
      end
    rescue Reach::Error
      :offline
    end

    def reset_allowed
      body = client(Reach::Enroll.current).get(RESET_ROUTE).json
      body.is_a?(Hash) && body["allowed"] == true ? :allowed : :not_allowed
    rescue Reach::Error
      :offline
    end

    def probe_file
      File.join(Reach::Login.state_dir, "reset_probe.json")
    end

    def drop_probe!
      FileUtils.rm_f(probe_file)
      nil
    end

    def reset_allowed_cached
      install = Reach::Enroll.current
      return :offline unless install

      FileUtils.mkdir_p(Reach::Login.state_dir)
      outcome = Reach::Locks.exclusive("#{probe_file}.lock") do
        now = Time.now.utc
        held = Reach::Login.read_json(probe_file)
        if held.is_a?(Hash) && held["install_id"] == install["install_id"] && PROBE_ANSWERS.include?(held["answer"])
          at = Time.iso8601(held["at"].to_s)
          next held["answer"].to_sym if at <= now && now - at < PROBE_TTL_S
        end

        answer = reset_allowed
        Reach::Login.write_json(probe_file, "install_id" => install["install_id"], "answer" => answer.to_s, "at" => now.strftime("%Y-%m-%dT%H:%M:%SZ"))
        answer
      end
      outcome == :busy ? :offline : outcome
    rescue StandardError
      :offline
    end

    def reset!(password)
      install = Reach::Enroll.current
      client(install).post_json(RESET_ROUTE, { "password" => password })
      store!(password, install)
      :ok
    rescue Reach::RemoteRefused => e
      e.code == "password_reset_not_allowed" ? :not_allowed : :offline
    rescue Reach::Error
      :offline
    end
  end
end
