require "fileutils"
require "yaml"
require "json"
require "time"
require "rbconfig"

module Reach
  module Enroll
    ROUTE = "/api/v1/enroll"
    LEGACY_ROUTE = "/api/v1/enrol"
    PREVIEW_ROUTE = "/api/v1/enrollment/preview"
    CONNECT_TIMEOUT_S = 5
    READ_TIMEOUT_S = 10

    module_function

    def generate_and_register(code, teach_url)
      key = Reach::Crypto.generate_install_key
      client = Reach::Client.anonymous(teach_url, link: false)
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
      Reach::Stamp.drop!
      Reach::EnrollmentLock.clear_moved!
      write_notice(body)
      announce_sidecar(current)
      Reach::Subscribe.spawn_ensure

      current
    end

    def flow_client(teach_url)
      Reach::Client.anonymous(teach_url, connect_timeout: CONNECT_TIMEOUT_S, read_timeout: READ_TIMEOUT_S, max_retries: 0, link: false)
    end

    def preview(course_code, teach_url)
      response = flow_client(teach_url).get(PREVIEW_ROUTE, query: { "course_code" => course_code })
      body = response.json
      raise Reach::Refused, Reach::Messages.text("M-ENROLL-INCOMPLETE") unless body.is_a?(Hash) && body["course"].is_a?(Hash)

      body
    end

    def register_v2(course_code:, username:, student_id:, teach_url:, harness:, enrolled_via:, password:, key: nil, fingerprint: nil)
      identity = { "course_code" => course_code, "username" => username, "student_id" => student_id }
      pending = key ? nil : load_pending(identity)
      key, fingerprint = pending[:key], pending[:fingerprint] if pending
      key ||= Reach::Crypto.generate_install_key
      fingerprint ||= Reach::Fingerprint.build(
        install_public_key: key.public_key, harness: harness, enrolled_via: enrolled_via, salt: (Reach::Fingerprint.stored || {})["salt"]
      )
      body_fields = {
        "shape" => "v2",
        "course_code" => course_code,
        "username" => username,
        "student_id" => student_id,
        "fingerprint" => fingerprint,
        "password" => password,
        "public_key_pem" => key.public_key.to_pem,
        "reach_version" => Reach::VERSION,
        "platform" => platform,
        "ruby_version" => RUBY_VERSION
      }

      begin
        response = post_enroll(flow_client(teach_url), body_fields)
      rescue Reach::RemoteRefused => e
        case e.code
        when "device_move_pending" then save_pending(key, fingerprint, identity)
        when "device_move_denied" then clear_pending
        end
        raise
      end
      body = response.json || {}
      verify_response!(body)
      raise Reach::Refused, Reach::Messages.text("M-ENROLL-INCOMPLETE") unless body["student_id"].to_s == student_id.to_s
      raise Reach::Refused, Reach::Messages.text("M-ENROLL-INCOMPLETE") unless body["course"].is_a?(Hash) && !body["course"]["id"].to_s.empty?

      stamp = body["enrollment_stamp"]
      begin
        Reach::Stamp.verify!(
          stamp,
          signing_public_keys: body["signing_public_keys"],
          expect: {
            "install_id" => body["install_id"], "student_id" => student_id, "username" => username,
            "course_id" => body["course"]["id"], "fingerprint_digest" => fingerprint["digest"],
            "fingerprint_strict_digest" => fingerprint["strict_digest"]
          }
        )
      rescue Reach::VerificationFailed
        raise Reach::Refused, Reach::Messages.text("M-ENROLL-INCOMPLETE")
      end

      Reach::Paths.ensure_home!
      previous = current
      FileUtils.rm_f(Reach::Paths.status_cache_file) if previous && previous["student_id"] != body["student_id"]
      write_private_key(key)
      write_install_file(body, teach_url, "shape" => "v2", "username" => username, "display_name" => body["display_name"])
      Reach::Fingerprint.store!(fingerprint)
      Reach::Stamp.store!(stamp)
      Reach::Fingerprint.clear_cache!
      Reach::EnrollmentLock.clear_moved!
      clear_pending
      Reach::Password.store!(password, current)
      write_notice(body)
      announce_sidecar(current)
      Reach::Subscribe.spawn_ensure

      current
    end

    def save_pending(key, fingerprint, identity)
      path = Reach::Paths.enroll_pending_key_file
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(key.to_pem) }
      File.chmod(0o600, path)
      Reach::Login.write_json(Reach::Paths.enroll_pending_fingerprint_file, fingerprint)
      Reach::Login.write_json(pending_identity_file, identity)
      nil
    end

    def pending_identity_file
      File.join(Reach::Paths.enroll_state_dir, "pending_identity.json")
    end

    def load_pending(identity = nil)
      key_path = Reach::Paths.enroll_pending_key_file
      fingerprint = Reach::Login.read_json(Reach::Paths.enroll_pending_fingerprint_file)
      return nil unless File.file?(key_path) && fingerprint.is_a?(Hash)
      return nil if identity && Reach::Login.read_json(pending_identity_file) != identity

      { key: Reach::Crypto.load_private_key(File.read(key_path)), fingerprint: fingerprint }
    rescue StandardError
      nil
    end

    def clear_pending
      FileUtils.rm_f(Reach::Paths.enroll_pending_key_file)
      FileUtils.rm_f(Reach::Paths.enroll_pending_fingerprint_file)
      FileUtils.rm_f(pending_identity_file)
      nil
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

    def write_notice(body)
      Reach::Login.write_json(Reach::Paths.enroll_notice_file, "course_title" => (body["course"] || {})["title"], "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
    rescue StandardError
      nil
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

    def write_install_file(body, teach_url, extras = {})
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
      extras.each { |name, value| data[name] = value unless value.nil? }
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
