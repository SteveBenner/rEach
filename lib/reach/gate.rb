require "shellwords"
require "rbconfig"
require "json"
require "fileutils"
require "time"

module Reach
  module Gate
    READONLY_SINGLE = %w[ls cat head tail less grep rg find wc diff].freeze
    READONLY_GIT_SUBCOMMANDS = %w[status diff log].freeze
    WRITE_SINGLE = %w[cp mv rm mkdir touch tee truncate chmod npm npx bundle gem].freeze
    WRITE_INPLACE_COMMANDS = %w[sed perl].freeze
    WRITE_GIT_SUBCOMMANDS = %w[checkout restore reset clean].freeze
    NETWORK_COMMANDS = %w[curl wget ssh scp nc].freeze

    module_function

    def session(harness:)
      check_enrolled!
      check_guardrails!
      check_has_workspace!
      witness("session", "harness" => harness.to_s)
      nil
    end

    def prompt
      check_enrolled!
      check_guardrails!
      check_has_workspace!
      witness("prompt")
      nil
    end

    def witness(kind, fields = {})
      workspace = current_workspace_path
      Reach::Ledger.append(workspace, kind, fields) if workspace
    rescue StandardError
      nil
    end

    PATCH_PREFIXES = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "].freeze

    def write(path: nil, patch: nil)
      return nil if path.nil? && patch.nil?

      workspace = current_workspace_path
      owned = workspace ? owned_absolute_paths(workspace) : []

      if patch
        base = workspace || Dir.pwd
        patch_targets(patch).each do |relative|
          target = resolve_target(File.expand_path(relative, base))
          next if owned.any? { |candidate| same_path?(candidate, target) }

          raise_blocked!("M-WRITE-OUTSIDE", owned_files: owned_files_display(workspace))
        end
        return nil
      end

      target = resolve_target(path)
      return nil if owned.any? { |candidate| same_path?(candidate, target) }

      raise_blocked!(
        "M-WRITE-OUTSIDE",
        owned_files: owned_files_display(workspace)
      )
    end

    def patch_targets(patch)
      patch.to_s.each_line.each_with_object([]) do |line, targets|
        PATCH_PREFIXES.each do |prefix|
          if line.start_with?(prefix)
            targets << line[prefix.length..-1].to_s.strip
          end
        end
      end
    end

    def shell(command:)
      text = command.to_s
      raise_blocked!("M-SHELL-BLOCKED") if subshell_or_substitution?(text)

      workspace = current_workspace_path
      owned = workspace ? owned_absolute_paths(workspace) : []

      split_segments(text).each do |segment|
        check_segment!(segment, workspace, owned)
      end

      witness("shell", "command_digest" => Reach::Crypto.digest_hex(text), "head" => text[0, 200])
      nil
    end

    def check_enrolled!
      install = begin
        Reach::Enrol.current
      rescue StandardError
        nil
      end
      raise_blocked!("M-GATE-NOENROL") unless install

      revoked = begin
        Reach::Enrol.revoked?
      rescue StandardError
        false
      end
      raise_blocked!("M-GATE-REVOKED") if revoked
    end

    def check_guardrails!
      Reach::Guardrails.load
    rescue Reach::Refused
      raise_blocked!("M-GATE-NOGUARD")
    end

    def check_has_workspace!
      slices = begin
        Reach::Workspace.current_slices
      rescue StandardError
        []
      end
      raise_blocked!("M-GATE-NOGUARD") if slices.empty?
    end

    def raise_blocked!(message_id, **fields)
      text = Reach::Messages.text(message_id, **fields)
      log_refusal(message_id, text)
      raise Reach::GateBlocked.new(message_id, text)
    end

    def log_refusal(message_id, text)
      FileUtils.mkdir_p(Reach::Paths.logs_dir)
      path = File.join(Reach::Paths.logs_dir, "gate-refusals.jsonl")
      record = { "at" => Time.now.utc.iso8601, "message_id" => message_id.to_s, "text" => text }
      File.open(path, "a") { |f| f.puts(JSON.generate(record)) }
    rescue StandardError
      nil
    end

    def current_workspace_path
      cwd = File.realpath(Dir.pwd)
      slices = Reach::Workspace.current_slices
      slices.find do |workspace|
        real_workspace = File.realpath(workspace)
        cwd == real_workspace || cwd.start_with?(real_workspace + File::SEPARATOR)
      end
    rescue StandardError
      nil
    end

    def owned_absolute_paths(workspace)
      Reach::Workspace.owned_files(workspace).map do |relative|
        resolve_target(File.join(workspace, relative))
      end
    end

    def owned_files_display(workspace)
      return "" unless workspace

      Reach::Workspace.owned_files(workspace).join(", ")
    rescue StandardError
      ""
    end

    def resolve_target(path)
      expanded = File.expand_path(path.to_s)
      dir = File.dirname(expanded)
      base = File.basename(expanded)
      real_dir = File.exist?(dir) ? File.realpath(dir) : dir
      File.join(real_dir, base)
    rescue Errno::ENOENT, Errno::ENOTDIR
      expanded
    end

    def same_path?(a, b)
      return false if a.nil? || b.nil?

      case_insensitive_fs? ? a.casecmp(b).zero? : a == b
    end

    def within?(path, root)
      return false if path.nil? || root.nil?

      root_resolved = resolve_target(root)
      return true if same_path?(path, root_resolved)

      if case_insensitive_fs?
        path.downcase.start_with?("#{root_resolved.downcase}#{File::SEPARATOR}")
      else
        path.start_with?("#{root_resolved}#{File::SEPARATOR}")
      end
    end

    def case_insensitive_fs?
      RbConfig::CONFIG["host_os"].to_s =~ /mswin|mingw|darwin/i ? true : false
    end

    def subshell_or_substitution?(text)
      text.include?("$(") || text.include?("`") || text.include?("(")
    end

    def split_segments(text)
      segments = []
      current = +""
      quote = nil
      chars = text.chars
      i = 0
      while i < chars.length
        ch = chars[i]
        if quote
          current << ch
          quote = nil if ch == quote
          i += 1
          next
        end
        case ch
        when "'", '"'
          quote = ch
          current << ch
          i += 1
        when ";", "\n"
          segments << current
          current = +""
          i += 1
        when "&"
          if chars[i + 1] == "&"
            segments << current
            current = +""
            i += 2
          else
            current << ch
            i += 1
          end
        when "|"
          if chars[i + 1] == "|"
            segments << current
            current = +""
            i += 2
          else
            segments << current
            current = +""
            i += 1
          end
        else
          current << ch
          i += 1
        end
      end
      segments << current
      segments.map(&:strip).reject(&:empty?)
    end

    def check_segment!(segment, workspace, owned)
      tokens = begin
        Shellwords.split(segment)
      rescue ArgumentError
        raise_blocked!("M-SHELL-BLOCKED")
      end
      return if tokens.empty?

      plain_tokens, redirect_targets = extract_redirects(tokens)
      cmd = plain_tokens[0]
      return if cmd.nil?

      check_vault_or_keys_reads!(plain_tokens, workspace)

      if NETWORK_COMMANDS.include?(cmd)
        raise_blocked!("M-SHELL-BLOCKED")
      elsif readonly_command?(plain_tokens)
        nil
      elsif write_command?(plain_tokens)
        redirect_targets.each { |target| ensure_owned_target!(target, workspace, owned) }
        ensure_write_args_owned!(plain_tokens, workspace, owned)
      else
        ensure_unknown_allowed!(plain_tokens, redirect_targets, workspace)
      end
    end

    def extract_redirects(tokens)
      plain = []
      redirects = []
      i = 0
      while i < tokens.length
        tok = tokens[i]
        if tok == ">" || tok == ">>"
          target = tokens[i + 1]
          redirects << target if target
          i += 2
        else
          plain << tok
          i += 1
        end
      end
      [plain, redirects]
    end

    def check_vault_or_keys_reads!(tokens, workspace)
      tokens.each do |tok|
        next unless path_like?(tok)

        resolved = resolve_arg(tok, workspace)
        raise_blocked!("M-SHELL-BLOCKED") if within?(resolved, Reach::Paths.vault_dir) || within?(resolved, Reach::Paths.keys_dir)
      end
    end

    def ensure_owned_target!(token, workspace, owned)
      resolved = resolve_arg(token, workspace)
      return if owned.any? { |candidate| same_path?(candidate, resolved) }

      raise_blocked!("M-SHELL-BLOCKED")
    end

    def ensure_write_args_owned!(tokens, workspace, owned)
      tokens[1..-1].to_a.each do |tok|
        next if tok.start_with?("-")
        next unless path_like?(tok)

        resolved = resolve_arg(tok, workspace)
        next if owned.any? { |candidate| same_path?(candidate, resolved) }

        raise_blocked!("M-SHELL-BLOCKED")
      end
    end

    def ensure_unknown_allowed!(tokens, redirect_targets, workspace)
      raise_blocked!("M-SHELL-BLOCKED") unless redirect_targets.empty?

      tokens[1..-1].to_a.each do |tok|
        next if tok.start_with?("-")
        next unless path_like?(tok)

        resolved = resolve_arg(tok, workspace)
        raise_blocked!("M-SHELL-BLOCKED") unless workspace && within?(resolved, workspace)
      end
    end

    def readonly_command?(tokens)
      cmd = tokens[0]
      return true if cmd == "reach"
      return true if cmd == "ruby" && tokens[1] == "-c"
      return READONLY_GIT_SUBCOMMANDS.include?(tokens[1]) if cmd == "git"
      return !(tokens.include?("-delete") || tokens.include?("-exec")) if cmd == "find"

      READONLY_SINGLE.include?(cmd)
    end

    def write_command?(tokens)
      cmd = tokens[0]
      return true if cmd == "find" && (tokens.include?("-delete") || tokens.include?("-exec"))
      return true if WRITE_INPLACE_COMMANDS.include?(cmd) && tokens.any? { |t| t.start_with?("-i") }
      return true if cmd == "git" && WRITE_GIT_SUBCOMMANDS.include?(tokens[1])

      WRITE_SINGLE.include?(cmd)
    end

    def path_like?(token)
      return false if token.nil? || token.empty?

      token.start_with?("/", "~", "./", "../") || token.include?("/")
    end

    def resolve_arg(token, workspace)
      base = workspace || Dir.pwd
      resolve_target(File.expand_path(token, base))
    end
  end
end
