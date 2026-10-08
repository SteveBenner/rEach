require "fileutils"
require "json"

module Reach
  class Packages
    def initialize
      @install = Reach::Enroll.current
    end

    def fetch(kind)
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless @install

      current = latest_stored_envelope(kind)
      headers = {}
      headers["If-None-Match"] = "\"#{current['header']['content_digest']}\"" if current

      response = client.get("/api/v1/packages/#{kind}", headers: headers)

      case response.status
      when 304
        :current
      else
        envelope = response.json
        open_and_store(kind, envelope)
        :updated
      end
    rescue Reach::RemoteRefused => e
      return :absent if e.code == "not_found"

      raise
    end

    def latest_version(kind)
      dir = Reach::Paths.packages_dir(kind)
      return nil unless File.directory?(dir)

      versions = Dir.children(dir).select { |name| name.end_with?(".pkg") }.map { |name| name.sub(/\.pkg\z/, "").to_i }
      versions.max
    end

    def stored_envelope(kind, version)
      path = File.join(Reach::Paths.packages_dir(kind), "#{version}.pkg")
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      quarantine(path)
      nil
    end

    def open(kind, version)
      envelope = stored_envelope(kind, version)
      raise Reach::Error, "reach: no stored package #{kind}/#{version}" unless envelope

      header, plaintext = open_envelope(kind, envelope)
      [header, Reach::Tarball.read(plaintext)]
    end

    def unpack(kind, version, into:, skip: [])
      _header, entries = open(kind, version)
      FileUtils.rm_rf(into)
      FileUtils.mkdir_p(into, mode: 0o700)
      entries.each do |relative_path, contents|
        next if skip.any? { |prefix| relative_path.start_with?(prefix) }

        full_path = File.join(into, relative_path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.open(full_path, "wb") { |f| f.write(contents) }
      end
      into
    end

    private

    def latest_stored_envelope(kind)
      version = latest_version(kind)
      return nil unless version

      stored_envelope(kind, version)
    end

    def open_and_store(kind, envelope)
      header, _plaintext = open_envelope(kind, envelope)
      dir = Reach::Paths.packages_dir(kind)
      FileUtils.mkdir_p(dir)
      final = File.join(dir, "#{header['version']}.pkg")
      temp = "#{final}.tmp.#{Process.pid}"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |handle|
        handle.write(JSON.generate(envelope))
        handle.flush
        handle.fsync
      end
      File.rename(temp, final)
    end

    def quarantine(path)
      File.rename(path, "#{path}.corrupt-#{Time.now.to_i}")
    rescue SystemCallError
      nil
    end

    def open_envelope(kind, envelope)
      Reach::Crypto.open_envelope(
        envelope,
        expected_kind: kind.to_s,
        expected_student_id: @install["student_id"],
        recipient_private_key: install_private_key,
        signer_public_key_for: method(:signer_public_key_for)
      )
    end

    def signer_public_key_for(key_id)
      key = signing_keys.find { |k| k["key_id"] == key_id }
      return Reach::Crypto.load_public_key(key["pem"]) if key

      Reach::Sync.refresh_status(quick: false)
      @install = Reach::Enroll.current
      key = signing_keys.find { |k| k["key_id"] == key_id }
      key ? Reach::Crypto.load_public_key(key["pem"]) : nil
    rescue StandardError
      nil
    end

    def signing_keys
      Array(@install["signing_public_keys"])
    end

    def install_private_key
      Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
    end

    def client
      Reach::Client.for_install(@install)
    end
  end
end
