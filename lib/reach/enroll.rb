require "fileutils"
require "yaml"
require "json"
require "time"
require "rbconfig"

module Reach
  module Enroll
    ROUTE = "/api/v1/enroll"
    LEGACY_ROUTE = "/api/v1/enrol"

    module_function

    def generate_and_register(code, teach_url)
      key = Reach::Crypto.generate_install_key
      client = Reach::Client.anonymous(teach_url)
      body_fields = {
        "code" => code,
        "public_key_pem" => key.public_key.to_pem,
        "reach_version" => Reach::VERSION,
        "platform" => platform,
        "ruby_version" => RUBY_VERSION
      }

      begin
        response = post_enroll(client, body_fields)
      rescue Reach::RemoteRefused => e
        raise Reach::Refused, Reach::Messages.text("M-ENROLL-REFUSED") if e.code == "invalid_request"

        raise
      end

      body = response.json || {}
      verify_response!(body)

      Reach::Paths.ensure_home!
      write_private_key(key)
      write_install_file(body, teach_url)
      announce_sidecar(current)

      current
    end

    def post_enroll(client, body_fields)
      client.post_json(ROUTE, body_fields)
    rescue Reach::RemoteRefused => e
      raise unless e.code == "not_found"

      client.post_json(LEGACY_ROUTE, body_fields)
    end

    def verify_response!(body)
      keys = body["signing_public_keys"]
      complete = %w[install_id student_id encryption_key wire_contract_sha256 minimum_reach_version].all? { |field| !body[field].to_s.empty? } &&
                 (keys.is_a?(Hash) || keys.is_a?(Array)) && !keys.empty?
      raise Reach::Refused, Reach::Messages.text("M-ENROLL-INCOMPLETE") unless complete
      raise Reach::Refused, Reach::Messages.text("M-ENROLL-WIRE") unless body["wire_contract_sha256"] == Reach::Wire.digest

      return unless Gem::Version.correct?(body["minimum_reach_version"].to_s)
      return unless Gem::Version.new(Reach::VERSION) < Gem::Version.new(body["minimum_reach_version"].to_s)

      raise Reach::Refused, Reach::Messages.text("M-REACH-OUTDATED", version: Reach::VERSION, minimum: body["minimum_reach_version"])
    end

    def announce_sidecar(install)
      prior = Reach::Sidecar.prior_install_ids(install["install_id"])
      Reach::Sidecar.record_install(install)
      detail = { "sidecar_id" => Reach::Sidecar.id, "prior_install_ids" => prior, "platform" => platform }
      Reach::Integrity.report("enrolled", detail: JSON.generate(detail), once: false)
    rescue StandardError
      nil
    end

    def current
      return nil unless File.file?(Reach::Paths.install_file)

      YAML.safe_load(File.read(Reach::Paths.install_file))
    end

    def revoked?
      data = current
      return false unless data

      !!data["revoked"]
    end

    def update!(fields)
      data = current || {}
      merged = data.merge(stringify_keys(fields))
      write_data(merged)
      merged
    end

    def mark_revoked!
      data = current || {}
      data["revoked"] = true
      write_data(data)
      nil
    end

    def write_private_key(key)
      path = Reach::Paths.install_key_file
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, key.to_pem)
      File.chmod(0o600, path)
      path
    end

    def write_install_file(body, teach_url)
      data = {
        "install_id" => body["install_id"],
        "student_id" => body["student_id"],
        "course" => body["course"],
        "teach_url" => teach_url,
        "signing_public_keys" => body["signing_public_keys"],
        "encryption_key" => body["encryption_key"],
        "minimum_reach_version" => body["minimum_reach_version"],
        "wire_contract_sha256" => body["wire_contract_sha256"],
        "revoked" => false,
        "enrolled_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "last_checked_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
      write_data(data)
      data
    end

    def write_data(data)
      path = Reach::Paths.install_file
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(data))
      File.chmod(0o600, path)
      data
    end

    def stringify_keys(fields)
      fields.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    def platform
      case RbConfig::CONFIG["host_os"]
      when /darwin/
        "macos"
      when /mswin|mingw|cygwin/
        "windows"
      else
        "linux"
      end
    end
  end
end
