require "openssl"
require "base64"
require "json"
require "time"
require "fileutils"
require "securerandom"
require "yaml"
require "digest"
require_relative "instructor_keyring"

module Reach
  module Instructor
    PREFIX = "RINS1".freeze
    KIND = "reach.instructor-unlock".freeze
    MAX_CODE_CHARS = 4096
    CODE_PATTERN = /\ARINS1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/.freeze
    HEX16 = /\A[0-9a-f]{16}\z/.freeze
    LABEL_PATTERN = /\A[A-Za-z0-9 ._-]{0,40}\z/.freeze
    CONTEXT_SESSIONS_KEPT = 50
    PASSES_KEPT = 50
    PASS_SKEW_S = 300
    PASS_KEY_LABEL = "reach.instructor-pass/v1".freeze
    DROPPED_FIELDS = %w[code signature raw_code].freeze

    module_function

    def stored_file
      File.join(Reach::Paths.root, "instructor.json")
    end

    def context_file
      File.join(Reach::Paths.root_state_dir, "enroll", "instructor_context.json")
    end

    def log_file
      File.join(Reach::Paths.root_logs_dir, "instructor.jsonl")
    end

    def log(event, fields = {})
      FileUtils.mkdir_p(Reach::Paths.root_logs_dir)
      record = { "at" => Time.now.utc.iso8601, "event" => event }.merge(fields)
      File.open(log_file, "a", 0o600) { |handle| handle.puts(JSON.generate(record)) }
      nil
    rescue StandardError
      nil
    end

    def attempt?(text)
      candidate = text.is_a?(String) ? text.strip : ""
      candidate.length <= MAX_CODE_CHARS && CODE_PATTERN.match?(candidate)
    end

    def key_id_for(public_key)
      pem = public_key.public_key.to_pem
      body = pem.lines.reject { |line| line.start_with?("-----") }.join
      Reach::Crypto.digest_hex(Base64.decode64(body))[0, 16]
    end

    def pinned_keys
      Reach::InstructorKeyring.keys
    end

    def revoked_ids
      Reach::InstructorKeyring.revoked_ids
    end

    def refusal
      @refusal
    end

    def pinned_public_key(key_id)
      entry = pinned_keys.find { |candidate| candidate["id"].to_s == key_id.to_s }
      return nil unless entry

      key = Reach::Crypto.load_public_key(entry["public_key_pem"].to_s)
      key_id_for(key) == entry["id"].to_s ? key : nil
    rescue StandardError
      nil
    end

    def unb64(text)
      Base64.urlsafe_decode64(text)
    end

    def parse(code)
      candidate = code.to_s.strip
      return nil unless candidate.length <= MAX_CODE_CHARS && CODE_PATTERN.match?(candidate)

      _prefix, segment, signature = candidate.split(".", 3)
      payload = JSON.parse(unb64(segment))
      return nil unless payload.is_a?(Hash)

      { "payload" => payload, "segment" => segment, "signature" => unb64(signature) }
    rescue StandardError
      nil
    end

    def payload_shape?(payload)
      payload["v"] == 1 && payload["kind"] == KIND &&
        payload["id"].is_a?(String) && HEX16.match?(payload["id"]) &&
        payload["key_id"].is_a?(String) && HEX16.match?(payload["key_id"]) &&
        payload["label"].is_a?(String) && LABEL_PATTERN.match?(payload["label"]) &&
        payload["issued_at"].is_a?(String) && !Time.iso8601(payload["issued_at"]).nil?
    rescue ArgumentError
      false
    end

    def verify(code)
      parsed = parse(code)
      return [nil, "malformed"] unless parsed

      payload = parsed["payload"]
      return [nil, "malformed"] unless payload_shape?(payload)

      return [nil, "keyring_unavailable"] unless Reach::InstructorKeyring.available?

      key = pinned_public_key(payload["key_id"])
      return [nil, "key_unpinned"] unless key
      return [nil, "signature"] unless Reach::Crypto.verify_pss(key, parsed["signature"], "#{PREFIX}.#{parsed['segment']}")
      return [nil, "revoked"] if revoked_ids.include?(payload["id"])

      [payload, nil]
    rescue StandardError
      [nil, "malformed"]
    end

    def verify_fresh(code)
      @refusal = nil
      Reach::InstructorKeyring.refresh_if_stale!(quick: true) if attempt?(code)
      payload, reason = verify(code)
      @refusal = reason unless payload
      [payload, reason]
    end

    def accept(code)
      payload, reason = verify_fresh(code)
      unless payload
        log("instructor.refused", "reason" => reason)
        return nil
      end

      record = { "code" => code.to_s.strip, "payload" => payload, "unlocked_at" => Time.now.utc.iso8601 }
      Reach::Login.write_json(stored_file, record)
      begin
        File.chmod(0o600, stored_file)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
      log("instructor.unlocked", "code_id" => payload["id"], "key_id" => payload["key_id"])
      record
    end

    def unlock!(code, session_id: nil, harness: nil)
      return unlock_enrolled!(code, session_id, harness) if Reach::Enroll.current

      record = accept(code)
      return nil unless record

      { "record" => record, "enrolled" => false }
    end

    def unlock_enrolled!(code, session_id, harness)
      payload, reason = verify_fresh(code)
      unless payload
        log("instructor.refused", "reason" => reason)
        return nil
      end

      cleared = Reach::Login.clear_lockouts.merge("enroll_lockout" => Reach::EnrollFlow.clear_lockout!)
      target = session_id.to_s.empty? ? nil : session_id.to_s
      if target.nil?
        waiting = Reach::Login.waiting_session
        target = waiting && waiting["session_id"]
        harness = waiting["harness"] if waiting && harness.to_s.empty?
      end
      granted = nil
      if target
        Reach::Login.sign_in_session(target, harness)
        granted = grant_pass!(payload, target)
      end
      log("instructor.signed_in", "code_id" => payload["id"], "key_id" => payload["key_id"], "session_id" => target, "cleared" => cleared, "pass_expires_at" => granted && granted["expires_at"])
      { "enrolled" => true, "session_id" => target, "cleared" => cleared }
    end

    def pass_file
      File.join(Reach::Paths.root_state_dir, "instructor_passes.json")
    end

    def read_passes
      data = Reach::Login.read_json(pass_file)
      Array(data.is_a?(Hash) ? data["passes"] : nil).select { |entry| entry.is_a?(Hash) }
    end

    def pass_secret(create: false)
      key_file = Reach::Paths.install_key_file
      return Digest::SHA256.digest("#{PASS_KEY_LABEL}\n#{File.binread(key_file)}") if File.file?(key_file)

      path = File.join(Reach::Paths.root_state_dir, "instructor_pass.key")
      return File.binread(path) if File.file?(path)
      return nil unless create

      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(SecureRandom.random_bytes(32)) }
      File.binread(path)
    rescue Errno::EEXIST
      File.binread(path)
    end

    def pass_mac(entry, secret)
      fields = %w[session_id code_id key_id granted_at expires_at].map { |name| entry[name].to_s }
      OpenSSL::HMAC.hexdigest("SHA256", secret, ([PASS_KEY_LABEL] + fields).join("\n"))
    end

    def pass_authentic?(entry)
      secret = pass_secret
      return false unless secret && entry["mac"].is_a?(String)

      Reach::EnrollFlow.digest_equal?(pass_mac(entry, secret), entry["mac"])
    rescue StandardError
      false
    end

    def pass_live?(entry, now = Time.now.utc)
      granted = Time.iso8601(entry["granted_at"].to_s)
      expires = Time.iso8601(entry["expires_at"].to_s)
      expires > now && granted <= now + PASS_SKEW_S && expires - granted <= Reach::Login.max_hours * 3600 && pass_authentic?(entry)
    rescue ArgumentError
      false
    end

    def grant_pass!(payload, session_id)
      now = Time.now.utc
      secret = pass_secret(create: true)
      return nil unless secret

      record = {
        "session_id" => session_id.to_s, "code_id" => payload["id"], "key_id" => payload["key_id"],
        "granted_at" => now.iso8601, "expires_at" => (now + (Reach::Login.max_hours * 3600)).iso8601
      }
      record["mac"] = pass_mac(record, secret)
      live = read_passes.reject { |entry| entry["session_id"] == record["session_id"] || !pass_live?(entry, now) }
      Reach::Login.write_json(pass_file, "passes" => (live + [record]).last(PASSES_KEPT))
      File.chmod(0o600, pass_file)
      record
    rescue StandardError
      nil
    end

    def pass_for(session_id)
      sid = session_id.to_s
      return nil if sid.empty?

      entry = read_passes.find { |candidate| candidate["session_id"] == sid }
      return nil unless entry && pass_live?(entry)
      return nil unless pinned_public_key(entry["key_id"])
      return nil if revoked_ids.include?(entry["code_id"].to_s)

      entry
    rescue StandardError
      nil
    end

    def root_enrolled?
      path = File.join(Reach::Paths.root, "install.yml")
      File.file?(path) && !YAML.safe_load(File.read(path)).nil?
    rescue StandardError
      false
    end

    def backup_without_code(data)
      backup_dir = File.join(File.dirname(stored_file), ".backup")
      FileUtils.mkdir_p(backup_dir)
      target = File.join(backup_dir, "instructor-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}.json")
      Reach::Login.write_json(target, (data || {}).reject { |key, _| DROPPED_FIELDS.include?(key) })
      target
    end

    def retire_stored!(event, fields = {})
      return nil unless File.file?(stored_file)

      data = stored
      target = begin
        backup_without_code(data)
      rescue StandardError
        nil
      end
      FileUtils.rm_f(stored_file)
      payload = data && data["payload"].is_a?(Hash) ? data["payload"] : {}
      log(event, { "code_id" => payload["id"], "key_id" => payload["key_id"] }.merge(fields))
      target
    end

    def drop_enrolled_code!
      return false unless File.file?(stored_file) && root_enrolled?

      retire_stored!("instructor.invalidated", "reason" => "enrolled_install")
      true
    rescue StandardError
      false
    end

    def scrub_enrolled_backups!
      return 0 unless root_enrolled?

      Dir.glob(File.join(File.dirname(stored_file), ".backup", "instructor-*.json")).count do |path|
        data = Reach::Login.read_json(path)
        next false unless data.is_a?(Hash) && DROPPED_FIELDS.any? { |key| data.key?(key) }

        payload = data["payload"].is_a?(Hash) ? data["payload"] : {}
        begin
          Reach::Login.write_json(path, data.reject { |key, _| DROPPED_FIELDS.include?(key) })
        rescue StandardError => e
          log("instructor.backup_scrub_failed", "code_id" => payload["id"], "key_id" => payload["key_id"], "file" => File.basename(path), "error" => e.class.name)
          next false
        end
        log("instructor.backup_scrubbed", "code_id" => payload["id"], "key_id" => payload["key_id"])
        true
      end
    rescue StandardError
      0
    end

    def stored
      data = Reach::Login.read_json(stored_file)
      data.is_a?(Hash) ? data : nil
    end

    def current
      data = stored
      return nil unless data
      return nil if drop_enrolled_code!

      payload, reason = verify(data["code"])
      if payload
        mark(data, nil) if data["invalid_reason"]
        return data.merge("payload" => payload)
      end

      unless data["invalid_reason"] == reason
        log("instructor.invalidated", "code_id" => (data["payload"].is_a?(Hash) ? data["payload"]["id"] : nil), "key_id" => (data["payload"].is_a?(Hash) ? data["payload"]["key_id"] : nil), "reason" => reason)
        mark(data, reason)
      end
      nil
    rescue StandardError
      nil
    end

    def mark(data, reason)
      updated = data.reject { |key, _| key == "invalid_reason" }
      updated["invalid_reason"] = reason if reason
      Reach::Login.write_json(stored_file, updated)
    rescue StandardError
      nil
    end

    def active?
      !current.nil?
    end

    def mode?
      active? && Reach::Enroll.current.nil?
    rescue StandardError
      false
    end

    def lock!
      return nil unless File.file?(stored_file)

      retire_stored!("instructor.relocked")
    end

    def status
      data = current
      return { "unlocked" => false } unless data

      payload = data["payload"]
      {
        "unlocked" => true, "code_id" => payload["id"], "label" => payload["label"],
        "key_id" => payload["key_id"], "unlocked_at" => data["unlocked_at"]
      }
    end

    def context_once(session_id)
      session = session_id.to_s
      data = Reach::Login.read_json(context_file)
      seen = Array(data.is_a?(Hash) ? data["sessions"] : nil)
      return nil if seen.include?(session)

      seen = (seen + [session]).last(CONTEXT_SESSIONS_KEPT)
      Reach::Login.write_json(context_file, { "sessions" => seen })
      Reach::Messages.text("M-INSTRUCTOR-CONTEXT")
    rescue StandardError
      nil
    end
  end
end
