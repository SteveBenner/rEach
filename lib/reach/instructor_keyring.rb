require "json"
require "base64"
require "time"
require "openssl"

module Reach
  module InstructorKeyring
    SCHEMA = "teach.instructor-keyring/v1".freeze
    ROUTE = "/api/v1/instructor/keyring".freeze
    DEFAULT_REFRESH_S = 900
    HEX16 = /\A[0-9a-f]{16}\z/.freeze
    CODE_ID = /\A[0-9a-f]{16}\z/.freeze
    REVISION = /\A[0-9a-f]{64}\z/.freeze
    TOP_FIELDS = %w[schema revision issued_at keys retired_key_ids revoked_code_ids signing_key_id signature].freeze

    module_function

    def cache_file
      File.join(Reach::Paths.root_state_dir, "instructor_keyring.json")
    end

    def refresh_s
      section = Reach::Runtime.load_config["instructor"]
      value = section.is_a?(Hash) ? section["keyring_refresh_s"] : nil
      number = Integer(value)
      number.positive? ? number : DEFAULT_REFRESH_S
    rescue StandardError
      DEFAULT_REFRESH_S
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def signing_keys
      install = Reach::Enroll.current
      list = install.is_a?(Hash) ? Array(install["signing_public_keys"]) : []
      list.select { |item| item.is_a?(Hash) && item["key_id"].to_s != "" && item["pem"].to_s != "" }
    rescue StandardError
      []
    end

    def string_list?(value, pattern)
      value.is_a?(Array) && value.all? { |item| item.is_a?(String) && pattern.match?(item) }
    end

    def key_entry?(entry)
      return false unless entry.is_a?(Hash)
      return false unless entry["key_id"].is_a?(String) && HEX16.match?(entry["key_id"])
      return false unless entry["label"].is_a?(String) && entry["public_key_pem"].is_a?(String)

      Reach::Instructor.key_id_for(Reach::Crypto.load_public_key(entry["public_key_pem"])) == entry["key_id"]
    rescue StandardError
      false
    end

    def well_formed?(body)
      return false unless body.is_a?(Hash) && body["schema"] == SCHEMA
      return false unless TOP_FIELDS.all? { |field| body.key?(field) }
      return false unless body["revision"].is_a?(String) && REVISION.match?(body["revision"])
      return false unless body["issued_at"].is_a?(String) && !Time.iso8601(body["issued_at"]).nil?
      return false unless body["keys"].is_a?(Array) && body["keys"].all? { |entry| key_entry?(entry) }
      return false unless string_list?(body["retired_key_ids"], HEX16) && string_list?(body["revoked_code_ids"], CODE_ID)
      return false unless body["signing_key_id"].is_a?(String) && body["signature"].is_a?(String)

      true
    rescue ArgumentError
      false
    end

    def signature_ok?(body, keys)
      return true if keys.empty?

      entry = keys.find { |item| item["key_id"] == body["signing_key_id"] }
      return false unless entry

      public_key = Reach::Crypto.load_public_key(entry["pem"])
      unsigned = body.reject { |key, _| key == "signature" }
      Reach::Crypto.verify_pss(public_key, Base64.strict_decode64(body["signature"]), Reach::Crypto.canonical_json(unsigned))
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      false
    end

    def acceptable?(body)
      well_formed?(body) && signature_ok?(body, signing_keys)
    end

    def read_cache
      data = Reach::Login.read_json(cache_file)
      return nil unless data.is_a?(Hash) && data["keyring"].is_a?(Hash)

      data
    end

    def cache
      path = cache_file
      return nil unless File.file?(path)

      stat = File.stat(path)
      keys = signing_keys.map { |item| item["key_id"] }.sort
      token = [path, stat.mtime.to_f, stat.size, keys]
      return @memo[1] if @memo && @memo[0] == token

      data = read_cache
      data = nil unless data && acceptable?(data["keyring"])
      @memo = [token, data]
      data
    rescue StandardError
      nil
    end

    def forget!
      @memo = nil
    end

    def keyring
      data = cache
      data ? data["keyring"] : nil
    end

    def available?
      !keyring.nil?
    end

    def keys
      body = keyring
      return [] unless body

      retired = body["retired_key_ids"]
      body["keys"].reject { |entry| retired.include?(entry["key_id"]) }.map do |entry|
        { "id" => entry["key_id"], "label" => entry["label"], "public_key_pem" => entry["public_key_pem"] }
      end
    end

    def revoked_ids
      body = keyring
      body ? body["revoked_code_ids"].dup : []
    end

    def age_s
      data = cache
      return nil unless data

      (Time.now - Time.iso8601(data["fetched_at"].to_s)).to_i
    rescue StandardError
      nil
    end

    def stale?
      age = age_s
      age.nil? || age > refresh_s
    end

    def older_than_cache?(body)
      data = cache
      return false unless data

      Time.iso8601(body["issued_at"]) < Time.iso8601(data["keyring"]["issued_at"])
    rescue StandardError
      false
    end

    def store!(data)
      Reach::Login.write_json(cache_file, data)
      File.chmod(0o600, cache_file)
      forget!
    rescue NotImplementedError, Errno::ENOENT
      forget!
    end

    def reject!(reason, fields = {})
      Reach::Instructor.log("instructor.keyring_rejected", { "reason" => reason }.merge(fields))
      nil
    end

    def fetch!(quick: true)
      base = Reach::Runtime.default_teach_url
      return nil if base.to_s.empty?

      current = cache
      headers = {}
      headers["If-None-Match"] = "\"#{current['keyring']['revision']}\"" if current
      client = Reach::Client.anonymous(base, quick: quick, link: false)
      response = client.get(ROUTE, headers: headers)
      if response.status == 304
        store!(current.merge("fetched_at" => now_s)) if current
        return current
      end
      return nil unless response.status == 200

      body = response.json
      return reject!("malformed") unless well_formed?(body)
      return reject!("signature", "signing_key_id" => body["signing_key_id"]) unless signature_ok?(body, signing_keys)
      return reject!("rollback", "issued_at" => body["issued_at"]) if older_than_cache?(body)

      data = { "fetched_at" => now_s, "keyring" => body }
      store!(data)
      data
    rescue StandardError
      nil
    end

    def refresh_if_stale!(quick: true)
      fetch!(quick: quick) if stale?
      nil
    rescue StandardError
      nil
    end

    def summary
      data = cache
      return nil unless data

      body = data["keyring"]
      {
        "revision" => body["revision"], "issued_at" => body["issued_at"], "age_s" => age_s,
        "key_ids" => keys.map { |entry| entry["id"] }, "retired_key_ids" => body["retired_key_ids"].dup,
        "revoked_code_ids" => body["revoked_code_ids"].dup
      }
    end
  end
end
