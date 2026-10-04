require "rbconfig"
require "shellwords"
require "yaml"
require "json"
require "fileutils"

module Reach
  module Runtime
    TEACH_URL = "https://sven-f1l1.tail062fd2.ts.net".freeze

    module_function

    def root
      File.expand_path("../..", __dir__)
    end

    def exe_path
      File.join(root, "exe", "reach")
    end

    def ruby_path
      RbConfig.ruby
    end

    def shim_path
      File.join(Reach::Paths.root, "bin", "reach")
    end

    def shim_root_path
      File.join(Reach::Paths.root, "bin", "root")
    end

    def shim_content
      shebang = "#{"#"}!/usr/bin/env ruby"
      [
        shebang,
        "root = File.read(File.join(__dir__, \"root\")).strip",
        "unless File.file?(File.join(root, \"exe\", \"reach\"))",
        "  begin",
        "    require \"json\"",
        "    state = JSON.parse(File.read(File.join(__dir__, \"..\", \"state\", \"update.json\")))",
        "    managed = File.join(__dir__, \"..\", \"plugin\")",
        "    unless File.exist?(managed)",
        "      if state[\"staged_path\"].is_a?(String) && File.directory?(state[\"staged_path\"])",
        "        File.rename(state[\"staged_path\"], managed)",
        "      elsif state[\"backup_path\"].is_a?(String) && File.directory?(state[\"backup_path\"])",
        "        File.rename(state[\"backup_path\"], managed)",
        "      end",
        "    end",
        "    if File.file?(File.join(managed, \"exe\", \"reach\"))",
        "      root = File.expand_path(managed)",
        "      File.write(File.join(__dir__, \"root\"), \"\#{root}\\n\")",
        "    end",
        "  rescue StandardError",
        "    nil",
        "  end",
        "end",
        "load File.join(root, \"exe\", \"reach\")",
        ""
      ].join("\n")
    end

    def ensure_shim!
      Reach::Paths.ensure_home!
      dir = File.dirname(shim_path)
      FileUtils.mkdir_p(dir)
      write_if_different(shim_path, shim_content)
      target = shim_root_target
      write_if_different(shim_root_path, "#{target}\n") if target
      begin
        File.chmod(0o755, shim_path)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
      nil
    rescue StandardError
      nil
    end

    def shim_root_target
      return (shim_root_replaceable? ? root : nil) if Reach::Paths.legacy_active?

      recorded = File.file?(shim_root_path) ? File.read(shim_root_path).strip : ""
      stale = !recorded.empty? && in_legacy_home?(recorded)
      if in_legacy_home?(root)
        managed = File.join(Reach::Paths.root, "plugin")
        return managed if (stale || recorded.empty?) && File.file?(File.join(managed, "exe", "reach"))

        return nil
      end
      stale || shim_root_replaceable? ? root : nil
    rescue StandardError
      nil
    end

    def shim_root_replaceable?
      recorded = File.file?(shim_root_path) ? File.read(shim_root_path).strip : ""
      return true if recorded.empty? || !File.directory?(recorded)

      version_file = File.join(recorded, "VERSION")
      return true unless File.file?(version_file)

      Gem::Version.new(File.read(version_file).strip) <= Gem::Version.new(Reach::VERSION)
    rescue StandardError
      true
    end

    def in_legacy_home?(path)
      Reach::Paths.path_within?(Reach::Paths.realish(path), Reach::Paths.realish(Reach::Paths.legacy_home))
    rescue StandardError
      false
    end

    def write_if_different(path, content)
      return if File.file?(path) && File.read(path) == content

      File.write(path, content)
    rescue StandardError
      nil
    end

    def hook_command(*args)
      parts = [ruby_path, shim_path, *args]
      if windows?
        parts.map { |part| "\"#{part}\"" }.join(" ")
      else
        parts.map { |part| Shellwords.escape(part) }.join(" ")
      end
    end

    def windows?
      RbConfig::CONFIG["host_os"].to_s =~ /mswin|mingw|cygwin/ ? true : false
    end

    def default_teach_url
      value = ENV["REACH_TEACH_URL"]
      return value if value && !value.empty?

      configured_teach_url || baked_teach_url || TEACH_URL
    rescue StandardError
      TEACH_URL
    end

    def configured_teach_url
      config = load_config
      teach = config["teach"] if config.is_a?(Hash)
      url = teach["url"] if teach.is_a?(Hash)
      url && !url.to_s.empty? ? url.to_s : nil
    end

    def baked_teach_url
      path = Reach::Paths.teach_url_file
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      url = data["url"] if data.is_a?(Hash)
      url && !url.to_s.empty? ? url.to_s : nil
    rescue StandardError
      nil
    end

    def bake_teach_url!
      url = configured_teach_url
      return nil unless url

      path = Reach::Paths.teach_url_file
      FileUtils.mkdir_p(File.dirname(path))
      write_if_different(path, "#{JSON.generate('url' => url)}\n")
      url
    rescue StandardError
      nil
    end

    def load_config
      path = File.join(root, "config.yml")
      return {} unless File.file?(path)

      YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      {}
    end
  end
end
