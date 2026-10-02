require "openssl"
require "base64"
require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Instructor
    PREFIX = "RINS1".freeze
    KIND = "reach.instructor-unlock".freeze
    KEY_BITS = 3072
    MAX_CODE_CHARS = 4096
    LABEL_MAX = 40
    CODE_PATTERN = /\ARINS1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/.freeze
    HEX16 = /\A[0-9a-f]{16}\z/.freeze
    LABEL_PATTERN = /\A[A-Za-z0-9 ._-]{0,40}\z/.freeze
    CONTEXT_SESSIONS_KEPT = 50

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

    def default_key_path
      base = ENV["XDG_CONFIG_HOME"].to_s
      base = File.join(Dir.home, ".config") if base.empty?
      File.join(File.expand_path(base), "reach-instructor", "key.pem")
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

    def generate_key
      OpenSSL::PKey::RSA.generate(KEY_BITS)
    end

    def keygen(path)
      path = File.expand_path(path)
      raise Reach::Error, Reach::Messages.text("M-INSTRUCTOR-KEY-EXISTS", path: path) if File.exist?(path)

      dir = File.dirname(path)
      existed = File.directory?(dir)
      FileUtils.mkdir_p(dir)
      File.chmod(0o700, dir) unless existed
      key = generate_key
      begin
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(key.to_pem) }
      rescue Errno::EEXIST
        raise Reach::Error, Reach::Messages.text("M-INSTRUCTOR-KEY-EXISTS", path: path)
      end
      { "path" => path, "key_id" => key_id_for(key), "public_key_pem" => key.public_key.to_pem }
    end

    def load_private(path)
      path = File.expand_path(path)
      raise Reach::Error, Reach::Messages.text("M-INSTRUCTOR-NO-KEY", path: path) unless File.file?(path)

      Reach::Crypto.load_private_key(File.read(path))
    rescue OpenSSL::PKey::PKeyError
      raise Reach::Error, Reach::Messages.text("M-INSTRUCTOR-NO-KEY", path: path)
    end

    def pinned_keys
      enrollment = Reach::Runtime.load_config["enrollment"]
      list = enrollment.is_a?(Hash) ? enrollment["instructor_keys"] : nil
      Array(list).select { |entry| entry.is_a?(Hash) }
    end

    def revoked_ids
      enrollment = Reach::Runtime.load_config["enrollment"]
      list = enrollment.is_a?(Hash) ? enrollment["instructor_revoked"] : nil
      Array(list).map { |entry| entry.is_a?(Hash) ? entry["id"].to_s : entry.to_s }
    end

    def pinned_public_key(key_id)
      entry = pinned_keys.find { |candidate| candidate["id"].to_s == key_id.to_s }
      return nil unless entry

      key = Reach::Crypto.load_public_key(entry["public_key_pem"].to_s)
      key_id_for(key) == entry["id"].to_s ? key : nil
    rescue StandardError
      nil
    end

    def clean_label(label)
      label.to_s.gsub(/[^A-Za-z0-9 ._-]/, "")[0, LABEL_MAX]
    end

    def mint(private_key, label: "")
      key_id = key_id_for(private_key)
      raise Reach::Error, Reach::Messages.text("M-INSTRUCTOR-KEY-UNPINNED", key_id: key_id) unless pinned_public_key(key_id)

      payload = {
        "v" => 1, "kind" => KIND, "id" => SecureRandom.hex(8), "key_id" => key_id,
        "label" => clean_label(label), "issued_at" => Time.now.utc.iso8601
      }
      segment = b64(Reach::Crypto.canonical_json(payload))
      signature = Reach::Crypto.sign_pss(private_key, "#{PREFIX}.#{segment}")
      "#{PREFIX}.#{segment}.#{b64(signature)}"
    end

    def b64(bytes)
      Base64.urlsafe_encode64(bytes, padding: false)
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

      key = pinned_public_key(payload["key_id"])
      return [nil, "key_unpinned"] unless key
      return [nil, "signature"] unless Reach::Crypto.verify_pss(key, parsed["signature"], "#{PREFIX}.#{parsed['segment']}")
      return [nil, "revoked"] if revoked_ids.include?(payload["id"])

      [payload, nil]
    rescue StandardError
      [nil, "malformed"]
    end

    def accept(code)
      payload, reason = verify(code)
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

    def stored
      data = Reach::Login.read_json(stored_file)
      data.is_a?(Hash) ? data : nil
    end

    def current
      data = stored
      return nil unless data

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

      data = stored
      backup_dir = File.join(File.dirname(stored_file), ".backup")
      FileUtils.mkdir_p(backup_dir)
      target = File.join(backup_dir, "instructor-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}.json")
      FileUtils.mv(stored_file, target)
      payload = data && data["payload"].is_a?(Hash) ? data["payload"] : {}
      log("instructor.relocked", "code_id" => payload["id"], "key_id" => payload["key_id"])
      target
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
