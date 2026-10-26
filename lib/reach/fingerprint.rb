require "json"
require "etc"
require "open3"
require "socket"
require "timeout"
require "fileutils"
require "securerandom"
require "rbconfig"
require "time"

module Reach
  module Fingerprint
    SCHEMA = "reach.fingerprint/v1".freeze
    CACHE_TTL_S = 600
    CLAUDE_ENTRYPOINTS = {
      "cli" => "claude-code-tui",
      "local-agent" => "claude-cowork",
      "remote_cowork" => "claude-cowork",
      "claude-desktop" => "claude-desktop",
      "claude-desktop-3p" => "claude-desktop",
      "claude-vscode" => "claude-code-vscode",
      "sdk-cli" => "claude-code-headless",
      "sdk-ts" => "claude-agent-sdk",
      "sdk-py" => "claude-agent-sdk",
      "remote" => "claude-code-web"
    }.freeze
    COWORK_ENTRYPOINT = /\A(?:local[-_]agent|remote_cowork|claude-coworker)/.freeze
    READER_TIMEOUT_S = 3
    WINDOWS_READER_TIMEOUT_S = 8
    READER_ATTEMPTS = 3
    UNKNOWN = "unknown".freeze

    module_function

    def build(install_public_key:, harness:, enrolled_via:, salt: nil)
      salt = (stored || {})["salt"] if salt.to_s.empty?
      salt = Reach::Sidecar.fingerprint_salt if salt.to_s.empty?
      salt = SecureRandom.hex(16) if salt.to_s.empty?
      binding_hashes = binding_for(salt, install_public_key)
      hostname_hash = component(salt, "hostname", hostname)
      descriptive = {
        "hostname" => hostname_hash,
        "harness" => harness_label(harness),
        "os_version" => os_version,
        "ruby_version" => RUBY_VERSION,
        "reach_version" => Reach::VERSION,
        "enrolled_via" => enrolled_via.to_s
      }
      digests = digests_for(binding_hashes, hostname_hash)
      {
        "schema" => SCHEMA,
        "salt" => salt,
        "binding" => binding_hashes,
        "descriptive" => descriptive,
        "digest" => digests[0],
        "strict_digest" => digests[1]
      }
    end

    def harness_label(hint)
      hint = hint.to_s
      override = ENV["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"].to_s
      if hint == "codex" || ENV["CODEX_THREAD_ID"].to_s != "" || ENV["CODEX_SANDBOX"].to_s != ""
        return "codex-app" if ENV["CODEX_DESKTOP_APP"].to_s != "" || override.match?(/desktop/i)
        return "codex-vscode" if ENV["CODEX_IDE_VSCODE"].to_s != "" || override.match?(/vscode/i)

        return "codex-tui"
      end
      entry = ENV["CLAUDE_CODE_ENTRYPOINT"].to_s
      return "claude-cowork" if entry.match?(COWORK_ENTRYPOINT)
      return CLAUDE_ENTRYPOINTS.fetch(entry) { "claude-code-#{entry.gsub(/[^a-z0-9_-]/i, '')[0, 24]}" } unless entry.empty?
      return "hermes" if hint == "hermes" || ENV["HERMES_HOME"].to_s != ""
      return "terminal" if hint == "cli"

      hint.empty? ? UNKNOWN : hint
    end

    def live(salt:)
      key = cache_key(salt)
      cached = read_cache
      if cached && cached["key"] == key && fresh?(cached["computed_at"])
        return cached["value"]
      end

      machine = machine_id
      login = login_name
      binding_hashes = binding_for(salt, load_install_public_key, machine: machine, login: login)
      hostname_hash = component(salt, "hostname", hostname)
      digests = digests_for(binding_hashes, hostname_hash)
      unreadable = []
      unreadable << "machine_id" if machine == UNKNOWN
      unreadable << "os_user" if login == UNKNOWN
      value = {
        "digest" => digests[0], "strict_digest" => digests[1], "binding" => binding_hashes, "hostname" => hostname_hash,
        "alternates" => alternate_digests(salt, binding_hashes, hostname_hash), "unreadable" => unreadable
      }
      write_cache("key" => key, "computed_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "value" => value) if unreadable.empty?
      value
    end

    def inconclusive?(stored_document, live_value)
      return false unless stored_document.is_a?(Hash) && live_value.is_a?(Hash)

      changed = changed_components(stored_document, live_value)
      unreadable = Array(live_value["unreadable"])
      return false if changed.empty? || !(changed - unreadable).empty?

      was = stored_document["binding"].is_a?(Hash) ? stored_document["binding"] : {}
      salt = stored_document["salt"].to_s
      changed.none? { |name| unknown_components(salt, name).include?(was[name]) }
    end

    def unknown_components(salt, name)
      values = name == "os_user" ? [UNKNOWN, "#{UNKNOWN}:#{Process.uid}"] : [UNKNOWN]
      values.map { |value| component(salt, name, value) }
    end

    def stored
      return nil unless File.file?(Reach::Paths.fingerprint_file)

      data = JSON.parse(File.read(Reach::Paths.fingerprint_file))
      data.is_a?(Hash) && data["schema"] == SCHEMA ? data : nil
    rescue StandardError
      nil
    end

    def store!(document)
      write_private(Reach::Paths.fingerprint_file, document)
      Reach::Sidecar.keep_fingerprint_salt(document["salt"]) if document.is_a?(Hash)
    end

    def changed_components(stored_document, live_value)
      return [] unless stored_document.is_a?(Hash) && live_value.is_a?(Hash)

      was = stored_document["binding"].is_a?(Hash) ? stored_document["binding"] : {}
      now = live_value["binding"].is_a?(Hash) ? live_value["binding"] : {}
      names = (was.keys | now.keys).select { |name| was[name] != now[name] }.sort
      stored_host = (stored_document["descriptive"] || {})["hostname"]
      names << "hostname" if names.empty? && stored_host && stored_host != live_value["hostname"]
      names
    end

    def digest_for(value, strict)
      strict ? value["strict_digest"] : value["digest"]
    end

    def candidates(value)
      [[value["digest"], value["strict_digest"]]] + Array(value["alternates"])
    end

    def matches?(value, wanted, strict)
      return false if wanted.to_s.empty?

      candidates(value).any? { |pair| pair[strict ? 1 : 0] == wanted }
    end

    def header_digest(value, stamp)
      wanted = stamp.is_a?(Hash) ? stamp["fingerprint_digest"].to_s : ""
      pair = candidates(value).find { |candidate| !wanted.empty? && candidate[0] == wanted }
      (pair || candidates(value).first)[0]
    end

    def alternate_digests(salt, binding_hashes, hostname_hash)
      os_user_alternates.map do |value|
        digests_for(binding_hashes.merge("os_user" => component(salt, "os_user", value)), hostname_hash)
      end
    end

    def clear_cache!
      FileUtils.rm_f(Reach::Paths.fingerprint_cache_file)
    end

    def binding_for(salt, install_public_key, machine: nil, login: nil)
      {
        "machine_id" => component(salt, "machine_id", machine || machine_id),
        "os_user" => component(salt, "os_user", format_os_user(login || login_name)),
        "platform" => Reach::Enroll.platform,
        "install_key" => component(salt, "install_key", install_key_digest(install_public_key))
      }
    end

    def digests_for(binding_hashes, hostname_hash)
      [
        Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(binding_hashes)),
        Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(binding_hashes.merge("hostname" => hostname_hash)))
      ]
    end

    def component(salt, name, value)
      Reach::Crypto.digest_hex([SCHEMA, salt, name, value].join("\0"))
    end

    def install_key_digest(key)
      return UNKNOWN if key.nil?

      key = Reach::Crypto.load_public_key(key) if key.is_a?(String)
      key = key.public_key if key.respond_to?(:private?) && key.private?
      Reach::Crypto.digest_hex(key.to_der)
    rescue StandardError
      UNKNOWN
    end

    def load_install_public_key
      path = Reach::Paths.install_key_file
      return nil unless File.file?(path)

      Reach::Crypto.load_private_key(File.read(path)).public_key
    rescue StandardError
      nil
    end

    def hostname
      Socket.gethostname.to_s
    rescue StandardError
      UNKNOWN
    end

    def windows?
      Reach::Enroll.platform == "windows"
    end

    def os_user
      format_os_user(login_name)
    end

    def format_os_user(name)
      windows? ? name.to_s : "#{name}:#{Process.uid}"
    end

    def login_name
      READER_ATTEMPTS.times do
        name = begin
          Etc.getlogin
        rescue StandardError
          nil
        end
        name = ENV["USER"] if name.to_s.empty?
        name = ENV["USERNAME"] if name.to_s.empty?
        return name.to_s unless name.to_s.empty?
      end
      UNKNOWN
    end

    def os_user_alternates
      return [] if windows?

      primary = os_user
      [account_name, "root"].compact.map { |name| "#{name}:#{Process.uid}" }.uniq.reject { |value| value == primary }
    end

    def account_name
      name = Etc.getpwuid(Process.uid).name.to_s
      name.empty? ? nil : name
    rescue StandardError
      nil
    end

    def os_version
      detail = windows? ? run_reader("cmd", "/c", "ver") : run_reader("uname", "-r")
      "#{Reach::Enroll.platform} #{detail}".strip
    end

    def machine_id
      value = case Reach::Enroll.platform
              when "macos" then macos_machine_id
              when "windows" then windows_machine_id
              else linux_machine_id
              end
      value.to_s.empty? ? UNKNOWN : value
    rescue StandardError
      UNKNOWN
    end

    def linux_machine_id
      ["/etc/machine-id", "/var/lib/dbus/machine-id"].each do |path|
        next unless File.file?(path)

        value = File.read(path).strip
        return value unless value.empty?
      end
      nil
    end

    def macos_machine_id
      READER_ATTEMPTS.times do
        out = run_reader("ioreg", "-rd1", "-c", "IOPlatformExpertDevice")
        match = out.match(/"IOPlatformUUID"\s*=\s*"([^"]+)"/)
        return match[1] if match
      end
      nil
    end

    def windows_machine_id
      READER_ATTEMPTS.times do
        out = run_reader("reg", "query", "HKLM\\SOFTWARE\\Microsoft\\Cryptography", "/v", "MachineGuid", timeout: WINDOWS_READER_TIMEOUT_S)
        match = out.match(/MachineGuid\s+REG_SZ\s+(\S+)/)
        return match[1] if match
      end
      nil
    end

    def run_reader(*command, timeout: READER_TIMEOUT_S)
      Timeout.timeout(timeout) do
        out, _err, status = Open3.capture3(*command)
        status.success? ? out.to_s.strip : ""
      end
    rescue StandardError, Timeout::Error
      ""
    end

    def cache_key(salt)
      [salt, os_user, hostname, Reach::Paths.home].join("|")
    end

    def fresh?(stamp)
      Time.now.utc - Time.iso8601(stamp.to_s) < CACHE_TTL_S
    rescue ArgumentError
      false
    end

    def read_cache
      return nil unless File.file?(Reach::Paths.fingerprint_cache_file)

      data = JSON.parse(File.read(Reach::Paths.fingerprint_cache_file))
      data.is_a?(Hash) && data["value"].is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def write_cache(data)
      write_private(Reach::Paths.fingerprint_cache_file, data)
    rescue StandardError
      nil
    end

    def write_private(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      Reach::StateFile.rename_into_place(tmp, path)
      path
    end
  end
end
