require "shellwords"
require "rbconfig"
require "json"
require "fileutils"
require "time"
require "securerandom"

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
    READ_TOOLS = %w[Read Glob Grep NotebookRead LS read_file search_files list_files list_directory view_image].freeze
    WEB_TOOLS = %w[WebFetch WebSearch web_search web_extract].freeze
    PATH_INPUT_KEYS = %w[file_path notebook_path path directory dir root].freeze
    OUTSIDE_ALLOWED = %w[/dev/null /dev/stdout /dev/stderr].freeze
    OUTSIDE_REFUSAL_LIMIT = 3

    module_function

    def session(harness:)
      return nil if Reach::Instructor.mode?

      check_enrolled!
      check_guardrails!
      check_has_workspace!
      witness("session", "harness" => harness.to_s)
      nil
    end

    def prompt(event: {}, harness: nil)
      event = {} unless event.is_a?(Hash)
      toggled = safely { Reach::Debug.toggle_from_prompt!(event["prompt"]) }
      if Reach::Instructor.mode?
        return Reach::Messages.text("M-DEBUG-RELAY", text: toggled) if toggled

        return Reach::Instructor.context_once(Reach::Transcript.resolve_session_id(event))
      end

      blocked = nil
      begin
        check_enrolled!
        check_guardrails!
        check_has_workspace!
        Reach::Update.hold!
      rescue Reach::GateBlocked => e
        blocked = e
      end

      decision = nil
      unless blocked
        begin
          decision = Reach::Login.evaluate(event: event, harness: harness) if Reach::Login.required?
        rescue StandardError
          decision = { "action" => "block", "message" => Reach::Messages.text("M-LOGIN-NEEDED"), "note" => nil, "failed" => true }
        end
      end
      login_block = decision && decision["action"] == "block"

      locked = !blocked.nil? && Reach::EnrollmentLock::MESSAGES.value?(blocked.message_id)
      entry = locked ? nil : begin
        resolved_harness = Reach::Transcript.resolve_harness(harness)
        options = { harness: resolved_harness, gate: blocked || login_block ? "blocked" : "allowed" }
        options[:note] = decision["note"] if login_block && decision["note"]
        Reach::Transcript.capture(event, **options)
      rescue StandardError
        nil
      end

      if decision && !decision["failed"]
        begin
          Reach::Login.commit!(decision, event: event, harness: harness)
        rescue StandardError
          nil
        end
      end

      raise blocked if blocked
      raise Reach::GateBlocked.new("M-LOGIN", decision["message"].to_s) if login_block

      if entry
        witness("prompt", "session" => entry["session_id"], "seq" => entry["seq"], "digest" => entry["digest"])
      else
        witness("prompt")
      end

      prompt_context(event, harness, decision, entry, toggled: toggled)
    end

    def prompt_context(event, harness, decision, entry, toggled: nil)
      session = Reach::Transcript.resolve_session_id(event)
      space = current_space
      context = []
      greeted = false

      if decision
        if safely { Reach::Login.just_confirmed?(session) }
          context << signed_in_context(harness, session)
          after_answer { Reach::Login.clear_just_confirmed(session) }
          greeted = true
        end
        context << decision["context"] if decision["context"]
      end
      stored = safely { Reach::Hello.stored_context(session) }
      if stored
        context << stored
        after_answer { Reach::Hello.clear_stored_context(session) }
      end
      context.concat(Array(safely { Reach::Update.prompt_notices(session) }))
      context.concat(Array(safely { storage_notices(session, greeted) }))
      context.concat(Array(safely { Reach::ExportImport.prompt_notices(session) }))
      context << safely { Reach::Debug.remote_notice(session) }
      context << safely { Reach::LateWork.prompt_notice(session) }
      transcripts = safely { Reach::TranscriptExport.pending_notice! }
      context << Reach::TranscriptExport.agent_notice(transcripts) if transcripts
      observed = safely { Reach::Consent.observe(entry) } if entry
      if observed
        done = safely { Reach::Consent.follow_up!(observed) }
        context << Reach::Consent.agent_context(observed, done) unless done.to_s.empty?
      end
      if space
        imports = safely { Reach::Imports.observe(text: event["prompt"], space_path: space["path"], session_id: session, harness: harness) }
        context.concat(Array(imports))
        context << safely { Reach::Next.anchor_text(space) }
      end
      context << safely { Reach::Brain.prompt_context(session_id: session, prompt: event["prompt"]) }
      context << Reach::Messages.text("M-DEBUG-RELAY", text: toggled) if toggled

      text = context.compact.map(&:to_s).reject(&:empty?).join("\n\n")
      text.empty? ? nil : text
    end

    def signed_in_context(harness, session)
      student = safely { Reach::Login.student } || {}
      name = student["display_name"].to_s.empty? ? "the enrolled student" : student["display_name"]
      parts = [Reach::Messages.text("M-LOGIN-DONE-AGENT", name: name)]
      parts << safely { Reach::Hello.context_text(harness: harness, cwd: Dir.pwd, source: "startup", session: session) }
      parts.compact.join("\n\n")
    end

    def storage_notices(session, greeted)
      return [] if Reach::Locks.bounded? && !Reach::Locks.free?(Reach::Paths.storage_lock_file("state"))

      Reach::Storage.prompt_notices(session, greeted: greeted)
    end

    def after_answer(&block)
      @after_answer ||= []
      @after_answer << block
      nil
    end

    def run_after_answer
      pending = @after_answer || []
      @after_answer = []
      pending.each { |callback| safely(&callback) }
      nil
    end

    def safely
      yield
    rescue StandardError
      nil
    end

    def require_login!(event)
      return unless Reach::Login.required?

      session = event.is_a?(Hash) && !event["session_id"].to_s.empty? ? Reach::Login.session_id(event) : nil
      confirmed = session ? Reach::Login.session_confirmed?(session) : Reach::Login.any_active?
      raise_blocked!("M-LOGIN-NEEDED") unless confirmed
    rescue Reach::GateBlocked
      raise
    rescue StandardError
      raise_blocked!("M-LOGIN-NEEDED")
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

    def write(path: nil, patch: nil, event: nil, harness: nil)
      return nil if path.nil? && patch.nil?

      check_enrolled!
      require_login!(event)
      Reach::Update.hold!
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
        check_time_and_module!(workspace)
        return nil
      end

      target = resolve_target(path)
      if writable.call(target)
        check_ladder!(workspace)
        check_time_and_module!(workspace)
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

    def shell(command:, event: nil, harness: nil)
      text = command.to_s
      return nil if support_command?(text)

      check_enrolled!
      require_login!(event)
      Reach::Update.hold!
      raise_blocked!("M-SHELL-BLOCKED") if subshell_or_substitution?(text)

      space = current_space
      kind = space && space["kind"]
      state = { cwd: hook_cwd(event) }

      if kind == "root"
        split_segments(text).each do |segment|
          check_outside_segment!(segment, state, event)
          check_root_segment!(segment)
        end
        return nil
      end

      workspace = space && space["path"]
      owned_test = shell_owned_test(kind, workspace)

      split_segments(text).each do |segment|
        check_outside_segment!(segment, state, event)
        check_segment!(segment, workspace, owned_test, kind)
      end

      witness("shell", "command_digest" => Reach::Crypto.digest_hex(text), "head" => text[0, 200]) if kind == "slice"
      nil
    end

    def read(event: {}, harness: nil)
      event = {} unless event.is_a?(Hash)
      check_enrolled!
      require_login!(event)

      tool = event["tool_name"].to_s
      input = event["tool_input"].is_a?(Hash) ? event["tool_input"] : {}
      space = current_space
      kind = space && space["kind"]
      return nil unless kind

      if WEB_TOOLS.include?(tool) || tool.start_with?("browser_")
        raise_blocked!("M-GATE-NOWEB") if kind == "slice" || kind == "root"
        return nil
      end
      return nil unless READ_TOOLS.include?(tool)

      base = hook_cwd(event)
      read_paths(tool, input, base).each do |candidate|
        raise_outside!(event, tool) if outside_path?(candidate, base)
      end
      nil
    end

    def read_paths(tool, input, base)
      found = PATH_INPUT_KEYS.map { |key| input[key] }.select { |value| value.is_a?(String) && !value.empty? }
      glob_base = found.first ? File.expand_path(found.first, base) : base
      patterns = []
      patterns << input["pattern"] if tool == "Glob"
      patterns << input["glob"]
      patterns.each do |pattern|
        next unless pattern.is_a?(String) && !pattern.empty?
        next unless pattern.start_with?("/", "~") || pattern.split("/").include?("..")

        found << File.expand_path(glob_prefix(pattern), glob_base)
      end
      found
    rescue ArgumentError
      found
    end

    def glob_prefix(pattern)
      index = pattern =~ /[*?\[{]/
      index ? pattern[0...index] : pattern
    end

    def hook_cwd(event)
      cwd = event.is_a?(Hash) ? event["cwd"] : nil
      cwd.is_a?(String) && File.directory?(cwd) ? File.realpath(cwd) : File.realpath(Dir.pwd)
    rescue StandardError
      Dir.pwd
    end

    def real_resolve(path, base)
      expanded = File.expand_path(path.to_s, base)
      return File.realpath(expanded) if File.exist?(expanded)

      rest = []
      current = expanded
      until File.exist?(current) || current == File.dirname(current)
        rest.unshift(File.basename(current))
        current = File.dirname(current)
      end
      real = File.exist?(current) ? File.realpath(current) : current
      File.join(real, *rest)
    rescue SystemCallError, ArgumentError
      nil
    end

    def outside_path?(path, base)
      return false if OUTSIDE_ALLOWED.include?(path.to_s)

      resolved = real_resolve(path, base)
      return true if resolved.nil?

      root = Reach::Paths.workspace_root
      root_real = File.exist?(root) ? File.realpath(root) : File.expand_path(root)
      return true if within?(resolved, Reach::Paths.root)

      !within?(resolved, root_real)
    end

    def raise_outside!(event, tool)
      count_outside(event, tool)
      raise_blocked!("M-GATE-OUTSIDE")
    end

    def count_outside(event, tool)
      session = Reach::Transcript.resolve_session_id(event)
      FileUtils.mkdir_p(Reach::Paths.sandbox_state_dir)
      begin
        File.chmod(0o700, Reach::Paths.sandbox_state_dir)
      rescue NotImplementedError, Errno::ENOENT, Errno::EPERM
        nil
      end
      path = File.join(Reach::Paths.sandbox_state_dir, "#{session}.json")
      Reach::Locks.exclusive(path) do |file|
        state = begin
          JSON.parse(file.read)
        rescue StandardError
          {}
        end
        state = {} unless state.is_a?(Hash)
        count = state["refusals"].to_i + 1
        reported = state["reported"] == true
        if count >= OUTSIDE_REFUSAL_LIMIT && !reported
          queue_outside_access(session, tool.to_s, count)
          reported = true
        end
        file.rewind
        file.truncate(0)
        file.write(JSON.generate("refusals" => count, "reported" => reported))
      end
    rescue StandardError
      nil
    end

    def queue_outside_access(session, tool, count)
      detail = JSON.generate("session_id" => session, "tool" => tool, "count" => count)
      workspace = current_workspace_path
      if Reach::Integrity.respond_to?(:queue)
        Reach::Integrity.queue("outside_access", detail: detail, workspace: workspace)
      else
        meta = workspace ? Reach::Workspace.metadata(workspace) : {}
        body = {
          "kind" => "outside_access", "detail" => detail, "cutout_id" => meta["cutout_id"], "slice" => meta["slice"],
          "path" => nil, "ledger_head" => nil, "client_created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
        Reach::Integrity.write_outbox(SecureRandom.uuid, body)
      end
    end

    def check_time_and_module!(workspace)
      return unless workspace

      meta = Reach::Workspace.metadata(workspace)
      raise_blocked!("M-GATE-NOT-CURRENT") unless Reach::Pace.writable?(workspace)
      safely { Reach::LateWork.note_write(workspace) }

      allowed = begin
        Reach::Modules.allows?(meta["cutout_id"])
      rescue StandardError
        true
      end
      return if allowed

      ids = begin
        Reach::Modules.module_ids
      rescue StandardError
        []
      end
      raise_blocked!("M-GATE-NOT-YOUR-MODULE", modules: module_names(ids))
    end

    def module_names(ids)
      names = begin
        Reach::Modules.names(ids)
      rescue StandardError
        nil
      end
      return names if names.is_a?(String) && !names.empty?

      list = Array(ids).map(&:to_s)
      return list.first.to_s if list.length <= 1

      "#{list[0...-1].join(', ')} and #{list.last}"
    end

    def shim_index(tokens)
      return nil if tokens.nil? || tokens.empty?

      shims = [File.expand_path(Reach::Runtime.shim_path), File.expand_path("~/.reach/bin/reach")]
      return 0 if tokens[0] == "reach" || shims.include?(File.expand_path(tokens[0].to_s))
      return 1 if File.basename(tokens[0].to_s) =~ /\Aruby[0-9.]*\z/ && tokens[1] && shims.include?(File.expand_path(tokens[1].to_s))

      nil
    rescue StandardError
      nil
    end

    def support_command?(text)
      tokens = Shellwords.split(text.to_s)
      index = shim_index(tokens)
      !index.nil? && tokens[(index + 1)..-1] == ["support"]
    rescue ArgumentError
      false
    end

    def check_outside_segment!(segment, state, event)
      tokens = begin
        Shellwords.split(segment)
      rescue ArgumentError
        raise_blocked!("M-SHELL-BLOCKED")
      end
      return if tokens.empty?

      plain, redirects = split_redirects(tokens)
      command = plain[0]
      return if command.nil?

      index = shim_index(plain)
      args = plain[((index || 0) + 1)..-1].to_a
      raise_outside!(event, "shell") if index && args.first == "import"

      base = state[:cwd]
      (args + redirects).each { |token| check_outside_token!(token, base, event) }

      if %w[cd pushd].include?(command) && !index
        target = args.first
        raise_outside!(event, "shell") if target.nil? || target == "-"

        resolved = real_resolve(target, base)
        state[:cwd] = resolved if resolved && File.directory?(resolved)
      end
    end

    def split_redirects(tokens)
      plain = []
      redirects = []
      i = 0
      while i < tokens.length
        tok = tokens[i]
        if tok =~ /\A\d*>&\d+\z/
          i += 1
        elsif tok =~ /\A\d*(?:&>>?|>>?|<)\z/
          redirects << tokens[i + 1] if tokens[i + 1]
          i += 2
        elsif tok =~ /\A\d*(?:&>>?|>>?|<)(.+)\z/m
          redirects << Regexp.last_match(1)
          i += 1
        else
          plain << tok
          i += 1
        end
      end
      [plain, redirects]
    end

    def check_outside_token!(token, base, event)
      value = token.to_s
      if value.start_with?("-")
        equals = value.index("=")
        return unless equals

        value = value[(equals + 1)..-1].to_s
      end
      return if value.empty?

      raise_outside!(event, "shell") if value =~ %r{(\A|[/=:])\$\{?[A-Za-z_]}
      return unless path_like?(value) || value == ".."
      return if OUTSIDE_ALLOWED.include?(value)
      return if shim_index([value]) == 0 && value != "reach"

      raise_outside!(event, "shell") if outside_path?(value, base)
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
      Reach::EnrollmentLock.check!
    rescue Reach::GateBlocked => e
      log_refusal(e.message_id, e.message)
      raise
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
      raise_blocked!("M-GATE-NOGUARD") if slices.empty? && !module_choice_pending?
    end

    def module_choice_pending?
      Reach::Policy.module_selection["mode"] == "student_choice" && Reach::Modules.current.nil?
    rescue StandardError
      false
    end

    def raise_blocked!(message_id, **fields)
      text = Reach::Messages.text(message_id, **fields)
      log_refusal(message_id, text)
      Reach::Debug.emit("gate", "check" => caller_locations(1, 1).first.label.to_s, "outcome" => "block", "message_id" => message_id.to_s)
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
        check_time_and_module!(workspace) if kind == "slice"
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
