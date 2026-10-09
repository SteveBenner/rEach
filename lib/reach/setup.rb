require "open3"
require "timeout"
require "fileutils"
require "rbconfig"
require "json"
require "stringio"

module Reach
  module Setup
    COPY_MARKER = ".reach-copy".freeze

    module_function

    def run(harness: "auto", source: nil, format: "text", runtime: false)
      ruby_problem = check_ruby
      return [ruby_problem, 1] if ruby_problem

      Reach::Paths.ensure_home!
      Reach::Runtime.ensure_shim!
      Reach::Runtime.bake_teach_url!

      resolved_source = source || Reach::Runtime.root
      Reach::Update.record_channel(resolved_source)
      candidates = harness.to_s == "auto" ? detected_harnesses : [harness.to_s]

      results = candidates.map { |id| run_harness(id, resolved_source) }
      results << { id: "auto", ok: false, message: "reach: no supported harness was found. Install Codex, Claude Code, Antigravity, or Hermes, then run setup again." } if results.empty?
      ok = results.any? { |entry| entry[:ok] }
      relocation = relocate_after_install
      Reach::Paths.ensure_workspace_dirs! if ok
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
      ids << "claude-code" if on_path?("claude") || File.directory?(Reach::Paths.claude_config_dir)
      ids << "codex" if on_path?("codex") || File.directory?(Reach::Paths.codex_home)
      ids << "antigravity" if on_path?("agy") || File.directory?(Reach::Paths.gemini_dir)
      ids << "hermes" if on_path?("hermes") || File.directory?(hermes_home)
      ids
    end

    def hermes_home
      Reach::Paths.hermes_home
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

      added = Reach::HarnessSource.claude_add(Reach::HarnessSource.pin(source, "claude-code"))
      unless added == "ok"
        update_out, update_err, update_status = capture(["claude", "plugin", "marketplace", "update", "reach"])
        unless update_status
          return { id: "claude-code", ok: false, message: "Claude: marketplace add/update failed: #{added.sub(/\Afailed: /, '')} #{update_err}#{update_out}".strip }
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

      source = Reach::HarnessSource.pin(source, "codex")
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

      Reach::CodexCache.repair
      { id: "codex", ok: true, message: "Codex: rEach installed. Start a new Codex session and trust rEach's two hooks when Codex asks (in Codex in a Terminal, type /hooks; in the desktop app, open Settings and go to Hooks). rEach will also ask to change two Codex settings so its commands can use the internet and its folder inside Codex; after that change, start a new chat in Codex." }
    end

    def run_antigravity(_source)
      root = Reach::Runtime.root
      if on_path?("agy")
        _out, err, status = capture(["agy", "plugin", "install", root])
        return { id: "antigravity", ok: false, message: "Antigravity: plugin install failed: #{err}" } unless status

        return { id: "antigravity", ok: true, message: "Antigravity: rEach installed. Start a new Antigravity session to meet rEach." }
      end

      targets = [File.join(Reach::Paths.gemini_dir, "config", "plugins", "reach")]
      antigravity_cli = File.join(Reach::Paths.gemini_dir, "antigravity-cli")
      targets << File.join(antigravity_cli, "plugins", "reach") if File.directory?(antigravity_cli)

      blocked = nil
      failed = nil
      targets.each do |target|
        FileUtils.mkdir_p(File.dirname(target))
        if File.exist?(target) || File.symlink?(target)
          next if File.symlink?(target) && File.readlink(target) == root

          if refreshable_copy?(target)
            failed ||= target unless link_target(root, target)
          else
            blocked ||= target
          end
          next
        end
        failed ||= target unless link_target(root, target)
      end

      return { id: "antigravity", ok: false, message: "blocked: #{blocked} exists" } if blocked
      return { id: "antigravity", ok: false, message: "Antigravity: rEach could not be copied to #{failed}" } if failed

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
      failed = nil
      %w[reach-assistant reach-course].each do |name|
        source_dir = File.join(root, "skills", name)
        target = File.join(skills_dir, name)
        FileUtils.mkdir_p(skills_dir)
        if File.exist?(target) || File.symlink?(target)
          next if File.symlink?(target) && File.readlink(target) == source_dir

          if refreshable_copy?(target)
            failed ||= target unless link_target(source_dir, target)
          else
            blocked ||= target
          end
          next
        end
        failed ||= target unless link_target(source_dir, target)
      end
      return { id: "hermes", ok: false, message: "blocked: #{blocked} exists" } if blocked
      return { id: "hermes", ok: false, message: "Hermes: rEach could not be copied to #{failed}" } if failed

      Reach::Harness.configure("hermes", nil)
      { id: "hermes", ok: true, message: "Hermes: rEach installed in its own Hermes profile, reach. Open a course folder with: #{Reach::Runtime.hook_command("work", "--harness", "hermes")}\n#{Reach::Messages.text("M-HERMES-APPROVE-ONCE")}" }
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

    def refreshable_copy?(target)
      Reach::Runtime.windows? && File.directory?(target) && !File.symlink?(target) && File.file?(File.join(target, COPY_MARKER))
    end

    def link_target(root, target)
      if Reach::Runtime.windows?
        copy_target(root, target)
      else
        File.symlink(root, target)
        true
      end
    rescue StandardError
      false
    end

    def copy_target(root, target)
      fresh = "#{target}.reach-new-#{Process.pid}"
      aside = "#{target}.reach-old-#{Process.pid}"
      FileUtils.rm_rf(fresh)
      FileUtils.rm_rf(aside)
      FileUtils.cp_r(root, fresh)
      File.write(File.join(fresh, COPY_MARKER), "#{root}\n")
      File.rename(target, aside) if File.exist?(target)
      begin
        File.rename(fresh, target)
      rescue SystemCallError
        File.rename(aside, target) if File.exist?(aside) && !File.exist?(target)
        raise
      end
      FileUtils.rm_rf(aside)
      true
    rescue StandardError
      FileUtils.rm_rf(fresh)
      false
    end

    def refresh_copies(root = Reach::Runtime.root)
      return [] unless Reach::Runtime.windows?

      pairs = [
        [root, File.join(Reach::Paths.gemini_dir, "config", "plugins", "reach")],
        [root, File.join(Reach::Paths.gemini_dir, "antigravity-cli", "plugins", "reach")]
      ]
      config_path = Reach::Harness.hermes_config_path
      if config_path
        %w[reach-assistant reach-course].each do |name|
          pairs << [File.join(root, "skills", name), File.join(File.dirname(config_path), "skills", name)]
        end
      end
      pairs.select { |source, target| refreshable_copy?(target) && File.directory?(source) && copy_target(source, target) }.map(&:last)
    rescue StandardError
      []
    end

    def capture(args)
      out, err, status = Timeout.timeout(120) { Open3.capture3(*args) }
      [out, err, status.success?]
    rescue StandardError => e
      ["", e.message, false]
    end

    def enrolled?
      !Reach::Enroll.current.nil?
    rescue StandardError
      false
    end

    def next_greeting_text
      return Reach::Greetings.text("G-INSTALLED-ENROLL") unless enrolled?
      return Reach::Greetings.text("G-LOGIN") if Reach::Login.required? && !Reach::Login.any_active?

      greeting_id, greeting_text, = Reach::Hello.choose_greeting(nil)
      greeting_id == "G-FIRST-RUN" ? nil : greeting_text
    rescue StandardError
      Reach::Greetings.text("G-INSTALLED-ENROLL")
    end

    def instructions_line
      return "Then connect rEach to the student's course. If the reach-assistant skill is not loaded in this session yet, run `#{Reach::Runtime.hook_command("hello", "--format", "text")}` and follow what it prints. Do not start the first-run interview until the student is enrolled and signed in." unless enrolled?

      "Then run the interview from the reach-assistant skill. If that skill is not loaded in this session yet, run `#{Reach::Runtime.hook_command("hello", "--format", "text")}` and follow what it prints."
    end

    def relocate_after_install
      return nil unless Reach::Paths.legacy_active?

      Reach::Relocation.run(trigger: "setup")
    rescue StandardError => e
      { phase: "failed", line: "rEach could not move its files into your reach-work folder (#{e.message}). Nothing was changed; your files are safe where they are." }
    end

    def host_step_lines(results)
      steps = []
      if results.any? { |entry| entry[:id] == "codex" && entry[:ok] }
        steps << "In Codex, open the reach-work folder in your home folder as the chat's folder (#{Reach::Paths.workspace_base})."
        steps << "rEach will ask to change two Codex settings so its commands can use the internet and the reach-work folder inside Codex. Answer yes, then start a new chat in Codex so the change takes effect."
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
      if next_greeting
        lines << next_greeting
        lines << ""
      end
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
