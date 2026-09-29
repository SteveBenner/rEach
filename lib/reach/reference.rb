require "json"
require "openssl"
require "zlib"

module Reach
  module Reference
    MAGIC = "RREF".b.freeze
    FORMAT_VERSION = 1
    KEYS_ENTRY = "reference-keys.json".freeze
    KEYS_SCHEMA = "reach.reference-keys/v1".freeze
    SCHEMA = "reach.reference/v1".freeze
    MAX_BLOB_BYTES = 20 * 1024 * 1024
    MAX_PLAINTEXT_BYTES = 64 * 1024 * 1024
    MAX_FILES = 2000
    NONCE_BYTES = 12
    TAG_BYTES = 16
    INFLATE_CHUNK = 16 * 1024
    KEY_ID_PATTERN = /\A[a-z0-9-]{8,64}\z/.freeze
    COURSE_PATTERN = /\A[a-z0-9-]{1,64}\z/.freeze
    MEDIA_TYPES = ["text/markdown", "text/plain"].freeze
    MAX_MATCHES_PER_FILE = 3

    module_function

    def dir
      value = ENV["REACH_REFERENCE_DIR"].to_s
      File.expand_path(value.empty? ? File.join(Reach::Runtime.root, "corpus", "course-reference") : value)
    end

    def blob_paths
      return [] unless File.directory?(dir)

      Dir.glob(File.join(dir, "*.rref")).sort
    end

    def keys
      Reach::Guardrails.ensure_current
      path = File.join(Reach::Paths.guardrails_vault_dir, KEYS_ENTRY)
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      return {} unless data.is_a?(Hash) && data["schema"] == KEYS_SCHEMA

      held = {}
      Array(data["keys"]).each do |entry|
        next unless entry.is_a?(Hash) && entry["key_id"].to_s =~ KEY_ID_PATTERN

        key = entry["key_b64"].to_s.unpack("m0").first
        held[entry["key_id"]] = key if key.bytesize == 32
      end
      held
    rescue JSON::ParserError, ArgumentError
      {}
    end

    def parse_header(bytes)
      raise Reach::VerificationFailed, refused_text("too short") if bytes.bytesize < 4 + 1 + 1 + 1 + NONCE_BYTES + TAG_BYTES
      raise Reach::VerificationFailed, refused_text("not a reference file") unless bytes.byteslice(0, 4) == MAGIC
      raise Reach::VerificationFailed, refused_text("unknown format version") unless bytes.getbyte(4) == FORMAT_VERSION

      offset = 5
      key_id_length = bytes.getbyte(offset)
      offset += 1
      key_id = bytes.byteslice(offset, key_id_length).to_s
      offset += key_id_length
      course_length = bytes.getbyte(offset).to_i
      offset += 1
      course = bytes.byteslice(offset, course_length).to_s
      offset += course_length

      raise Reach::VerificationFailed, refused_text("bad key id") unless key_id =~ KEY_ID_PATTERN
      raise Reach::VerificationFailed, refused_text("bad course") unless course =~ COURSE_PATTERN
      raise Reach::VerificationFailed, refused_text("too short") if bytes.bytesize < offset + NONCE_BYTES + TAG_BYTES

      {
        "key_id" => key_id,
        "course" => course,
        "aad" => bytes.byteslice(0, offset),
        "nonce" => bytes.byteslice(offset, NONCE_BYTES),
        "tag" => bytes.byteslice(offset + NONCE_BYTES, TAG_BYTES),
        "ciphertext" => bytes.byteslice(offset + NONCE_BYTES + TAG_BYTES, bytes.bytesize - offset - NONCE_BYTES - TAG_BYTES)
      }
    end

    def decrypt(header, key)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = key
      cipher.iv = header["nonce"]
      cipher.auth_tag = header["tag"]
      cipher.auth_data = header["aad"]
      cipher.update(header["ciphertext"]) + cipher.final
    rescue OpenSSL::Cipher::CipherError
      raise Reach::VerificationFailed, refused_text("failed its integrity check")
    end

    def inflate(compressed)
      inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
      output = "".b
      offset = 0
      while offset < compressed.bytesize
        output << inflater.inflate(compressed.byteslice(offset, INFLATE_CHUNK))
        offset += INFLATE_CHUNK
        raise Reach::VerificationFailed, refused_text("too large") if output.bytesize > MAX_PLAINTEXT_BYTES
      end
      raise Reach::VerificationFailed, refused_text("truncated") unless inflater.finished?

      output
    rescue Zlib::Error
      raise Reach::VerificationFailed, refused_text("corrupt")
    ensure
      inflater.close if inflater && !inflater.closed?
    end

    def validate(document, header)
      raise Reach::VerificationFailed, refused_text("bad content") unless document.is_a?(Hash) && document["schema"] == SCHEMA
      raise Reach::VerificationFailed, refused_text("course mismatch") unless document["course"] == header["course"]

      files = document["files"]
      links = document["links"]
      raise Reach::VerificationFailed, refused_text("bad content") unless files.is_a?(Array) && links.is_a?(Array)
      raise Reach::VerificationFailed, refused_text("too many files") if files.size > MAX_FILES

      files.each do |file|
        ok = file.is_a?(Hash) && file["path"].is_a?(String) && file["title"].is_a?(String) &&
             file["text"].is_a?(String) && MEDIA_TYPES.include?(file["media_type"])
        raise Reach::VerificationFailed, refused_text("bad content") unless ok
      end
      links.each do |link|
        raise Reach::VerificationFailed, refused_text("bad content") unless link.is_a?(Hash) && link["title"].is_a?(String) && link["url"].is_a?(String)
      end
      document
    end

    def open_blob(path, held_keys)
      raise Reach::VerificationFailed, refused_text("too large") if File.size(path) > MAX_BLOB_BYTES

      header = parse_header(File.binread(path))
      key = held_keys[header["key_id"]]
      return { "locked" => true, "course" => header["course"], "name" => File.basename(path) } unless key

      plaintext = inflate(decrypt(header, key))
      document = JSON.parse(plaintext.force_encoding(Encoding::UTF_8))
      validate(document, header)
      document
    rescue JSON::ParserError
      raise Reach::VerificationFailed, refused_text("corrupt")
    end

    def refused_text(reason)
      Reach::Messages.text("M-REFERENCE-REFUSED", reason: reason)
    end

    def documents
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROL") unless Reach::Enrol.current

      paths = blob_paths
      raise Reach::Refused, Reach::Messages.text("M-REFERENCE-NONE") if paths.empty?

      held = keys
      opened = []
      locked = 0
      paths.each do |path|
        begin
          document = open_blob(path, held)
        rescue Reach::VerificationFailed => e
          raise Reach::VerificationFailed, "#{File.basename(path)}: #{e.message}"
        end
        if document["locked"]
          locked += 1
        else
          opened << document
        end
      end
      raise Reach::Refused, Reach::Messages.text("M-REFERENCE-LOCKED") if opened.empty? && locked.positive?

      opened
    end

    def list
      documents.flat_map do |document|
        document["files"].map { |file| "#{document['course']}  #{file['path']}  #{file['title']}" }
      end
    end

    def show(path)
      documents.each do |document|
        file = document["files"].find { |candidate| candidate["path"] == path }
        return file["text"] if file
      end
      raise Reach::Refused, Reach::Messages.text("M-REFERENCE-UNKNOWN", path: path)
    end

    def search(terms)
      needles = Array(terms).map { |term| term.to_s.downcase }.reject(&:empty?)
      raise Reach::Refused, Reach::Messages.text("M-REFERENCE-NOTERMS") if needles.empty?

      results = []
      documents.each do |document|
        document["files"].each do |file|
          haystack = file["text"].downcase
          next unless needles.all? { |needle| haystack.include?(needle) }

          lines = file["text"].each_line.map(&:strip).select do |line|
            downcased = line.downcase
            needles.any? { |needle| downcased.include?(needle) }
          end
          results << { "path" => file["path"], "lines" => lines.first(MAX_MATCHES_PER_FILE) }
        end
      end
      results
    end

    def links
      documents.flat_map do |document|
        document["links"].map { |link| "#{link['title']}  #{link['url']}  #{link['licence']}" }
      end
    end

    def format_search(results)
      return Reach::Messages.text("M-REFERENCE-NOMATCH") if results.empty?

      results.map do |result|
        ([result["path"]] + result["lines"].map { |line| "  #{line}" }).join("\n")
      end.join("\n")
    end
  end
end
