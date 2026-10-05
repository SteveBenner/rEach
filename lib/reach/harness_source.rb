require "open3"
require "timeout"

module Reach
  module HarnessSource
    CONFLICT = "already added from a different source".freeze

    module_function

    def repoint(source)
      { "claude-code" => claude(source), "codex" => codex(source) }
    end

    def claude(source)
      return "absent" unless on_path?("claude")

      _out, err, ok = capture(["claude", "plugin", "marketplace", "add", source])
      ok ? "ok" : "failed: #{first_line(err)}"
    end

    def codex(source)
      return "absent" unless on_path?("codex")

      out, err, ok = capture(["codex", "plugin", "marketplace", "add", source])
      return "ok" if ok

      combined = "#{out}#{err}"
      return "failed: #{first_line(combined)}" unless combined.include?(CONFLICT)

      replace_codex_source(source)
    end

    def replace_codex_source(source)
      old_source = codex_source
      _out, err, ok = capture(%w[codex plugin marketplace remove reach])
      return "failed: #{first_line(err)}" unless ok

      _out, err, ok = capture(["codex", "plugin", "marketplace", "add", source])
      return "ok" if ok

      reason = first_line(err)
      if old_source && File.directory?(old_source)
        _out, _err, restored = capture(["codex", "plugin", "marketplace", "add", old_source])
        return "failed: #{reason} (previous source #{restored ? 'restored' : 'could not be restored'})"
      end
      "failed: #{reason}"
    end

    def codex_source
      from_config || from_list
    end

    def from_config
      config = File.join(codex_home, "config.toml")
      return nil unless File.file?(config)

      inside = false
      File.foreach(config) do |line|
        stripped = line.strip
        if stripped.start_with?("[")
          inside = stripped == "[marketplaces.reach]"
          next
        end
        next unless inside

        match = stripped.match(/\Asource\s*=\s*"(.*)"\z/)
        return match[1].gsub('\\"', '"').gsub("\\\\", "\\") if match
      end
      nil
    rescue StandardError
      nil
    end

    def from_list
      out, _err, ok = capture(%w[codex plugin marketplace list])
      return nil unless ok

      out.each_line do |line|
        next unless line =~ /\breach\b/

        found = line.scan(%r{(?:[A-Za-z]:)?[/\\][^\s"']+}).first
        return found if found
      end
      nil
    end

    def codex_home
      Reach::Paths.codex_home
    end

    def first_line(text)
      lines = text.to_s.lines.map(&:strip).reject(&:empty?)
      lines.reject { |line| line.start_with?("WARNING") }.first || lines.first || "no output"
    end

    def on_path?(executable)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, executable)) && !File.directory?(File.join(dir, executable))
      end
    end

    def capture(args)
      out, err, status = Timeout.timeout(120) { Open3.capture3(*args) }
      [out, err, status.success?]
    rescue StandardError => e
      ["", e.message, false]
    end
  end
end
