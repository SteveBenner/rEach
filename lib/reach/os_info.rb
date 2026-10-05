require "json"
require "open3"
require "timeout"
require "rbconfig"
require "etc"
require "time"

module Reach
  module OsInfo
    PROBE_TIMEOUT_S = 2
    CACHE_TTL_S = 86_400
    MAX_VALUE_BYTES = 200
    OS_RELEASE_KEYS = { "NAME" => "os_name", "VERSION_ID" => "os_version", "VERSION" => "os_build", "ID" => "distro_id",
                        "ID_LIKE" => "distro_like", "VARIANT_ID" => "distro_variant", "BUILD_ID" => "distro_build" }.freeze
    WINDOWS_VALUES = { "ProductName" => "os_name", "DisplayVersion" => "os_version", "CurrentBuild" => "os_build",
                       "UBR" => "windows_ubr", "EditionID" => "windows_edition" }.freeze

    module_function

    def snapshot
      cached = read_cache
      return cached if cached

      data = clean(collect)
      write_cache(data)
      data
    rescue StandardError
      {}
    end

    def cache_file
      File.join(Reach::Debug.dir, "os_info.json")
    end

    def read_cache
      parsed = JSON.parse(File.read(cache_file))
      return nil unless parsed.is_a?(Hash) && parsed["platform"] == RUBY_PLATFORM && parsed["data"].is_a?(Hash)

      at = Time.iso8601(parsed["at"].to_s)
      return nil if Time.now - at > CACHE_TTL_S || at > Time.now + 60

      parsed["data"]
    rescue StandardError
      nil
    end

    def write_cache(data)
      Reach::Debug.ensure_dir
      Reach::Debug.write_json(cache_file, "at" => Time.now.utc.iso8601, "platform" => RUBY_PLATFORM, "data" => data)
    rescue StandardError
      nil
    end

    def clean(data)
      out = {}
      data.each do |key, value|
        next if value.nil? || Reach::Debug::DROP_KEY.match?(key.to_s)

        out[key.to_s] = value.is_a?(String) ? scrub(value) : value
      end
      out
    end

    def scrub(text)
      value = text.to_s.dup
      value = value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?") unless value.encoding == Encoding::UTF_8 && value.valid_encoding?
      value = value.gsub(%r{(?<![A-Za-z0-9])/(?:home|Users|root|var|tmp|etc|usr|opt|mnt)/[^\s,;]*}, "[path]")
      value = value.gsub(/[A-Za-z]:\\[^\s,;]*/, "[path]")
      [Dir.home, (defined?(Reach::Paths) ? (Reach::Paths.user_home rescue nil) : nil), ENV["USER"], ENV["USERNAME"], (Etc.getlogin rescue nil)].compact.map(&:to_s).reject { |name| name.length < 3 }.each do |name|
        value = value.gsub(name, "[scrubbed]")
      end
      value = value.byteslice(0, MAX_VALUE_BYTES).scrub("") if value.bytesize > MAX_VALUE_BYTES
      value.strip
    rescue StandardError
      nil
    end

    def collect
      data = {}
      family = os_family
      data["os_family"] = family
      unix = family != "windows"
      probe(data) { data["arch"] = [RbConfig::CONFIG["host_cpu"], unix ? run("uname", "-m") : nil].compact.uniq.join(" ") }
      probe(data) { data["kernel"] = run("uname", "-sr") if unix }
      case family
      when "linux" then probe(data) { linux(data) }
      when "darwin" then probe(data) { darwin(data) }
      when "windows" then probe(data) { windows(data) }
      end
      probe(data) { shared(data, family) }
      probe(data) { environment(data, family) }
      probe(data) { toolchain(data) }
      data
    end

    def os_family
      case RbConfig::CONFIG["host_os"].to_s
      when /linux/i then "linux"
      when /darwin|mac os/i then "darwin"
      when /mswin|mingw|cygwin|windows/i then "windows"
      when /bsd|dragonfly/i then "bsd"
      else "other"
      end
    end

    def probe(_data)
      yield
    rescue StandardError, Timeout::Error
      nil
    end

    def run(*command)
      out = nil
      Open3.popen3(*command) do |stdin, stdout, stderr, thread|
        stdin.close
        begin
          Timeout.timeout(PROBE_TIMEOUT_S) { out = stdout.read }
        rescue Timeout::Error
          begin
            Process.kill("KILL", thread.pid)
          rescue StandardError
            nil
          end
          out = nil
        end
        stderr.close
        thread.join(PROBE_TIMEOUT_S)
      end
      text = out.to_s.strip
      text.empty? ? nil : text
    rescue StandardError, Timeout::Error
      nil
    end

    def linux(data)
      release = {}
      File.readlines("/etc/os-release").each do |line|
        match = line.strip.match(/\A([A-Z_]+)=(.*)\z/)
        release[match[1]] = match[2].sub(/\A(["'])(.*)\1\z/, '\2') if match
      end
      OS_RELEASE_KEYS.each { |source, target| data[target] = release[source] if release[source] }
    end

    def darwin(data)
      data["os_name"] = run("sw_vers", "-productName")
      data["os_version"] = run("sw_vers", "-productVersion")
      data["os_build"] = run("sw_vers", "-buildVersion")
      translated = run("sysctl", "-n", "sysctl.proc_translated")
      data["rosetta"] = translated == "1" unless translated.nil?
    end

    def windows(data)
      data["os_build_banner"] = run("cmd", "/c", "ver")
      output = run("reg", "query", 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
      return unless output

      output.each_line do |line|
        parts = line.strip.split(/\s{2,}/)
        target = WINDOWS_VALUES[parts[0]]
        data[target] = parts.last if target && parts.size >= 3
      end
    end

    def shared(data, family)
      probe(data) do
        version = family == "linux" ? [File.read("/proc/version"), data["kernel"]].join(" ") : ""
        if version =~ /microsoft|wsl/i
          data["wsl"] = true
          data["wsl_version"] = version =~ /wsl2/i ? 2 : 1 if version =~ /wsl2/i
        elsif family == "linux"
          data["wsl"] = false
        end
      end
      if family == "linux"
        probe(data) { data["container"] = container }
        probe(data) { data["virtualization"] = run("systemd-detect-virt") if which("systemd-detect-virt") }
        probe(data) { data["immutable"] = true if File.exist?("/run/ostree-booted") }
        probe(data) { data["init"] = "systemd" if File.directory?("/run/systemd/system") }
      end
      data["cpu_count"] = Etc.nprocessors
      probe(data) { data["cpu_model"] = cpu_model(family) }
      probe(data) { memory(data, family) }
      probe(data) { disk(data, family) }
      probe(data) { uptime(data, family) }
      probe(data) { data["load_1m"] = File.read("/proc/loadavg").split.first.to_f if family == "linux" }
    end

    def container
      return "docker" if File.exist?("/.dockerenv")
      return "podman" if File.exist?("/run/.containerenv")

      cgroup = File.read("/proc/1/cgroup")
      return "docker" if cgroup =~ /docker/
      return "podman" if cgroup =~ /libpod|podman/
      return "lxc" if cgroup =~ /lxc/
      return "kubernetes" if cgroup =~ /kubepods/

      nil
    end

    def which(name)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) && !File.directory?(File.join(dir, name)) }
    end

    def cpu_model(family)
      case family
      when "linux"
        line = File.foreach("/proc/cpuinfo").find { |text| text.start_with?("model name") }
        line && line.split(":", 2)[1].to_s.strip
      when "darwin" then run("sysctl", "-n", "machdep.cpu.brand_string")
      when "windows" then ENV["PROCESSOR_IDENTIFIER"]
      end
    end

    def memory(data, family)
      case family
      when "linux"
        info = {}
        File.foreach("/proc/meminfo") { |line| info[$1] = $2.to_i if line =~ /\A(\w+):\s+(\d+)/ }
        data["memory_mb"] = info["MemTotal"] / 1024 if info["MemTotal"]
        data["memory_available_mb"] = info["MemAvailable"] / 1024 if info["MemAvailable"]
      when "darwin"
        bytes = run("sysctl", "-n", "hw.memsize")
        data["memory_mb"] = bytes.to_i / 1_048_576 if bytes
      end
    end

    def disk(data, family)
      return if family == "windows"

      dir = File.directory?(Reach::Paths.home) ? Reach::Paths.home : File.dirname(Reach::Paths.home)
      line = run("df", "-Pk", dir).to_s.lines.last.to_s.split
      if line.size >= 4
        data["disk_total_mb"] = line[1].to_i / 1024
        data["disk_free_mb"] = line[3].to_i / 1024
      end
      data["filesystem"] = run("stat", "-f", "-c", "%T", dir) if family == "linux"
    end

    def uptime(data, family)
      case family
      when "linux"
        data["uptime_h"] = (File.read("/proc/uptime").split.first.to_f / 3600).round(1)
      when "darwin"
        sec = run("sysctl", "-n", "kern.boottime").to_s[/sec\s*=\s*(\d+)/, 1]
        data["uptime_h"] = ((Time.now.to_i - sec.to_i) / 3600.0).round(1) if sec
      end
    end

    def environment(data, family)
      data["locale"] = [ENV["LC_ALL"], ENV["LC_MESSAGES"], ENV["LANG"]].find { |value| !value.to_s.empty? }
      data["timezone"] = timezone
      data["utc_offset_min"] = Time.now.utc_offset / 60
      shell = family == "windows" ? ENV["ComSpec"] : ENV["SHELL"]
      data["shell"] = File.basename(shell.to_s.tr("\\", "/")) unless shell.to_s.empty?
      program = ENV["TERM_PROGRAM"].to_s
      data["terminal"] = program.empty? ? ENV["TERM"] : [program, ENV["TERM_PROGRAM_VERSION"]].reject { |value| value.to_s.empty? }.join(" ")
      data["desktop"] = ENV["XDG_CURRENT_DESKTOP"]
      data["session_type"] = if !ENV["XDG_SESSION_TYPE"].to_s.empty? then ENV["XDG_SESSION_TYPE"]
                             elsif !ENV["WAYLAND_DISPLAY"].to_s.empty? then "wayland"
                             elsif !ENV["DISPLAY"].to_s.empty? then "x11"
                             end
      data["ssh"] = !(ENV["SSH_CONNECTION"].to_s.empty? && ENV["SSH_TTY"].to_s.empty?)
    end

    def timezone
      return ENV["TZ"] unless ENV["TZ"].to_s.empty?

      zone = File.read("/etc/timezone").strip rescue nil
      return zone unless zone.to_s.empty?

      target = File.readlink("/etc/localtime") rescue nil
      name = target.to_s.split("zoneinfo/", 2)[1]
      return name unless name.to_s.empty?

      Time.now.zone
    end

    def toolchain(data)
      data["ruby_engine"] = defined?(RUBY_ENGINE) ? RUBY_ENGINE : nil
      data["ruby_platform"] = RUBY_PLATFORM
      data["ruby_from"] = ruby_from
      data["git_version"] = run("git", "--version")
      data["node_version"] = run("node", "--version")
      chrome = chrome_binary
      data["chrome"] = run(chrome, "--version") if chrome
    end

    def ruby_from
      exe = RbConfig.ruby.to_s
      kit = Reach::Paths.runtime_dir.to_s
      return "runtime_kit" if !kit.empty? && exe.start_with?(kit)
      return "system" if exe.start_with?("/usr") || exe.start_with?("/System")

      "other"
    end

    def chrome_binary
      env = ENV["REACH_CHROME"].to_s
      return env if !env.empty? && File.file?(env)

      active = Reach::RuntimeKit.active
      path = active && active["chrome_exe"]
      path && File.file?(path) ? path : nil
    rescue StandardError
      nil
    end
  end
end
