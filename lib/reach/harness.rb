require "open3"
require "json"
require "fileutils"

module Reach
  module Harness
    class << self
      def detect
        [detect_one("claude-code", "claude"), detect_one("codex", "codex"), detect_one("antigravity", "agy")].compact
      end

      def configure_all(workspace_path)
        ids = []
        [["claude-code", :configure_claude_code], ["codex", :configure_codex]].each do |id, method_name|
          begin
            send(method_name, workspace_path)
            ids << id
          rescue StandardError
            nil
          end
        end
        ids
      rescue StandardError
        []
      end

      def configure(harness_id, workspace_path)
        case harness_id.to_s
        when "claude-code"
          configure_claude_code(workspace_path)
        when "codex"
          configure_codex(workspace_path)
        when "antigravity"
          nil
        else
          raise Reach::InstallError, "reach: unknown harness #{harness_id.inspect}"
        end
      end

      def launch(harness_id, workspace_path, initial_prompt: nil)
        is_workspace = workspace_launch?(workspace_path)
        if is_workspace
          Reach::Gate.session(harness: harness_id)
          Reach::Workspace.write_rules_files(workspace_path)
          configure(harness_id, workspace_path)
        end
        exec_harness(harness_id, workspace_path, initial_prompt)
      end

      private

      def workspace_launch?(workspace_path)
        return true if File.file?(File.join(workspace_path, ".reach", "slice.json"))

        Reach::Workspace.current_slices.any? do |slice_path|
          File.realpath(slice_path) == File.realpath(workspace_path)
        end
      rescue StandardError
        false
      end

      def detect_one(id, executable)
        path = which(executable)
        return nil unless path

        output, status = Open3.capture2(executable, "--version")
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

      def configure_claude_code(workspace_path)
        dir = File.join(workspace_path, ".claude")
        FileUtils.mkdir_p(dir)
        settings_path = File.join(dir, "settings.json")
        write_protected(settings_path, JSON.pretty_generate(claude_settings_content))
        mcp_path = File.join(workspace_path, ".mcp.json")
        write_protected(mcp_path, JSON.pretty_generate(claude_mcp_content))
        settings_path
      end

      def claude_settings_content
        {
          "hooks" => {
            "SessionStart" => [hook_entry(nil, h("gate", "session", "--harness", "claude-code"), 10)],
            "UserPromptSubmit" => [hook_entry(nil, h("gate", "prompt", "--harness", "claude-code"), 10)],
            "PreToolUse" => [
              hook_entry("Write|Edit|MultiEdit|NotebookEdit", h("gate", "write"), 10),
              hook_entry("Bash", h("gate", "shell"), 10)
            ],
            "PostToolUse" => [
              hook_entry("Write|Edit|MultiEdit", h("check", "--format", "agent"), 60)
            ],
            "Stop" => [
              hook_entry(nil, h("attempts", "settle"), 30),
              hook_entry(nil, h("transcript", "flush", "--quick"), 30)
            ],
            "SessionEnd" => [hook_entry(nil, h("transcript", "flush", "--quick", "--final"), 30)]
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

      def claude_mcp_content
        {
          "mcpServers" => {
            "reach" => { "command" => Reach::Runtime.ruby_path, "args" => [Reach::Runtime.shim_path, "mcp"] }
          }
        }
      end

      def hook_entry(matcher, command, timeout)
        entry = { "hooks" => [{ "type" => "command", "command" => command, "timeout" => timeout }] }
        entry["matcher"] = matcher if matcher
        entry
      end

      def configure_codex(workspace_path)
        dir = File.join(workspace_path, ".codex")
        FileUtils.mkdir_p(dir)
        config_path = File.join(dir, "config.toml")
        write_protected(config_path, codex_config_toml)
        hooks_path = File.join(dir, "hooks.json")
        write_protected(hooks_path, JSON.pretty_generate(codex_hooks_content))
        config_path
      end

      def codex_config_toml
        lines = []
        lines << "sandbox_mode = \"workspace-write\""
        lines << ""
        lines << "[sandbox_workspace_write]"
        lines << "writable_roots = [#{toml_string(Reach::Paths.home)}]"
        lines << "network_access = true"
        lines << ""
        lines << "[mcp_servers.reach]"
        lines << "command = #{toml_string(Reach::Runtime.ruby_path)}"
        lines << "args = [#{toml_string(Reach::Runtime.shim_path)}, \"mcp\"]"
        "#{lines.join("\n")}\n"
      end

      def codex_hooks_content
        {
          "hooks" => {
            "SessionStart" => [hook_entry(nil, h("gate", "session", "--harness", "codex"), 10)],
            "UserPromptSubmit" => [hook_entry(nil, h("gate", "prompt", "--harness", "codex"), 10)],
            "PreToolUse" => [
              hook_entry("apply_patch|Write|Edit", h("gate", "write"), 10),
              hook_entry("Bash|shell|exec_command", h("gate", "shell"), 10)
            ],
            "PostToolUse" => [
              hook_entry("apply_patch|Write|Edit", h("check", "--format", "agent"), 60)
            ],
            "Stop" => [
              hook_entry(nil, h("attempts", "settle"), 30),
              hook_entry(nil, h("transcript", "flush", "--quick"), 30)
            ]
          }
        }
      end

      def toml_string(value)
        escaped = value.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")
        "\"#{escaped}\""
      end

      def write_protected(path, content)
        File.chmod(0o644, path) if File.exist?(path)
        File.write(path, content)
        File.chmod(0o444, path)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end

      def exec_harness(harness_id, workspace_path, initial_prompt)
        case harness_id.to_s
        when "claude-code"
          Dir.chdir(workspace_path) { Kernel.exec(*["claude", initial_prompt].compact) }
        when "codex"
          Dir.chdir(workspace_path) { Kernel.exec(*["codex", initial_prompt].compact) }
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
