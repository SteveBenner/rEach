require "json"
require "digest"
require "fileutils"
require "securerandom"
require "open3"
require "time"
require "zlib"
require "stringio"
require "rubygems/package"

module Reach
  module SdkKit
    SDK_TAG = "sdk-1.9.0-0.14.0-r2".freeze
    SDK_ID = "1.9.0-0.14.0-r2".freeze
    MANIFEST_SHA256 = "c984949b07336f90a2b6762160bf61a2c1492d643b87ecb00a29db820cf708c0".freeze
    RELEASE_BASE = Reach::RuntimeKit::RELEASE_BASE
    MANIFEST_ASSET = "sdk-manifest.json".freeze
    MANIFEST_SCHEMA = "reach.sdk-manifest/v1".freeze
    SMOKE_TIMEOUT_S = 60
    MAX_ENTRY_BYTES = 64 * 1024 * 1024

    COPY = {
      no_pin: "reach: this Reach build has no SDK pin yet; update Reach, or set REACH_SDK_ALLOW_UNPINNED=1 to install from a folder with --from",
      disabled: "reach: SDK downloads are turned off (REACH_SDK_DISABLE, REACH_RUNTIME_DISABLE or REACH_OFFLINE); install from a folder with --from",
      no_runtime: "reach: the SDK needs Reach's runtime Ruby first; run reach runtime install",
      installed: "Reach SDK %{sdk_id} installed: rplugin %{rplugin}, rBrain %{rbrain}"
    }.freeze

    module_function

    def copy(key, values = {})
      COPY.fetch(key) % values
    end

    def sdk_root
      File.join(File.dirname(Reach::RuntimeKit.runtime_root), "sdk")
    end

    def current_file
      File.join(sdk_root, "current")
    end

    def pinned?
      !MANIFEST_SHA256.empty?
    end

    def disabled?
      ENV["REACH_SDK_DISABLE"] == "1" || Reach::RuntimeKit.network_disabled?
    end

    def manifest_url
      "#{RELEASE_BASE}/#{SDK_TAG}/#{MANIFEST_ASSET}"
    end

    def asset_url(asset)
      "#{RELEASE_BASE}/#{SDK_TAG}/#{asset}"
    end

    def allow_unpinned?
      ENV["REACH_SDK_ALLOW_UNPINNED"] == "1"
    end

    def manifest(from: nil)
      if from
        path = File.join(File.expand_path(from), MANIFEST_ASSET)
        raise Reach::Error, "reach: #{MANIFEST_ASSET} was not found in #{from}" unless File.file?(path)

        bytes = File.binread(path)
      else
        raise Reach::Error, copy(:disabled) if disabled?
        raise Reach::Error, copy(:no_pin) unless pinned?

        bytes = Reach::Download.get_small(manifest_url)
      end
      verify_manifest_bytes!(bytes)
      data = JSON.parse(bytes)
      raise Reach::Error, "reach: the SDK manifest is not one this Reach understands" unless data.is_a?(Hash) && data["schema"] == MANIFEST_SCHEMA

      data
    rescue JSON::ParserError
      raise Reach::Error, "reach: the SDK manifest could not be read"
    end

    def verify_manifest_bytes!(bytes)
      return if allow_unpinned?
      raise Reach::Error, copy(:no_pin) unless pinned?

      raise Reach::Error, "reach: the SDK manifest does not match this Reach's pin; it was not used" unless Digest::SHA256.hexdigest(bytes) == MANIFEST_SHA256
    end

    def install!(from: nil, out: $stdout)
      runtime = Reach::RuntimeKit.active
      raise Reach::Error, copy(:no_runtime) unless runtime && runtime["ruby_exe"]

      data = manifest(from: from)
      sdk_id = data["sdk_id"].to_s
      raise Reach::Error, "reach: the SDK manifest has no usable SDK id" unless sdk_id.match?(/\A[A-Za-z0-9._-]+\z/)
      asset = data["asset"].to_s
      raise Reach::Error, "reach: the SDK manifest names no asset" unless asset.match?(/\A[A-Za-z0-9._-]+\z/)

      return active_state(sdk_id, out) if complete_info(File.join(sdk_root, sdk_id)) && current_id == sdk_id

      FileUtils.mkdir_p(sdk_root)
      sweep_staging
      stage = File.join(sdk_root, ".staging-#{SecureRandom.hex(6)}")
      FileUtils.mkdir_p(stage)
      begin
        archive = File.join(stage, ".download", asset)
        FileUtils.mkdir_p(File.dirname(archive))
        fetch_asset(asset, data, archive, from, out)
        out.puts "extracting #{asset}"
        extract!(archive, File.join(stage, "tree"))
        File.delete(archive)
        tree = File.join(stage, "tree")
        smoke!(runtime["ruby_exe"], File.join(tree, "sdk"), data)
        place!(tree, stage, sdk_id, data)
      ensure
        FileUtils.rm_rf(stage) if File.exist?(stage)
      end
      Reach::Download.log("event" => "sdk.install", "sdk_id" => sdk_id, "result" => "ok")
      out.puts copy(:installed, sdk_id: sdk_id, rplugin: data["rplugin_version"], rbrain: data["rbrain_version"])
      status
    rescue Reach::Error, SystemCallError => e
      Reach::Download.log("event" => "sdk.install", "sdk_id" => sdk_id.to_s, "result" => "failed", "error" => e.message)
      raise
    end

    def active_state(sdk_id, out)
      out.puts "Reach SDK #{sdk_id} is already installed"
      status
    end

    def fetch_asset(asset, data, destination, from, out)
      local = from ? File.join(File.expand_path(from), asset) : nil
      if local && File.file?(local)
        out.puts "copying #{asset}"
        FileUtils.cp(local, destination)
        verify_file!(destination, data, asset)
      else
        raise Reach::Error, copy(:disabled) if disabled?

        out.puts "downloading #{asset}"
        Reach::Download.get_to_file(asset_url(asset), destination, expected_sha256: data["sha256"].to_s, expected_size: data["size"].to_i)
      end
    end

    def verify_file!(path, meta, asset)
      raise Reach::Error, "reach: #{asset} has the wrong size; it was not used" unless File.size(path) == meta["size"].to_i
      raise Reach::Error, "reach: sha256 mismatch for #{asset}; it was not used" unless Digest::SHA256.file(path).hexdigest == meta["sha256"].to_s
    end

    def extract!(archive, into)
      FileUtils.mkdir_p(into)
      root = File.expand_path(into)
      File.open(archive, "rb") do |file|
        Zlib::GzipReader.wrap(file) do |gz|
          Gem::Package::TarReader.new(gz) do |tar|
            tar.each do |entry|
              name = entry.full_name.to_s
              raise Reach::Error, "reach: the SDK archive holds an unsafe path (#{name[0, 80]})" if name.empty? || name.start_with?("/") || name.split("/").include?("..") || name.include?("\0")
              raise Reach::Error, "reach: the SDK archive holds a link (#{name[0, 80]})" if entry.symlink? || entry.header.typeflag == "1"

              target = File.expand_path(File.join(root, name))
              raise Reach::Error, "reach: the SDK archive holds an unsafe path (#{name[0, 80]})" unless target.start_with?(root + File::SEPARATOR)

              if entry.directory?
                FileUtils.mkdir_p(target)
              elsif entry.file?
                raise Reach::Error, "reach: the SDK archive holds an oversized file (#{name[0, 80]})" if entry.header.size.to_i > MAX_ENTRY_BYTES

                FileUtils.mkdir_p(File.dirname(target))
                File.open(target, "wb", entry.header.mode.to_i & 0o755 | 0o600) { |out| out.write(entry.read.to_s) }
              else
                raise Reach::Error, "reach: the SDK archive holds an entry that is not a file (#{name[0, 80]})"
              end
            end
          end
        end
      end
    rescue Zlib::Error, Gem::Package::TarInvalidError => e
      raise Reach::Error, "reach: the SDK archive could not be read (#{e.message[0, 80]})"
    end

    def smoke!(ruby_exe, sdk_dir, data)
      script = "require ARGV[0]; require ARGV[1]; puts Rplugin::VERSION; puts Rcorpus::VERSION"
      command = [ruby_exe, "-e", script, File.join(sdk_dir, "lib", "rplugin"), File.join(sdk_dir, "rcorpus", "lib", "rcorpus")]
      ok, output = run_checked(command)
      lines = output.to_s.lines.map(&:strip)
      unless ok && lines.last(2) == [data["rplugin_version"].to_s, data["rbrain_version"].to_s]
        raise Reach::Error, "reach: the SDK did not load under the runtime Ruby (#{output.to_s.strip[0, 160]})"
      end
    end

    def run_checked(command)
      Open3.popen2e(Reach::RuntimeKit.clean_env, *command) do |stdin, io, thread|
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
        return [thread.value.success?, reader.value]
      end
    rescue SystemCallError => e
      [false, e.message]
    end

    def sweep_staging
      Dir.glob(File.join(sdk_root, ".staging-*")).each do |dir|
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

    def place!(tree, stage, sdk_id, data)
      File.write(File.join(stage, ".complete"), JSON.pretty_generate(
        "sdk_id" => sdk_id,
        "rplugin_version" => data["rplugin_version"],
        "rbrain_version" => data["rbrain_version"],
        "installed_at" => Time.now.utc.iso8601
      ))
      root = File.join(sdk_root, sdk_id)
      File.rename(root, "#{root}.old-#{stamp}") if File.exist?(root)
      FileUtils.mkdir_p(File.join(stage, "slot"))
      File.rename(File.join(stage, ".complete"), File.join(stage, "slot", ".complete"))
      File.rename(File.join(tree, "sdk"), File.join(stage, "slot", "sdk"))
      begin
        File.rename(File.join(stage, "slot"), root)
      rescue SystemCallError
        old = Dir.glob("#{root}.old-*").sort.last
        File.rename(old, root) if old && !File.exist?(root)
        raise
      end
      write_current(sdk_id)
      Reach::RuntimeKit.prune_superseded(sdk_root, sdk_id)
    end

    def write_current(sdk_id)
      FileUtils.mkdir_p(sdk_root)
      temp = "#{current_file}.tmp"
      File.write(temp, "#{sdk_id}\n")
      File.rename(temp, current_file)
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

      root = File.join(sdk_root, id)
      info = complete_info(root)
      return nil unless info

      home = File.join(root, "sdk")
      return nil unless File.file?(File.join(home, "lib", "rplugin.rb")) && File.file?(File.join(home, "rcorpus", "lib", "rcorpus.rb"))

      { "sdk_id" => id, "home" => home, "info" => info }
    end

    def status
      sdk = active
      info = sdk ? sdk["info"] : {}
      {
        "sdk_id" => sdk ? sdk["sdk_id"] : nil,
        "installed" => !sdk.nil?,
        "current" => sdk && sdk["sdk_id"] == SDK_ID,
        "rplugin" => info["rplugin_version"],
        "rbrain" => info["rbrain_version"],
        "pinned" => pinned?,
        "disabled" => disabled?,
        "root" => sdk ? sdk["home"] : nil
      }
    end

    def status_lines(state = status)
      lines = []
      if state["installed"]
        lines << "sdk: #{state['sdk_id']} (installed)"
        lines << "rplugin: #{state['rplugin']}"
        lines << "rbrain: #{state['rbrain']}"
        lines << "location: #{state['root']}"
      else
        lines << "sdk: not installed"
      end
      lines << "wanted: #{SDK_ID}"
      lines << "pinned: #{state['pinned'] ? 'yes' : 'no'}"
      lines << "downloads: #{state['disabled'] ? 'off' : 'on'}"
      lines
    end
  end
end
