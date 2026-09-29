require "rbconfig"
require "shellwords"
require "yaml"
require "fileutils"

module Reach
  module Runtime
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
      File.join(Reach::Paths.home, "bin", "reach")
    end

    def shim_root_path
      File.join(Reach::Paths.home, "bin", "root")
    end

    def shim_content
      shebang = "#{"#"}!/usr/bin/env ruby"
      [
        shebang,
        "root = File.read(File.join(__dir__, \"root\")).strip",
        "load File.join(root, \"exe\", \"reach\")",
        ""
      ].join("\n")
    end

    def ensure_shim!
      Reach::Paths.ensure_home!
      dir = File.dirname(shim_path)
      FileUtils.mkdir_p(dir)
      write_if_different(shim_path, shim_content)
      write_if_different(shim_root_path, "#{root}\n")
      begin
        File.chmod(0o755, shim_path)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
      nil
    rescue StandardError
      nil
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

      config = load_config
      teach = config["teach"] if config.is_a?(Hash)
      url = teach["url"] if teach.is_a?(Hash)
      url && !url.to_s.empty? ? url : nil
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
