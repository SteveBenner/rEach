require "digest"
require "shellwords"
require "rbconfig"
require "json"
require "fileutils"
require "time"
require "securerandom"

module Reach
  module Gate
    READONLY_SINGLE = %w[ls cat head tail less grep rg find wc diff].freeze
    STRICT_WRITE = %w[cp mv rm rmdir mkdir touch tee truncate chmod chown chgrp ln unlink shred install rsync dd patch tar zip unzip gzip gunzip bzip2 xz 7z cpio vi vim nvim nano emacs ed ex split del erase ri rd ren rni move mi copy cpi ni sc ac md].freeze
    PACKAGE_WRITE = %w[npm npx bundle gem].freeze
    WRITE_SINGLE = (STRICT_WRITE + PACKAGE_WRITE).freeze
    FIND_WRITE_FLAGS = %w[-delete -exec -execdir -ok -okdir -fprint -fprint0 -fprintf -fls].freeze
    PROTECTED_NAMES = %w[.claude .codex .mcp.json CLAUDE.md AGENTS.md].freeze
    RUN_STRING_COMMANDS = %w[iex icm saps start ii sal nal ipmo foreach where % invoke-expression invoke-command start-process invoke-item set-alias new-alias import-module awk gawk mawk nawk eval xargs source . sudo doas su parallel watch setsid script chroot busybox pwsh powershell cmd wsl at batch flock ionice chrt taskset setarch unshare nsenter strace ltrace gdb].freeze
    SHELL_COMMANDS = %w[sh bash zsh dash ksh csh tcsh fish].freeze
    STDIN_INTERPRETERS = %w[ruby python python2 python3 node perl php lua irb].freeze
    SHELL_RESERVED = %w[{ } if then else elif fi for while until do done case esac function select [[ ]] coproc].freeze
    ENV_ASSIGN_DENY = /\A(?:PATH|IFS|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|CDPATH|PROMPT_COMMAND|PS[0-4]|HOME|SHELL|RUBYOPT|RUBYLIB|NODE_OPTIONS|NODE_PATH|PYTHONSTARTUP|PYTHONPATH|PYTHONHOME|PERL5OPT|PERL5LIB|LD_.*|DYLD_.*|GIT_.*|REACH_.*|CLAUDE.*|CODEX.*)\z/.freeze
    SHELL_WORD = Struct.new(:text, :dynamic)
    SAFE_SED_COMMAND = /\A\s*(?:(?:\d+|\$|\/[^\/]*\/)(?:,(?:\d+|\$|\/[^\/]*\/))?)?\s*!?\s*(?:[pdqnNDlP=]|s(.)(?:(?!\1).)*\1(?:(?!\1).)*\1[gpiImM0-9]*)\s*\z/m.freeze
    ShellUnmodeled = Class.new(StandardError)
    PS_COMMON_VALUE = %w[erroraction warningaction].freeze
    PS_COMMON_SWITCH = %w[verbose whatif debug].freeze
    POWERSHELL_CMDLETS = {
      "ls" => %w[get-childitem gci dir ls childitem],
      "cat" => %w[get-content gc type cat],
      "grep" => %w[select-string sls],
      "pwd" => %w[get-location gl pwd],
      "cd" => %w[set-location sl cd chdir],
      "echo" => %w[write-output echo write],
      "testpath" => %w[test-path],
      "wc" => %w[measure-object measure],
      "tee" => %w[set-content sc add-content ac out-file],
      "touch" => %w[new-item ni],
      "rm" => %w[remove-item ri rm del erase rd rmdir],
      "mv" => %w[move-item mi mv move],
      "cp" => %w[copy-item cp copy cpi],
      "rename" => %w[rename-item rni ren]
    }.freeze
    PS_CMDLET_INDEX = POWERSHELL_CMDLETS.each_with_object({}) { |(canon, names), memo| names.each { |name| memo[name] = canon } }.freeze
    PS_SPECS = {
      "ls" => { path: %w[path literalpath], value: %w[filter include exclude depth], switch: %w[recurse force name file directory], positional: [:path], rest: :path },
      "testpath" => { path: %w[path literalpath], value: %w[pathtype], switch: %w[isvalid], positional: [:path], rest: :path },
      "cat" => { path: %w[path literalpath], value: %w[totalcount tail head first last encoding readcount delimiter], switch: %w[raw], positional: [:path], rest: :path },
      "grep" => { path: %w[path literalpath], value: %w[pattern context encoding include exclude], switch: %w[simplematch casesensitive list quiet notmatch allmatches], positional: [:pattern, :path], rest: :path },
      "pwd" => { path: [], value: [], switch: [], positional: [], rest: nil },
      "cd" => { path: %w[path literalpath], value: [], switch: %w[passthru], positional: [:path], rest: nil },
      "echo" => { path: [], value: %w[inputobject], switch: [], positional: [], rest: :arg },
      "wc" => { path: [], value: %w[property], switch: %w[line word character sum average maximum minimum], positional: [], rest: nil },
      "tee" => { path: %w[path literalpath filepath], value: %w[value encoding width], switch: %w[append force noclobber nonewline], positional: [:path, :ignore], rest: nil },
      "touch" => { path: %w[path], value: %w[name itemtype value], switch: %w[force], positional: [:path], rest: nil },
      "rm" => { path: %w[path literalpath], value: %w[filter include exclude], switch: %w[recurse force], positional: [:path], rest: :path },
      "mv" => { path: %w[path literalpath], dest: %w[destination], value: %w[filter include exclude], switch: %w[force], positional: [:path, :dest], rest: nil },
      "cp" => { path: %w[path literalpath], dest: %w[destination], value: %w[filter include exclude], switch: %w[recurse force container], positional: [:path, :dest], rest: nil },
      "rename" => { path: %w[path literalpath], value: %w[newname], switch: %w[force], positional: [:path, :newname], rest: nil }
    }.freeze
    WRITE_INPLACE_COMMANDS = %w[sed perl].freeze
    NETWORK_COMMANDS = %w[curl wget ssh scp nc iwr irm].freeze
    INLINE_CODE_FLAGS = {
      /\Aruby[0-9.]*\z/ => %w[-e],
      /\Apython[0-9.]*\z/ => %w[-c],
      /\Anode\z/ => %w[-e -p --eval --print],
      /\Aphp[0-9.]*\z/ => %w[-r],
      /\Alua[0-9.]*\z/ => %w[-e],
      /\Aperl\z/ => %w[-e -E],
      /\A(ba|z)?sh\z/ => %w[-c]
    }.freeze
    READ_TOOLS = %w[Read Glob Grep NotebookRead LS read_file search_files list_files list_directory view_image].freeze
    WEB_TOOLS = %w[WebFetch WebSearch web_search web_extract].freeze
    PATH_INPUT_KEYS = %w[file_path notebook_path path directory dir root].freeze
    OUTSIDE_ALLOWED = %w[/dev/null /dev/stdout /dev/stderr].freeze
    OUTSIDE_REFUSAL_LIMIT = 3
    RECURSIVE_READ_TOOLS = %w[Glob Grep LS list_files search_files list_directory].freeze
    RELOCATION_EXEMPT_ARGS = %w[status doctor relocate].freeze

    module_function

    def session(harness:)
      safely { Reach::KnownIssues.spawn_refresh! }
      return nil if Reach::Instructor.mode?

      check_enrolled!
      check_guardrails!
      check_has_workspace!
      witness("session", "harness" => harness.to_s)
      nil
    end

    ONCE_KEEP_S = 86_400
    INSTRUCTOR_WINDOW_S = 30
    INSTRUCTOR_LOCK_WAIT_S = 2

    def once_dir
      File.join(Reach::Paths.root_state_dir, "hook_once")
    end

    def once!(event, kind)
      session = Reach::Session.resolve_session_id(event)
      token = kind.to_s == "session" ? "session:#{event["source"]}" : event["turn_id"].to_s
      return true if token.empty?

      dir = once_dir
      FileUtils.mkdir_p(dir)
      prune_once(dir)
      name = Digest::SHA256.hexdigest("#{kind}\n#{session}\n#{token}")
      File.open(File.join(dir, name), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")) }
      true
    rescue Errno::EEXIST
      false
    rescue StandardError
      true
    end

    def instructor_once!(event, source)
      event = {} unless event.is_a?(Hash)
      return once!(event, "instructor") unless event["turn_id"].to_s.empty?

      session = Reach::Session.resolve_session_id(event)
      dir = once_dir
      FileUtils.mkdir_p(dir)
      prune_once(dir)
      name = Digest::SHA256.hexdigest("instructor\n#{session}\n#{Digest::SHA256.hexdigest(event["prompt"].to_s)}")
      path = File.join(dir, name)
      claimed = Reach::Locks.exclusive("#{path}.lock", wait_s: INSTRUCTOR_LOCK_WAIT_S) do
        if File.file?(path) && File.read(path).strip != source.to_s && Time.now - File.mtime(path) < INSTRUCTOR_WINDOW_S
          false
        else
          File.write(path, source.to_s)
          true
        end
      end
      claimed == true
    rescue StandardError
      true
    end

    def prune_once(dir)
      cutoff = Time.now - ONCE_KEEP_S
      Dir.children(dir).each do |name|
        path = File.join(dir, name)
        File.delete(path) if File.file?(path) && File.mtime(path) < cutoff
      rescue SystemCallError
        next
      end
    rescue SystemCallError
      nil
    end

    def codex_wrong_folder?(harness, cwd)
      return false unless harness.to_s == "codex"

      path = cwd.to_s.empty? ? Reach::Paths.cwd : cwd.to_s
      path = Reach::Paths.windows_slashes(path) if Reach::Paths.windows_host?
      base = Reach::Paths.realish(Reach::Paths.workspace_base)
      !Reach::Paths.path_within?(Reach::Paths.realish(path), base)
    rescue StandardError
      false
    end

    def codex_wrong_folder_text(event, harness)
      event = {} unless event.is_a?(Hash)
      return nil unless harness.to_s == "codex"
      return nil if Reach::Instructor.mode? || Reach::Instructor.attempt?(event["prompt"])

      lock = Reach::EnrollmentLock.state
      pending = (lock["locked"] && lock["reason"] != "course_ended") || Reach::Hello.login_pending?(event)
      return nil unless pending
      return nil unless codex_wrong_folder?(harness, event["cwd"])

      Reach::Messages.text("M-CODEX-WRONG-FOLDER")
    rescue StandardError
      nil
    end

    def prompt(event: {}, harness: nil, claimed: false)
      event = {} unless event.is_a?(Hash)
      if !claimed && Reach::Instructor.attempt?(event["prompt"])
        attempt = Reach::EnrollFlow.instructor_decision(event, event["prompt"], Reach::EnrollmentLock.state, harness, "prompt")
        return nil if attempt["action"] == "elsewhere"

        raise Reach::GateBlocked.new("M-INSTRUCTOR", framed("gate.instructor", attempt["message"]))
      end
      toggled = safely { Reach::Debug.toggle_from_prompt!(event["prompt"]) }
      if Reach::Instructor.mode?
        return Reach::Messages.text("M-DEBUG-RELAY", text: toggled) if toggled

        return Reach::Instructor.context_once(Reach::Session.resolve_session_id(event))
      end

      blocked = nil
      begin
        check_enrolled!
        check_guardrails!
        check_has_workspace!
        Reach::Update.hold!
        Reach::Controls.check_prompt!(current_space)
      rescue Reach::GateBlocked => e
        blocked = e
      end

      decision = nil
      unless blocked
        begin
          decision = Reach::Login.claim(event: event, harness: harness) if Reach::Login.required? && !claimed
        rescue StandardError
          decision = { "action" => "block", "message" => Reach::Messages.text("M-LOGIN-NEEDED"), "note" => nil, "stuck" => true }
        end
      end
      elsewhere = decision == :elsewhere
      decision = nil if elsewhere
      login_block = decision && decision["action"] == "block"

      locked = !blocked.nil? && Reach::EnrollmentLock::MESSAGES.value?(blocked.message_id)
      entry = locked || blocked || login_block || elsewhere ? nil : live_prompt(event)
      recorded = entry ? record_prompt(event, harness) : nil

      live = blocked || (login_block && decision["stuck"]) ? safely { Reach::Live.blocked_prompt(event) } : nil
      blocked = Reach::GateBlocked.new(blocked.message_id, [blocked.message, live, toggled].compact.join("\n\n")) if blocked && (toggled || live)
      raise blocked if blocked
      raise Reach::GateBlocked.new("M-LOGIN", framed("gate.login", [decision["message"].to_s, live, toggled].compact.join("\n\n"))) if login_block
      return nil if elsewhere

      if recorded
        witness("prompt", "session" => recorded["session_id"], "seq" => recorded["seq"], "digest" => recorded["digest"])
      else
        witness("prompt")
      end
      safely { Reach::Progress.assignment_started(current_workspace_path) }
      context = prompt_context(event, harness, decision, entry, toggled: toggled)
      learn_prompt(entry, recorded) if entry
      context
    end

    def record_prompt(event, harness)
      captured = Reach::Transcript.capture(event, harness: Reach::Session.resolve_harness(harness), gate: "allowed")
      captured.is_a?(Hash) && captured["seq"].is_a?(Integer) ? captured : nil
    rescue StandardError
      nil
    end

    def live_prompt(event)
      text = event["prompt"].is_a?(String) ? event["prompt"] : nil
      {
        "session_id" => Reach::Session.resolve_session_id(event), "gate" => "allowed", "text" => text, "seq" => nil,
        "digest" => text ? Digest::SHA256.hexdigest(text) : nil, "transcript_path" => event["transcript_path"]
      }
    rescue StandardError
      nil
    end

    def learn_prompt(entry, recorded = nil)
      space = current_space
      kind = space ? space["kind"] : "outside"
      safely { Reach::Brain.capture_prompt(session_id: entry["session_id"], space: kind, text: entry["text"]) }
      safely { Reach::Part.observe_prompt(space, entry["text"], recorded) }
      return unless kind == "slice" && !entry["text"].to_s.strip.empty?

      safely { Reach::Ladder.note_prompt(space["path"]) }
    end

    def prompt_context(event, harness, decision, entry, toggled: nil)
      session = Reach::Session.resolve_session_id(event)
      space = current_space
      context = []
      greeted = false

      if decision
        if safely { Reach::Login.just_confirmed?(session) }
          context << signed_in_context(harness, session)
          after_answer { Reach::Login.clear_just_confirmed(session) }
          greeted = true
        end
        context << framed("gate.decision", decision["context"]) if decision["context"]
      end
      stored = safely { Reach::Hello.stored_context(session) }
      if stored
        context << framed("hello.refreshed", stored)
        after_answer { Reach::Hello.clear_stored_context(session) }
      end
      context.concat(Array(framed("notice.update", safely { Reach::Update.prompt_notices(session) })))
      context.concat(Array(framed("notice.storage", safely { storage_notices(session, greeted) })))
      context.concat(Array(framed("notice.export_import", safely { Reach::ExportImport.prompt_notices(session) })))
      context << framed("notice.debug", safely { Reach::Debug.remote_notice(session) })
      context << framed("notice.late_work", safely { Reach::LateWork.prompt_notice(session) })
      context.concat(Array(safely { Reach::Announcements.prompt_notices }))
      context.concat(Array(safely { Reach::DueChanges.prompt_notices }))
      transcripts = safely { Reach::TranscriptExport.pending_notice! }
      context << framed("notice.transcripts", Reach::TranscriptExport.agent_notice(transcripts)) if transcripts
      observed = safely { Reach::Consent.observe(entry) } if entry
      if observed
        done = safely { Reach::Consent.follow_up!(observed) }
        context << framed("notice.consent", Reach::Consent.agent_context(observed, done)) unless done.to_s.empty?
      end
      context << framed("notice.consent", safely { Reach::Consent.relay!(session) }) unless observed
      context.concat(Array(framed("notice.live", safely { Reach::Live.prompt_notices(session) })))
      context.concat(Array(safely { Reach::Controls.context_blocks("notice.control") }))
      context.concat(Array(safely { Reach::ExamMode.context_blocks("notice.test") }))
      if space
        import_path = space["kind"] == "root" ? safely { focus_workspace } : space["path"]
        imports = import_path ? safely { Reach::Imports.observe(text: event["prompt"], space_path: import_path) } : nil
        context.concat(Array(framed("notice.import", imports)))
        context << framed("notice.next", safely { Reach::Next.anchor_text(space) })
      end
      context << framed("notice.memory", safely { Reach::Brain.prompt_context(session_id: session, prompt: event["prompt"]) })
      context << framed("notice.subscribe", safely { Reach::Subscribe.prompt_notice })
      context << framed("notice.debug", Reach::Messages.text("M-DEBUG-RELAY", text: toggled)) if toggled

      text = context.compact.map(&:to_s).reject(&:empty?).join("\n\n")
      text.empty? ? nil : text
    end

    def framed(id, value, **fields)
      return value if value.nil?
      return value.map { |item| framed(id, item, **fields) } if value.is_a?(Array)

      Reach::AgentControl.channel(id, **fields) { value }
    rescue StandardError
      value
    end

    def signed_in_context(harness, session)
      student = safely { Reach::Login.student } || {}
      name = student["display_name"].to_s.empty? ? "the enrolled student" : student["display_name"]
      hello = safely { Reach::Hello.context_text(harness: harness, cwd: Reach::Paths.cwd, source: "startup", session: session) }
      done = framed("gate.signin", Reach::Messages.text("M-LOGIN-DONE-AGENT", name: name))
      parts = Reach::AgentControl.flag?("render") ? [hello, done] : [done, hello]
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
      raise_blocked!(login_needed_id) unless confirmed
    rescue Reach::GateBlocked
      raise
    rescue StandardError
      raise_blocked!(login_needed_id)
    end

    def login_needed_id
      Reach::KnownIssues.signin_hook_dead? ? Reach::KnownIssues.untrusted_or("M-LOGIN-NEEDED-NO-HOOK") : "M-LOGIN-NEEDED"
    rescue StandardError
      "M-LOGIN-NEEDED"
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

    def witness_in(workspace, kind, fields)
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
      Reach::Relocation.hold!
      space = current_space
      Reach::Controls.check_tool!("write", space)
      kind = space && space["kind"]

      return write_from_root(path: path, patch: patch) if kind == "root"

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
        base = workspace || Reach::Paths.cwd
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

    def write_from_root(path:, patch:)
      base = File.realpath(Reach::Paths.cwd)
      raw = patch ? patch_targets(patch) : [path.to_s]
      targets = raw.map { |entry| root_target(File.expand_path(entry, base)) }

      spaces = targets.map { |target| target_space(target) }
      slices = spaces.select { |space| space && space["kind"] == "slice" }.map { |space| space["path"] }.uniq
      raise_blocked!("M-WRITE-ROOT") if slices.length > 1

      targets.each_with_index do |target, index|
        raise_blocked!("M-WRITE-OUTSIDE", owned_files: outside_owned_text) if Reach::Paths.inside_home?(target)

        space = spaces[index]
        kind = space && space["kind"]
        case kind
        when "slice"
          workspace = space["path"]
          owned = owned_absolute_paths(workspace)
          allowed = owned.any? { |candidate| same_path?(candidate, target) } || qualify_target?(workspace, target)
          raise_blocked!("M-WRITE-OUTSIDE", owned_files: owned_files_display(workspace)) unless allowed
        when "extracurricular"
          raise_blocked!("M-WRITE-OUTSIDE-EXTRA") unless within?(target, space["path"])
        when "root"
          raise_blocked!("M-WRITE-ROOT")
        else
          raise_blocked!("M-WRITE-OUTSIDE", owned_files: outside_owned_text)
        end
      end

      slices.each do |workspace|
        check_ladder!(workspace)
        check_time_and_module!(workspace)
      end
      nil
    end

    def outside_owned_text
      "your slice's files under deliverables/"
    end

    def root_target(expanded)
      File.join(Reach::Paths.realish(File.dirname(expanded)), File.basename(expanded))
    end

    def target_space(target)
      return nil if Reach::Paths.inside_home?(target)

      Reach::Workspace.space_for_target(target)
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

    APPLY_PATCH_NAMES = %w[apply_patch applypatch].freeze

    def apply_patch_payload(command, event = nil)
      text = command.to_s
      return whole_patch(text) if text.lstrip.start_with?("*** Begin Patch")

      heredoc_patch(text, event) || argument_patch(text)
    end

    def whole_patch(text)
      lines = text.strip.lines.map(&:chomp)
      return nil unless lines.first == "*** Begin Patch" && lines.last == "*** End Patch"

      text
    end

    def argument_patch(text)
      lexed = lex_segment(text.strip)
      words = lexed[:words]
      return nil unless lexed[:outs].empty? && lexed[:ins].empty? && words.length == 2
      return nil unless APPLY_PATCH_NAMES.include?(words[0].text) && !words[0].dynamic

      whole_patch(words[1].text)
    rescue ShellUnmodeled
      nil
    end

    def heredoc_patch(text, event)
      lines = text.lines.map(&:chomp)
      head = lines.shift.to_s
      match = head.match(/\A\s*(?:cd\s+([A-Za-z0-9_.\/-]+)\s*&&\s*)?(apply_patch|applypatch)\s*<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\4\s*\z/)
      return nil unless match

      delimiter = match[5]
      close = lines.index { |line| (match[3] == "-" ? line.sub(/\A\t+/, "") : line) == delimiter }
      return nil unless close
      return nil unless lines[(close + 1)..-1].all? { |line| line.strip.empty? }

      patch = whole_patch(lines[0...close].join("\n") + "\n")
      return nil unless patch

      match[1] ? rebase_patch(patch, File.expand_path(match[1], hook_cwd(event))) : patch
    end

    def rebase_patch(patch, base)
      patch.each_line.map do |line|
        prefix = PATCH_PREFIXES.find { |candidate| line.start_with?(candidate) }
        prefix ? "#{prefix}#{File.expand_path(line[prefix.length..-1].to_s.strip, base)}\n" : line
      end.join
    end

    def shell(command:, event: nil, harness: nil, dialect: nil)
      @powershell = dialect.to_s == "powershell"
      text = command.to_s
      text = text.tr("\\", "/") if @powershell
      return nil if support_command?(text)

      check_enrolled!
      require_login!(event)
      Reach::Update.hold!
      Reach::Relocation.hold! unless relocation_exempt?(text)
      segments = shell_segments(text)

      space = current_space
      Reach::Controls.check_tool!("shell", space)
      kind = space && space["kind"]
      state = { cwd: hook_cwd(event) }

      if kind == "root"
        shell_from_root(segments, state, event)
        return nil
      end

      workspace = space && space["path"]
      owned_test = shell_owned_test(kind, workspace)

      segments.each do |segment, before, after|
        cwd = state[:cwd]
        check_cd_context!(segment, before, after)
        check_outside_segment!(segment, state, event)
        check_segment!(segment, workspace, owned_test, kind, cwd)
      end

      witness("shell", "command_digest" => Reach::Crypto.digest_hex(text), "head" => text[0, 200]) if kind == "slice"
      nil
    ensure
      @powershell = false
    end

    def shell_segments(text)
      split_segments_with_seps(text)
    rescue ShellUnmodeled
      raise_blocked!("M-SHELL-UNMODELED")
    end

    def shell_from_root(segments, state, event)
      segments.each do |segment, before, after|
        cwd = state[:cwd]
        here = Reach::Workspace.space_for(cwd)
        here_kind = here && here["kind"]
        check_cd_context!(segment, before, after)
        check_outside_segment!(segment, state, event)

        case here_kind
        when "slice"
          workspace = here["path"]
          check_segment!(segment, workspace, shell_owned_test("slice", workspace), "slice", cwd)
          witness_in(workspace, "shell", { "command_digest" => Reach::Crypto.digest_hex(segment), "head" => segment[0, 200] })
        when "extracurricular"
          workspace = here["path"]
          check_segment!(segment, workspace, shell_owned_test("extracurricular", workspace), "extracurricular", cwd)
        else
          check_root_segment!(segment)
        end
      end
    end

    def check_cd_context!(segment, before, after)
      words = parse_segment(segment)[:words]
      return if words.empty?
      return unless %w[cd pushd popd].include?(File.basename(words[0].text))

      chained = %w[&& || | |& &].include?(before.to_s) || %w[| |& &].include?(after.to_s)
      raise_blocked!("M-SHELL-UNMODELED") if chained
    end

    def relocation_exempt?(text)
      segments = split_segments(text)
      return false if segments.empty?

      segments.all? do |segment|
        tokens = Shellwords.split(segment)
        index = shim_index(tokens)
        index && RELOCATION_EXEMPT_ARGS.include?(tokens[index + 1])
      end
    rescue ArgumentError, ShellUnmodeled
      false
    end

    def read(event: {}, harness: nil)
      event = {} unless event.is_a?(Hash)
      check_enrolled!
      require_login!(event)

      tool = event["tool_name"].to_s
      input = event["tool_input"].is_a?(Hash) ? event["tool_input"] : {}
      space = current_space
      Reach::Controls.check_tool!(WEB_TOOLS.include?(tool) || tool.start_with?("browser_") ? "web" : "read", space)
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
        raise_blocked!("M-GATE-EXTRACURRICULAR-READ") if (kind == "slice" || kind == "root") && extracurricular_path?(candidate, base)
      end
      check_recursive_read!(input, base) if RECURSIVE_READ_TOOLS.include?(tool)
      nil
    end

    def check_recursive_read!(input, base)
      given = PATH_INPUT_KEYS.map { |key| input[key] }.find { |value| value.is_a?(String) && !value.empty? }
      resolved = given ? real_resolve(given, base) : base
      raise_blocked!("M-GATE-OUTSIDE") if resolved.nil? || Reach::Paths.ancestor_of_home?(resolved)
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
      cwd.is_a?(String) && File.directory?(cwd) ? File.realpath(cwd) : File.realpath(Reach::Paths.cwd)
    rescue StandardError
      Reach::Paths.cwd
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

    def extracurricular_path?(path, base)
      resolved = real_resolve(path, base)
      return false if resolved.nil?

      root = real_resolve(Reach::Paths.extracurricular_root, base)
      !root.nil? && within?(resolved, root)
    end

    def outside_path?(path, base)
      return false if OUTSIDE_ALLOWED.include?(path.to_s)

      resolved = real_resolve(path, base)
      return true if resolved.nil?

      root = Reach::Paths.workspace_root
      root_real = File.exist?(root) ? File.realpath(root) : File.expand_path(root)
      return true if Reach::Paths.inside_home?(resolved)

      !within?(resolved, root_real)
    end

    def raise_outside!(event, tool)
      count_outside(event, tool)
      raise_blocked!("M-GATE-OUTSIDE")
    end

    def count_outside(event, tool)
      session = Reach::Session.resolve_session_id(event)
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

      shims = [File.expand_path(Reach::Runtime.shim_path), File.expand_path(File.join(Reach::Paths.legacy_home, "bin", "reach"))]
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
      parsed = parse_segment(segment)
      plain = parsed[:words].map(&:text)
      redirects = (parsed[:ins] + parsed[:outs]).map(&:text)
      return if plain.empty? && redirects.empty?

      command = plain[0]
      index = shim_index(plain)
      args = plain[((index || 0) + 1)..-1].to_a
      raise_outside!(event, "shell") if index && args.first == "import"

      base = state[:cwd]
      (args + redirects).each { |token| check_outside_token!(token, base, event) }
      check_search_exposes_home!(plain, base)

      if %w[cd pushd popd].include?(command) && !index
        target = args.first
        raise_outside!(event, "shell") if target.nil? || target.start_with?("-") || args.length != 1 || command == "popd"

        resolved = real_resolve(target, base)
        state[:cwd] = resolved if resolved && File.directory?(resolved)
      end
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
      unless path_like?(value) || value == ".."
        raise_outside!(event, "shell") if Reach::Paths.inside_home?(File.expand_path(value, base)) || glob_reaches_home?(value, base)
        return
      end
      return if OUTSIDE_ALLOWED.include?(value)
      return if shim_index([value]) == 0 && value != "reach"

      raise_outside!(event, "shell") if outside_path?(value, base)
      raise_outside!(event, "shell") if glob_reaches_home?(value, base)
    end

    def glob_reaches_home?(value, base)
      return false unless value =~ /[*?\[{]/

      Dir.glob(value, base: base).any? { |match| Reach::Paths.inside_home?(File.join(base, match)) }
    rescue StandardError
      false
    end

    def recursive_search?(tokens)
      flags = tokens[1..-1].to_a.select { |token| token.start_with?("-") }
      case tokens[0]
      when "rg", "find"
        true
      when "grep", "diff"
        flags.any? { |flag| flag =~ /\A--(dereference-)?recursive\z/ || flag =~ /\A-[A-Za-z]*[rR][A-Za-z]*\z/ }
      when "ls"
        flags.any? { |flag| flag == "--recursive" || flag =~ /\A-[A-Za-z]*R[A-Za-z]*\z/ }
      else
        false
      end
    end

    def search_operands(tokens)
      rest = tokens[1..-1].to_a
      if tokens[0] == "find"
        rest.take_while { |token| !token.start_with?("-") && token != "(" && token != "!" }
      else
        operands = rest.reject { |token| token.start_with?("-") }
        pattern_flag = rest.any? { |token| token =~ /\A-[A-Za-z]*[ef]\z/ || token.start_with?("--regexp", "--file") }
        operands = operands.drop(1) if %w[grep rg].include?(tokens[0]) && !pattern_flag
        operands
      end
    end

    def search_bases(tokens, cwd)
      operands = search_operands(tokens)
      operands.empty? ? [cwd] : operands.map { |token| real_resolve(token, cwd) }
    end

    def check_search_exposes_home!(tokens, cwd)
      return unless recursive_search?(tokens)

      search_bases(tokens, cwd).each do |resolved|
        next if resolved.nil?

        raise_blocked!("M-SHELL-BLOCKED") if Reach::Paths.ancestor_of_home?(resolved)
      end
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
      parsed = parse_segment(segment)
      words = parsed[:words]
      raise_blocked!("M-SHELL-BLOCKED") unless parsed[:outs].all? { |target| !target.dynamic && OUTSIDE_ALLOWED.include?(target.text) }
      return if words.empty?

      tokens = words.map(&:text)
      cmd = tokens[0]
      raise_blocked!("M-SHELL-UNMODELED") if words[0].dynamic || SHELL_RESERVED.include?(cmd)
      raise_blocked!("M-GATE-NOGIT") if File.basename(cmd) == "git"
      return if cmd == "reach"
      return if %w[cd pushd].include?(cmd) && tokens.length == 2
      forbid_command!(tokens, "slice")
      return if readonly_command?(tokens)

      raise_blocked!("M-SHELL-BLOCKED")
    end

    def check_enrolled!
      Reach::BehaviorPolicy.ensure!
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
      raise_blocked!("M-GATE-NOGUARD") if slices.empty? && !module_choice_pending? && !free_space?
    end

    def free_space?
      space = current_space
      space && %w[extracurricular root].include?(space["kind"]) ? true : false
    end

    def module_choice_pending?
      Reach::Policy.module_selection["mode"] == "student_choice" && Reach::Modules.current.nil?
    rescue StandardError
      false
    end

    def raise_blocked!(message_id, channel: "gate.refusal", frame: {}, **fields)
      text = Reach::Messages.text(message_id, **fields)
      log_refusal(message_id, text)
      Reach::Debug.emit("gate", "check" => caller_locations(1, 1).first.label.to_s, "outcome" => "block", "message_id" => message_id.to_s)
      raise Reach::GateBlocked.new(message_id, framed(channel, text, **frame))
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
      cwd = File.realpath(Reach::Paths.cwd)
      slices = Reach::Workspace.current_slices
      slices.find do |workspace|
        real_workspace = File.realpath(workspace)
        cwd == real_workspace || cwd.start_with?(real_workspace + File::SEPARATOR)
      end
    rescue StandardError
      nil
    end

    def current_space
      cwd = File.realpath(Reach::Paths.cwd)
      Reach::Workspace.space_for(cwd)
    rescue StandardError
      nil
    end

    def focus_workspace(target: nil)
      here = current_workspace_path
      return here if here

      space = current_space
      return nil unless space && space["kind"] == "root"

      if target && !target.to_s.empty?
        found = Reach::Workspace.space_for_target(File.expand_path(target.to_s))
        return found["path"] if found && found["kind"] == "slice"
      end

      slices = Reach::Workspace.current_slices
      slices.length == 1 ? slices.first : nil
    rescue StandardError
      nil
    end

    def root_kind?
      space = current_space
      space && space["kind"] == "root" ? true : false
    end

    def pick_slice_text
      Reach::Messages.text("M-PICK-SLICE", choices: pick_slice_choices)
    end

    def raise_pick_slice!
      raise_blocked!("M-PICK-SLICE", choices: pick_slice_choices)
    end

    def pick_slice_choices
      root = File.expand_path(Reach::Paths.workspace_root)
      Reach::Workspace.current_slices.map { |path| "cd #{path.sub("#{root}#{File::SEPARATOR}", "")}" }.join(", or ")
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

    def split_segments(text)
      split_segments_with_seps(text).map(&:first)
    end

    def split_segments_with_seps(text)
      out = []
      current = +""
      before = nil
      quote = nil
      chars = text.chars
      i = 0
      cut = lambda do |sep|
        stripped = current.strip
        out << [stripped, before, sep] unless stripped.empty?
        current = +""
        before = sep
      end
      while i < chars.length
        ch = chars[i]
        nxt = chars[i + 1]
        if quote == "'"
          current << ch
          quote = nil if ch == "'"
          i += 1
          next
        end
        if quote == '"'
          raise ShellUnmodeled if ch == "`" || (ch == "$" && nxt == "(")

          if ch == "\\"
            current << ch << nxt.to_s
            i += 2
            next
          end
          current << ch
          quote = nil if ch == '"'
          i += 1
          next
        end
        case ch
        when "\\"
          current << ch << nxt.to_s
          i += 2
        when "'", '"'
          quote = ch
          current << ch
          i += 1
        when "`", "(", ")"
          raise ShellUnmodeled
        when "$"
          raise ShellUnmodeled if ["(", "'", '"'].include?(nxt)

          current << ch
          i += 1
        when "<"
          raise ShellUnmodeled if nxt == "<"

          current << ch
          i += 1
        when "#"
          if current.empty? || [" ", "\t"].include?(current[-1])
            i += 1
            i += 1 while i < chars.length && chars[i] != "\n"
          else
            current << ch
            i += 1
          end
        when ";"
          cut.call(";")
          i += 1
        when "\n"
          cut.call("\n")
          i += 1
        when "&"
          if nxt == "&"
            cut.call("&&")
            i += 2
          elsif nxt == ">" || [">", "<"].include?(current[-1])
            current << ch
            i += 1
          else
            cut.call("&")
            i += 1
          end
        when "|"
          if nxt == "|"
            cut.call("||")
            i += 2
          elsif nxt == "&"
            cut.call("|&")
            i += 2
          else
            cut.call("|")
            i += 1
          end
        else
          current << ch
          i += 1
        end
      end
      raise ShellUnmodeled if quote

      cut.call(nil)
      out
    end

    def lex_segment(segment)
      words = []
      outs = []
      ins = []
      buf = nil
      dynamic = false
      literal_digits = true
      pending = nil
      chars = segment.chars
      i = 0
      finish = lambda do
        unless buf.nil?
          if @powershell && pending && buf == "$null"
            buf = "/dev/null"
            dynamic = false
          end
          word = SHELL_WORD.new(buf, dynamic)
          if pending
            (pending == :in ? ins : outs) << word
            pending = nil
          else
            words << word
          end
        end
        buf = nil
        dynamic = false
        literal_digits = true
      end
      append = lambda do |text, dyn, digits|
        buf = +"" if buf.nil?
        buf << text
        dynamic ||= dyn
        literal_digits &&= digits
      end
      while i < chars.length
        ch = chars[i]
        nxt = chars[i + 1]
        case ch
        when " ", "\t"
          finish.call
          i += 1
        when "\\"
          raise ShellUnmodeled if nxt.nil?

          append.call(nxt, false, false) unless nxt == "\n"
          i += 2
        when "'"
          j = (i + 1...chars.length).find { |k| chars[k] == "'" }
          raise ShellUnmodeled unless j

          append.call(chars[(i + 1)...j].join, false, false)
          i = j + 1
        when '"'
          i += 1
          piece = +""
          dyn = false
          closed = false
          while i < chars.length
            c = chars[i]
            if c == "\\" && i + 1 < chars.length
              n = chars[i + 1]
              if ["$", "`", '"', "\\"].include?(n)
                piece << n
              elsif n != "\n"
                piece << c << n
              end
              i += 2
            elsif c == '"'
              closed = true
              i += 1
              break
            else
              raise ShellUnmodeled if c == "`" || (c == "$" && chars[i + 1] == "(")

              dyn = true if c == "$" && chars[i + 1].to_s =~ /[A-Za-z_0-9{@*#?!$-]/
              piece << c
              i += 1
            end
          end
          raise ShellUnmodeled unless closed

          append.call(piece, dyn, false)
        when "$"
          raise ShellUnmodeled if ["(", "'", '"'].include?(nxt)

          append.call(ch, nxt.to_s =~ /[A-Za-z_0-9{@*#?!$-]/ ? true : false, false)
          i += 1
        when "*", "?", "[", "{", "}"
          append.call(ch, true, false)
          i += 1
        when "@"
          append.call(ch, @powershell && buf.nil? ? true : false, false)
          i += 1
        when "~"
          append.call(ch, buf.nil?, false)
          i += 1
        when "<", ">", "&"
          if ch != "&" && !buf.nil? && literal_digits && buf =~ /\A\d+\z/ && !pending
            buf = nil
            dynamic = false
            literal_digits = true
          else
            finish.call
          end
          op = ch
          if ch == "&"
            raise ShellUnmodeled unless nxt == ">"

            op = "&>"
            i += 2
            if chars[i] == ">"
              op = "&>>"
              i += 1
            end
          else
            i += 1
            if chars[i] == ch && ch == ">"
              op = ">>"
              i += 1
            elsif chars[i] == "&"
              op = "#{ch}&"
              i += 1
            elsif chars[i] == "|" && ch == ">"
              op = ">|"
              i += 1
            elsif chars[i] == ">" && ch == "<"
              op = "<>"
              i += 1
            end
          end
          if op.end_with?("&") && op.length == 2
            rest = chars[i..-1].join
            if rest =~ /\A(\d+|-)(?=[ \t]|\z)/
              i += Regexp.last_match(1).length
              next
            end
          end
          pending = op == "<" ? :in : :out
        when ";", "|", "(", ")", "`", "\n"
          raise ShellUnmodeled
        else
          append.call(ch, false, ch =~ /\d/ ? true : false)
          i += 1
        end
      end
      finish.call
      raise ShellUnmodeled if pending

      { words: words, outs: outs, ins: ins }
    end

    def parse_segment(segment)
      lexed = lex_segment(segment)
      words = unwrap_words(lexed[:words], 0)
      words = translate_cmdlet(words) if @powershell && !words.empty?
      lexed.merge(words: words)
    rescue ShellUnmodeled
      raise_blocked!("M-SHELL-UNMODELED")
    end

    def translate_cmdlet(words)
      head = words[0].text.downcase.sub(/\.exe\z/, "")
      canon = PS_CMDLET_INDEX[head]
      return words unless canon

      spec = PS_SPECS.fetch(canon)
      found = { path: [], dest: [], arg: [], pattern: [], newname: [], name: [] }
      positional = []
      recurse = false
      rest = words[1..-1]
      i = 0
      while i < rest.length
        word = rest[i]
        text = word.text
        if text.start_with?("-") && text.length > 1 && text !~ /\A-\d/
          key, colon, inline = text[1..-1].partition(":")
          key = key.downcase
          takes = (spec[:path] + Array(spec[:dest]) + spec[:value]).include?(key) || PS_COMMON_VALUE.include?(key)
          if takes
            if colon == ":" && !inline.empty?
              value = SHELL_WORD.new(inline, word.dynamic)
            else
              i += 1
              raise ShellUnmodeled if rest[i].nil?

              value = rest[i]
            end
            if spec[:path].include?(key)
              found[:path] << value
            elsif Array(spec[:dest]).include?(key)
              found[:dest] << value
            elsif key == "pattern"
              found[:pattern] << value
            elsif key == "newname"
              found[:newname] << value
            elsif key == "name"
              found[:name] << value
            elsif key == "inputobject"
              found[:arg] << value
            end
          elsif spec[:switch].include?(key) || PS_COMMON_SWITCH.include?(key)
            recurse = true if key == "recurse"
          else
            raise ShellUnmodeled
          end
        else
          positional << word
        end
        i += 1
      end

      positional.each_with_index do |word, index|
        slot = spec[:positional][index] || spec[:rest]
        raise ShellUnmodeled if slot.nil?

        found[slot] << word unless slot == :ignore
      end

      words_for_powershell(canon, found, recurse)
    end

    def words_for_powershell(canon, found, recurse)
      plain = ->(text) { SHELL_WORD.new(text, false) }
      paths = found[:path]
      (paths + found[:dest]).each { |word| raise ShellUnmodeled if word.text.include?(",") }
      case canon
      when "ls", "testpath"
        [plain.call("ls")] + (recurse ? [plain.call("-R")] : []) + paths
      when "cat"
        [plain.call("cat")] + paths
      when "grep"
        raise ShellUnmodeled if found[:pattern].length != 1

        [plain.call("grep"), plain.call("-e"), found[:pattern].first] + paths
      when "pwd", "wc"
        raise ShellUnmodeled unless paths.empty?

        [plain.call(canon)]
      when "cd"
        raise ShellUnmodeled if paths.length > 1

        [plain.call("cd")] + paths
      when "echo"
        [plain.call("echo")] + found[:arg]
      when "tee"
        raise ShellUnmodeled if paths.empty?

        [plain.call("tee")] + paths
      when "touch"
        if found[:name].empty?
          raise ShellUnmodeled if paths.empty?

          [plain.call("touch")] + paths
        else
          bases = paths.empty? ? [plain.call(".")] : paths
          [plain.call("touch")] + bases.product(found[:name]).map { |base, name| SHELL_WORD.new(File.join(base.text, name.text), base.dynamic || name.dynamic) }
        end
      when "rm"
        raise ShellUnmodeled if paths.empty?

        [plain.call("rm")] + (recurse ? [plain.call("-r")] : []) + paths
      when "mv", "cp"
        raise ShellUnmodeled if paths.empty? || found[:dest].empty?

        [plain.call(canon)] + (recurse ? [plain.call("-r")] : []) + paths + found[:dest]
      when "rename"
        raise ShellUnmodeled if paths.length != 1 || found[:newname].length != 1

        target = SHELL_WORD.new(File.join(File.dirname(paths.first.text), found[:newname].first.text), paths.first.dynamic || found[:newname].first.dynamic)
        [plain.call("mv"), paths.first, target]
      end
    end

    def strip_assignments(words)
      rest = words.dup
      while rest.first && rest.first.text =~ /\A([A-Za-z_][A-Za-z0-9_]*)=/
        raise_blocked!("M-SHELL-UNMODELED") if Regexp.last_match(1) =~ ENV_ASSIGN_DENY
        rest.shift
      end
      rest
    end

    def unwrap_words(words, depth)
      raise ShellUnmodeled if depth > 8

      words = strip_assignments(words)
      return words if words.empty?

      raise ShellUnmodeled if words[0].dynamic

      name = File.basename(words[0].text).sub(/\.exe\z/i, "")
      rest = words[1..-1]
      case name
      when "!", "builtin", "nohup"
        unwrap_words(rest, depth + 1)
      when "env"
        unwrap_words(skip_env_options(rest), depth + 1)
      when "command"
        return words if rest.first && %w[-v -V].include?(rest.first.text)

        rest = rest.drop_while { |word| %w[-p --].include?(word.text) }
        raise ShellUnmodeled if rest.first && rest.first.text.start_with?("-")

        unwrap_words(rest, depth + 1)
      when "exec"
        loop do
          head = rest.first
          break unless head && head.text.start_with?("-")

          rest = rest.drop(head.text == "-a" ? 2 : 1)
        end
        unwrap_words(rest, depth + 1)
      when "time"
        rest = rest.drop(1) while rest.first && rest.first.text == "-p"
        unwrap_words(rest, depth + 1)
      when "nice"
        head = rest.first
        if head && head.text == "-n"
          rest = rest.drop(2)
        elsif head && head.text =~ /\A(-n\d+|-\d+|--adjustment=\d+)\z/
          rest = rest.drop(1)
        end
        unwrap_words(rest, depth + 1)
      when "timeout"
        rest = skip_timeout_options(rest)
        unwrap_words(rest, depth + 1)
      when "stdbuf"
        loop do
          head = rest.first
          break unless head && head.text.start_with?("-")

          rest = rest.drop(%w[-i -o -e].include?(head.text) ? 2 : 1)
        end
        unwrap_words(rest, depth + 1)
      else
        words
      end
    end

    def skip_env_options(words)
      rest = words.dup
      loop do
        head = rest.first
        break unless head

        text = head.text
        if text == "--"
          rest.shift
          break
        elsif text =~ /\A-[i0v]+\z/ || %w[--ignore-environment --null --debug].include?(text)
          rest.shift
        elsif text == "-u" || text == "--unset"
          rest = rest.drop(2)
        elsif text =~ /\A(-u.+|--unset=.*)\z/
          rest.shift
        elsif text.start_with?("-")
          raise ShellUnmodeled
        elsif text =~ /\A([A-Za-z_][A-Za-z0-9_]*)=/
          raise ShellUnmodeled if Regexp.last_match(1) =~ ENV_ASSIGN_DENY

          rest.shift
        else
          break
        end
      end
      rest
    end

    def skip_timeout_options(words)
      rest = words.dup
      loop do
        head = rest.first
        break unless head && head.text.start_with?("-")

        rest = rest.drop(%w[-k -s].include?(head.text) ? 2 : 1)
      end
      rest.drop(1)
    end

    def check_segment!(segment, workspace, owned_test, kind = "slice", cwd = nil)
      cwd ||= workspace || Reach::Paths.cwd
      parsed = parse_segment(segment)
      words = parsed[:words]
      outs = parsed[:outs]
      return if words.empty? && outs.empty? && parsed[:ins].empty?

      plain = words.map(&:text)
      check_vault_or_keys_reads!(plain + parsed[:ins].map(&:text) + outs.map(&:text), cwd)
      if words.empty?
        outs.each { |target| ensure_owned_target!(target, cwd, owned_test) }
        return
      end

      check_command_words!(words, outs, workspace, owned_test, kind, cwd)
    end

    def check_command_words!(words, outs, workspace, owned_test, kind, cwd)
      plain = words.map(&:text)
      cmd = plain[0]
      name = File.basename(cmd).sub(/\.exe\z/i, "")
      raise_blocked!("M-SHELL-UNMODELED") if words[0].dynamic || SHELL_RESERVED.include?(cmd)
      raise_blocked!("M-GATE-NOGIT") if name == "git" && kind != "extracurricular"
      forbid_command!(plain, kind)

      if readonly_command?(plain)
        outs.each { |target| ensure_owned_target!(target, cwd, owned_test) }
      elsif write_command?(plain)
        outs.each { |target| ensure_owned_target!(target, cwd, owned_test) }
        ensure_write_args_owned!(words, cwd, owned_test)
        inner = runner_inner(words)
        check_command_words!(inner, [], workspace, owned_test, kind, cwd) if inner
        check_ladder!(workspace) if kind == "slice"
        check_time_and_module!(workspace) if kind == "slice"
      else
        ensure_unknown_allowed!(words, outs, workspace, cwd)
      end
    end

    def runner_inner(words)
      name = File.basename(words[0].text)
      rest = words[1..-1]
      case name
      when "bundle"
        head = rest.drop_while { |word| word.text.start_with?("-") }.first
        return nil unless head && head.text == "exec"

        inner = rest.drop_while { |word| word.text.start_with?("-") }.drop(1).drop_while { |word| word.text.start_with?("-") }
        inner.empty? ? nil : unwrap_words(inner, 0)
      when "npx"
        inner = rest.drop_while { |word| word.text.start_with?("-") }
        inner.empty? ? nil : unwrap_words(inner, 0)
      when "npm"
        head = rest.first
        return nil unless head && %w[exec x].include?(head.text)

        inner = rest.drop(1).drop_while { |word| word.text.start_with?("-") }
        inner.empty? ? nil : unwrap_words(inner, 0)
      end
    end

    def forbid_command!(plain, kind)
      name = File.basename(plain[0].to_s).sub(/\.exe\z/i, "")
      args = plain[1..-1].to_a
      if kind != "extracurricular"
        raise_blocked!("M-SHELL-UNMODELED") if RUN_STRING_COMMANDS.include?(name) || name =~ /\A[A-Za-z]+(?:-[A-Za-z0-9]+)+\z/
        raise_blocked!("M-GATE-NOCODETOOL") if inline_code?(plain)
        check_shell_invocation!(name, args)
        check_stdin_interpreter!(name, args)
        check_sed_script!(args) if name == "sed"
      end
      raise_blocked!("M-SHELL-BLOCKED") if NETWORK_COMMANDS.include?(name)
      raise_blocked!("M-SHELL-UNMODELED") if %w[export declare typeset readonly local].include?(name) && args.any? { |arg| arg.sub(/\A-+\w*/, "") =~ /\A(?:[^=]*\s)?([A-Za-z_]\w*)=?/ && Regexp.last_match(1) =~ ENV_ASSIGN_DENY }
      raise_blocked!("M-SHELL-BLOCKED") if %w[rg grep].include?(name) && args.any? { |arg| arg.start_with?("--pre", "--hostname-bin") }
    end

    def check_sed_script!(args)
      scripts = []
      expression = false
      operand = nil
      i = 0
      while i < args.length
        arg = args[i]
        if arg.start_with?("--expression=")
          scripts << arg.sub("--expression=", "")
          expression = true
        elsif arg == "--expression" || arg =~ /\A-[A-Za-z]*e\z/
          scripts << args[i + 1].to_s
          expression = true
          i += 1
        elsif arg =~ /\A--file/ || arg =~ /\A-[A-Za-z]*f\z/
          raise_blocked!("M-SHELL-UNMODELED")
        elsif !arg.start_with?("-")
          operand ||= arg
        end
        i += 1
      end
      scripts << operand.to_s unless expression || operand.nil?
      safe = scripts.all? { |script| script.split(/;|\n/).all? { |part| part =~ SAFE_SED_COMMAND } }
      raise_blocked!("M-SHELL-UNMODELED") unless safe
    end

    def check_shell_invocation!(name, args)
      return unless SHELL_COMMANDS.include?(name)

      options = args.take_while { |arg| arg.start_with?("-") }
      operand = args[options.length]
      allowed = options.all? { |option| option =~ /\A-[exuvnl]+\z/ || %w[--norc --noprofile --posix].include?(option) }
      raise_blocked!("M-SHELL-UNMODELED") unless allowed && operand
    end

    def check_stdin_interpreter!(name, args)
      return unless STDIN_INTERPRETERS.include?(name.sub(/[0-9.]+\z/, "")) || STDIN_INTERPRETERS.include?(name)
      return if args.any? && args.all? { |arg| %w[-v -V --version -h --help].include?(arg) }

      raise_blocked!("M-SHELL-UNMODELED") unless args.any? { |arg| !arg.start_with?("-") }
    end

    def check_vault_or_keys_reads!(tokens, base)
      tokens.each do |tok|
        next unless path_like?(tok)

        resolved = resolve_arg(tok, base)
        raise_blocked!("M-SHELL-BLOCKED") if within?(resolved, Reach::Paths.vault_dir) || within?(resolved, Reach::Paths.keys_dir)
        next if shim_index([tok]) == 0 && tok != "reach"

        raise_blocked!("M-SHELL-BLOCKED") if Reach::Paths.inside_home?(resolved)
      end
    end

    def protected_path?(resolved)
      parts = resolved.to_s.split(File::SEPARATOR)
      names = case_insensitive_fs? ? PROTECTED_NAMES.map(&:downcase) : PROTECTED_NAMES
      parts = parts.map(&:downcase) if case_insensitive_fs?
      parts.any? { |part| names.include?(part) }
    end

    def resolve_write_target(token, base)
      resolved = resolve_target(File.expand_path(token.to_s, base))
      resolved = File.realpath(resolved) if File.symlink?(resolved)
      resolved
    rescue SystemCallError, ArgumentError
      raise_blocked!("M-SHELL-BLOCKED")
    end

    def ensure_owned_target!(word, base, owned_test)
      token = word.respond_to?(:text) ? word.text : word.to_s
      dynamic = word.respond_to?(:dynamic) && word.dynamic
      return if !dynamic && OUTSIDE_ALLOWED.include?(token)

      raise_blocked!("M-SHELL-BLOCKED") if dynamic || token.empty?

      resolved = resolve_write_target(token, base)
      raise_blocked!("M-SHELL-BLOCKED") if protected_path?(resolved)
      return if owned_test.call(resolved)

      raise_blocked!("M-SHELL-BLOCKED")
    end

    def ensure_write_args_owned!(words, base, owned_test)
      name = File.basename(words[0].text)
      if PACKAGE_WRITE.include?(name)
        words[1..-1].to_a.each do |word|
          next if word.text.start_with?("-")
          next unless path_like?(word.text)

          ensure_owned_target!(word, base, owned_test)
        end
        return
      end

      strict_write_operands(words, name).each { |word| ensure_owned_target!(word, base, owned_test) }
    end

    LONG_FLAGS_WITHOUT_PATH = %w[--size --mode --owner --group --suffix --backup --preserve --no-preserve --update --reflink --sparse --context].freeze

    def strict_write_operands(words, name)
      args = words[1..-1].to_a
      operands = []
      done = false
      skip = 0
      first_skipped = !%w[chmod chown chgrp].include?(name)
      script_skipped = name != "sed"
      script_flag = false
      reference = args.any? { |word| word.text.start_with?("--reference") }
      args.each do |word|
        text = word.text
        if skip > 0
          skip -= 1
          next
        end
        if !done && text == "--"
          done = true
        elsif !done && text.start_with?("-") && text != "-"
          if text.start_with?("--")
            flag, _, value = text.partition("=")
            operands << SHELL_WORD.new(value, word.dynamic) if !value.empty? && !LONG_FLAGS_WITHOUT_PATH.include?(flag)
            script_flag = true if %w[--expression --file].include?(flag)
            skip = 1 if name == "truncate" && flag == "--size" && value.empty?
          else
            skip = 1 if name == "truncate" && text == "-s"
            if %w[sed perl].include?(name) && text =~ /\A-[A-Za-z]*[ef]\z/
              script_flag = true
              skip = 1
            end
            match = %w[cp mv ln install].include?(name) ? text.match(/\A-[A-Za-z]*?t(.+)\z/) : nil
            operands << SHELL_WORD.new(match[1], word.dynamic) if match
            first_skipped = true if %w[chmod].include?(name) && text =~ /\A-[rwxXstugoa,=+-]+\z/
          end
        elsif name == "dd"
          key, eq, value = text.partition("=")
          operands << SHELL_WORD.new(value, word.dynamic) if eq == "=" && key == "of"
        elsif !first_skipped && !reference
          first_skipped = true
        elsif !script_skipped && !script_flag
          script_skipped = true
        else
          operands << word
        end
      end
      operands
    end

    def ensure_unknown_allowed!(words, outs, workspace, cwd)
      outs.each do |target|
        raise_blocked!("M-SHELL-BLOCKED") if target.dynamic || !OUTSIDE_ALLOWED.include?(target.text)
      end

      words[1..-1].to_a.each do |word|
        tok = word.text
        next if tok.start_with?("-")
        next unless path_like?(tok)

        resolved = resolve_arg(tok, cwd)
        raise_blocked!("M-SHELL-BLOCKED") unless workspace && within?(resolved, workspace)
      end
    end

    def readonly_command?(tokens)
      cmd = tokens[0]
      return true if cmd == "reach"
      return true if reach_shim_call?(tokens)
      return true if cmd == "ruby" && tokens[1] == "-c"
      return !tokens.any? { |token| FIND_WRITE_FLAGS.include?(token) } if cmd == "find"

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
      name = File.basename(tokens[0])
      args = tokens[1..-1].to_a
      return true if name == "find" && args.any? { |token| FIND_WRITE_FLAGS.include?(token) }
      return true if name == "sed" && args.any? { |token| token.start_with?("--in-place") || token =~ /\A-[nrsEzu]*i/ }
      return true if name == "sort" && args.any? { |token| token == "--output" || token.start_with?("--output=") || token =~ /\A-[A-Za-z]*o/ }
      return true if name == "perl" && args.any? { |token| token =~ /\A-[nplaswWtTuUx0-9]*i/ }

      WRITE_SINGLE.include?(name)
    end

    def path_like?(token)
      return false if token.nil? || token.empty?

      token.start_with?("/", "~", "./", "../") || token.include?("/")
    end

    def resolve_arg(token, workspace)
      base = workspace || Reach::Paths.cwd
      resolve_target(File.expand_path(token, base))
    end
  end
end
