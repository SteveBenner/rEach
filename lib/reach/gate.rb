require "shellwords"
require "rbconfig"
require "json"
require "fileutils"
require "time"

module Reach
  module Gate
    READONLY_SINGLE = %w[ls cat head tail less grep rg find wc diff].freeze
    WRITE_SINGLE = %w[cp mv rm mkdir touch tee truncate chmod npm npx bundle gem].freeze
    WRITE_INPLACE_COMMANDS = %w[sed perl].freeze
    NETWORK_COMMANDS = %w[curl wget ssh scp nc].freeze
    INLINE_CODE_FLAGS = {
      /\Aruby[0-9.]*\z/ => %w[-e],
      /\Apython[0-9.]*\z/ => %w[-c],
      /\Anode\z/ => %w[-e -p --eval --print],
      /\Aperl\z/ => %w[-e -E],
      /\A(ba|z)?sh\z/ => %w[-c]
    }.freeze

    module_function

    def session(harness:)
      check_enrolled!
      check_guardrails!
      check_has_workspace!
      witness("session", "harness" => harness.to_s)
      nil
    end

    def prompt(event: {}, harness: nil)
      blocked = nil
      begin
        check_enrolled!
        check_guardrails!
        check_has_workspace!
      rescue Reach::GateBlocked => e
        blocked = e
      end

      entry = begin
        resolved_harness = Reach::Transcript.resolve_harness(harness)
        Reach::Transcript.capture(event, harness: resolved_harness, gate: blocked ? "blocked" : "allowed")
      rescue StandardError
        nil
      end

      unless blocked
        if entry
          witness("prompt", "session" => entry["session_id"], "seq" => entry["seq"], "digest" => entry["digest"])
        else
          witness("prompt")
        end
      end

      raise blocked if blocked

      nil
    end

    def code_tool!
      space = current_space
      return nil if space && space["kind"] == "extracurricular"

      raise_blocked!("M-GATE-NOCODETOOL")
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

      space = current_space
      kind = space && space["kind"]

      raise_blocked!("M-WRITE-ROOT") if kind == "root"

      if kind == "extracurricular"
        root = space["path"]
        if patch
          patch_targets(patch).each do |relative|
            target = resolve_target(File.expand_path(relative, root))
            raise_blocked!("M-WRITE-OUTSIDE-EXTRA") unless within?(target, root)
          end
          return nil
        end

        target = resolve_target(path)
        raise_blocked!("M-WRITE-OUTSIDE-EXTRA") unless within?(target, root)
        return nil
      end

      workspace = kind == "slice" ? space["path"] : nil
      owned = workspace ? owned_absolute_paths(workspace) : []
      writable = ->(target) { owned.any? { |candidate| same_path?(candidate, target) } || qualify_target?(workspace, target) }

      if patch
        base = workspace || Dir.pwd
        patch_targets(patch).each do |relative|
          target = resolve_target(File.expand_path(relative, base))
          next if writable.call(target)

          raise_blocked!("M-WRITE-OUTSIDE", owned_files: owned_files_display(workspace))
        end
        check_ladder!(workspace)
        return nil
      end

      target = resolve_target(path)
      if writable.call(target)
        check_ladder!(workspace)
        return nil
      end

      raise_blocked!(
        "M-WRITE-OUTSIDE",
        owned_files: owned_files_display(workspace)
      )
    end

    def qualify_target?(workspace, target)
      return false unless workspace

      Reach::Workspace::WRITABLE_DIRS.any? { |dir| within?(target, File.join(workspace, dir)) && !same_path?(target, resolve_target(File.join(workspace, dir))) }
    end

    def check_ladder!(workspace)
      return unless workspace

      message_id = Reach::Ladder.blocked_message(workspace)
      return unless message_id

      raise_blocked!(message_id, attempt: Reach::Ladder.state(workspace)["failed"], limit: Reach::Ladder::HARD_STOP)
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

      space = current_space
      kind = space && space["kind"]

      if kind == "root"
        split_segments(text).each { |segment| check_root_segment!(segment) }
        return nil
      end

      workspace = space && space["path"]
      owned_test = shell_owned_test(kind, workspace)

      split_segments(text).each do |segment|
        check_segment!(segment, workspace, owned_test, kind)
      end

      witness("shell", "command_digest" => Reach::Crypto.digest_hex(text), "head" => text[0, 200]) if kind == "slice"
      nil
    end

    def shell_owned_test(kind, workspace)
      if kind == "extracurricular"
        root = workspace
        ->(resolved) { within?(resolved, root) }
      else
        owned = workspace ? owned_absolute_paths(workspace) : []
        ->(resolved) { owned.any? { |candidate| same_path?(candidate, resolved) } || qualify_target?(workspace, resolved) }
      end
    end

    def check_root_segment!(segment)
      tokens = begin
        Shellwords.split(segment)
      rescue ArgumentError
        raise_blocked!("M-SHELL-BLOCKED")
      end
      return if tokens.empty?

      cmd = tokens[0]
      raise_blocked!("M-GATE-NOGIT") if cmd == "git"
      return if cmd.nil? || cmd == "reach" || readonly_command?(tokens)

      raise_blocked!("M-SHELL-BLOCKED")
    end

    def check_enrolled!
      install = begin
        Reach::Enroll.current
      rescue StandardError
        nil
      end
      raise_blocked!("M-GATE-NOENROLL") unless install

      revoked = begin
        Reach::Enroll.revoked?
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

    def current_space
      cwd = File.realpath(Dir.pwd)
      Reach::Workspace.space_for(cwd)
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
      quote = nil
      chars = text.chars
      i = 0
      while i < chars.length
        ch = chars[i]
        if quote == "'"
          quote = nil if ch == "'"
        elsif ch == "\\"
          i += 1
        elsif quote == '"'
          return true if ch == "`" || (ch == "$" && chars[i + 1] == "(")
          quote = nil if ch == '"'
        elsif ch == "'" || ch == '"'
          quote = ch
        elsif ch == "`" || ch == "("
          return true
        end
        i += 1
      end
      false
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

    def check_segment!(segment, workspace, owned_test, kind = "slice")
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
      raise_blocked!("M-GATE-NOGIT") if cmd == "git" && kind != "extracurricular"
      raise_blocked!("M-GATE-NOCODETOOL") if kind != "extracurricular" && inline_code?(plain_tokens)

      if NETWORK_COMMANDS.include?(cmd)
        raise_blocked!("M-SHELL-BLOCKED")
      elsif readonly_command?(plain_tokens)
        nil
      elsif write_command?(plain_tokens)
        redirect_targets.each { |target| ensure_owned_target!(target, workspace, owned_test) }
        ensure_write_args_owned!(plain_tokens, workspace, owned_test)
        check_ladder!(workspace) if kind == "slice"
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

    def ensure_owned_target!(token, workspace, owned_test)
      resolved = resolve_arg(token, workspace)
      return if owned_test.call(resolved)

      raise_blocked!("M-SHELL-BLOCKED")
    end

    def ensure_write_args_owned!(tokens, workspace, owned_test)
      tokens[1..-1].to_a.each do |tok|
        next if tok.start_with?("-")
        next unless path_like?(tok)

        resolved = resolve_arg(tok, workspace)
        next if owned_test.call(resolved)

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
      return true if reach_shim_call?(tokens)
      return true if cmd == "ruby" && tokens[1] == "-c"
      return !(tokens.include?("-delete") || tokens.include?("-exec")) if cmd == "find"

      READONLY_SINGLE.include?(cmd)
    end

    def inline_code?(tokens)
      name = File.basename(tokens[0].to_s)
      flags = INLINE_CODE_FLAGS.find { |pattern, _| name =~ pattern }
      return false unless flags

      tokens[1..-1].to_a.any? do |tok|
        flags[1].include?(tok) || flags[1].any? { |flag| flag.length == 2 && tok =~ /\A-[a-zA-Z]{1,3}\z/ && !tok.start_with?("-I", "-r") && tok.end_with?(flag[1]) }
      end
    end

    def reach_shim_call?(tokens)
      return false unless File.basename(tokens[0].to_s) =~ /\Aruby[0-9.]*\z/ && tokens[1]

      File.expand_path(tokens[1]) == File.expand_path(Reach::Runtime.shim_path)
    rescue StandardError
      false
    end

    def write_command?(tokens)
      cmd = tokens[0]
      return true if cmd == "find" && (tokens.include?("-delete") || tokens.include?("-exec"))
      return true if WRITE_INPLACE_COMMANDS.include?(cmd) && tokens.any? { |t| t.start_with?("-i") }

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
