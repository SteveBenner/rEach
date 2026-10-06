require "json"
require "digest"
require "fileutils"
require "securerandom"
require "open3"
require "rbconfig"
require "time"
require "timeout"

module Reach
  module RuntimeKit
    RUNTIME_TAG = "runtime-4.0.7-r3".freeze
    RUNTIME_ID = "4.0.7-r3".freeze
    MANIFEST_SHA256 = "cd79747a0bb564f2210ee744cfdc28274ccd21ef868457587b39ed28c0bbc6a2".freeze
    RELEASE_BASE = "https://github.com/SteveBenner/rEach/releases/download".freeze
    MANIFEST_ASSET = "runtime-manifest.json".freeze
    MANIFEST_SCHEMA = "reach.runtime-manifest/v1".freeze
    SMOKE_TIMEOUT_S = 30
    PLATFORMS = %w[macos-arm64 macos-x86_64 linux-x86_64 linux-arm64 windows-x86_64].freeze
    CHROME_PLATFORMS = %w[macos-arm64 macos-x86_64 linux-x86_64 windows-x86_64].freeze

    COPY = {
      offer: "Local checks run best with Reach's runtime (Ruby 4.0.7, prebuilt gems, Chrome for Testing 154). Install it with: reach runtime install",
      no_pin: "reach: this Reach build has no runtime pin yet; update Reach, or install from a folder with --from",
      disabled: "reach: runtime downloads are turned off (REACH_RUNTIME_DISABLE or REACH_OFFLINE); install from a folder with --from",
      unsupported: "reach: no runtime is built for this platform (%{platform}); local checks use the Ruby and Chrome already installed",
      no_cft: "Google publishes no Chrome for Testing build for %{platform}; install your distribution's chromium and Reach will find it",
      doctor_chrome: "R-DOC-CHROME: no usable Chrome was found - run reach runtime install",
      installed: "Reach runtime %{runtime_id} installed: Ruby %{ruby}, Chrome %{chrome}, %{profiles} gem profile(s)"
    }.freeze
    INHERITED_RUBY_ENV = %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH GEM_SPEC_CACHE RUBYGEMS_GEMDEPS].freeze
    INHERITED_RUBY_ENV_PREFIXES = %w[BUNDLE_ BUNDLER_].freeze

    module_function

    def clean_env(overlay = {})
      cleared = INHERITED_RUBY_ENV.to_h { |name| [name, nil] }
      ENV.each_key do |name|
        cleared[name] = nil if INHERITED_RUBY_ENV_PREFIXES.any? { |prefix| name.start_with?(prefix) }
      end
      cleared.merge(overlay)
    end

    def copy(key, values = {})
      COPY.fetch(key) % values
    end

    def platform
      host_os = RbConfig::CONFIG["host_os"].to_s
      host_cpu = RbConfig::CONFIG["host_cpu"].to_s
      os = if host_os =~ /darwin/
             "macos"
           elsif host_os =~ /mswin|mingw/
             "windows"
           elsif host_os =~ /linux/
             Dir.glob("/lib/ld-musl-*").empty? ? "linux" : nil
           end
      cpu = if host_cpu =~ /\A(arm64|aarch64)\z/
              "arm64"
            elsif host_cpu =~ /\A(x86_64|x64|amd64)\z/
              "x86_64"
            end
      return nil unless os && cpu

      name = "#{os}-#{cpu}"
      PLATFORMS.include?(name) ? name : nil
    end

    def supported?
      !platform.nil?
    end

    def network_disabled?
      ENV["REACH_RUNTIME_DISABLE"] == "1" || ENV["REACH_OFFLINE"] == "1"
    end

    def pinned?
      MANIFEST_SHA256 != "PENDING"
    end

    def manifest_url
      "#{RELEASE_BASE}/#{RUNTIME_TAG}/#{MANIFEST_ASSET}"
    end

    def asset_url(asset)
      "#{RELEASE_BASE}/#{RUNTIME_TAG}/#{asset}"
    end

    def runtime_root
      Reach::Paths.runtime_dir
    end

    def current_file
      File.join(runtime_root, "current")
    end

    def manifest(from: nil)
      if from
        path = File.join(File.expand_path(from), MANIFEST_ASSET)
        raise Reach::Error, "reach: #{MANIFEST_ASSET} was not found in #{from}" unless File.file?(path)

        bytes = File.binread(path)
        unless ENV["REACH_RUNTIME_ALLOW_UNPINNED"] == "1"
          raise Reach::Error, copy(:no_pin) unless pinned?
        end
      else
        raise Reach::Error, copy(:disabled) if network_disabled?
        raise Reach::Error, copy(:no_pin) unless pinned?

        bytes = Reach::Download.get_small(manifest_url)
      end
      verify_manifest_bytes!(bytes, from)
      data = JSON.parse(bytes)
      raise Reach::Error, "reach: the runtime manifest is not one this Reach understands" unless data.is_a?(Hash) && data["schema"] == MANIFEST_SCHEMA

      data
    rescue JSON::ParserError
      raise Reach::Error, "reach: the runtime manifest could not be read"
    end

    def verify_manifest_bytes!(bytes, from)
      return if from && ENV["REACH_RUNTIME_ALLOW_UNPINNED"] == "1"

      actual = Digest::SHA256.hexdigest(bytes)
      raise Reach::Error, "reach: the runtime manifest does not match this Reach's pin; it was not used" unless actual == MANIFEST_SHA256
    end

    def install!(only: nil, from: nil, out: $stdout)
      raise Reach::Error, "reach: --only takes ruby or chrome" unless only.nil? || %w[ruby chrome].include?(only)

      plat = platform
      raise Reach::Error, copy(:unsupported, platform: plat || "this computer") unless plat

      data = manifest(from: from)
      entry = data.fetch("platforms", {})[plat]
      raise Reach::Error, copy(:unsupported, platform: plat) unless entry

      want_bundle = only != "chrome"
      chrome_entry = entry["chrome"]
      if only == "chrome" && chrome_entry.nil?
        raise Reach::Error, copy(:no_cft, platform: plat)
      end
      want_chrome = only != "ruby" && !chrome_entry.nil?
      if only == "ruby" && entry["bundle"].nil?
        raise Reach::Error, copy(:unsupported, platform: plat)
      end

      runtime_id = data["runtime_id"].to_s
      raise Reach::Error, "reach: the runtime manifest has no runtime id" unless runtime_id =~ /\A[A-Za-z0-9._-]+\z/

      FileUtils.mkdir_p(runtime_root)
      sweep_staging
      stage = File.join(runtime_root, ".staging-#{SecureRandom.hex(6)}")
      download_dir = File.join(stage, ".download")
      FileUtils.mkdir_p(download_dir)
      components = []
      begin
        if want_bundle
          bundle = entry.fetch("bundle")
          path = fetch_component(bundle["asset"], bundle["url"] || asset_url(bundle["asset"]), bundle, download_dir, from, out)
          out.puts "extracting #{bundle['asset']}"
          Reach::Untar.extract(path, into: stage, strip: "runtime/")
          File.delete(path)
          ruby_exe = File.join(stage, bundle["ruby_exe"].to_s.sub(%r{\Aruntime/}, ""))
          smoke_ruby!(ruby_exe, data["ruby_version"])
          components << "ruby"
        end
        if want_chrome
          path = fetch_component(File.basename(chrome_entry["url"]), chrome_entry["url"], chrome_entry, download_dir, from, out)
          out.puts "extracting #{File.basename(chrome_entry['url'])}"
          Reach::Unzip.extract(path, into: File.join(stage, "chrome"))
          File.delete(path)
          smoke_chrome!(File.join(stage, "chrome", chrome_entry["exe"].to_s), data["chrome_version"])
          components << "chrome"
        end
        FileUtils.rm_rf(download_dir)
        place!(stage, runtime_id, plat, data, components, only)
      ensure
        FileUtils.rm_rf(stage) if File.exist?(stage)
      end
      Reach::Download.log("event" => "runtime.install", "runtime_id" => runtime_id, "components" => components, "result" => "ok")
      result = status
      out.puts copy(:installed, runtime_id: runtime_id, ruby: result["ruby"] || "none", chrome: result["chrome"] || "none", profiles: result["profiles"].length)
      result
    rescue Reach::Error, SystemCallError => e
      Reach::Download.log("event" => "runtime.install", "runtime_id" => runtime_id.to_s, "components" => components || [], "result" => "failed", "error" => e.message)
      raise
    end

    def fetch_component(asset, url, meta, download_dir, from, out)
      destination = File.join(download_dir, asset)
      local = from ? File.join(File.expand_path(from), asset) : nil
      if local && File.file?(local)
        out.puts "copying #{asset}"
        FileUtils.cp(local, destination)
        verify_file!(destination, meta, asset)
      else
        raise Reach::Error, copy(:disabled) if network_disabled?

        out.puts "downloading #{asset}"
        Reach::Download.get_to_file(url, destination, expected_sha256: meta["sha256"].to_s, expected_size: meta["size"].to_i)
      end
      destination
    end

    def verify_file!(path, meta, asset)
      raise Reach::Error, "reach: #{asset} has the wrong size; it was not used" unless File.size(path) == meta["size"].to_i
      raise Reach::Error, "reach: sha256 mismatch for #{asset}; it was not used" unless Digest::SHA256.file(path).hexdigest == meta["sha256"].to_s
    end

    def run_checked(command)
      output = +""
      Open3.popen2e(*command) do |stdin, io, thread|
        stdin.close
        reader = Thread.new { io.read.to_s }
        unless thread.join(SMOKE_TIMEOUT_S)
          begin
            Process.kill("KILL", thread.pid)
          rescue SystemCallError
            nil
          end
          thread.join
          reader.join(2)
          return [nil, "timed out"]
        end
        output = reader.value
        return [thread.value.success?, output]
      end
    rescue SystemCallError => e
      [false, e.message]
    end

    def smoke_ruby!(exe, version)
      raise Reach::Error, "reach: the runtime has no Ruby where the manifest says" unless File.file?(exe)

      ok, output = run_checked([exe, "-v"])
      raise Reach::Error, "reach: the runtime Ruby did not report #{version} (#{output.to_s.strip[0, 120]})" unless ok && output.include?(version.to_s)
    end

    def smoke_chrome!(exe, version)
      raise Reach::Error, "reach: the runtime has no Chrome where the manifest says" unless File.file?(exe)

      if Reach::Untar.windows?
        return if File.file?(File.join(File.dirname(exe), "#{version}.manifest"))

        raise Reach::Error, "reach: the runtime Chrome did not report #{version} (no #{version}.manifest beside chrome.exe)"
      end

      ok, output = run_checked([exe, "--version"])

      return if ok && output.include?(version.to_s)

      missing = missing_libraries(exe)
      unless missing.empty?
        raise Reach::Error, "reach: the runtime Chrome cannot start because this computer lacks system libraries it needs: #{missing.join(', ')}. Install your distribution's packages that provide them (a desktop Linux has them; a minimal or server install often does not), then run reach runtime install again"
      end

      raise Reach::Error, "reach: the runtime Chrome did not report #{version} (#{output.to_s.strip[0, 120]})"
    end

    def missing_libraries(exe)
      return [] unless RbConfig::CONFIG["host_os"] =~ /linux/

      stdout, _stderr, _status = Open3.capture3("ldd", exe)
      stdout.to_s.lines.map { |line| line[/\A\s*(\S+)\s+=>\s+not found/, 1] }.compact.uniq
    rescue StandardError
      []
    end

    def sweep_staging
      Dir.glob(File.join(runtime_root, ".staging-*")).each do |dir|
        next unless File.directory?(dir)
        next if Time.now - File.mtime(dir) < 3600

        FileUtils.rm_rf(dir)
      end
    end

    def stamp
      Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def complete_info(root)
      marker = File.join(root, ".complete")
      return nil unless File.file?(marker)

      info = JSON.parse(File.read(marker))
      info.is_a?(Hash) ? info : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def place!(stage, runtime_id, plat, data, components, only)
      root = File.join(runtime_root, runtime_id)
      existing = complete_info(root)
      in_place = !only.nil? && existing
      write_build_json(stage, runtime_id, plat, data) unless File.file?(File.join(stage, "BUILD.json")) || in_place

      info = {
        "runtime_id" => runtime_id,
        "platform" => plat,
        "components" => components,
        "ruby_version" => nil,
        "chrome_version" => nil,
        "profiles" => [],
        "installed_at" => Time.now.utc.iso8601
      }
      if in_place
        info = existing.merge("installed_at" => info["installed_at"])
        info["components"] = (Array(existing["components"]) + components).uniq
      end
      info["ruby_version"] = data["ruby_version"] if components.include?("ruby")
      info["chrome_version"] = data["chrome_version"] if components.include?("chrome")
      info["bundler_version"] = data["bundler_version"] if components.include?("ruby")
      info["profiles"] = Array(data["profiles"]) if components.include?("ruby")

      if in_place
        swap_components(stage, root)
        write_marker(root, info)
      else
        File.write(File.join(stage, ".complete"), JSON.pretty_generate(info))
        if File.exist?(root)
          File.rename(root, "#{root}.old-#{stamp}")
        end
        begin
          File.rename(stage, root)
        rescue SystemCallError
          old = Dir.glob("#{root}.old-*").sort.last
          File.rename(old, root) if old && !File.exist?(root)
          raise
        end
      end
      write_current(runtime_id)
    end

    def swap_components(stage, root)
      Dir.children(stage).each do |name|
        next if name.start_with?(".")

        source = File.join(stage, name)
        target = File.join(root, name)
        previous = File.join(stage, ".prev-#{name}")
        File.rename(target, previous) if File.exist?(target)
        begin
          File.rename(source, target)
        rescue SystemCallError
          File.rename(previous, target) if File.exist?(previous) && !File.exist?(target)
          raise
        end
      end
    end

    def write_marker(root, info)
      temp = File.join(root, ".complete.tmp")
      File.write(temp, JSON.pretty_generate(info))
      File.rename(temp, File.join(root, ".complete"))
    end

    def write_build_json(stage, runtime_id, plat, data)
      File.write(File.join(stage, "BUILD.json"), JSON.pretty_generate(
        "runtime_id" => runtime_id,
        "platform" => plat,
        "ruby_version" => data["ruby_version"],
        "bundler_version" => data["bundler_version"],
        "built_at" => Time.now.utc.iso8601,
        "profiles" => Array(data["profiles"])
      ))
    end

    def write_current(runtime_id)
      FileUtils.mkdir_p(runtime_root)
      temp = "#{current_file}.tmp"
      File.write(temp, "#{runtime_id}\n")
      File.rename(temp, current_file)
    end

    def chrome_missing?
      runtime = active
      return false unless runtime && runtime["runtime_id"] == RUNTIME_ID
      return false if Array(runtime["info"]["components"]).include?("chrome")

      CHROME_PLATFORMS.include?(platform)
    end

    def current_id
      return nil unless File.file?(current_file)

      value = File.read(current_file).strip
      value =~ /\A[A-Za-z0-9._-]+\z/ ? value : nil
    rescue SystemCallError
      nil
    end

    def active
      id = current_id
      return nil unless id

      root = File.join(runtime_root, id)
      info = complete_info(root)
      return nil unless info

      exe_name = Reach::Untar.windows? ? "ruby.exe" : "ruby"
      ruby_exe = File.join(root, "ruby", "bin", exe_name)
      ruby_exe = nil unless File.file?(ruby_exe)
      chrome_exe = chrome_path(root, info)
      {
        "root" => root,
        "runtime_id" => id,
        "ruby_exe" => ruby_exe,
        "ruby_bin" => ruby_exe ? File.dirname(ruby_exe) : nil,
        "chrome_exe" => chrome_exe,
        "profiles" => profile_dirs(root, info),
        "info" => info
      }
    end

    def chrome_path(root, info)
      return nil unless Array(info["components"]).include?("chrome")

      chrome_root = File.join(root, "chrome")
      relative = info["chrome_exe"].to_s
      if relative.empty?
        platform_dir = { "linux-x86_64" => "chrome-linux64/chrome",
                         "macos-arm64" => "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
                         "macos-x86_64" => "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
                         "windows-x86_64" => "chrome-win64/chrome.exe" }
        relative = platform_dir[info["platform"].to_s].to_s
      end
      path = File.join(chrome_root, relative)
      File.file?(path) ? path : nil
    end

    def profile_dirs(root, info)
      built = built_profiles(root)
      Array(info["profiles"]).map do |profile|
        lock = profile["lock_sha256"].to_s
        next nil if lock.length < 12

        dir = File.join(root, "gems", lock[0, 12])
        dir = built_dir(root, built, profile["name"]) || dir unless File.directory?(dir)
        { "name" => profile["name"], "lock_sha256" => lock, "dir" => dir }
      end.compact
    end

    def built_profiles(root)
      info = JSON.parse(File.read(File.join(root, "BUILD.json")))
      info.is_a?(Hash) ? Array(info["profiles"]).select { |profile| profile.is_a?(Hash) } : []
    rescue JSON::ParserError, SystemCallError
      []
    end

    def built_dir(root, built, name)
      profile = built.find { |entry| !name.to_s.empty? && entry["name"] == name }
      return nil unless profile

      lock = (profile["lock12"] || profile["lock_sha256"]).to_s
      return nil if lock.length < 12

      dir = File.join(root, "gems", lock[0, 12])
      File.directory?(dir) ? dir : nil
    end

    def lock_digests(lock_bytes)
      lf = lock_bytes.to_s.b.gsub("\r\n".b, "\n".b)
      crlf = lf.gsub("\n".b, "\r\n".b)
      [lock_bytes.to_s.b, lf, crlf].map { |bytes| Digest::SHA256.hexdigest(bytes) }.uniq
    end

    def gems_for(lock_bytes)
      runtime = active
      return nil unless runtime

      digests = lock_digests(lock_bytes)
      profile = runtime["profiles"].find { |entry| digests.include?(entry["lock_sha256"]) }
      return nil unless profile && File.directory?(profile["dir"])

      gemfile = File.join(profile["dir"], "Gemfile")
      lock = File.join(profile["dir"], "Gemfile.lock")
      return nil unless File.file?(gemfile) && File.file?(lock)

      { "dir" => profile["dir"], "gemfile" => gemfile, "lock" => lock }
    end

    def status
      plat = platform
      runtime = active
      info = runtime ? runtime["info"] : {}
      {
        "platform" => plat,
        "supported" => !plat.nil?,
        "runtime_id" => runtime ? runtime["runtime_id"] : nil,
        "installed" => !runtime.nil?,
        "active" => !runtime.nil?,
        "components" => runtime ? Array(info["components"]) : [],
        "ruby" => info["ruby_version"],
        "chrome" => info["chrome_version"],
        "profiles" => runtime ? runtime["profiles"].map { |entry| entry["name"] || entry["lock_sha256"][0, 12] } : [],
        "root" => runtime ? runtime["root"] : nil
      }
    end

    def status_lines(state = status)
      lines = ["platform: #{state['platform'] || 'unsupported'}"]
      if state["installed"]
        lines << "runtime: #{state['runtime_id']} (active)"
        lines << "components: #{state['components'].join(', ')}"
        lines << "ruby: #{state['ruby'] || 'not installed'}"
        lines << "chrome: #{state['chrome'] || 'not installed'}"
        lines << "gem profiles: #{state['profiles'].empty? ? 'none' : state['profiles'].join(', ')}"
        lines << "location: #{state['root']}"
      else
        lines << "runtime: not installed"
      end
      lines
    end

    def remove!(old_only: false)
      removed = []
      if old_only
        Dir.glob(File.join(runtime_root, "*.old-*")).each do |dir|
          FileUtils.rm_rf(dir)
          removed << dir
        end
        return removed
      end
      id = current_id
      if id
        dir = File.join(runtime_root, id)
        if File.directory?(dir)
          FileUtils.rm_rf(dir)
          removed << dir
        end
        FileUtils.rm_f(current_file)
      end
      removed
    end
  end
end
