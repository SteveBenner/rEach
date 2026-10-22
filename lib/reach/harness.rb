require "open3"
require "timeout"
require "json"
require "fileutils"
require "yaml"
require "date"
require "time"

module Reach
  module Harness
    class << self
      def detect
        [detect_one("claude-code", "claude"), detect_one("codex", "codex"), detect_one("antigravity", "agy"), detect_one("hermes", "hermes")].compact
      end

      def configure_all(workspace_path)
        space_kind = space_kind_for(workspace_path)
        ids = []
        [["claude-code", :configure_claude_code], ["codex", :configure_codex]].each do |id, method_name|
          begin
            send(method_name, workspace_path, space_kind)
            ids << id
          rescue StandardError
            nil
          end
        end
        begin
          ids << "hermes" if configure_hermes
        rescue StandardError
          nil
        end
        ids
      rescue StandardError
        []
      end

      def configure(harness_id, workspace_path)
        space_kind = space_kind_for(workspace_path)
        case harness_id.to_s
        when "claude-code"
          configure_claude_code(workspace_path, space_kind)
        when "codex"
          configure_codex(workspace_path, space_kind)
        when "hermes"
          configure_hermes
        when "antigravity"
          nil
        else
          raise Reach::InstallError, "reach: unknown harness #{harness_id.inspect}"
        end
      end

      def hermes_config_path
        path = Reach::Paths.hermes_state_file
        return nil unless File.file?(path)

        value = JSON.parse(File.read(path))["config_path"]
        value.is_a?(String) && !value.empty? ? value : nil
      rescue StandardError
        nil
      end

      RULES_FILES = { "CLAUDE.md" => "claude-code", "AGENTS.md" => "codex", "GEMINI.md" => "antigravity" }.freeze
      RULES_SETTINGS = %w[auto stub full].freeze
      HOOKED = %w[claude-code codex hermes].freeze
      HOOKS_VERIFIED_FILE = "hooks_verified.json".freeze
      FAMILY_HARNESS = { "claude" => "claude-code", "codex" => "codex", "hermes" => "hermes" }.freeze

      def rules_file_setting
        section = Reach::Runtime.load_config["harness"]
        value = section.is_a?(Hash) ? section["rules_file"].to_s : ""
        RULES_SETTINGS.include?(value) ? value : "auto"
      rescue StandardError
        "auto"
      end

      def rules_mode(file_name)
        setting = rules_file_setting
        return setting unless setting == "auto"

        hooks_verified?(RULES_FILES.fetch(file_name.to_s, "antigravity")) ? "stub" : "full"
      end

      def hooks_verified?(harness_id)
        return false unless HOOKED.include?(harness_id.to_s)
        return false unless Reach::StateFile.read(HOOKS_VERIFIED_FILE)[harness_id.to_s].is_a?(String)

        harness_id.to_s != "codex" || !Reach::CodexSetup.plugin_hooks_untrusted?
      rescue StandardError
        false
      end

      def note_hooks_ran(label)
        harness_id = FAMILY_HARNESS[label.to_s.split("-").first]
        return nil unless harness_id

        Reach::StateFile.update(HOOKS_VERIFIED_FILE) { |state| state[harness_id] = Reach::StateFile.now_s }
        nil
      rescue StandardError
        nil
      end

      def launch(harness_id, workspace_path, initial_prompt: nil)
        is_workspace = workspace_launch?(workspace_path)
        prepare_hermes if harness_id.to_s == "hermes"
        if is_workspace
          Reach::Gate.session(harness: harness_id)
          refresh_rules_files(workspace_path)
          configure_space(harness_id, workspace_path)
        end
        exec_harness(harness_id, workspace_path, initial_prompt)
      end

      private

      def configure_space(harness_id, workspace_path)
        configure(harness_id, workspace_path)
      rescue *Reach::Sandbox::WRITE_ERRORS => e
        Reach::Debug.error(e, "harness:configure")
        nil
      end

      def prepare_hermes
        Reach::Setup.ensure_hermes_profile if hermes_config_path.nil? && which("hermes")
        configure_hermes
      rescue StandardError
        nil
      end

      def workspace_launch?(workspace_path)
        !Reach::Workspace.space_for(workspace_path).nil?
      rescue StandardError
        false
      end

      def space_kind_for(workspace_path)
        space = Reach::Workspace.space_for(workspace_path)
        space ? space["kind"] : "slice"
      end

      def refresh_rules_files(workspace_path)
        case space_kind_for(workspace_path)
        when "extracurricular"
          Reach::Workspace.write_space_rules_files(workspace_path, "extracurricular")
        when "root"
          Reach::Workspace.write_space_rules_files(workspace_path, "root")
        else
          Reach::Workspace.write_rules_files(workspace_path)
        end
      rescue StandardError
        nil
      end

      def detect_one(id, executable)
        path = which(executable)
        return nil unless path

        output, _err, status = Open3.capture3(executable, "--version")
        { id: id, version: status.success? ? output.strip : "unknown" }
      rescue StandardError
        { id: id, version: "unknown" }
      end

      def which(executable)
        return nil if executable.nil? || executable.empty?

        exts = (ENV["PATHEXT"] || "").split(File::PATH_SEPARATOR)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, executable)
          return candidate if File.file?(candidate) && File.executable?(candidate)

          exts.each do |ext|
            with_ext = candidate + ext
            return with_ext if File.file?(with_ext) && File.executable?(with_ext)
          end
        end
        nil
      end

      def h(*args)
        Reach::Runtime.hook_command(*args)
      end

      def configure_claude_code(workspace_path, space_kind = "slice")
        dir = File.join(workspace_path, ".claude")
        FileUtils.mkdir_p(dir)
        settings_path = File.join(dir, "settings.json")
        write_protected(settings_path, JSON.pretty_generate(claude_settings_content(space_kind)))
        mcp_path = File.join(workspace_path, ".mcp.json")
        write_protected(mcp_path, JSON.pretty_generate(claude_mcp_content))
        settings_path
      end

      CLAUDE_READ_MATCHER = "Read|Glob|Grep|NotebookRead|LS|WebFetch|WebSearch".freeze
      CODEX_READ_MATCHER = "view_image".freeze

      def claude_settings_content(space_kind = "slice")
        post_tool_use = []
        post_tool_use << hook_entry("Write|Edit|MultiEdit", hook_line("check", "--format", "agent"), 60) if %w[slice root].include?(space_kind.to_s)

        stop_hooks = []
        post_tool_use << hook_entry("Write|Edit|MultiEdit|NotebookEdit", hook_line("transcript", "code", "--harness", "claude-code"), 15)
        stop_hooks << hook_entry(nil, hook_line("hook", "stop", "--harness", "claude-code"), 30)
        stop_hooks << wake_entry(hook_line("live", "watch", "--harness", "claude-code")) if claude_wake?

        {
          "hooks" => {
            "SessionStart" => [hook_entry(nil, hook_line("gate", "session", "--harness", "claude-code"), 10)],
            "MessageDisplay" => [hook_entry(nil, hook_line("hook", "display", "--harness", "claude-code"), 30)],
            "UserPromptSubmit" => [hook_entry(nil, hook_line("gate", "prompt", "--harness", "claude-code"), 10)],
            "PreToolUse" => [
              hook_entry("Write|Edit|MultiEdit|NotebookEdit", hook_line("gate", "write", "--harness", "claude-code"), 10),
              hook_entry("Bash|PowerShell", hook_line("gate", "shell", "--harness", "claude-code"), 10),
              hook_entry(CLAUDE_READ_MATCHER, hook_line("gate", "read", "--harness", "claude-code"), 10)
            ],
            "PostToolUse" => post_tool_use,
            "Stop" => stop_hooks,
            "SessionEnd" => [hook_entry(nil, hook_line("hook", "stop", "--final", "--harness", "claude-code"), 30)]
          },
          "permissions" => {
            "deny" => [
              "Read(#{Reach::Paths.vault_dir}/**)",
              "Read(#{Reach::Paths.keys_dir}/**)"
            ]
          },
          "enableAllProjectMcpServers" => true
        }
      end

      def hook_line(*args)
        command = h(*args)
        Reach::Runtime.windows? ? "& #{command}; exit $LASTEXITCODE" : command
      end

      def claude_mcp_content
        {
          "mcpServers" => {
            "reach" => { "command" => Reach::Runtime.ruby_path, "args" => [Reach::Runtime.shim_path, "mcp"] }
          }
        }
      end

      CLAUDE_WAKE_VERSION = [2, 1, 288].freeze
      CLAUDE_PROBE_S = 5
      WAKE_TIMEOUT_S = 900

      def wake_entry(command)
        { "hooks" => [{ "type" => "command", "command" => command, "timeout" => WAKE_TIMEOUT_S, "async" => true, "asyncRewake" => true }] }
      end

      def claude_version
        return @claude_version if defined?(@claude_version)

        @claude_version = begin
          out = Timeout.timeout(CLAUDE_PROBE_S) { Open3.capture2e("claude", "--version").first }
          found = out.to_s.match(/(\d+)\.(\d+)\.(\d+)/)
          found && found.captures.map(&:to_i)
        rescue StandardError, Timeout::Error
          nil
        end
      end

      def claude_wake?
        return false unless Reach::Live.wake?

        version = claude_version
        !version.nil? && (version <=> CLAUDE_WAKE_VERSION) >= 0
      rescue StandardError
        false
      end

      def hook_entry(matcher, command, timeout)
        entry = { "hooks" => [{ "type" => "command", "command" => command, "timeout" => timeout }] }
        entry["matcher"] = matcher if matcher
        entry
      end

      def configure_codex(workspace_path, space_kind = "slice")
        dir = File.join(workspace_path, ".codex")
        FileUtils.mkdir_p(dir)
        config_path = File.join(dir, "config.toml")
        write_protected(config_path, codex_config_toml(space_kind))
        hooks_path = File.join(dir, "hooks.json")
        write_protected(hooks_path, JSON.pretty_generate(codex_hooks_content(space_kind)))
        Reach::CodexSetup.refresh_trust!(hooks_path)
        config_path
      end

      def codex_config_toml(space_kind = "slice")
        lines = []
        lines << "sandbox_mode = \"workspace-write\""
        lines << "web_search = \"disabled\"" if %w[slice root].include?(space_kind.to_s)
        lines << ""
        lines << "[sandbox_workspace_write]"
        lines << "writable_roots = [#{toml_string(Reach::Paths.root)}]"
        lines << "network_access = true"
        lines << ""
        lines << "[mcp_servers.reach]"
        lines << "command = #{toml_string(Reach::Runtime.ruby_path)}"
        lines << "args = [#{toml_string(Reach::Runtime.shim_path)}, \"mcp\"]"
        "#{lines.join("\n")}\n"
      end

      def codex_hooks_content(space_kind = "slice")
        post_tool_use = []
        post_tool_use << hook_entry("apply_patch|Write|Edit", hook_line("check", "--format", "agent"), 60) if %w[slice root].include?(space_kind.to_s)

        stop_hooks = []
        post_tool_use << hook_entry("apply_patch|Write|Edit", hook_line("transcript", "code", "--harness", "codex"), 15)
        stop_hooks << hook_entry(nil, hook_line("hook", "stop", "--harness", "codex"), 30)

        {
          "hooks" => {
            "PreToolUse" => [
              hook_entry("apply_patch|Write|Edit", hook_line("gate", "write", "--harness", "codex"), 10),
              hook_entry("Bash|shell|exec_command", hook_line("gate", "shell", "--harness", "codex"), 10),
              hook_entry(CODEX_READ_MATCHER, hook_line("gate", "read", "--harness", "codex"), 10)
            ],
            "PostToolUse" => post_tool_use,
            "Stop" => stop_hooks
          }
        }
      end

      HERMES_HOOK_WRITE_MATCHER = "write_file|patch|execute_code".freeze
      HERMES_HOOK_SHELL_MATCHER = "terminal".freeze
      HERMES_HOOK_READ_MATCHER = "read_file|search_files|list_files|list_directory|web_search|web_extract|browser_.*".freeze

      def hermes_hook_entry(command, timeout, matcher: nil, fail_closed: false)
        entry = {}
        entry["matcher"] = matcher if matcher
        entry["command"] = command
        entry["timeout"] = timeout
        entry["fail_closed"] = true if fail_closed
        entry
      end

      def hermes_hooks_content
        {
          "on_session_start" => [hermes_hook_entry(h("gate", "session", "--harness", "hermes"), 10)],
          "pre_llm_call" => [
            hermes_hook_entry(h("gate", "enroll", "--harness", "hermes"), 60),
            hermes_hook_entry(h("gate", "prompt", "--harness", "hermes"), 15)
          ],
          "pre_tool_call" => [
            hermes_hook_entry(h("gate", "write", "--harness", "hermes"), 10, matcher: HERMES_HOOK_WRITE_MATCHER, fail_closed: true),
            hermes_hook_entry(h("gate", "shell", "--harness", "hermes"), 10, matcher: HERMES_HOOK_SHELL_MATCHER, fail_closed: true),
            hermes_hook_entry(h("gate", "read", "--harness", "hermes"), 10, matcher: HERMES_HOOK_READ_MATCHER, fail_closed: true)
          ],
          "post_tool_call" => [hermes_hook_entry(h("transcript", "code", "--harness", "hermes"), 15)],
          "post_llm_call" => [hermes_hook_entry(h("hook", "stop", "--harness", "hermes"), 30)],
          "on_session_end" => [hermes_hook_entry(h("hook", "stop", "--final", "--harness", "hermes"), 30)],
          "pre_verify" => [hermes_hook_entry(h("check", "--format", "hermes"), 60)]
        }
      end

      def configure_hermes(_workspace_path = nil, _space_kind = nil)
        path = hermes_config_path
        return nil unless path && File.file?(path)

        text = File.read(path)
        loaded = begin
          YAML.safe_load(text, permitted_classes: [Date, Time, Symbol], aliases: false)
        rescue StandardError, Psych::SyntaxError
          return nil
        end
        loaded = {} if loaded.nil?
        return nil unless loaded.is_a?(Hash)

        computed = hermes_document(Marshal.load(Marshal.dump(loaded)))
        return nil unless computed
        return path if computed == loaded

        backup = "#{path}.reach-backup"
        FileUtils.cp(path, backup) unless File.exist?(backup)
        File.write(path, YAML.dump(computed))
        path
      rescue StandardError
        nil
      end

      def hermes_document(document)
        hooks = document["hooks"]
        hooks = {} if hooks.nil?
        return nil unless hooks.is_a?(Hash)

        shim = Reach::Runtime.shim_path
        legacy_shim = File.join(Reach::Paths.legacy_home, "bin", "reach")
        hermes_hooks_content.each do |event, entries|
          existing = hooks[event]
          existing = [] if existing.nil?
          return nil unless existing.is_a?(Array)

          kept = existing.reject { |entry| entry.is_a?(Hash) && (entry["command"].to_s.include?(shim) || entry["command"].to_s.include?(legacy_shim)) }
          hooks[event] = kept + entries
        end
        document["hooks"] = hooks

        servers = document["mcp_servers"]
        servers = {} if servers.nil?
        return nil unless servers.is_a?(Hash)

        servers["reach"] = { "command" => Reach::Runtime.ruby_path, "args" => [shim, "mcp"] }
        document["mcp_servers"] = servers

        agent = document["agent"]
        agent = {} if agent.nil?
        return nil unless agent.is_a?(Hash)

        disabled = agent["disabled_toolsets"]
        disabled = [] if disabled.nil?
        return nil unless disabled.is_a?(Array)

        disabled = disabled + ["code_execution"] unless disabled.include?("code_execution")
        agent["disabled_toolsets"] = disabled
        document["agent"] = agent
        document
      end

      def toml_string(value)
        escaped = value.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")
        "\"#{escaped}\""
      end

      def write_protected(path, content)
        File.chmod(0o644, path) if File.exist?(path)
        Reach::StateFile.write_atomic(path, content, mode: 0o644)
        File.chmod(0o444, path)
      rescue NotImplementedError, Errno::ENOENT
        nil
      rescue *Reach::Sandbox::WRITE_ERRORS
        keep_read_only(path)
        raise
      end

      def keep_read_only(path)
        File.chmod(0o444, path) if File.exist?(path)
      rescue NotImplementedError, SystemCallError
        nil
      end

      def terminal?
        $stdin.tty? && $stdout.tty?
      end

      def no_terminal_text(harness_id, workspace_path)
        app = Reach::HarnessMove.display(harness_id)
        here = Reach::Workspace.space_for(Reach::Paths.cwd)
        if here && (here["kind"] == "root" || Reach::Paths.realish(here["path"]) == Reach::Paths.realish(workspace_path))
          return Reach::Messages.text("M-WORK-HERE", app: app, folder: workspace_path, name: File.basename(workspace_path))
        end
        return Reach::Messages.text("M-WORK-CODEX-PROJECT", folder: Reach::Paths.workspace_root) if harness_id.to_s == "codex"

        Reach::Messages.text("M-WORK-NO-TERMINAL", app: app, folder: workspace_path)
      end

      def exec_harness(harness_id, workspace_path, initial_prompt)
        if %w[claude-code codex hermes].include?(harness_id.to_s) && !terminal?
          puts no_terminal_text(harness_id, workspace_path)
          return 0
        end

        case harness_id.to_s
        when "claude-code"
          Dir.chdir(workspace_path) { Kernel.exec(*["claude", initial_prompt].compact) }
        when "codex"
          Dir.chdir(workspace_path) { Kernel.exec(*["codex", initial_prompt].compact) }
        when "hermes"
          argv = ["hermes", "-p", "reach", "--accept-hooks", "chat"]
          argv.concat(["-q", initial_prompt]) if initial_prompt
          Dir.chdir(workspace_path) { Kernel.exec(*argv) }
        when "antigravity"
          if which("agy")
            Dir.chdir(workspace_path) { Kernel.exec(*["agy", initial_prompt].compact) }
          else
            puts "Open this folder in Antigravity: #{workspace_path}"
            0
          end
        else
          raise Reach::InstallError, "reach: unknown harness #{harness_id.inspect}"
        end
      end
    end
  end
end
