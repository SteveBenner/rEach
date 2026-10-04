# frozen_string_literal: true

require "base64"
require "etc"
require "fileutils"
require "json"
require "securerandom"
require "socket"

module Reach
  module Deidentify
    SCHEMA = "reach.identity/v1"
    TEXT_FIELDS = %w[text summary note].freeze
    DIGEST_KINDS = %w[prompt reply reasoning code].freeze
    MIN_LENGTH = 3
    MAX_VALUE_BYTES = 1024
    WORD = /[\p{L}\p{N}]/.freeze

    module_function

    def pseudonym_path
      File.join(Reach::Paths.state_dir, "pseudonym.json")
    end

    def pseudonym(install)
      path = pseudonym_path
      stored = begin
        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end
      if stored.is_a?(Hash) && stored["install_id"] == install["install_id"] && stored["pseudonym"].to_s.match?(/\Aanon_[0-9a-f]{32}\z/)
        return stored["pseudonym"]
      end

      value = "anon_#{SecureRandom.hex(16)}"
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate("install_id" => install["install_id"], "pseudonym" => value))
      end
      value
    end

    def identity_key(status)
      key = status.is_a?(Hash) && status["transcripts"].is_a?(Hash) ? status["transcripts"]["identity_key"] : nil
      return nil unless key.is_a?(Hash) && key["key_id"].is_a?(String) && key["pem"].is_a?(String)

      key
    end

    def display_name(install, status)
      student = status.is_a?(Hash) ? status["student"] : nil
      name = student.is_a?(Hash) ? student["display_name"] : nil
      (name || install["display_name"]).to_s.strip
    end

    def account_name
      (Etc.getlogin || ENV["USER"] || ENV["USERNAME"]).to_s
    rescue StandardError
      ""
    end

    def home_folder
      Dir.home.to_s
    rescue StandardError
      ""
    end

    def computer_name
      Socket.gethostname.to_s
    rescue StandardError
      ""
    end

    def identifiers(install, status)
      name = display_name(install, status)
      username = install["username"].to_s.strip
      list = [["[[home-folder]]", home_folder], ["[[student-name]]", name], ["[[student-email]]", username]]
      list << ["[[student-username]]", username.split("@", 2).first.to_s] if username.include?("@")
      list << ["[[student-id]]", install["student_id"].to_s]
      name.split(/\s+/).map { |part| part.gsub(/\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+\z/, "") }.uniq.each_with_index do |part, index|
        list << ["[[student-name-#{index + 1}]]", part]
      end
      list << ["[[computer-account]]", account_name]
      list << ["[[computer-name]]", computer_name]
      list.select { |_token, value| value.length >= MIN_LENGTH && value.bytesize <= MAX_VALUE_BYTES }
    end

    def surfaces(token, value)
      forms = [value]
      if token == "[[home-folder]]" && value.include?("\\")
        forms << value.tr("\\", "/")
        forms << value.gsub("\\", "\\\\\\\\")
      end
      forms
    end

    def scrubber(install, status)
      placeholders = {}
      lookup = {}
      identifiers(install, status).each do |token, value|
        surfaces(token, value).each do |form|
          key = form.downcase
          next if lookup.key?(key)

          lookup[key] = token
          placeholders[token] ||= value
        end
      end
      forms = lookup.keys.sort_by { |form| [-form.length, form] }
      { "regexp" => forms.empty? ? nil : Regexp.new(forms.map { |form| pattern(form) }.join("|"), Regexp::IGNORECASE),
        "lookup" => lookup, "placeholders" => placeholders }
    end

    def pattern(form)
      head = form[0].match?(WORD) ? "(?<![\\p{L}\\p{N}])" : ""
      tail = form[-1].match?(WORD) ? "(?![\\p{L}\\p{N}])" : ""
      "#{head}#{Regexp.escape(form)}#{tail}"
    end

    def scrub(text, scrubber)
      regexp = scrubber["regexp"]
      return text if regexp.nil? || !text.is_a?(String)

      text.gsub(regexp) { |found| scrubber["lookup"].fetch(found.downcase, found) }
    end

    def entry(entry, scrubber)
      result = entry.dup
      original = entry["text"]
      TEXT_FIELDS.each { |field| result[field] = scrub(entry[field], scrubber) if entry[field].is_a?(String) }
      result["source_digest"] = entry["digest"] if entry["kind"] == "prompt"
      return result unless DIGEST_KINDS.include?(entry["kind"].to_s) && original.is_a?(String) && result["text"] != original

      text = result["text"]
      full = text.bytesize
      if entry["truncated"] == true
        text = Reach::Transcript.truncate_to_bytes(text, Reach::Transcript::MAX_TEXT_BYTES) if full > Reach::Transcript::MAX_TEXT_BYTES
        result["text"] = text
        result["bytes"] = [entry["bytes"].to_i, text.bytesize].max
      elsif full > Reach::Transcript::MAX_TEXT_BYTES
        result["text"] = Reach::Transcript.truncate_to_bytes(text, Reach::Transcript::MAX_TEXT_BYTES)
        result["truncated"] = true
        result["bytes"] = full
        result["digest"] = Reach::Crypto.digest_hex(text)
      else
        result["bytes"] = full
        result["digest"] = Reach::Crypto.digest_hex(text)
      end
      result
    end

    def seal(install, key, pseudonym, placeholders)
      plaintext = Reach::Crypto.canonical_json(
        "install_id" => install["install_id"], "placeholders" => placeholders, "student_id" => install["student_id"]
      )
      aad = Reach::Crypto.canonical_json("schema" => SCHEMA, "key_id" => key["key_id"], "pseudonym" => pseudonym)
      sealed = Reach::Crypto.encrypt_gcm(plaintext, aad: aad)
      wrapped = Reach::Crypto.wrap_key(Reach::Crypto.load_public_key(key["pem"]), sealed[:key])
      {
        "schema" => SCHEMA, "key_id" => key["key_id"],
        "wrapped_key" => Base64.strict_encode64(wrapped), "nonce" => Base64.strict_encode64(sealed[:nonce]),
        "ciphertext" => Base64.strict_encode64(sealed[:ciphertext]), "tag" => Base64.strict_encode64(sealed[:tag])
      }
    end

    def envelope(install, status)
      key = identity_key(status)
      return nil if key.nil?

      rules = scrubber(install, status)
      name = pseudonym(install)
      { "pseudonym" => name, "identity" => seal(install, key, name, rules["placeholders"]), "scrubber" => rules }
    end
  end
end
