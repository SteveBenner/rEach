require "open3"
require "timeout"
require "fileutils"
require "rbconfig"
require "json"
require "stringio"

module Reach
  module Setup
    module_function

    def run(harness: "auto", source: nil, format: "text", runtime: false)
      ruby_problem = check_ruby
      return [ruby_problem, 1] if ruby_problem

      Reach::Paths.ensure_home!
      Reach::Runtime.ensure_shim!

      resolved_source = source || Reach::Runtime.root
      candidates = harness.to_s == "auto" ? detected_harnesses : [harness.to_s]

      results = candidates.map { |id| run_harness(id, resolved_source) }
      results << { id: "auto", ok: false, message: "reach: no supported harness was found. Install Codex, Claude Code, Antigravity, or Hermes, then run setup again." } if results.empty?
      ok = results.any? { |entry| entry[:ok] }
      relocation = relocate_after_install
      exit_code = ok ? 0 : 1

      host_steps = ok ? host_step_lines(results) : []
      next_greeting = ok ? next_greeting_text : nil
      runtime_note = runtime_section(runtime)
      exit_code = 1 if runtime_note[:failed]

      if format.to_s == "json"
        payload = {
          "harnesses" => results.map { |entry| { "id" => entry[:id], "ok" => entry[:ok], "message" => entry[:message] } },
          "next" => next_greeting,
          "instructions" => (ok ? instructions_line : nil),
          "host_steps" => host_steps,
          "exit" => exit_code
        }
        payload["relocation"] = relocation[:line] if relocation
        payload["runtime"] = runtime_note[:json] if runtime_note[:json]
        [JSON.generate(payload), exit_code]
      else
        output = text_output(results, next_greeting, relocation, host_steps)
        output = "#{output}\n\n#{runtime_note[:text]}" if runtime_note[:text]
        [output, exit_code]
      end
    end

    def runtime_section(install)
      return {} unless Reach::RuntimeKit.supported?

      if install
        begin
          state = Reach::RuntimeAuto.with_lock { Reach::RuntimeKit.install!(out: StringIO.new) }
          return { text: Reach::RuntimeAuto::BUSY, json: { "installed" => false, "installing" => true } } if state == :busy

          line = Reach::RuntimeKit.copy(:installed, runtime_id: state["runtime_id"], ruby: state["ruby"] || "none", chrome: state["chrome"] || "none", profiles: state["profiles"].length)
          return { text: line, json: { "installed" => true, "runtime_id" => state["runtime_id"] } }
        rescue Reach::Error => e
          return { text: e.message, json: { "installed" => false, "error" => e.message }, failed: true }
        end
      end

      return {} if Reach::RuntimeKit.active
      return { text: Reach::RuntimeAuto::SETUP_NOTE, json: { "installed" => false, "auto" => true } } if Reach::RuntimeAuto.enabled?

      offer = Reach::RuntimeKit.copy(:offer)
      { text: offer, json: { "installed" => false, "offer" => offer } }
    rescue StandardError
      {}
    end

    def platform
      host_os = RbConfig::CONFIG["host_os"].to_s
      if host_os =~ /darwin/
        "macos"
      elsif host_os =~ /mswin|mingw|cygwin/
        "windows"
      else
        "linux"
      end
    end

    def check_ruby
      version = Gem::Version.new(RUBY_VERSION)
      ok = version >= Gem::Version.new("2.6.10") && version < Gem::Version.new("4.1.0")
      return nil if ok

      case platform
      when "macos"
        "Run setup with the built-in Ruby: /usr/bin/ruby #{File.join(Reach::Runtime.root, "exe", "reach")} setup"
      when "windows"
        "Install Ruby 4.0 from https://rubyinstaller.org for this user only, then run setup again."
      else
        "Install your distribution's Ruby (2.6.10 to 4.0.x), then run setup again."
      end
    end

    def detected_harnesses
      ids = []
      ids << "claude-code" if on_path?("claude") || File.directory?(File.expand_path("~/.claude"))
      ids << "codex" if on_path?("codex") || File.directory?(File.expand_path("~/.codex"))
      ids << "antigravity" if on_path?("agy") || File.directory?(File.expand_path("~/.gemini"))
      ids << "hermes" if on_path?("hermes") || File.directory?(hermes_home)
      ids
    end

    def hermes_home
      value = ENV["HERMES_HOME"].to_s
      File.expand_path(value.empty? ? "~/.hermes" : value)
    end

    def on_path?(executable)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, executable)) && !File.directory?(File.join(dir, executable))
      end
    end

    def run_harness(id, source)
      case id
      when "claude-code"
        run_claude(source)
      when "codex"
        run_codex(source)
      when "antigravity"
        run_antigravity(source)
      when "hermes"
        run_hermes(source)
      when "deepseek-tui", "dsh"
        { id: id, ok: false, message: "DeepSeek Harness: rEach doesn't support it yet." }
      else
        { id: id, ok: false, message: "reach: unknown harness #{id.inspect}" }
      end
    end

    def run_claude(source)
      unless on_path?("claude")
        return { id: "claude-code", ok: false, message: "Claude app: open Customize › Plugins › Add › Add marketplace, paste this repository's link, then add rEach." }
      end

      add_out, add_err, add_status = capture(["claude", "plugin", "marketplace", "add", source])
      unless add_status
        update_out, update_err, update_status = capture(["claude", "plugin", "marketplace", "update", "reach"])
        unless update_status
          return { id: "claude-code", ok: false, message: "Claude: marketplace add/update failed: #{add_err}#{add_out} #{update_err}#{update_out}".strip }
        end
      end

      _install_out, install_err, install_status = capture(["claude", "plugin", "install", "reach@reach", "--scope", "user"])
      unless install_status
        return { id: "claude-code", ok: false, message: "Claude: plugin install failed: #{install_err}" }
      end

      { id: "claude-code", ok: true, message: "Claude: rEach installed. Start a new Claude session (or run /reload-plugins) to meet rEach." }
    end

    def run_codex(source)
      unless on_path?("codex")
        return { id: "codex", ok: false, message: "Codex app: add this repository as a plugin marketplace, then add rEach from the Plugins directory." }
      end

      add_out, add_err, add_status = capture(["codex", "plugin", "marketplace", "add", source])
      if !add_status && "#{add_out}#{add_err}".include?(Reach::HarnessSource::CONFLICT)
        replaced = Reach::HarnessSource.replace_codex_source(source)
        add_status = replaced == "ok"
        add_err = replaced.sub(/\Afailed: /, "")
      end
      unless add_status
        return { id: "codex", ok: false, message: "Codex: marketplace add failed: #{add_err}" }
      end

      _install_out, install_err, install_status = capture(["codex", "plugin", "add", "reach@reach"])
      unless install_status
        return { id: "codex", ok: false, message: "Codex: plugin add failed: #{install_err}" }
      end

      { id: "codex", ok: true, message: "Codex: rEach installed. When Codex asks you to review rEach's start-up hook, choose to trust it; then start a new Codex session." }
    end

    def run_antigravity(_source)
      root = Reach::Runtime.root
      if on_path?("agy")
        _out, err, status = capture(["agy", "plugin", "install", root])
        return { id: "antigravity", ok: false, message: "Antigravity: plugin install failed: #{err}" } unless status

        return { id: "antigravity", ok: true, message: "Antigravity: rEach installed. Start a new Antigravity session to meet rEach." }
      end

      targets = [File.expand_path("~/.gemini/config/plugins/reach")]
      antigravity_cli = File.expand_path("~/.gemini/antigravity-cli")
      targets << File.join(antigravity_cli, "plugins", "reach") if File.directory?(antigravity_cli)

      blocked = nil
      targets.each do |target|
        FileUtils.mkdir_p(File.dirname(target))
        if File.exist?(target) || File.symlink?(target)
          next if File.symlink?(target) && File.readlink(target) == root

          blocked ||= target
          next
        end
        link_target(root, target)
      end

      return { id: "antigravity", ok: false, message: "blocked: #{blocked} exists" } if blocked

      { id: "antigravity", ok: true, message: "Antigravity: rEach installed. Start a new Antigravity session to meet rEach." }
    end

    def run_hermes(_source)
      unless on_path?("hermes")
        return { id: "hermes", ok: false, message: "Hermes: install Hermes Agent first (https://hermes-agent.nousresearch.com), then run setup again." }
      end

      config_path, error = ensure_hermes_profile
      return { id: "hermes", ok: false, message: "Hermes: #{error}" } unless config_path

      skills_dir = File.join(File.dirname(config_path), "skills")
      root = Reach::Runtime.root
      blocked = nil
      %w[reach-assistant reach-course].each do |name|
        source_dir = File.join(root, "skills", name)
        target = File.join(skills_dir, name)
        FileUtils.mkdir_p(skills_dir)
        if File.exist?(target) || File.symlink?(target)
          next if File.symlink?(target) && File.readlink(target) == source_dir

          blocked ||= target
          next
        end
        link_target(source_dir, target)
      end
      return { id: "hermes", ok: false, message: "blocked: #{blocked} exists" } if blocked

      Reach::Harness.configure("hermes", nil)
      { id: "hermes", ok: true, message: "Hermes: rEach installed in its own Hermes profile, reach. Open a course folder with: #{Reach::Runtime.hook_command("work", "--harness", "hermes")}" }
    end

    def ensure_hermes_profile
      path = hermes_profile_config_path
      unless path
        _out, err, ok = capture(["hermes", "profile", "create", "reach", "--clone", "--no-alias"])
        return [nil, err.to_s.strip.empty? ? "could not create the reach profile" : err.strip] unless ok

        path = hermes_profile_config_path
        return [nil, "could not find the reach profile's configuration file"] unless path
      end
      record_hermes_config(path)
      [path, nil]
    end

    def hermes_profile_config_path
      out, _err, ok = capture(["hermes", "-p", "reach", "config", "path"])
      return nil unless ok

      candidate = out.to_s.lines.map(&:strip).reject(&:empty?).last
      candidate && File.file?(candidate) ? candidate : nil
    end

    def record_hermes_config(path)
      Reach::Paths.ensure_home!
      FileUtils.mkdir_p(Reach::Paths.state_dir)
      state_file = Reach::Paths.hermes_state_file
      File.write(state_file, JSON.generate("config_path" => path))
      File.chmod(0o600, state_file)
    rescue NotImplementedError, Errno::ENOENT
      nil
    end

    def link_target(root, target)
      if Reach::Runtime.windows?
        FileUtils.cp_r(root, target)
      else
        File.symlink(root, target)
      end
    rescue StandardError
      nil
    end

    def capture(args)
      out, err, status = Timeout.timeout(120) { Open3.capture3(*args) }
      [out, err, status.success?]
    rescue StandardError => e
      ["", e.message, false]
    end

    def next_greeting_text
      status = Reach::Profile.load["status"]
      if status == "not_started"
        Reach::Greetings.text("G-FIRST-RUN")
      else
        greeting_id, greeting_text, = Reach::Hello.choose_greeting(nil)
        greeting_text || Reach::Greetings.text("G-FIRST-RUN")
      end
    rescue StandardError
      Reach::Greetings.text("G-FIRST-RUN")
    end

    def instructions_line
      "Then run the interview from the reach-assistant skill. If that skill is not loaded in this session yet, run `#{Reach::Runtime.hook_command("hello", "--format", "text")}` and follow what it prints."
    end

    def relocate_after_install
      return nil unless Reach::Paths.legacy_active?

      Reach::Relocation.run(trigger: "setup")
    rescue StandardError => e
      { phase: "failed", line: "rEach could not move your files into your rEach folder (#{e.message}). Nothing was changed; your files are safe where they are." }
    end

    def host_step_lines(results)
      steps = []
      if results.any? { |entry| entry[:id] == "codex" && entry[:ok] }
        steps << "In Codex, open the rEach folder in your home folder as your project (#{Reach::Paths.root}). After that you can set permissions back to the default."
      end
      steps
    end

    def text_output(results, next_greeting, relocation = nil, host_steps = [])
      lines = results.map { |entry| entry[:message] }
      lines << relocation[:line] if relocation && relocation[:line]
      return lines.join("\n") unless results.any? { |entry| entry[:ok] }

      lines << ""
      lines << "NEXT - say this to the student now, word for word:"
      lines << ""
      lines << Reach::Greetings.text("G-INSTALLED")
      lines << ""
      lines << next_greeting
      lines << ""
      lines << instructions_line
      unless host_steps.empty?
        lines << ""
        lines << "Host steps for the student, after the lines above:"
        host_steps.each { |step| lines << step }
      end
      lines.join("\n")
    end
  end
end
