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
        "digest" => text ? Digest::SHA256.hexdigest(text) : nil
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

    def shell(command:, event: nil, harness: nil)
      text = command.to_s
      return nil if support_command?(text)

      check_enrolled!
      require_login!(event)
      Reach::Update.hold!
      Reach::Relocation.hold! unless relocation_exempt?(text)
      raise_blocked!("M-SHELL-BLOCKED") if subshell_or_substitution?(text)

      space = current_space
      Reach::Controls.check_tool!("shell", space)
      kind = space && space["kind"]
      state = { cwd: hook_cwd(event) }

      if kind == "root"
        shell_from_root(text, state, event)
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

    def shell_from_root(text, state, event)
      split_segments(text).each do |segment|
        here = Reach::Workspace.space_for(state[:cwd])
        here_kind = here && here["kind"]
        check_outside_segment!(segment, state, event)

        case here_kind
        when "slice"
          workspace = here["path"]
          check_segment!(segment, workspace, shell_owned_test("slice", workspace), "slice")
          witness_in(workspace, "shell", { "command_digest" => Reach::Crypto.digest_hex(segment), "head" => segment[0, 200] })
        when "extracurricular"
          workspace = here["path"]
          check_segment!(segment, workspace, shell_owned_test("extracurricular", workspace), "extracurricular")
        else
          check_root_segment!(segment)
        end
      end
    end

    def relocation_exempt?(text)
      segments = split_segments(text)
      return false if segments.empty?

      segments.all? do |segment|
        tokens = Shellwords.split(segment)
        index = shim_index(tokens)
        index && RELOCATION_EXEMPT_ARGS.include?(tokens[index + 1])
      end
    rescue ArgumentError
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
      check_search_exposes_home!(plain, base)

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
      tokens = begin
        Shellwords.split(segment)
      rescue ArgumentError
        raise_blocked!("M-SHELL-BLOCKED")
      end
      return if tokens.empty?

      cmd = tokens[0]
      raise_blocked!("M-GATE-NOGIT") if cmd == "git"
      return if cmd.nil?

      raise_blocked!("M-SHELL-BLOCKED") if root_output_redirect?(tokens)
      return if cmd == "reach"
      return if %w[cd pushd].include?(cmd) && tokens.length == 2
      return if readonly_command?(tokens)

      raise_blocked!("M-SHELL-BLOCKED")
    end

    def root_output_redirect?(tokens)
      tokens.each_with_index.any? do |token, index|
        next false if token =~ /\A\d*>&\d+\z/

        match = token.match(/\A\d*(?:&>>?|>>?)(.*)\z/m)
        next false unless match

        target = match[1].to_s.empty? ? tokens[index + 1].to_s : match[1]
        !OUTSIDE_ALLOWED.include?(target)
      end
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

      check_vault_or_keys_reads!(plain_tokens + redirect_targets, workspace)
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
        next if shim_index([tok]) == 0 && tok != "reach"

        raise_blocked!("M-SHELL-BLOCKED") if Reach::Paths.inside_home?(resolved)
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
      base = workspace || Reach::Paths.cwd
      resolve_target(File.expand_path(token, base))
    end
  end
end
