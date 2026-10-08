require "json"
require "base64"
require "time"
require "fileutils"

module Reach
  module Stamp
    SCHEMA = "teach.enrollment-stamp/v1".freeze
    FIELDS = %w[schema stamp_id install_id student_id username course_id fingerprint_digest fingerprint_strict_digest issued_at expires_at signing_key_id signature].freeze
    EXPECTED = %w[install_id student_id username course_id fingerprint_digest fingerprint_strict_digest].freeze

    module_function

    def verify!(stamp, signing_public_keys:, expect: {})
      raise Reach::VerificationFailed, "reach: enrollment stamp is malformed" unless stamp.is_a?(Hash)
      raise Reach::VerificationFailed, "reach: enrollment stamp has the wrong schema" unless stamp["schema"] == SCHEMA
      raise Reach::VerificationFailed, "reach: enrollment stamp is incomplete" unless FIELDS.all? { |field| !stamp[field].to_s.empty? }
      raise Reach::VerificationFailed, "reach: enrollment stamp has a malformed id" unless stamp["stamp_id"] =~ /\Astm_[0-9a-f]{20}\z/

      unsigned = stamp.reject { |key, _| key == "signature" }
      key = Array(signing_public_keys.is_a?(Hash) ? signing_public_keys.values : signing_public_keys).find do |item|
        item.is_a?(Hash) && item["key_id"] == stamp["signing_key_id"]
      end
      public_key = key ? Reach::Crypto.load_public_key(key["pem"]) : nil
      valid = begin
        public_key && Reach::Crypto.verify_pss(public_key, Base64.strict_decode64(stamp["signature"]), Reach::Crypto.canonical_json(unsigned))
      rescue ArgumentError, OpenSSL::PKey::PKeyError
        false
      end
      raise Reach::VerificationFailed, "reach: enrollment stamp signature does not verify" unless valid

      EXPECTED.each do |field|
        next unless expect.key?(field.to_sym) || expect.key?(field)

        wanted = expect.key?(field.to_sym) ? expect[field.to_sym] : expect[field]
        raise Reach::VerificationFailed, "reach: enrollment stamp #{field} does not match" unless stamp[field].to_s == wanted.to_s
      end
      stamp
    end

    def expired?(stamp, now = Time.now.utc)
      Time.iso8601(stamp["expires_at"].to_s) <= now
    rescue ArgumentError
      true
    end

    def store!(stamp)
      path = Reach::Paths.stamp_file
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(stamp)) }
      Reach::StateFile.rename_into_place(tmp, path)
      path
    end

    def current
      return nil unless File.file?(Reach::Paths.stamp_file)

      data = JSON.parse(File.read(Reach::Paths.stamp_file))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def drop!
      path = Reach::Paths.stamp_file
      return nil unless File.exist?(path)

      target = "#{path}.dropped-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
      File.rename(path, target)
      target
    rescue StandardError
      nil
    end
  end
end
