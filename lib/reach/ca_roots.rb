require "rbconfig"

module Reach
  module CaRoots
    ENV_NAME = "SSL_CERT_FILE".freeze
    ENV_TOGGLE = "REACH_WINDOWS_ROOTS".freeze
    MAX_AGE_S = 24 * 60 * 60
    EXPORT_TIMEOUT_S = 20
    EXPORT_SCRIPT = [
      "$ErrorActionPreference='SilentlyContinue'",
      "$now=Get-Date",
      "foreach($store in 'Cert:\\LocalMachine\\Root','Cert:\\CurrentUser\\Root'){",
      "Get-ChildItem -Path $store | Where-Object { $_.NotAfter -gt $now } | ForEach-Object { [Convert]::ToBase64String($_.RawData) }",
      "}"
    ].join("; ").freeze

    @last_result = nil

    module_function

    def last_result
      @last_result
    end

    def windows?
      RbConfig::CONFIG["host_os"].to_s.match?(/mswin|mingw|cygwin/)
    end

    def home
      explicit = ENV["REACH_HOME"].to_s
      return File.expand_path(explicit) unless explicit.empty?
      return Reach::Paths.root.to_s if defined?(Reach::Paths) && Reach::Paths.respond_to?(:root)

      base = Dir.home
      workspace = ENV["REACH_WORKSPACE_ROOT"].to_s
      workspace = File.join(base, "reach-work") if workspace.empty?
      fresh = File.join(File.expand_path(workspace), ".reach-home")
      legacy = File.join(base, ".reach")
      return legacy if !File.file?(File.join(fresh, "install.yml")) && File.directory?(legacy)

      fresh
    rescue StandardError
      nil
    end

    def merged_file
      root = home
      return nil if root.nil? || root.empty?

      File.join(root, "runtime", "ca", "roots.pem")
    end

    def config_disabled?
      root = home
      return false if root.nil? || root.empty?

      path = File.join(root, "config.yml")
      return false unless File.file?(path)

      require "yaml"
      parsed = YAML.safe_load(File.read(path))
      return false unless parsed.is_a?(Hash) && parsed["tls"].is_a?(Hash)

      parsed["tls"]["windows_store"] == false
    rescue StandardError
      false
    end

    def enabled?
      return false if ENV[ENV_TOGGLE] == "0"

      !config_disabled?
    end

    def merged_ready?
      path = merged_file
      !path.nil? && File.file?(path) && File.size(path) > 0
    rescue StandardError
      false
    end

    def bundled_file(ruby = RbConfig.ruby)
      File.expand_path(File.join("..", "..", "libexec", "cert.pem"), ruby)
    end

    def apply!(env = ENV, ruby = RbConfig.ruby)
      current = env[ENV_NAME].to_s
      bundled = bundled_file(ruby)
      if windows? && enabled? && merged_ready?
        replaceable = current.empty? || !File.file?(current) || File.expand_path(current) == File.expand_path(bundled)
        if replaceable
          env[ENV_NAME] = merged_file
          return merged_file
        end
      end
      return current if !current.empty? && File.file?(current)
      return nil unless File.file?(bundled)

      env[ENV_NAME] = bundled
    rescue StandardError
      nil
    end

    def stale?(ruby = RbConfig.ruby)
      path = merged_file
      return true if path.nil? || !File.file?(path)

      mtime = File.mtime(path)
      return true if Time.now - mtime > MAX_AGE_S

      bundled = bundled_file(ruby)
      File.file?(bundled) && File.mtime(bundled) > mtime
    rescue StandardError
      true
    end

    def refresh!(force: false, ruby: RbConfig.ruby)
      outcome = begin
        compute_refresh(force, ruby)
      rescue StandardError
        [:failed, nil]
      end
      @last_result = outcome
      outcome.first == :written ? outcome : outcome.first
    end

    def compute_refresh(force, ruby)
      return [:disabled, nil] unless windows? && enabled?
      return [:fresh, nil] if !force && !stale?(ruby)

      exported = export_certificates
      return [:failed, nil] if exported.nil?

      merged = merge_certificates(ruby, exported)
      path = merged_file
      return [:failed, nil] if merged.nil? || path.nil?

      require "digest"
      pem = merged.map(&:to_pem).join
      return [:unchanged, merged.size] if File.file?(path) && Digest::SHA256.hexdigest(File.binread(path)) == Digest::SHA256.hexdigest(pem)

      write_atomic(path, pem)
      [:written, merged.size]
    end

    def export_certificates
      require "open3"
      require "timeout"
      require "base64"
      require "openssl"
      output = nil
      Open3.popen3("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", EXPORT_SCRIPT) do |stdin, stdout, stderr, thread|
        stdin.close
        reader = Thread.new { stdout.read }
        drain = Thread.new { stderr.read }
        begin
          Timeout.timeout(EXPORT_TIMEOUT_S) { thread.join }
          output = reader.value.to_s
        rescue Timeout::Error
          begin
            Process.kill("KILL", thread.pid)
          rescue StandardError
            nil
          end
        ensure
          reader.kill
          drain.kill
        end
      end
      return nil if output.nil?

      output.each_line.filter_map do |line|
        text = line.strip
        next if text.empty?

        begin
          OpenSSL::X509::Certificate.new(Base64.strict_decode64(text))
        rescue StandardError
          nil
        end
      end
    rescue StandardError
      nil
    end

    def merge_certificates(ruby, exported)
      require "digest"
      require "openssl"
      kit = bundled_file(ruby)
      kit_certs = []
      if File.file?(kit)
        File.read(kit).scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).each do |block|
          kit_certs << OpenSSL::X509::Certificate.new(block)
        rescue StandardError
          nil
        end
      end
      seen = {}
      merged = []
      (kit_certs + exported).each do |cert|
        digest = Digest::SHA256.hexdigest(cert.to_der)
        next if seen[digest]

        seen[digest] = true
        merged << cert
      end
      merged.empty? ? nil : merged
    rescue StandardError
      nil
    end

    def write_atomic(path, content)
      require "fileutils"
      FileUtils.mkdir_p(File.dirname(path))
      temp = "#{path}.#{Process.pid}.tmp"
      File.binwrite(temp, content)
      File.rename(temp, path)
    ensure
      File.delete(temp) if temp && File.file?(temp)
    end
  end
end
