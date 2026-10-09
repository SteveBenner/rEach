# frozen_string_literal: true

require "base64"
require "etc"
require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "socket"

module Reach
  module Deidentify
    SCHEMA = "reach.identity/v1"
    TEXT_FIELDS = %w[text summary note path scope].freeze
    NAME_PART_LENGTH = 2
    SCOPE_VALUE_LIMIT = 512
    DIGEST_KINDS = %w[prompt reply reasoning output code].freeze
    MIN_LENGTH = 3
    MAX_VALUE_BYTES = 1024
    TOKEN = /\[\[[a-z0-9-]{1,40}\]\]/.freeze
    FIELD_LIMITS = { "text" => 131_072, "summary" => 2000, "note" => 200, "path" => 2048, "scope" => 2048 }.freeze
    WORD = /[\p{L}\p{N}]/.freeze

    module_function

    def pseudonym_path
      File.join(Reach::Paths.state_dir, "pseudonym.json")
    end

    def state(install)
      path = pseudonym_path
      stored = begin
        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end
      if stored.is_a?(Hash) && stored["install_id"] == install["install_id"] &&
         stored["pseudonym"].to_s.match?(/\Aanon_[0-9a-f]{32}\z/) && stored["restore_key"].to_s.match?(/\A[0-9a-f]{64}\z/)
        return stored
      end

      kept = stored.is_a?(Hash) && stored["install_id"] == install["install_id"] && stored["pseudonym"].to_s.match?(/\Aanon_[0-9a-f]{32}\z/)
      fresh = {
        "install_id" => install["install_id"],
        "pseudonym" => kept ? stored["pseudonym"] : "anon_#{SecureRandom.hex(16)}",
        "restore_key" => SecureRandom.hex(Reach::Crypto::AES_KEY_BYTES)
      }
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(fresh))
        file.flush
        file.fsync
      end
      File.rename(tmp, path)
      fresh
    end

    def pseudonym(install)
      state(install)["pseudonym"]
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

    def other_home_folder
      return "" unless Reach::Paths.windows_host?

      value = Reach::Paths.windows_slashes(ENV["HOME"])
      return "" if value.empty? || value.casecmp(Reach::Paths.user_home.to_s).zero?

      value
    rescue StandardError
      ""
    end

    def home_folder
      Reach::Paths.user_home.to_s
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
      other = other_home_folder
      list << ["[[home-folder-env]]", other] unless other.empty?
      list << ["[[computer-account]]", account_name]
      list << ["[[computer-name]]", computer_name]
      list.select do |token, value|
        floor = token.start_with?("[[student-name-") ? NAME_PART_LENGTH : MIN_LENGTH
        value.length >= floor && value.bytesize <= MAX_VALUE_BYTES
      end
    end

    def surfaces(token, value)
      forms = [value]
      if token.start_with?("[[home-folder")
        base = value.tr("\\", "/")
        return [] if base =~ %r{\A(?:[A-Za-z]:)?/*\z}
        forms << base
        if base =~ %r{\A[A-Za-z]:/}
          back = base.tr("/", "\\")
          forms << back
          forms << back.gsub("\\", "\\\\\\\\")
        end
        if base =~ %r{\A([A-Za-z]):/(.*)\z}m
          drive = Regexp.last_match(1).downcase
          rest = Regexp.last_match(2)
          forms << "/#{drive}/#{rest}"
          forms << "/mnt/#{drive}/#{rest}"
          forms << "/cygdrive/#{drive}/#{rest}"
        end
        if base.start_with?("//")
          back = base.tr("/", "\\")
          forms << back
          forms << back.gsub("\\", "\\\\\\\\")
        end
      end
      forms.uniq.select { |form| form.length >= NAME_PART_LENGTH }
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
      parts = ["(?<token>(?-i:#{TOKEN.source}))"] + forms.map { |form| pattern(form) }
      { "regexp" => Regexp.new(parts.join("|"), Regexp::IGNORECASE), "lookup" => lookup, "placeholders" => placeholders }
    end

    def pattern(form)
      head = form[0].match?(WORD) ? "(?<![\\p{L}\\p{N}])" : ""
      tail = form[-1].match?(WORD) ? "(?![\\p{L}\\p{N}])" : ""
      "#{head}#{Regexp.escape(form)}#{tail}"
    end

    def segments(text, scrubber)
      out = []
      position = 0
      text.scan(scrubber["regexp"]) do
        found = Regexp.last_match
        out << [text[position...found.begin(0)], nil] if found.begin(0) > position
        shown = found[:token] ? found[0] : scrubber["lookup"].fetch(found[0].downcase, found[0])
        out << [shown, found[0]]
        position = found.end(0)
      end
      out << [text[position..], nil] if position < text.length
      out
    end

    def scrub(text, scrubber, limit)
      pieces = segments(text, scrubber)
      kept = +""
      originals = []
      tail = nil
      pieces.each_with_index do |(shown, original), index|
        room = limit - kept.bytesize
        if shown.bytesize <= room
          kept << shown
          originals << original if original
          next
        end

        rest = pieces[(index + 1)..].map { |piece, source| source || piece }.join
        if original
          tail = original + rest
        else
          head = Reach::Transcript.truncate_to_bytes(shown, room)
          kept << head
          tail = shown[head.length..] + rest
        end
        break
      end
      { "text" => kept, "originals" => originals, "tail" => tail }
    end

    def seal_restore(record, restore_key, pseudonym, session_id, seq)
      aad = Reach::Crypto.canonical_json("pseudonym" => pseudonym, "seq" => seq, "session_id" => session_id)
      key = [restore_key].pack("H*")
      nonce = SecureRandom.random_bytes(Reach::Crypto::AES_IV_BYTES)
      plaintext = JSON.generate(record)
      if Reach::GCM.native_aad?
        cipher = OpenSSL::Cipher.new(Reach::Crypto::GCM_CIPHER)
        cipher.encrypt
        cipher.key = key
        cipher.iv = nonce
        cipher.auth_data = aad
        ciphertext = cipher.update(plaintext) + cipher.final
        tag = cipher.auth_tag
      else
        ciphertext, tag = Reach::GCM.encrypt(key: key, nonce: nonce, plaintext: plaintext, aad: aad)
      end
      Base64.strict_encode64(nonce + tag + ciphertext)
    end

    def entry(entry, envelope, session_id)
      entry = Reach::Redact.entry(entry)
      scrubber = envelope["scrubber"]
      result = entry.dup
      record = {}
      TEXT_FIELDS.each do |field|
        if entry[field].is_a?(Hash)
          scoped = entry[field].dup
          entry[field].each do |name, value|
            next unless value.is_a?(String)

            scrubbed = scrub(value, scrubber, SCOPE_VALUE_LIMIT)
            scoped[name] = scrubbed["text"]
            next if scrubbed["originals"].empty? && scrubbed["tail"].nil?

            record["#{field}.#{name}"] = { "o" => scrubbed["originals"], "t" => scrubbed["tail"] }
          end
          result[field] = scoped
          next
        end
        next unless entry[field].is_a?(String)

        limit = FIELD_LIMITS.fetch(field)
        limit = FIELD_LIMITS.fetch("text") if field == "summary" && entry[field].bytesize > limit
        scrubbed = scrub(entry[field], scrubber, limit)
        result[field] = scrubbed["text"]
        next if scrubbed["originals"].empty? && scrubbed["tail"].nil?

        record[field] = { "o" => scrubbed["originals"], "t" => scrubbed["tail"] }
      end
      result["source_digest"] = entry["whole_digest"] || entry["digest"] if entry["kind"] == "prompt"
      result["restore"] = record.empty? ? nil : seal_restore(record, envelope["restore_key"], envelope["pseudonym"], session_id, entry["seq"])
      original = entry["text"]
      return result unless DIGEST_KINDS.include?(entry["kind"].to_s) && original.is_a?(String) && result["text"] != original

      text = result["text"]
      tail = record["text"] && record["text"]["t"]
      if entry["truncated"] == true
        result["bytes"] = [entry["bytes"].to_i, text.bytesize].max
      elsif tail
        result["truncated"] = true
        result["bytes"] = text.bytesize + tail.bytesize
        result["digest"] = Reach::Crypto.digest_hex(text)
      else
        result["bytes"] = text.bytesize
        result["digest"] = Reach::Crypto.digest_hex(text)
      end
      result
    end

    def seal(install, key, pseudonym, placeholders, restore_key)
      plaintext = Reach::Crypto.canonical_json(
        "install_id" => install["install_id"], "placeholders" => placeholders, "restore_key" => restore_key,
        "student_id" => install["student_id"]
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
      stored = state(install)
      name = stored["pseudonym"]
      { "pseudonym" => name, "identity" => seal(install, key, name, rules["placeholders"], stored["restore_key"]),
        "restore_key" => stored["restore_key"], "scrubber" => rules }
    end
  end
end
