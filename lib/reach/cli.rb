require "json"
require "timeout"
require "fileutils"
require "yaml"
require "time"
require "shellwords"
require "io/console"
require "stringio"

module Reach
  module CLI
    STDIN_GRACE_S = 0.5
    HERMES_EVENTS = %w[on_session_start on_session_end on_session_finalize on_session_reset pre_llm_call post_llm_call pre_tool_call post_tool_call pre_verify].freeze
    UNLOCKED_COMMANDS = [nil, "--help", "-h", "help", "version", "--version", "-V", "enroll", "enrol", "setup", "doctor", "support", "update", "runtime", "hello", "gate", "mcp", "guide", "instructor", "debug", "known-issues", "subscribe", "relocate", "codex"].freeze
    HERMES_BLOCK_NOTE = "Do not act on this message; tell the student what the rEach message above says.".freeze
    HOOK_BUDGETS_S = {
      "gate-session" => 8, "gate-prompt" => 8, "gate-write" => 8, "gate-shell" => 8, "gate-read" => 8, "gate-enroll" => 55,
      "hook-stop" => 26, "transcript-turn" => 26, "transcript-code" => 12, "hello" => 8, "check" => 55
    }.freeze
    HERMES_PROMPT_BUDGET_S = 13
    HOOK_DEFAULT_BUDGET_S = 8
    HERMES_FAIL_CLOSED_SUBS = %w[write shell read].freeze

    class << self
      def run(argv)
        started = Reach::Debug.clock
        code = nil
        failure = nil
        begin
          Reach::RetiredCapture.purge_once!
          code = hook_invocation?(argv) ? run_hook(argv) : run_terminal(argv)
        rescue StandardError, ScriptError => e
          failure = e
          code = 1
        ensure
          Reach::Debug.command(argv, code, started, failure || $!)
        end
        code
      end

      def run_terminal(argv)
        code = dispatch(argv)
        notice = argv.first == "mcp" || background_hello?(argv) ? nil : Reach::Link.notice!
        warn notice if notice
        issue_notice = argv.first == "mcp" || !$stderr.tty? ? nil : Reach::Issues.notice!
        warn issue_notice if issue_notice
        code
      rescue StandardError, ScriptError => e
        if Reach::Sandbox.blocking_error?(e)
          warn Reach::Sandbox.agent_text
          return 1
        end
        Reach::Debug.fault(e, "command:#{command_label(argv)}", "M-REACH-HICCUP-CLI")
        warn Reach::Messages.text("M-REACH-HICCUP-CLI")
        1
      end

      def background_hello?(argv)
        argv.first == "hello" && argv.include?("--background")
      end

      def command_label(argv)
        label = argv.first.to_s
        label.match?(/\A[a-z-]{1,24}\z/) ? label : "?"
      end

      def hook_invocation?(argv)
        case argv.first
        when "gate"
          true
        when "hello"
          !background_hello?(argv)
        when "hook"
          argv[1] == "stop"
        when "transcript"
          %w[turn code].include?(argv[1])
        when "check"
          flag = argv.index("--format")
          flag ? %w[agent hermes].include?(argv[flag + 1].to_s) : false
        else
          false
        end
      end

      def hook_label(argv)
        case argv.first
        when "gate", "transcript", "hook"
          "#{argv[0]}-#{argv[1]}"
        else
          argv.first.to_s
        end
      end

      def hook_harness_flag(argv)
        flag = argv.index("--harness")
        flag ? argv[flag + 1].to_s : nil
      end

      def hook_hermes?(argv)
        return true if hook_harness_flag(argv) == "hermes" || @hook_hermes == true

        flag = argv.index("--format")
        argv.first == "check" && flag ? argv[flag + 1].to_s == "hermes" : false
      end

      def hook_budget(argv)
        return HERMES_PROMPT_BUDGET_S if argv.first == "gate" && argv[1] == "prompt" && hook_harness_flag(argv) == "hermes"

        HOOK_BUDGETS_S.fetch(hook_label(argv), HOOK_DEFAULT_BUDGET_S)
      end

      def run_hook(argv)
        @hook_hermes = false
        original = $stdout
        buffer = StringIO.new
        $stdout = buffer
        code = nil
        failure = nil
        Reach::Locks.bound!
        begin
          code = Reach::Client.with_deadline(hook_budget(argv)) { dispatch_hook(argv) }
        rescue Reach::GateBlocked => e
          Reach::Debug.note(e)
          warn e.message
          code = 2
        rescue StandardError, ScriptError => e
          failure = e
        ensure
          $stdout = original
        end
        printed = buffer.string
        unless printed.empty?
          original.write(printed)
          original.flush
        end
        unless failure
          Reach::Gate.run_after_answer
          return code
        end

        hook_failure(failure, argv, !printed.empty?)
      end

      def hook_failure(error, argv, printed)
        label = hook_label(argv)
        hermes = hook_hermes?(argv)
        closed = hermes && argv.first == "gate" && HERMES_FAIL_CLOSED_SUBS.include?(argv[1])
        network = error.is_a?(Reach::NetworkError)
        text = closed ? nil : (network ? Reach::Link.notice! : Reach::Link.hiccup!)
        shown = if closed
          "M-REACH-HICCUP-BLOCKED"
        elsif text
          network ? "M-TEACH-LINK-LOST" : "M-REACH-HICCUP"
        end
        Reach::Debug.fault(error, "hook:#{label}", shown)
        if closed
          warn Reach::Messages.text("M-REACH-HICCUP-BLOCKED")
          warn HERMES_BLOCK_NOTE
          return 2
        end
        return 0 if printed

        if hermes
          if argv.first == "gate" && argv[1] == "prompt" && text
            puts JSON.generate("context" => Reach::Messages.text("M-TEACH-LINK-RELAY", text: text))
          else
            puts "{}"
          end
        elsif text
          puts JSON.generate("systemMessage" => text)
        end
        0
      rescue StandardError
        closed ? 2 : 0
      end

      def dispatch_hook(argv)
        route(argv.dup)
      end

      def failure_text(error, name = nil)
        return Reach::Sandbox.agent_text if Reach::Sandbox.blocking_error?(error)

        if Reach::Link.masked?(error)
          Reach::Debug.fault(error, "command:#{name || @command_name || "?"}", "M-REACH-HICCUP-CLI")
        end
        text = Reach::Link.student_text(error, :cli)
        Reach::Link.notice! if error.is_a?(Reach::NetworkError) && text == Reach::Messages.text("M-TEACH-LINK-LOST")
        text
      end

      def dispatch(argv)
        route(argv.dup)
      rescue Reach::GateBlocked => e
        Reach::Debug.note(e)
        warn e.message
        2
      rescue Reach::Error => e
        Reach::Debug.note(e)
        warn failure_text(e, @command_name)
        1
      end

      def route(args)
        unless args.first == "relocate" && Reach::Paths.legacy_active?
          begin
            Reach::Runtime.ensure_shim!
          rescue StandardError
            nil
          end
        end

        command = args.shift
        @command_name = command.to_s.match?(/\A[a-z-]{1,24}\z/) ? command.to_s : "?"

        unless UNLOCKED_COMMANDS.include?(command)
          lock = Reach::EnrollmentLock.state
          if lock["locked"]
            warn Reach::Messages.text(lock["message_id"])
            return 2
          end
        end

        case command
        when nil, "--help", "-h", "help"
          print_usage
          0
        when "version", "--version", "-V"
          puts "reach #{Reach::VERSION}"
          0
        when "enroll", "enrol"
          cmd_enroll(args)
        when "instructor"
          cmd_instructor(args)
        when "debug"
          cmd_debug(args)
        when "sync"
          cmd_sync(args)
        when "status"
          cmd_status(args)
        when "work"
          cmd_work(args)
        when "start"
          cmd_start(args)
        when "gate"
          cmd_gate(args)
        when "shape"
          cmd_shape(args)
        when "qualify"
          cmd_qualify(args)
        when "submit"
          cmd_submit(args)
        when "receipts"
          cmd_receipts(args)
        when "hand"
          cmd_hand(args)
        when "watch"
          cmd_watch(args)
        when "doctor"
          cmd_doctor(args)
        when "lock"
          cmd_lock(args)
        when "mcp"
          cmd_mcp(args)
        when "hello"
          cmd_hello(args)
        when "guide"
          cmd_guide(args)
        when "setup"
          cmd_setup(args)
        when "runtime"
          cmd_runtime(args)
        when "update"
          cmd_update(args)
        when "profile"
          cmd_profile(args)
        when "attempts"
          cmd_attempts(args)
        when "check"
          cmd_check(args)
        when "checkpoint"
          cmd_checkpoint(args)
        when "plan"
          cmd_plan(args)
        when "directive"
          cmd_directive(args)
        when "reference"
          cmd_reference(args)
        when "part"
          cmd_part(args)
        when "next"
          cmd_next(args)
        when "support"
          cmd_support(args)
        when "hook"
          cmd_hook(args)
        when "transcript"
          cmd_transcript(args)
        when "import"
          cmd_import(args)
        when "modules"
          cmd_modules(args)
        when "transfer"
          cmd_transfer(args)
        when "login"
          cmd_login(args)
        when "relocate"
          cmd_relocate(args)
        when "remember"
          cmd_remember(args)
        when "memory"
          cmd_memory(args)
        when "storage"
          cmd_storage(args)
        when "issues"
          cmd_issues(args)
        when "live"
          cmd_live(args)
        when "known-issues"
          cmd_known_issues(args)
        when "codex"
          cmd_codex(args)
        when "subscribe"
          cmd_subscribe(args)
        when "grade"
          cmd_grade(args)
        when "extra-credit"
          cmd_extra_credit(args)
        else
          warn "reach: unknown command #{command.inspect}"
          print_usage
          1
        end
      end

      private

      def print_usage
        puts <<~USAGE
          usage: reach <command> [options]

          commands:
            enroll [--course-passkey P --username U --student-id I --password-stdin]   enroll with your course passkey, username, student ID and a password you choose (--password-stdin reads the password from standard input; asks for them when none are given)
            enroll <code>                        enroll with a per-student code
            version                              print this rEach's version (also --version, -V)
            sync                                 fetch new packages and refresh workspaces
            status                               enrollment, slices, receipts, open hands
            work [--harness ...] [--slice ... | --extracurricular]   open a slice, or your own folder
            start [--harness ...]                launch a harness outside a course workspace
            gate session|prompt|enroll|write|shell|read  called by harness hooks
            shape check [--changed <path>] [--format text|agent|json]
            qualify [--slice ...] [--list] [--format text|agent|json] [--local-only] [--task ...] [--summary ...]   prove the slice before submitting
            submit [--slice ...]                 ask the student, then submit and wait for the receipt
            submit archive [--assignment A]      save the ZIP of a submitted assignment to Downloads again (the student must also upload it to the course's learning system)
            receipts [wait|show|acks]            receipts
            hand raise [--type T] [--summary ...] [--slice ...] [--include-profile] | status | list   hand-raises; T is one of the request types (student_request, concept_question, assignment_question, deadline_question, grade_question, submission_question, technical_issue, setup_issue, access_issue, extension_request, feedback, integrity_question, other)
            grade [--format text|json]           the points recorded for the student in Teach
            extra-credit CODE ANSWER... | extra-credit CODE --answer TEXT | extra-credit list [--format text|json]   turn in an extra-credit answer, or list what was turned in
            watch [--slice ...]                  polling shape-check backstop for Codex
            doctor [--install-chromium]          check the local install, one line per problem
            doctor --report [--offline] [--format json]  print every diagnostic fact (Ruby, OpenSSL, kit, crypto self-tests, package opening stage by stage), never secrets
            lock                                 wipe the decrypted vault
            debug on [--for MINUTES] | off | status [--format text|json] | show [--last N] [--format ascii|markdown|json] | flush   debug mode: what rEach did, with no prompts, replies, code or secrets
            instructor keygen [--out PATH] | code [--label TEXT] [--key PATH] | status [--format text|json] | lock | dummy [--course ID] | as USERNAME [--course ID] | exit   instructor unlock codes
            mcp                                  the stdio MCP bridge
            hello [--harness ...] [--format ...] [--source ...]   session-start greeting
            guide [--path] [--format text|json]  the installation and setup guide, as text
            setup [--harness auto|claude-code|codex|antigravity|hermes] [--source ...] [--format ...] [--runtime]
            codex status|probe [--format text|json] | configure [--mode workspace|full] | off   set Codex's own settings so rEach works in its sandbox (asks the student first), test the sandbox, or stop putting the settings back
            runtime install [--only ruby|chrome] [--from DIR] [--yes] | status [--json] | remove --yes [--old]   the Ruby, gems and Chrome for local checks
            update status|check|run [--apply]    look for, download and install a newer rEach
            subscribe status [--format text|json] | install | uninstall   the course server update check and its background job
            profile show|save|forget             the student's saved interview answers
            attempts show|continue [--slice ...] the attempt ladder; continue records the student's yes
            check [--changed <path>] [--format text|agent|json|hermes]   check the slice's code against the rules
            checkpoint save|list|show|restore    snapshots of the slice's files, kept by rEach
            plan save|show|note                  the slice plan
            part [record <id>]                   the questions only you can answer for this assignment
            next                                 the next step
            support                              help if you are having a hard time
            directive <OPCODE> | --list          a directive's full text
            reference list|show <path>|search <words>|links|ingest [--force]   the course reference material
            hook stop [--final] --harness H
            modules [choose <a> <b>]             your modules; choose them when your course lets you
            transfer request --modules a,b       ask your instructor to confirm a module move
            login status                         whether this session is signed in
            relocate [--format text|json]        move rEach's own files into your reach-work folder, or show where that stands
            remember --category C --claim TEXT --evidence TEXT [--supersedes ID] [--origin import:JOB/CONVERSATION] [--format text|json]   keep one durable thing you learned about the student or their work
            memory [list [--category C] [--limit N] | show ID | forget ID... | forget --all --yes | export] [--format text|json]   what rEach remembers, and forgetting it
            issues [list | flush]   technical problems rEach noticed and reported by itself (the list is for instructors and debug mode)
            live [status | request [--hand ID] | wait | note TEXT | say TEXT | end]   a live session with your instructors; rEach asks you before anything is run or sent
            storage [status | measure | compact] [--format text|json]   how much space rEach's memory uses on this computer, and compacting the saved course memory (asks the student first)
            import export PATH --mode brain|copy [--format text|json]   bring a downloaded ChatGPT, Claude or Gemini export (folder or ZIP) into rEach, asking the student first (brain: a catalog and findings; copy: the same plus a full copy on this computer)
            import pick [--folder]               open the operating system's own picker for the export's ZIP (or its folder) and print the chosen path
            import status | cancel | list [--job ID] [--format text|json]   progress of the background import, stop it, or list imports
            import next [--job ID] | done CONVERSATION [--part N] [--job ID]   the next queued conversation to learn from, and mark it worked
            import search QUERY [--job ID] | show CONVERSATION [--part N] [--job ID]   search the imported conversations, or print one from the saved copy
        USAGE
      end

      def parse_flags(args, keys)
        options = {}
        remaining = []
        index = 0
        while index < args.length
          token = args[index]
          flag_key = keys.find { |key| token == "--#{key.to_s.tr('_', '-')}" }
          if flag_key
            options[flag_key] = args[index + 1]
            index += 2
          else
            remaining << token
            index += 1
          end
        end
        [options, remaining]
      end

      def parse_bare_flag(args, name)
        found = args.include?("--#{name}")
        remaining = args.reject { |token| token == "--#{name}" }
        [found, remaining]
      end

      def resolve_workspace(slice_hint)
        slices = Reach::Workspace.current_slices
        return nil if slices.nil? || slices.empty?
        return slices.first if slice_hint.nil? && slices.length == 1
        return nil if slice_hint.nil?

        slices.find { |workspace_path| File.basename(workspace_path).include?(slice_hint) }
      rescue StandardError
        nil
      end

      def pick_slice_if_ambiguous(workspace)
        return workspace if workspace

        Reach::Gate.raise_pick_slice! if Reach::Gate.root_kind? && Reach::Workspace.current_slices.length > 1
        nil
      end

      def default_slice_id(slice_hint = nil)
        return slice_hint if slice_hint

        current_workspace_basename || begin
          workspace_path = resolve_workspace(nil)
          workspace_path && File.basename(workspace_path)
        end
      end

      def read_stdin_json
        return {} if STDIN.tty?
        return {} unless IO.select([STDIN], nil, nil, STDIN_GRACE_S)

        data = STDIN.read
        return {} if data.nil? || data.strip.empty?

        JSON.parse(data)
      rescue StandardError
        {}
      end

      def cmd_enroll(args)
        password_stdin, args = parse_bare_flag(args, "password-stdin")
        options, remaining = parse_flags(args, [:teach_url, :course_passkey, :course_code, :username, :student_id])
        options[:course_code] = options.delete(:course_passkey) || options[:course_code]
        options[:password_stdin] = password_stdin
        code = remaining.shift
        teach_url = options[:teach_url] || Reach::Runtime.default_teach_url
        unless teach_url
          warn "reach: this copy of rEach has no course server configured; run reach update, then try again"
          return 1
        end
        if options[:course_code] || (code.nil? && STDIN.tty?)
          return enroll_with_identity(options, teach_url)
        end

        unless code
          warn "usage: reach enroll [--course-passkey P --username U --student-id I --password-stdin] | reach enroll <code>"
          return 1
        end
        install = Reach::Enroll.generate_and_register(code, teach_url)
        finish_enroll(install)
      rescue Reach::NetworkError => e
        Reach::Debug.note(e)
        warn Reach::Messages.text("M-ENR-CLI-OFFLINE", url: teach_url, detail: e.detail || e.cause_name)
        1
      end

      def enroll_with_identity(options, teach_url)
        interactive = options[:course_code].nil?
        parsed = interactive ? ask_course_code : Reach::Identity.parse_course_code(options[:course_code])
        unless parsed
          warn Reach::Messages.text("M-ENR-CODE-FORMAT")
          return 1
        end
        begin
          preview = Reach::Enroll.preview(parsed["code"], teach_url)
        rescue Reach::RemoteRefused => e
          warn Reach::EnrollFlow.refusal_text(e)
          return 1
        end
        course = preview["course"]
        rules = Reach::Identity.rules(preview["identity"])
        asked = Reach::Messages.text(
          "M-ENR-ASK-USERNAME",
          course_title: course["title"], course_id: course["id"], term: course["term"],
          institution: rules["institution_name"], domain: rules["username_domain"]
        )
        username = interactive ? ask_value(asked, Reach::Messages.text("M-ENR-USERNAME-FORMAT", institution: rules["institution_name"], domain: rules["username_domain"])) { |text| Reach::Identity.normalize_username(text, rules) } : Reach::Identity.normalize_username(options[:username], rules)
        unless username
          warn Reach::Messages.text("M-ENR-USERNAME-FORMAT", institution: rules["institution_name"], domain: rules["username_domain"])
          return 1
        end
        student_id = interactive ? ask_value(Reach::Messages.text("M-ENR-ASK-ID", institution: rules["institution_name"]), Reach::Messages.text("M-ENR-ID-FORMAT", institution: rules["institution_name"])) { |text| Reach::Identity.normalize_student_id(text, rules) } : Reach::Identity.normalize_student_id(options[:student_id], rules)
        unless student_id
          warn Reach::Messages.text("M-ENR-ID-FORMAT", institution: rules["institution_name"])
          return 1
        end
        password = interactive ? ask_password : read_password_stdin(options)
        return 1 unless password

        begin
          install = Reach::Enroll.register_v2(
            course_code: parsed["code"], username: username, student_id: student_id,
            teach_url: teach_url, harness: "cli", enrolled_via: "cli", password: password
          )
        rescue Reach::RemoteRefused => e
          if e.code == "password_required"
            warn failure_text(e, "enroll")
            return 1
          end
          if e.code == "device_move_pending"
            warn Reach::Messages.text("M-ENR-MOVE-PENDING")
            return 3
          end
          if e.code == "device_move_denied"
            warn Reach::Messages.text("M-ENR-MOVE-DENIED", reason: Reach::EnrollFlow.denial_reason(e))
            return 1
          end
          warn(e.code == "enrollment_refused" ? Reach::Messages.text("M-ENR-REFUSED", course_id: course["id"]) : Reach::EnrollFlow.refusal_text(e))
          return 1
        end
        finish_enroll(install)
      end

      def read_hidden
        line = STDIN.noecho(&:gets)
        puts
        line && line.strip
      end

      def ask_password
        loop do
          puts Reach::Messages.text("M-ENR-ASK-PASSWORD")
          password = read_hidden
          return nil if password.nil?

          unless password.length >= 8 && password.length <= 256
            puts Reach::Messages.text("M-ENR-PASSWORD-SHORT")
            next
          end
          puts Reach::Messages.text("M-ENR-ASK-PASSWORD-AGAIN")
          again = read_hidden
          return nil if again.nil?
          return password if again == password

          puts Reach::Messages.text("M-ENR-PASSWORD-MISMATCH")
        end
      end

      def read_password_stdin(options)
        if options[:password_stdin]
          line = STDIN.gets
          password = line.to_s.strip
          unless password.length >= 8 && password.length <= 256
            warn Reach::Messages.text("M-ENR-PASSWORD-SHORT")
            return nil
          end
          return password
        end
        warn "reach: enroll needs --password-stdin when it is not run in a terminal"
        nil
      end

      def ask_course_code
        ask_value(Reach::Messages.text("M-ENR-ASK-CODE"), Reach::Messages.text("M-ENR-CODE-FORMAT")) { |text| Reach::Identity.parse_course_code(text) }
      end

      def ask_value(question, retry_text)
        puts question
        5.times do
          line = STDIN.gets
          return nil if line.nil?

          value = yield(line.strip)
          return value if value

          puts retry_text
        end
        nil
      end

      def finish_enroll(install)
        course_title = install["course"] && install["course"]["title"]
        puts Reach::Messages.text("M-ENROLL-DONE", course: course_title)
        puts Reach::Messages.text("M-FINGERPRINT-NOTICE") if install["shape"] == "v2"
        puts Reach::Messages.text("M-ENR-PASSWORD-REMINDER") if install["shape"] == "v2"
        summary = Reach::Sync.run
        print_sync_summary(summary)
        if Array(summary["workspaces"]).empty?
          puts Reach::Messages.text("M-ENROLL-PENDING")
        else
          puts Reach::Messages.text("M-ENROLL-READY")
        end
        0
      end

      def cmd_sync(_args)
        Reach::Update.hold!
        summary = Reach::Sync.run
        print_sync_summary(summary)
        return 2 if summary["state"] == "revoked"

        0
      end

      def print_sync_summary(summary)
        puts "Course rules: v#{summary["guardrails_version"]} (verified)" if summary["guardrails_version"]
        Array(summary["workspaces"]).each do |workspace|
          puts "Workspace: #{workspace["path"]}"
          kept = workspace["kept_files"]
          puts "Kept your changes: #{Array(kept).join(", ")}" if kept && !Array(kept).empty?
        end
        puts "Sent #{summary["outbox_sent"]} queued item(s)." if summary["outbox_sent"].to_i > 0
        Array(summary["grades"]).each { |text| puts text }
        if summary["transfer"]
          puts summary["transfer"]
          Reach::Transfer.mark_announced!
        end
        Array(summary["warnings"]).each { |warning| puts warning }
        puts Reach::Messages.text("M-OFFLINE") if summary["state"] == "offline"
        puts Reach::Messages.text("M-GATE-REVOKED") if summary["state"] == "revoked"
      end

      def cmd_status(_args)
        puts Reach::Status.summary
        0
      end

      def cmd_work(args)
        options, remaining = parse_flags(args, [:harness, :slice])
        extracurricular, _remaining = parse_bare_flag(remaining, "extracurricular")
        if extracurricular
          Reach::Workspace.provision_extracurricular!
          workspace_path = Reach::Paths.extracurricular_root
        else
          workspace_path = resolve_workspace(options[:slice])
          unless workspace_path
            warn "reach: no matching slice workspace found; run reach sync"
            return 1
          end
        end
        harness_id = options[:harness] || pick_harness
        unless harness_id
          warn "reach: no supported harness found on PATH; pass --harness claude-code|codex|antigravity|hermes"
          return 1
        end
        Reach::Harness.launch(harness_id, workspace_path, initial_prompt: "Hi rEach")
        0
      end

      def cmd_start(args)
        options, _remaining = parse_flags(args, [:harness])
        harness_id = options[:harness] || pick_harness
        unless harness_id
          warn "reach: no supported harness found on PATH; pass --harness claude-code|codex|antigravity|hermes"
          return 1
        end
        Reach::Harness.launch(harness_id, Dir.pwd, initial_prompt: "Hi rEach")
        0
      end

      def pick_harness
        detected = Reach::Harness.detect
        return nil if detected.nil? || detected.empty?
        return detected.first[:id] if detected.length == 1

        nil
      end

      def cmd_gate(args)
        sub = args.shift
        options, _remaining = parse_flags(args, [:harness, :path, :command])
        event = read_stdin_json
        Reach::KnownIssues.record_hook!(Reach::Fingerprint.harness_label(options[:harness]))
        Reach::Debug.begin_hook(event, options[:harness])
        started = Reach::Debug.clock
        @gate_decision = "allow"
        rule = nil
        begin
          gate_dispatch(sub, options, event)
        rescue Reach::GateBlocked => e
          @gate_decision = "block"
          rule = e.message_id
          raise
        ensure
          name = event.is_a?(Hash) && event["hook_event_name"] ? event["hook_event_name"].to_s : "gate-#{sub}"
          Reach::Debug.hook(name, @gate_decision, rule, started)
          Reach::Debug.emit("gate", "check" => sub.to_s, "outcome" => @gate_decision, "message_id" => rule)
        end
      end

      def gate_dispatch(sub, options, event)
        return gate_enroll(options[:harness], event) if sub == "enroll"

        hermes = hermes_hook?(options[:harness], event)
        if hermes
          event = normalize_hermes_event(event)
          return 0 unless event
        end
        tool_input = event["tool_input"] || {}
        case sub
        when "session"
          harness_id = options[:harness] || event["harness"] || "claude-code"
          Reach::Gate.session(harness: harness_id)
          announced = hermes ? false : announce_guardrails
          unless hermes || announced
            notice = [Reach::Link.notice!, Reach::Issues.notice!].compact.join("\n\n")
            puts JSON.generate("systemMessage" => notice) unless notice.empty?
          end
          0
        when "prompt"
          return gate_hermes_prompt(event) if hermes

          context = Reach::Gate.prompt(event: event, harness: options[:harness])
          @gate_decision = "context" if context
          payload = {}
          payload["hookSpecificOutput"] = { "hookEventName" => "UserPromptSubmit", "additionalContext" => context } if context
          message = [Reach::Link.notice!, Reach::Issues.notice!, Reach::Debug.prompt_message(event, options[:harness])].compact.join("\n\n")
          payload["systemMessage"] = message unless message.empty?
          puts JSON.generate(payload) unless payload.empty?
          0
        when "write"
          path = options[:path] || tool_input["file_path"] || tool_input["path"] || tool_input["notebook_path"]
          tool_name = event["tool_name"]
          command_text = tool_input["command"]
          patch = command_text if tool_name == "apply_patch" || command_text.to_s.start_with?("*** Begin Patch")
          patch = tool_input["patch"].to_s if tool_name == "patch" && tool_input["mode"] == "patch"
          Reach::Gate.code_tool! if hermes && tool_name == "execute_code"
          Reach::Gate.write(path: path, patch: patch, event: event, harness: options[:harness])
          0
        when "shell"
          command = shell_text(options[:command] || tool_input["command"] || tool_input["cmd"])
          if command.include?("*** Begin Patch")
            Reach::Gate.write(patch: command, event: event, harness: options[:harness])
          else
            Reach::Gate.shell(command: command, event: event, harness: options[:harness])
          end
          0
        when "read"
          Reach::Gate.read(event: event, harness: options[:harness])
          0
        else
          warn "usage: reach gate session|prompt|enroll|write|shell|read"
          1
        end
      end

      def cmd_instructor(args)
        sub = args.shift
        case sub
        when "keygen"
          options, _remaining = parse_flags(args, [:out])
          result = Reach::Instructor.keygen(options[:out] || Reach::Instructor.default_key_path)
          puts Reach::Messages.text(
            "M-INSTRUCTOR-KEYGEN",
            path: result["path"], key_id: result["key_id"],
            entry: instructor_entry(result["key_id"], result["public_key_pem"])
          )
          0
        when "code"
          options, _remaining = parse_flags(args, [:label, :key])
          key = Reach::Instructor.load_private(options[:key] || Reach::Instructor.default_key_path)
          puts Reach::Instructor.mint(key, label: options[:label].to_s)
          0
        when "status"
          options, _remaining = parse_flags(args, [:format])
          status = Reach::Instructor.status
          persona = Reach::Persona.status
          if (options[:format] || "text") == "json"
            puts JSON.generate(status.merge("persona" => persona))
          else
            if status["unlocked"]
              puts Reach::Messages.text(
                "M-INSTRUCTOR-STATUS",
                code_id: status["code_id"], label: status["label"], key_id: status["key_id"], unlocked_at: status["unlocked_at"]
              )
            else
              puts Reach::Messages.text("M-INSTRUCTOR-STATUS-OFF")
            end
            if persona["active"]
              puts Reach::Messages.text(
                "M-PERSONA-STATUS",
                display_name: persona["display_name"], id: persona["id"], kind: persona["kind"], username: persona["username"],
                student_id: persona["student_id"], course_id: persona["course_id"], started_at: persona["started_at"], workspace: persona["workspace"]
              )
            end
          end
          0
        when "lock"
          if Reach::Persona.active?
            exited = Reach::Persona.exit!
            puts Reach::Messages.text("M-PERSONA-EXITED", display_name: exited["display_name"]) if exited
          end
          Reach::Instructor.lock!
          puts Reach::Messages.text("M-INSTRUCTOR-LOCKED")
          0
        when "dummy", "as"
          instructor_persona(sub, args)
        when "exit"
          raise Reach::Refused, Reach::Messages.text("M-PERSONA-NEEDS-UNLOCK") unless Reach::Instructor.active? || Reach::Persona.active?

          exited = Reach::Persona.exit!
          if exited
            puts Reach::Messages.text("M-PERSONA-EXITED", display_name: exited["display_name"])
            0
          else
            puts Reach::Messages.text("M-PERSONA-NONE")
            1
          end
        else
          warn Reach::Messages.text("M-INSTRUCTOR-USAGE")
          1
        end
      rescue Reach::Error => e
        warn failure_text(e, "instructor")
        1
      end

      def cmd_debug(args)
        sub = args.shift
        case sub
        when "on"
          options, _remaining = parse_flags(args, [:for])
          minutes = options[:for]
          if !minutes.nil? && !minutes.to_s.match?(/\A[1-9][0-9]{0,5}\z/)
            warn Reach::Messages.text("M-DEBUG-USAGE")
            return 1
          end
          if Reach::Persona.active?
            puts Reach::Messages.text("M-DEBUG-PERSONA")
            return 0
          end
          until_at = Reach::Debug.turn_on!(minutes)
          puts until_at ? Reach::Messages.text("M-DEBUG-ON-UNTIL", until: until_at) : Reach::Messages.text("M-DEBUG-ON")
          0
        when "off"
          if Reach::Persona.active?
            puts Reach::Messages.text("M-DEBUG-PERSONA")
            return 1
          end
          Reach::Debug.turn_off!
          puts Reach::Messages.text("M-DEBUG-OFF")
          puts Reach::Messages.text("M-DEBUG-REMOTE-STILL") if Reach::Debug.on?
          0
        when "status"
          options, _remaining = parse_flags(args, [:format])
          report = Reach::Debug.status
          if (options[:format] || "text") == "json"
            puts JSON.generate(report)
          elsif report["on"]
            puts Reach::Messages.text(
              "M-DEBUG-STATUS-ON", reason: report["reason"], until: report["until"] || "no end time",
              queued: report["spool"]["queued"], sent: report["spool"]["sent"], dropped: report["spool"]["dropped"]
            )
          else
            puts Reach::Messages.text("M-DEBUG-STATUS-OFF", queued: report["spool"]["queued"], sent: report["spool"]["sent"])
          end
          0
        when "show"
          options, _remaining = parse_flags(args, [:last, :format])
          format = options[:format] || Reach::DebugRender.format_for(Reach::Debug.resolve_harness(nil), {})
          unless %w[ascii markdown json].include?(format)
            warn Reach::Messages.text("M-DEBUG-USAGE")
            return 1
          end
          last = options[:last].to_s.match?(/\A[1-9][0-9]{0,4}\z/) ? options[:last].to_i : Reach::Debug.config["show_max_rows"].to_i
          entries = Reach::Debug.read_events.last(last)
          if format == "json"
            puts JSON.generate(entries.map { |entry| entry["event"] })
          else
            puts Reach::DebugRender.table(entries, format: format, limit: last)
          end
          0
        when "flush"
          result = Reach::Debug.flush(quick: false)
          puts Reach::Messages.text("M-DEBUG-FLUSHED", sent: result["sent"], stopped: result["stopped"] || "none")
          0
        else
          warn Reach::Messages.text("M-DEBUG-USAGE")
          1
        end
      end

      def instructor_persona(sub, args)
        raise Reach::Refused, Reach::Messages.text("M-PERSONA-NEEDS-UNLOCK") unless Reach::Instructor.active?

        options, remaining = parse_flags(args, [:course])
        username = nil
        if sub == "as"
          username = remaining.shift.to_s.strip
          if username.empty?
            warn Reach::Messages.text("M-INSTRUCTOR-USAGE")
            return 1
          end
        end
        result = Reach::Persona.start!(kind: sub == "as" ? "copy" : "dummy", username: username, course_id: options[:course])
        record = result["persona"]
        puts Reach::Messages.text("M-PERSONA-STARTED", display_name: record["display_name"], student_id: record["student_id"], course_id: record["course_id"], workspace: result["workspace"])
        print_sync_summary(result["summary"]) if result["summary"]
        0
      end

      def instructor_entry(key_id, pem)
        indented = pem.lines.map { |line| "        #{line.chomp}" }.join("\n")
        "enrollment:\n  instructor_keys:\n    - id: #{key_id}\n      label: instructor\n      public_key_pem: |\n#{indented}"
      end

      def gate_enroll(harness, event)
        hermes = hermes_hook?(harness, event)
        harness_id = hermes ? "hermes" : (harness || "claude-code")
        event = {} unless event.is_a?(Hash)
        if hermes
          extra = event["extra"].is_a?(Hash) ? event["extra"] : {}
          message = extra["user_message"]
          message = message.map { |part| part.is_a?(Hash) && part["type"] == "text" ? part["text"].to_s : nil }.compact.join("\n") if message.is_a?(Array)
          event = event.merge("prompt" => message) if message.is_a?(String)
        end
        if Reach::Persona.active? && !Reach::Instructor.attempt?(event["prompt"]) && Reach::EnrollmentLock.state["reason"] == "instructor_revoked"
          text = Reach::Messages.text("M-PERSONA-LOCKED")
          if hermes
            puts JSON.generate("context" => Reach::Messages.text("M-ENR-HERMES", message: text))
            return 0
          end
          raise Reach::GateBlocked.new("M-PERSONA-LOCKED", text)
        end
        decision = Reach::EnrollFlow.evaluate(event: event, harness: harness_id)
        signed_in = nil
        decision, signed_in = enroll_login(event, harness_id) if decision.nil? && !hermes
        if decision.nil?
          notice = [Reach::EnrollFlow.consume_notice, signed_in].compact.join("\n\n")
          notice = nil if notice.empty?
          if Reach::Instructor.mode?
            session = Reach::Session.resolve_session_id(event)
            notice = [notice, Reach::Instructor.context_once(session)].compact.join("\n\n")
            notice = nil if notice.empty?
          end
          remote = Reach::Debug.remote_notice(nil)
          notice = [notice, remote].compact.join("\n\n") if remote
          if hermes
            puts JSON.generate(notice ? { "context" => notice } : {})
          else
            payload = {}
            payload["hookSpecificOutput"] = { "hookEventName" => "UserPromptSubmit", "additionalContext" => notice } if notice
            message = Reach::Debug.prompt_message(event, harness)
            payload["systemMessage"] = message if message
            puts JSON.generate(payload) unless payload.empty?
          end
          return 0
        end

        message = decision["message"]
        if hermes
          guide = Reach::Messages.text("M-ENR-HERMES-GUIDE", command: Reach::Runtime.hook_command("guide"))
          puts JSON.generate("context" => "#{Reach::Messages.text("M-ENR-HERMES", message: message)}\n\n#{guide}")
          return 0
        end
        raise Reach::GateBlocked.new(decision["id"] || "M-ENR", message)
      end

      def enroll_login(event, harness_id)
        return nil if Reach::Instructor.mode? || !Reach::Login.required?

        codex = !event["turn_id"].to_s.empty?
        unless codex
          cwd = event["cwd"].is_a?(String) && !event["cwd"].empty? ? event["cwd"] : Dir.pwd
          return nil if Reach::Workspace.space_for(cwd)
        end
        harness_id = "codex" if codex
        result = begin
          Reach::Login.claim(event: event, harness: harness_id)
        rescue StandardError
          { "action" => "block", "message" => Reach::Messages.text("M-LOGIN-NEEDED") }
        end
        return [{ "id" => "M-LOGIN", "message" => result["message"].to_s }, nil] if result.is_a?(Hash) && result["action"] == "block"
        return nil unless result.is_a?(Hash)

        session = Reach::Session.resolve_session_id(event)
        context = []
        if Reach::Login.just_confirmed?(session)
          context << Reach::Gate.signed_in_context(harness_id, session)
          Reach::Gate.after_answer { Reach::Login.clear_just_confirmed(session) }
        end
        context << result["context"]
        text = context.compact.join("\n\n")
        [nil, text.empty? ? nil : text]
      rescue StandardError
        nil
      end

      def hermes_hook?(harness, event)
        found = harness.to_s == "hermes" || (event.is_a?(Hash) && HERMES_EVENTS.include?(event["hook_event_name"]))
        @hook_hermes = true if found
        found
      end

      def normalize_hermes_event(event)
        event = {} unless event.is_a?(Hash)
        cwd = event["cwd"]
        begin
          Dir.chdir(cwd) if cwd.is_a?(String) && File.directory?(cwd)
        rescue StandardError
          nil
        end
        return nil unless Reach::Gate.current_space

        extra = event["extra"].is_a?(Hash) ? event["extra"] : {}
        normalized = event.dup
        message = extra["user_message"]
        message = message.map { |part| part.is_a?(Hash) && part["type"] == "text" ? part["text"].to_s : nil }.compact.join("\n") if message.is_a?(Array)
        normalized["prompt"] = message if message.is_a?(String)
        normalized["is_first_turn"] = extra["is_first_turn"]
        normalized["assistant_response"] = extra["assistant_response"]
        normalized["attempt"] = extra["attempt"]
        tool_input = event["tool_input"].is_a?(Hash) ? event["tool_input"].dup : {}
        if event["tool_name"] == "patch" && tool_input["mode"] == "patch" && tool_input["patch"].is_a?(String)
          tool_input["command"] = tool_input["patch"]
        end
        normalized["tool_input"] = tool_input
        normalized
      end

      def gate_hermes_prompt(event)
        blocked = nil
        context = nil
        begin
          context = Reach::Gate.prompt(event: event, harness: "hermes")
        rescue Reach::GateBlocked => e
          blocked = e
        rescue StandardError
          nil
        end
        parts = []
        parts << Reach::Hello.context_text(harness: "hermes", cwd: Dir.pwd, source: "startup", session: Reach::Session.resolve_session_id(event)) if event["is_first_turn"] == true && blocked.nil?
        parts << context if context
        notice = [Reach::Link.notice!, Reach::Issues.notice!].compact.join("\n\n")
        parts << Reach::Messages.text("M-TEACH-LINK-RELAY", text: notice) unless notice.empty?
        parts << blocked.message << HERMES_BLOCK_NOTE if blocked
        puts JSON.generate(parts.empty? ? {} : { "context" => parts.join("\n\n") })
        0
      rescue StandardError
        puts "{}"
        0
      end

      def check_hermes(event)
        workspace = Reach::Gate.focus_workspace
        attempt = event["attempt"].to_i
        if workspace.nil? || attempt > 0
          puts "{}"
          return 0
        end

        findings = Reach::Check.run(workspace, changed: nil, format: :agent)
        if findings.empty?
          puts "{}"
        else
          lines = findings.map { |finding| Reach::Check.render_text([finding]) }
          message = (["reach check found problems in your files. Fix them, run reach check again, then finish:"] + lines).join("\n")
          puts JSON.generate("action" => "continue", "message" => message)
        end
        0
      rescue StandardError
        puts "{}"
        0
      end

      def shell_text(command)
        return command.to_s unless command.is_a?(Array)

        parts = command.map(&:to_s)
        if parts.length >= 3 && %w[bash sh zsh].include?(File.basename(parts[0])) && %w[-c -lc].include?(parts[1])
          parts[2..-1].join(" ")
        else
          Shellwords.join(parts)
        end
      end

      def announce_guardrails
        puts "Course rules #{Reach::Guardrails.version} verified."
        true
      rescue StandardError
        false
      end

      def cmd_shape(args)
        sub = args.shift
        unless sub == "check"
          warn "usage: reach shape check [--changed <path>] [--format text|agent|json]"
          return 1
        end
        options, _remaining = parse_flags(args, [:changed, :format, :slice])
        workspace_path = resolve_workspace(options[:slice]) || (Reach::Gate.root_kind? ? pick_slice_if_ambiguous(Reach::Gate.focus_workspace) : nil) || Dir.pwd
        format = (options[:format] || "text").to_sym
        findings = Reach::Shape.check(workspace_path: workspace_path, changed: options[:changed], format: format)
        case format
        when :json, :agent
          puts JSON.generate(findings)
        else
          puts findings
        end
        0
      end

      def cmd_qualify(args)
        Reach::Update.hold!
        local_only, args = parse_bare_flag(args, "local-only")
        listing, args = parse_bare_flag(args, "list")
        options, _remaining = parse_flags(args, [:slice, :format, :task, :summary])
        workspace = resolve_workspace(options[:slice]) || Reach::Gate.focus_workspace
        pick_slice_if_ambiguous(workspace)
        unless workspace
          warn "reach: no matching slice workspace found; run reach sync"
          return 1
        end
        if listing
          puts Reach::Qualify.listing(workspace)
          return 0
        end
        format = (options[:format] || "text").to_sym
        record = Reach::Qualify.run(workspace, local_only: local_only, task: options[:task], agent_summary: options[:summary])
        puts Reach::Qualify.render(record, format)
        return 0 if record["passed"]

        record["pending"] ? 3 : 1
      end

      def cmd_submit_archive(args)
        options, _remaining = parse_flags(args, [:assignment])
        result = Reach::Submit.archive_again(assignment: options[:assignment])
        puts result["text"]
        result["archive"]["state"] == "saved" ? 0 : 1
      end

      def cmd_grade(args)
        options, _remaining = parse_flags(args, [:format])
        result = Reach::Grades.fetch
        if (options[:format] || "text") == "json"
          puts JSON.generate(result)
        else
          puts result["text"]
        end
        0
      end

      def cmd_extra_credit(args)
        if args.first == "list"
          options, _remaining = parse_flags(args.drop(1), [:format])
          result = Reach::ExtraCredit.list
          puts((options[:format] || "text") == "json" ? JSON.generate(result) : result["text"])
          return 0
        end

        options, remaining = parse_flags(args, [:answer, :format])
        code = remaining.shift
        if code.nil?
          warn "usage: reach extra-credit CODE ANSWER... | reach extra-credit CODE --answer TEXT | reach extra-credit list"
          return 1
        end
        answer = options[:answer] || remaining.join(" ")
        result = Reach::ExtraCredit.redeem(code: code, answer: answer)
        puts((options[:format] || "text") == "json" ? JSON.generate(result) : result["text"])
        result["state"] == "refused" ? 1 : 0
      end

      def cmd_submit(args)
        Reach::Update.hold!
        return cmd_submit_archive(args.drop(1)) if args.first == "archive"

        options, _remaining = parse_flags(args, [:slice])
        Reach::Relocation.hold!
        slice = default_slice_id(options[:slice])
        pick_slice_if_ambiguous(slice)
        unless slice
          warn "usage: reach submit --slice <id>"
          return 1
        end
        result = Reach::Submit.submit(slice: slice)
        case result["state"]
        when "asked", "declined"
          puts result["text"]
          0
        when "ingested"
          puts Reach::Receipts.announce(result["receipt"])
          followup = Reach::Submit.followup_text(result)
          puts followup unless followup.empty?
          0
        when "rejected"
          rejection = result["rejection"] || {}
          warn Reach::Messages.text("M-SUBMIT-REJECTED", reason: rejection["reason"], fix: Reach::Messages.rejection_fix(rejection["code"]))
          1
        else
          puts Reach::Messages.text("M-SUBMIT-PENDING")
          0
        end
      end

      def cmd_receipts(args)
        sub = args.shift
        case sub
        when nil
          Reach::Receipts.list.each { |receipt| puts JSON.generate(receipt) }
          0
        when "wait"
          options, _remaining = parse_flags(args, [:submission])
          unless options[:submission]
            warn "usage: reach receipts wait --submission <id>"
            return 1
          end
          receipt = Reach::Receipts.wait(submission_id: options[:submission])
          if receipt
            puts Reach::Receipts.announce(receipt)
          else
            puts Reach::Messages.text("M-SUBMIT-PENDING")
          end
          0
        when "show"
          id = args.shift
          unless id
            warn "usage: reach receipts show <id>"
            return 1
          end
          receipt = Reach::Receipts.show(id)
          if receipt
            puts JSON.generate(receipt)
            0
          else
            warn "reach: no receipt #{id}"
            1
          end
        when "acks"
          Reach::ReceiptAcks.list.each { |record| puts JSON.generate(record) }
          0
        else
          warn "usage: reach receipts [wait|show|acks]"
          1
        end
      end

      def cmd_hand(args)
        sub = args.shift
        case sub
        when "raise"
          include_profile, args = parse_bare_flag(args, "include-profile")
          options, _remaining = parse_flags(args, [:type, :trigger, :summary, :slice])
          unless options[:summary]
            warn "usage: reach hand raise --summary <text> [--type student_request] [--slice <id>] [--include-profile]"
            return 1
          end
          record = Reach::Hands.raise_record(
            trigger: options[:type] || options[:trigger] || Reach::Hands::STUDENT_REQUEST,
            summary: options[:summary],
            slice: default_slice_id(options[:slice]),
            include_profile: include_profile
          )
          if record["refused"]
            raise Reach::Refused, Reach::Messages.text("M-HAND-REFUSED", reason: record["refused"]["message"])
          end

          if record["queued"]
            puts Reach::Messages.text("M-HAND-QUEUED")
          else
            puts "Hand raised: #{record['hand_id']}"
          end
          0
        when "late"
          options, _remaining = parse_flags(args, [:assignment, :type])
          assignment = options[:assignment].to_s
          if assignment.empty?
            warn "usage: reach hand late --assignment <id> [--type late_work|late_submission]"
            return 1
          end
          type = options[:type] == Reach::Hands::LATE_SUBMISSION ? Reach::Hands::LATE_SUBMISSION : Reach::Hands::LATE_WORK
          outcome = Reach::LateWork.send_hand(assignment: assignment, type: type)
          puts outcome["state"]
          0
        when "status"
          id = args.shift
          unless id
            warn "usage: reach hand status <id>"
            return 1
          end
          puts JSON.generate(Reach::Hands.status(id))
          0
        when "list"
          hands = Reach::Hands.respond_to?(:list) ? Reach::Hands.list : []
          hands.each { |hand| puts JSON.generate(hand) }
          0
        else
          warn "usage: reach hand raise|status|list"
          1
        end
      end

      def cmd_watch(args)
        options, _remaining = parse_flags(args, [:slice])
        workspace_path = resolve_workspace(options[:slice])
        unless workspace_path
          warn "reach: no matching slice workspace found"
          return 1
        end
        mtimes = {}
        interrupted = false
        trap("INT") { interrupted = true }
        until interrupted
          changed_path = detect_change(workspace_path, mtimes)
          if changed_path
            begin
              findings = Reach::Shape.check(workspace_path: workspace_path, changed: changed_path, format: :agent)
              puts JSON.generate(findings)
            rescue Reach::Error => e
              warn failure_text(e, "watch")
            end
          end
          sleep(2)
        end
        0
      end

      def detect_change(workspace_path, mtimes)
        changed_path = nil
        Reach::Workspace.owned_files(workspace_path).each do |relative_path|
          full_path = File.join(workspace_path, relative_path)
          next unless File.exist?(full_path)

          mtime = File.mtime(full_path)
          if mtimes.key?(relative_path) && mtimes[relative_path] != mtime
            changed_path = relative_path
          end
          mtimes[relative_path] = mtime
        end
        changed_path
      rescue StandardError
        nil
      end

      def cmd_doctor(args)
        report, args = parse_bare_flag(args, "report")
        if report
          offline, args = parse_bare_flag(args, "offline")
          options, _remaining = parse_flags(args, [:format])
          puts Reach::Sandbox.agent_text if options[:format] != "json" && Reach::Sandbox.blocked?
          data = Reach::Diagnose.report(network: !offline)
          if options[:format] == "json"
            puts JSON.pretty_generate(data)
          else
            puts Reach::Diagnose.text_lines(data)
          end
          return 0
        end
        puts Reach::Sandbox.agent_text if Reach::Sandbox.blocked?
        codex_probe
        install_chrome, _rest = parse_bare_flag(args, "install-chromium")
        if install_chrome
          if Reach::RuntimeAuto.with_lock { Reach::RuntimeKit.install!(only: "chrome") } == :busy
            warn Reach::RuntimeAuto::BUSY
            return 1
          end
        end
        problems = []
        problems.concat(check_ruby)
        problems.concat(check_shim)
        problems.concat(check_harness_detected)
        problems.concat(check_enroll)
        problems.concat(check_keys)
        problems.concat(check_guard)
        problems.concat(check_workspaces)
        problems.concat(check_chrome)
        problems.concat(check_gems)
        problems.concat(check_net)
        problems.concat(check_outbox)
        problems.concat(check_issues)
        problems.concat(check_outdated)
        problems.concat(check_wire)
        problems.concat(check_version)
        problems.concat(check_persona)
        problems.concat(check_directives)
        problems.concat(check_taste)
        problems.concat(check_sidecar)
        problems.concat(check_storage)
        codex_status = codex_doctor_status
        problems.concat(check_codex(codex_status))
        limit_lines = limits_report
        problems.concat(limit_lines.select { |line| line.start_with?("WARNING") })
        relocation_line = Reach::Relocation.doctor_line
        relocation_failed = relocation_line.start_with?("R-DOC-RELOCATION failed") && Reach::Enroll.current
        problems << "#{relocation_line.sub("R-DOC-RELOCATION ", "R-DOC-RELOCATION: ")} - clear what the reason names, then run reach relocate" if relocation_failed
        problems.each { |line| puts line }
        puts relocation_line unless relocation_failed
        enroll_line = doctor_enroll_line
        puts enroll_line if enroll_line
        puts doctor_runtime_line
        puts "R-DOC-SUBSCRIBE: #{Reach::Subscribe.doctor_line}"
        puts codex_line(codex_status)
        limit_lines.reject { |line| line.start_with?("WARNING") }.each { |line| puts line }
        problems.empty? ? 0 : 1
      end

      def codex_probe
        Reach::CodexSetup.probe! if Reach::CodexSetup.doctor_probe?
      rescue StandardError
        nil
      end

      def codex_doctor_status
        Reach::CodexSetup.status
      rescue StandardError
        nil
      end

      def check_codex(codex_status)
        codex_status ? Reach::CodexSetup.doctor_problems(codex_status) : []
      rescue StandardError
        []
      end

      def codex_line(codex_status)
        codex_status ? Reach::CodexSetup.doctor_line(codex_status) : "codex: could not be checked"
      rescue StandardError
        "codex: could not be checked"
      end

      def check_directives
        Reach::Directives.problems.map { |problem| "R-DOC-DIRECTIVES: #{problem}" }
      rescue StandardError => e
        ["R-DOC-DIRECTIVES: the public directives could not be checked (#{e.message})"]
      end

      def check_taste
        dir = File.join(Reach::Runtime.root, "skills", "design-taste-frontend")
        skill = File.join(dir, "SKILL.md")
        return ["R-DOC-TASTE: skills/design-taste-frontend/SKILL.md is missing"] unless File.file?(skill)
        return ["R-DOC-TASTE: skills/design-taste-frontend/LICENSE is missing"] unless File.file?(File.join(dir, "LICENSE"))

        text = File.read(skill)
        return ["R-DOC-TASTE: the taste skill's frontmatter does not read name: design-taste-frontend"] unless text.include?("name: design-taste-frontend")
        return ["R-DOC-TASTE: the taste skill's body does not open with the tasteskill heading"] unless text.include?("# tasteskill: Anti-Slop Frontend Skill")

        []
      rescue StandardError
        ["R-DOC-TASTE: the taste skill could not be checked"]
      end

      def limits_report
        Reach::Limits.report
      rescue StandardError
        ["R-DOC-LIMITS the local size limits could not be checked"]
      end

      def cmd_import(args)
        return cmd_export_import(args) if Reach::ExportImport::ACTIONS.include?(args.first)

        path = args.shift
        unless path
          warn "usage: reach import <path> | reach import export|pick|status|cancel|list|next|done|search|show ..."
          return 1
        end
        space = Reach::Gate.current_space
        raise Reach::Refused, Reach::Messages.text("M-GATE-OUTSIDE") unless space

        space_path = space["path"]
        if space["kind"] == "root"
          space_path = pick_slice_if_ambiguous(Reach::Gate.focus_workspace)
          raise Reach::Refused, Reach::Messages.text("M-GATE-OUTSIDE") unless space_path
        end
        result = Reach::Imports.import!(path, space_path: space_path)
        if result["ok"]
          puts Reach::Messages.text("M-IMPORT-OK", name: result["name"])
          0
        else
          warn Reach::Messages.text("M-IMPORT-REFUSED", source_name: result["source_name"], reason: result["reason"])
          1
        end
      end

      def cmd_export_import(args)
        action = args.shift
        json = args.each_cons(2).any? { |flag, value| flag == "--format" && value == "json" }
        folder, args = parse_bare_flag(args, "folder")
        options, rest = parse_flags(args, [:mode, :job, :part, :format])
        params = { "folder" => folder, "mode" => options[:mode], "job" => options[:job], "part" => options[:part] }
        case action
        when "export"
          params["path"] = rest.first
          if params["path"].to_s.empty? || options[:mode].to_s.empty?
            warn "usage: reach import export <folder-or-zip> --mode brain|copy [--format text|json]"
            return 1
          end
        when "done", "show"
          params["conversation_id"] = rest.first
        when "search"
          params["query"] = rest.join(" ")
        when "run"
          if options[:job].to_s.empty?
            warn "usage: reach import run --job ID"
            return 1
          end
        end
        result = Reach::ExportImport.perform(action, params)
        if action == "run"
          puts JSON.generate(result) if json
          return result["state"] == "failed" ? 1 : 0
        end
        puts json ? JSON.generate(result) : result["text"]
        result["state"] == "cancelled" && action == "pick" ? 1 : 0
      end

      def check_sidecar
        return [] unless Reach::Enroll.current

        Reach::Sidecar.ensure_written
        File.file?(Reach::Sidecar.path) ? [] : ["R-DOC-SEAL: the seal sidecar at #{Reach::Sidecar.path} could not be written"]
      rescue StandardError
        ["R-DOC-SEAL: the seal sidecar at #{Reach::Sidecar.path} could not be written"]
      end

      def check_ruby
        version = Gem::Version.new(RUBY_VERSION)
        ok = version >= Gem::Version.new("2.6.10") && version < Gem::Version.new("4.1.0")
        ok ? [] : ["R-DOC-RUBY: Ruby #{RUBY_VERSION} is outside 2.6.10-4.0.x - use the installer command for this platform"]
      end

      def check_shim
        shim_ok = File.file?(Reach::Runtime.shim_path) && File.file?(Reach::Runtime.shim_root_path)
        root_ok = shim_ok && File.directory?(File.read(Reach::Runtime.shim_root_path).strip) &&
                  File.file?(File.join(File.read(Reach::Runtime.shim_root_path).strip, "exe", "reach"))
        root_ok ? [] : ["R-DOC-SHIM: the reach shim is missing or broken - run reach setup"]
      rescue StandardError
        ["R-DOC-SHIM: the reach shim could not be checked - run reach setup"]
      end

      def check_harness_detected
        detected = Reach::Harness.detect
        detected.nil? || detected.empty? ? ["R-DOC-HARNESS: no supported harness version was found - update the harness or install one"] : []
      rescue StandardError
        ["R-DOC-HARNESS: harness version could not be checked - update the harness or install one"]
      end

      def check_enroll
        lock = Reach::EnrollmentLock.state
        return [] unless lock["locked"] && lock["reason"] != "not_enrolled"

        ["R-DOC-ENROLL: rEach is locked (#{lock["reason"]}): #{Reach::Messages.text(lock["message_id"])}"]
      rescue StandardError
        ["R-DOC-ENROLL: enrollment could not be checked - run reach enroll <code>"]
      end

      def doctor_enroll_line
        return nil if Reach::Enroll.current

        "enrollment: #{Reach::Messages.text("M-GATE-NOENROLL")}"
      rescue StandardError
        nil
      end

      def check_keys
        install = Reach::Enroll.current
        return [] unless install

        ok = install["signing_public_keys"] && install["encryption_key"]
        ok ? [] : ["R-DOC-KEYS: the instructors' public keys are missing or stale - run reach sync"]
      rescue StandardError
        ["R-DOC-KEYS: keys could not be checked - run reach sync"]
      end

      def check_guard
        return [] unless Reach::Enroll.current

        Reach::Guardrails.load
        []
      rescue StandardError
        ["R-DOC-GUARD: the guardrails package does not verify or is not the latest known - run reach sync"]
      end

      def check_workspaces
        Reach::Workspace.current_slices.each do |workspace_path|
          next if Reach::Workspace.verify(workspace_path)

          return ["R-DOC-WS: #{workspace_path} failed verification - run reach sync, then reach work"]
        end
        []
      rescue StandardError
        ["R-DOC-WS: workspaces could not be checked - run reach sync, then reach work"]
      end

      def check_chrome
        runtime = Reach::RuntimeKit.active
        found = (ENV["REACH_CHROME"] && File.exist?(ENV["REACH_CHROME"])) ||
                (runtime && runtime["chrome_exe"]) ||
                which_binary("google-chrome") || which_binary("chromium") || which_binary("chromium-browser") ||
                which_binary("microsoft-edge") || File.directory?(Reach::Paths.chromium_dir)
        found ? [] : [Reach::RuntimeKit.copy(:doctor_chrome)]
      rescue StandardError
        ["R-DOC-CHROME: Chrome could not be checked - run reach runtime install"]
      end

      def doctor_runtime_line
        state = Reach::RuntimeKit.status
        state["installed"] ? "runtime: #{state['runtime_id']} installed (#{state['components'].join(', ')})" : "runtime: not installed"
      rescue StandardError
        "runtime: not installed"
      end

      def which_binary(name)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
      end

      def check_gems
        slices = Reach::Workspace.current_slices
        return [] if slices.none? { |path| Reach::Workspace.metadata(path).dig("qualify", "local") }

        dir = Reach::Paths.gems_dir
        installed = File.directory?(dir) && !Dir.children(dir).empty?
        installed ? [] : ["R-DOC-GEMS: the checking tools are not installed yet - reach qualify installs them on first run"]
      rescue StandardError
        ["R-DOC-GEMS: the checking tools could not be checked - reach qualify installs them on first run"]
      end

      def check_net
        return [] if ENV["REACH_OFFLINE"] == "1"
        url = Reach::Enroll.current ? Reach::Enroll.current["teach_url"] : Reach::Runtime.default_teach_url
        Reach::Client.anonymous(url, quick: true, link: false).get("/api/v1/health")
        cached = Reach::Sync.cached_status
        if cached && cached["server_time"] && cached["fetched_at"]
          skew = (Time.parse(cached["server_time"].to_s).to_f - Time.parse(cached["fetched_at"].to_s).to_f).abs rescue nil
          return ["R-DOC-NET: the course server's clock is more than 300 s from this computer's - check both clocks"] if skew && skew > 300
        end
        []
      rescue Reach::NetworkError => e
        ["R-DOC-NET: Teach at #{url} could not be reached (#{e.detail || e.cause_name}) - check the connection or the computer's clock"]
      rescue StandardError => e
        ["R-DOC-NET: Teach at #{url} could not be reached (#{e.class.name}) - check the connection or the computer's clock"]
      end

      def check_issues
        counts = Reach::Issues.counts
        return [] if counts["queued"].to_i.zero?

        ["R-DOC-ISSUES: #{counts["queued"]} technical problem report(s) are waiting to be sent - rEach sends them by itself; stay online"]
      rescue StandardError
        []
      end

      def check_outbox
        dir = Reach::Paths.outbox_dir
        waiting = File.directory?(dir) ? Dir.children(dir).size - Reach::Issues.queued_entries.size : 0
        empty = waiting <= 0
        empty ? [] : ["R-DOC-OUTBOX: the outbox is not empty - reach submit retries automatically; stay online"]
      rescue StandardError
        ["R-DOC-OUTBOX: the outbox could not be checked - reach submit retries automatically; stay online"]
      end

      def check_outdated
        install = Reach::Enroll.current
        return [] unless install && install["minimum_reach_version"]

        outdated = Gem::Version.new(Reach::VERSION) < Gem::Version.new(install["minimum_reach_version"])
        outdated ? ["R-DOC-OUTDATED: this reach (#{Reach::VERSION}) is older than the course needs (#{install["minimum_reach_version"]}) - update reach"] : []
      rescue StandardError
        []
      end

      def check_storage
        return [] unless Reach::Storage.demanded?

        latest = Reach::Storage.last_measure
        ["R-DOC-STORAGE: rEach's memory is #{Reach::Storage.mb_text(latest['total'])} MB, at the #{Reach::Storage.config['demand_mb']} MB limit - run reach storage compact"]
      rescue StandardError
        []
      end

      def check_wire
        cached = Reach::Sync.cached_status
        return [] unless cached && cached["wire_contract_sha256"]

        cached["wire_contract_sha256"] == Reach::Wire.digest ? [] : ["R-DOC-WIRE: this reach's wire contract does not match the course server's - update reach"]
      rescue StandardError
        []
      end

      def check_version
        root = Reach::Runtime.root
        expected = Reach::VERSION
        candidates = {
          "plugin.json" => File.join(root, "plugin.json"),
          ".claude-plugin/plugin.json" => File.join(root, ".claude-plugin", "plugin.json"),
          ".codex-plugin/plugin.json" => File.join(root, ".codex-plugin", "plugin.json"),
          "reach.rplugin.yml" => File.join(root, "reach.rplugin.yml")
        }
        candidates.each do |label, path|
          next unless File.file?(path)

          value = path.end_with?(".yml") ? YAML.safe_load(File.read(path))["version"] : JSON.parse(File.read(path))["version"]
          return ["R-DOC-VERSION: #{label} version #{value} does not match VERSION #{expected}"] if value != expected
        end
        marketplace_path = File.join(root, ".claude-plugin", "marketplace.json")
        if File.file?(marketplace_path)
          data = JSON.parse(File.read(marketplace_path))
          plugin = Array(data["plugins"]).first
          version = plugin && plugin["version"]
          return ["R-DOC-VERSION: .claude-plugin/marketplace.json version #{version} does not match VERSION #{expected}"] if version && version != expected
        end
        []
      rescue StandardError
        ["R-DOC-VERSION: plugin versions could not be checked"]
      end

      def check_persona
        root = Reach::Runtime.root
        skill_path = File.join(root, "skills", "reach-assistant", "SKILL.md")
        agent_path = File.join(root, "agents", "reach.md")
        return ["R-DOC-PERSONA: skills/reach-assistant/SKILL.md or agents/reach.md is missing"] unless File.file?(skill_path) && File.file?(agent_path)

        skill_body = File.read(skill_path).sub(/\A---.*?---\n/m, "")
        agent_body = File.read(agent_path).sub(/\A---.*?---\n/m, "")
        return ["R-DOC-PERSONA: the reach-assistant skill body and the reach agent body do not match"] unless skill_body == agent_body

        greeting = Reach::Greetings.text("G-FIRST-RUN")
        missing = greeting.split("\n").reject { |line| line.empty? || skill_body.include?(line) }
        return ["R-DOC-PERSONA: the persona body does not quote the first-run greeting in full"] unless missing.empty?

        []
      rescue StandardError
        ["R-DOC-PERSONA: the persona body could not be checked"]
      end

      def cmd_lock(_args)
        vault = Reach::Paths.vault_dir
        FileUtils.rm_rf(vault)
        FileUtils.mkdir_p(vault)
        begin
          File.chmod(0o700, vault)
        rescue NotImplementedError, Errno::ENOENT
          nil
        end
        puts "Vault locked."
        0
      end

      def cmd_mcp(_args)
        Reach::CodexCache.repair
        Reach::CodexSetup.heal!
        Reach::MCPBridge.serve
        0
      end

      def cmd_hello(args)
        background, args = parse_bare_flag(args, "background")
        options, _remaining = parse_flags(args, [:harness, :format, :source, :session])
        if background
          Reach::Hello.background(session: options[:session], cwd: Dir.pwd)
          return 0
        end
        Reach::KnownIssues.record_hook!(Reach::Fingerprint.harness_label(options[:harness] || Reach::Hello.resolve_harness(nil))) if (options[:format] || "hook") == "hook"
        puts Reach::Hello.run(
          harness: options[:harness],
          source: options[:source],
          format: options[:format] || "hook",
          cwd: Dir.pwd
        )
        0
      end

      def cmd_known_issues(args)
        refresh, args = parse_bare_flag(args, "refresh")
        json = args.each_cons(2).any? { |flag, value| flag == "--format" && value == "json" }
        if refresh
          Reach::KnownIssues.fetch!(quick: true)
          return 0
        end

        Reach::KnownIssues.refresh_if_stale!(quick: true)
        issues = Reach::KnownIssues.matching
        if json
          puts JSON.generate("issues" => issues)
        elsif issues.empty?
          puts Reach::Messages.text("M-KNOWN-ISSUES-NONE")
        else
          issues.each_with_index do |issue, index|
            puts "" if index.positive?
            puts issue["detected"] ? Reach::Messages.text("M-KNOWN-ISSUE-DETECTED", title: issue["title"]) : issue["title"]
            puts "  #{issue['symptom']}"
            puts "  #{issue['steps']}" if issue["steps"]
          end
        end
        0
      end

      def cmd_codex(args)
        sub = args.first && !args.first.start_with?("--") ? args.shift : "status"
        options, _remaining = parse_flags(args, [:format, :mode])
        json = options[:format] == "json"
        case sub
        when "status"
          data = Reach::CodexSetup.status
          puts json ? JSON.pretty_generate(data) : Reach::CodexSetup.doctor_line(data)
          0
        when "probe"
          result = Reach::CodexSetup.probe!
          puts json ? JSON.pretty_generate(result) : result["text"]
          result["available"] ? 0 : 1
        when "configure"
          result = $stdin.tty? ? Reach::CodexSetup.configure_terminal(mode: options[:mode]) : Reach::CodexSetup.ask_chat(mode: options[:mode])
          puts result["text"]
          %w[applied already no_codex asked].include?(result["state"]) ? 0 : 1
        when "off"
          result = Reach::CodexSetup.withdraw!
          puts result["text"]
          result["ok"] ? 0 : 1
        when "probe-child"
          puts JSON.generate(Reach::CodexSetup.probe_child)
          0
        else
          warn "usage: reach codex status|probe [--format text|json] | configure [--mode workspace|full] | off"
          1
        end
      end

      def cmd_subscribe(args)
        sub = args.shift || "status"
        options, _remaining = parse_flags(args, [:format, :source])
        case sub
        when "status"
          data = Reach::Subscribe.status
          if options[:format] == "json"
            puts JSON.pretty_generate(data)
          else
            puts Reach::Subscribe.status_lines(data)
          end
          0
        when "tick"
          source = Reach::Subscribe::SOURCES.include?(options[:source]) ? options[:source] : "background"
          Reach::Subscribe.tick(source: source)
          0
        when "install"
          Reach::Subscribe.install!
          puts Reach::Subscribe.status_lines
          0
        when "uninstall"
          Reach::Subscribe.uninstall!
          puts Reach::Subscribe.status_lines
          0
        when "ensure"
          Reach::Subscribe.ensure!
          0
        else
          warn "reach: unknown subscribe command #{sub.inspect}"
          1
        end
      end

      def cmd_guide(args)
        path_only, args = parse_bare_flag(args, "path")
        options, _remaining = parse_flags(args, [:format])
        puts Reach::Guide.run(format: options[:format] || "text", path_only: path_only)
        0
      end

      def cmd_setup(args)
        with_runtime, args = parse_bare_flag(args, "runtime")
        options, _remaining = parse_flags(args, [:harness, :source, :format])
        output, exit_code = Reach::Setup.run(
          harness: options[:harness] || "auto",
          source: options[:source],
          format: options[:format] || "text",
          runtime: with_runtime
        )
        puts output
        exit_code
      end

      def cmd_relocate(args)
        options, remaining = parse_flags(args, [:format])
        unless remaining.empty?
          warn "usage: reach relocate [--format text|json]"
          return 2
        end
        result = Reach::Relocation.run(trigger: "cli")
        if (options[:format] || "text") == "json"
          puts JSON.generate(result.each_with_object({}) { |(key, value), table| table[key.to_s] = value })
        else
          puts result[:line]
        end
        result[:phase] == "failed" ? 1 : 0
      end

      def cmd_runtime(args)
        sub = args.shift
        case sub
        when "install"
          _yes, args = parse_bare_flag(args, "yes")
          auto, args = parse_bare_flag(args, "auto")
          return Reach::RuntimeAuto.run if auto

          options, _remaining = parse_flags(args, [:only, :from])
          if Reach::RuntimeAuto.with_lock { Reach::RuntimeKit.install!(only: options[:only], from: options[:from]) } == :busy
            warn Reach::RuntimeAuto::BUSY
            return 1
          end
          0
        when "status"
          json, _rest = parse_bare_flag(args, "json")
          state = Reach::RuntimeKit.status
          puts(json ? JSON.pretty_generate(state) : Reach::RuntimeKit.status_lines(state))
          0
        when "remove"
          yes, args = parse_bare_flag(args, "yes")
          old_only, _rest = parse_bare_flag(args, "old")
          unless yes
            warn "reach: runtime remove deletes the installed runtime; run it again with --yes"
            return 1
          end
          removed = Reach::RuntimeKit.remove!(old_only: old_only)
          puts(removed.empty? ? "nothing to remove" : removed.map { |dir| "removed #{dir}" })
          0
        else
          warn "usage: reach runtime install [--only ruby|chrome] [--from DIR] [--yes] | status [--json] | remove --yes [--old]"
          1
        end
      end

      def cmd_update(args)
        sub = args.shift || "status"
        apply, args = parse_bare_flag(args, "apply")
        background, args = parse_bare_flag(args, "background")
        force, args = parse_bare_flag(args, "force")
        scheduled, args = parse_bare_flag(args, "scheduled")
        options, _remaining = parse_flags(args, [:format])
        json = options[:format] == "json"
        case sub
        when "status"
          if json
            puts JSON.pretty_generate(Reach::Update.load_manifest)
          else
            puts Reach::Update.status_lines
          end
          0
        when "check"
          if Reach::Sandbox.blocked?
            warn Reach::Sandbox.agent_text
            return 1
          end
          result = Reach::Update.with_lock { Reach::Update.check(Reach::Update.load_manifest) }
          if result == :locked
            puts "reach: an update is already running"
            return 0
          end
          if json
            puts JSON.pretty_generate(result)
          else
            versions = Array(result["remote_versions"]).map { |entry| entry["version"] }
            puts "source: #{result['source']}"
            puts "local version: #{result['local_version']}"
            puts "remote versions: #{versions.empty? ? 'none newer' : versions.join(', ')}"
            puts "last error: #{result['last_error']}" if result["last_error"].to_s != ""
          end
          0
        when "run"
          if background
            Reach::Update.spawn_background(apply: apply)
            return 0
          end
          if Reach::Sandbox.blocked?
            warn Reach::Sandbox.agent_text
            return 1
          end
          result = Reach::Update.run(apply: apply, force: force || STDIN.tty?, check: !scheduled)
          if json
            puts JSON.pretty_generate(result)
          elsif result["skipped"]
            puts "update skipped: #{result['skipped']}"
          elsif result["held"]
            puts "update held: #{result['held']}"
          elsif result["error"]
            puts "update error: #{result['error']}"
          else
            puts "update phase: #{result['phase']} (local #{result['local']}, target #{result['target'] || 'none'})"
          end
          0
        else
          warn "usage: reach update status|check|run [--apply] [--background] [--force] [--format text|json]"
          2
        end
      end

      def cmd_profile(args)
        sub = args.shift
        case sub
        when "show"
          options, _remaining = parse_flags(args, [:format])
          profile = Reach::Profile.load
          if (options[:format] || "text") == "json"
            puts JSON.generate(profile)
          elsif profile["fields"].nil? || profile["fields"].empty?
            puts "No profile yet."
          else
            profile["fields"].each { |key, value| puts "#{key}: #{value}" }
            puts "Status: #{profile["status"]}"
          end
          0
        when "save"
          options, remaining = parse_flags(args, [:status])
          fields = {}
          index = 0
          while index < remaining.length
            token = remaining[index]
            if token.start_with?("--")
              fields[token[2..-1].tr("-", "_")] = remaining[index + 1]
              index += 2
              next
            end
            index += 1
          end
          Reach::Profile.save(fields: fields, status: options[:status] || "partial")
          puts "Saved."
          0
        when "forget"
          Reach::Profile.forget!
          puts "Your profile is deleted."
          puts Reach::Messages.text("M-XC-FORGET-NOTE")
          0
        else
          warn "usage: reach profile show|save|forget"
          1
        end
      end

      def cmd_remember(args)
        options, _remaining = parse_flags(args, [:category, :claim, :evidence, :supersedes, :origin, :format])
        if options[:category].to_s.empty? || options[:claim].to_s.empty? || options[:evidence].to_s.empty?
          warn "usage: reach remember --category C --claim TEXT --evidence TEXT [--supersedes ID] [--origin import:JOB/CONVERSATION] [--format text|json]"
          return 1
        end

        result = Reach::Brain.remember(
          category: options[:category], claim: options[:claim], evidence: options[:evidence], supersedes: options[:supersedes], origin: options[:origin]
        )
        message = Reach::Brain.outcome_message(result)
        if options[:format].to_s == "json"
          puts JSON.generate(result.merge("message" => message))
        else
          puts message
        end
        0
      end

      def cmd_memory(args)
        sub = args.first && !args.first.start_with?("--") ? args.shift : "list"
        json = args.each_cons(2).any? { |flag, value| flag == "--format" && value == "json" }
        case sub
        when "list"
          options, _remaining = parse_flags(args, [:category, :limit, :format])
          rows = Reach::Brain.list(category: options[:category], limit: options[:limit] || 50)
          if json
            puts JSON.generate(rows)
          elsif rows.empty?
            puts Reach::Messages.text("M-BRAIN-EMPTY")
          else
            rows.each { |row| puts "#{row['id']}  [#{row['category']}] #{row['claim']}" }
          end
          0
        when "show"
          id = args.shift
          unless id
            warn "usage: reach memory show ID [--format text|json]"
            return 1
          end
          row = Reach::Brain.show(id)
          if json
            puts JSON.generate(row)
          else
            puts "#{row['id']}  [#{row['category']}] #{row['claim']}"
            puts "evidence: #{row['evidence']}"
            puts "noted: #{row['at']}"
          end
          0
        when "forget"
          everything, args = parse_bare_flag(args, "all")
          confirmed, args = parse_bare_flag(args, "yes")
          _options, ids = parse_flags(args, [:format])
          if everything
            unless confirmed
              warn "usage: reach memory forget --all --yes"
              return 1
            end
            count = Reach::Brain.forget(all: true)
          elsif ids.empty?
            warn "usage: reach memory forget ID... | forget --all --yes"
            return 1
          else
            count = Reach::Brain.forget(ids: ids)
          end
          message = Reach::Messages.text("M-BRAIN-FORGOTTEN", count: count)
          json ? puts(JSON.generate("forgotten" => count, "message" => message)) : puts(message)
          0
        when "export"
          puts Reach::Brain.export
          0
        else
          warn "usage: reach memory [list [--category C] [--limit N] | show ID | forget ID... | forget --all --yes | export] [--format text|json]"
          1
        end
      end

      def cmd_storage(args)
        sub = args.first && !args.first.start_with?("--") ? args.shift : "status"
        json = args.each_cons(2).any? { |flag, value| flag == "--format" && value == "json" }
        worker, args = parse_bare_flag(args, "run")
        case sub
        when "status"
          info = Reach::Storage.status
          puts json ? JSON.generate(info) : Reach::Storage.status_text(info)
          0
        when "measure"
          result = Reach::Storage.measure!
          if result == :busy
            puts json ? JSON.generate("state" => "busy") : "storage: a measure is already running"
          else
            puts json ? JSON.generate(result) : "storage: #{Reach::Storage.mb_text(result['total'])} MB measured"
          end
          0
        when "compact"
          if worker
            result = Reach::Storage.run_compact
            puts JSON.generate(result) if json
            return result["state"] == "failed" ? 1 : 0
          end

          result = Reach::Storage.compact
          puts json ? JSON.generate(result) : result["text"]
          0
        else
          warn "usage: reach storage [status | measure | compact] [--format text|json]"
          1
        end
      end

      def cmd_attempts(args)
        sub = args.shift
        options, _remaining = parse_flags(args, [:slice])
        case sub
        when "settle"
          puts JSON.generate([])
          0
        when "show", "continue"
          workspace = workspace_or_fail(options[:slice])
          return 1 unless workspace

          if sub == "show"
            puts JSON.generate(Reach::Attempts.show(workspace))
          else
            puts Reach::Attempts.continue(workspace)
          end
          0
        else
          warn "usage: reach attempts show|continue [--slice <id>]"
          1
        end
      end

      def workspace_or_fail(slice_hint, target: nil)
        workspace_path = resolve_workspace(slice_hint)
        workspace_path ||= Reach::Gate.focus_workspace(target: target)
        pick_slice_if_ambiguous(workspace_path)
        warn Reach::Messages.text("M-GATE-NOGUARD") unless workspace_path
        workspace_path
      end

      def cmd_check(args)
        options, _remaining = parse_flags(args, [:changed, :format, :slice])
        event = read_stdin_json
        if options[:format].to_s == "hermes" || hermes_hook?(nil, event)
          event = normalize_hermes_event(event)
          return 0 unless event

          return check_hermes(event)
        end
        tool_input = event["tool_input"] || {}
        hook_target = tool_input["file_path"] || tool_input["path"] || tool_input["notebook_path"]
        changed = options[:changed] || hook_target
        if hook_target && options[:slice].nil? && Reach::Gate.root_kind?
          found = Reach::Workspace.space_for_target(File.expand_path(hook_target.to_s))
          return 0 unless found && found["kind"] == "slice"
        end
        workspace_path = workspace_or_fail(options[:slice], target: hook_target)
        return 1 unless workspace_path

        format = (options[:format] || "text").to_sym
        findings = Reach::Check.run(workspace_path, changed: changed, format: format)
        if format == :text
          puts findings
          findings == Reach::Messages.text("M-CHECK-CLEAN") ? 0 : 1
        else
          puts JSON.generate(findings)
          findings.empty? ? 0 : 1
        end
      end

      def cmd_checkpoint(args)
        sub = args.shift
        options, remaining = parse_flags(args, [:note, :slice])
        workspace_path = workspace_or_fail(options[:slice])
        return 1 unless workspace_path

        case sub
        when "save"
          result = Reach::Checkpoint.save(workspace_path, note: options[:note] || remaining.first)
          puts result["message"]
          0
        when "list"
          entries = Reach::Checkpoint.list(workspace_path)
          if entries.empty?
            puts Reach::Messages.text("M-CHECKPOINT-NONE")
          else
            previous = nil
            entries.each do |entry|
              changed = Reach::Checkpoint.changed_count(entry, previous)
              note = entry["note"].to_s.empty? ? (entry["automatic"] ? "(automatic)" : "") : entry["note"]
              shown_at = Reach::Messages.respond_to?(:course_time) ? Reach::Messages.course_time(entry["at"]) : entry["at"]
              puts "#{entry['n']}  #{shown_at}  #{note}  #{changed} file(s) changed"
              previous = entry
            end
          end
          0
        when "show"
          entry = Reach::Checkpoint.show(workspace_path, remaining.first)
          if entry
            puts JSON.generate(entry)
            0
          else
            warn Reach::Messages.text("M-CHECKPOINT-UNKNOWN", n: remaining.first)
            1
          end
        when "restore"
          result = Reach::Checkpoint.restore(workspace_path, remaining.first)
          puts result["message"]
          0
        else
          warn "usage: reach checkpoint save [--note <text>] | list | show <n> | restore <n>"
          1
        end
      end

      def cmd_plan(args)
        sub = args.shift
        options, remaining = parse_flags(args, [:slice, :format])
        workspace_path = workspace_or_fail(options[:slice])
        return 1 unless workspace_path

        case sub
        when "save", "note"
          fields = {}
          index = 0
          while index < remaining.length
            token = remaining[index]
            if token.start_with?("--")
              fields[token[2..-1].tr("-", "_")] = remaining[index + 1]
              index += 2
              next
            end
            index += 1
          end
          Reach::Plan.save(workspace_path, fields)
          puts Reach::Messages.text("M-PLAN-SAVED")
          0
        when "show"
          if (options[:format] || "text") == "json"
            puts JSON.generate(Reach::Plan.load(workspace_path) || {})
          else
            puts Reach::Plan.render(workspace_path)
          end
          0
        else
          warn "usage: reach plan save --behaviour <text> [--input ...] [--output ...] [--steps a|b|c] [--edge-cases a|b] [--scenarios a|b] [--evidence ...] | note --progress <text> --next <text> | show [--format json]"
          1
        end
      end

      def cmd_part(args)
        if args.first == "record"
          args.shift
          question_id = args.shift
          unless question_id
            warn "usage: reach part record <question id>"
            return 1
          end
          workspace = Reach::Gate.focus_workspace
          pick_slice_if_ambiguous(workspace)
          unless workspace
            warn "reach: no matching slice workspace found; run reach sync"
            return 1
          end
          answer = Reach::Part.record!(question_id, workspace: workspace)
          question = Reach::Part.questions(Reach::Workspace.metadata(workspace)["assignment"]).find { |item| item["id"] == answer["question_id"] }
          puts Reach::Messages.text("M-PART-RECORDED", question: question ? question["question"] : answer["question_id"])
          return 0
        end

        format, args = parse_flags(args, [:format, :slice])
        workspace = resolve_workspace(format[:slice]) || Reach::Gate.focus_workspace
        assignment = workspace ? Reach::Workspace.metadata(workspace)["assignment"] : nil
        status = Reach::Sync.cached_status || {}
        assignment ||= status["current_assignment"].is_a?(Hash) ? status["current_assignment"]["id"] : nil
        rows = assignment ? Reach::Part.status(assignment) : []
        if (format[:format] || "text") == "json"
          answers = assignment ? Reach::Part.document(assignment)["answers"] : []
          questions = rows.map do |row|
            answer = answers.find { |item| item["question_id"] == row["id"] }
            row.merge("text" => answer && answer["text"])
          end
          puts JSON.generate("assignment" => assignment, "questions" => questions)
        elsif rows.empty?
          puts Reach::Messages.text("M-PART-LIST-EMPTY")
        else
          rows.each { |row| puts "#{row['id']}  #{row['answered'] ? 'answered' : 'not answered yet'}  #{row['question']}" }
        end
        0
      end

      def cmd_next(args)
        options, _remaining = parse_flags(args, [:format])
        step = Reach::Next.compute
        if (options[:format] || "text") == "json"
          puts JSON.generate(step)
        else
          puts step["text"]
        end
        0
      end

      def cmd_issues(args)
        sub = args.shift || "list"
        case sub
        when "flush"
          background, _rest = parse_bare_flag(args, "background")
          result = Reach::Issues.flush!(quick: background ? true : false, force: !background)
          puts Reach::Messages.text("M-ISSUES-FLUSHED", sent: result["sent"], queued: result["queued"]) unless background
          0
        when "list"
          unless Reach::Persona.active? || Reach::Debug.on?
            puts Reach::Messages.text("M-ISSUES-NONE-FOR-YOU")
            return 0
          end
          rows = Reach::Issues.list
          if rows.empty?
            puts Reach::Messages.text("M-ISSUES-EMPTY")
            return 0
          end
          rows.sort_by { |row| row["last_at"].to_s }.reverse_each do |row|
            state = row["reported"] ? "reported" : (row["queued"] || row["waiting"] ? "waiting" : "seen")
            puts [row["signature"], row["count"], row["first_at"], row["last_at"], row["blocking"] ? "blocking" : "repeating", state, row["fix_version"]].compact.join("  ")
          end
          0
        else
          warn "usage: reach issues [list | flush [--background]]"
          1
        end
      end

      def cmd_live(args)
        sub = args.shift || "status"
        case sub
        when "run"
          Reach::Live.run!
        when "watch"
          Reach::Live.watch!
        when "status"
          puts Reach::Live.status["message"]
          0
        when "request"
          options, _rest = parse_flags(args, [:hand])
          puts Reach::Live.ask!(hand_id: options[:hand])["message"]
          0
        when "note", "say"
          puts Reach::Live.send!(sub == "say" ? "agent" : "note", args.join(" "))["message"]
          0
        when "wait"
          result = Reach::Live.wait
          result["messages"].each { |row| puts "#{row['from']}: #{row['text']}" }
          puts result["message"]
          0
        when "end"
          puts Reach::Live.end!["message"]
          0
        else
          warn "usage: reach live [status | request [--hand ID] | wait | note TEXT | say TEXT | end]"
          1
        end
      end

      def cmd_support(args)
        if args.include?("--flush")
          Reach::Support.flush_queued!(quick: true)
          return 0
        end

        Reach::Support.run!
        0
      end

      def cmd_hook(args)
        sub = args.shift
        unless sub == "stop"
          warn "usage: reach hook stop [--final] --harness H"
          return 1
        end
        options, remaining = parse_flags(args, [:harness])
        final, _remaining = parse_bare_flag(remaining, "final")
        Reach::KnownIssues.record_hook!(Reach::Fingerprint.harness_label(options[:harness]))
        event = read_stdin_json
        if hermes_hook?(options[:harness], event)
          event = normalize_hermes_event(event)
          return 0 unless event

          options = options.merge(harness: "hermes")
        end
        Reach::Debug.begin_hook(event, options[:harness])
        started = Reach::Debug.clock
        Reach::Debug.hook(final ? "SessionEnd" : "Stop", "allow", nil, started)
        shown = final ? nil : Reach::Debug.turn_message(event, options[:harness])
        Reach::Debug.flush(quick: true)
        Reach::Issues.spawn_flush if Reach::Issues.work?
        notice = hermes_hook?(options[:harness], event) ? nil : [Reach::Link.notice!, Reach::Issues.notice!].compact.join("\n\n")
        notice = nil if notice && notice.empty?
        message = [notice, shown].compact.join("\n\n")
        puts JSON.generate("systemMessage" => message) unless message.empty?
        0
      end

      def cmd_transcript(args)
        sub = args.shift
        return 0 unless sub == "turn"

        final, remaining = parse_bare_flag(args, "final")
        _quick, remaining = parse_bare_flag(remaining, "quick")
        cmd_hook(["stop"] + remaining + (final ? ["--final"] : []))
      end

      def cmd_modules(args)
        if args.first == "--flush"
          Reach::Modules.flush_pending!
          return 0
        end

        if args.first == "choose"
          args.shift
          chosen = args.reject { |token| token.start_with?("--") }.flat_map { |token| token.split(",") }.map(&:strip).reject(&:empty?)
          return print_choice_result(Reach::Modules.choose!(chosen))
        end

        options, _remaining = parse_flags(args, [:format])
        if options[:format].to_s == "json"
          response = begin
            Reach::Modules.refresh!(quick: true)
          rescue Reach::NetworkError, Reach::RemoteRefused
            nil
          end
          puts JSON.generate(response || Reach::Modules.current || {})
          return 0
        end
        puts Reach::Modules.summary_text
        0
      end

      def cmd_transfer(args)
        sub = args.shift
        case sub
        when "--flush"
          Reach::Transfer.flush_queued!
          0
        when "request"
          options, _remaining = parse_flags(args, [:modules, :note])
          wanted = options[:modules].to_s.split(",").map(&:strip).reject(&:empty?)
          if wanted.empty?
            warn "usage: reach transfer request --modules a,b [--note "..."]"
            return 1
          end
          print_choice_result(Reach::Transfer.request!(modules: wanted, note: options[:note]))
        when "status"
          answer = Reach::Transfer.poll!
          if answer
            puts answer
            Reach::Transfer.mark_announced!
          else
            puts(Reach::Transfer.status_text || Reach::Modules.summary_text)
          end
          0
        else
          warn "usage: reach transfer request --modules a,b [--note <text>] | status"
          1
        end
      end

      def print_choice_result(result)
        case result["state"]
        when "asked"
          puts result["text"]
          3
        when "locked", "queued", "sent"
          puts result["text"]
          0
        else
          warn result["text"]
          1
        end
      end

      def cmd_login(args)
        sub = args.shift
        unless sub == "status"
          warn "usage: reach login status"
          return 1
        end
        latest = Reach::Login.last_session_state
        recent = latest && Reach::Login.session_confirmed?(latest["session_id"])
        puts "Most recent session: #{recent ? 'signed in' : 'not signed in'}"
        puts "Any active sign-in: #{Reach::Login.any_active? ? 'yes' : 'no'}"
        0
      end

      def cmd_reference(args)
        verb = args.shift
        case verb
        when "list"
          puts Reach::Reference.list
        when "show"
          path = args.shift
          raise Reach::Refused, Reach::Messages.text("M-REFERENCE-UNKNOWN", path: path.to_s) if path.nil?

          text = Reach::Reference.show(path)
          puts text
        when "search"
          puts Reach::Reference.format_search(Reach::Reference.search(args))
        when "links"
          puts Reach::Reference.links
        when "ingest"
          force, _rest = parse_bare_flag(args, "force")
          report = Reach::CourseCorpus.ingest(force: force)
          puts Reach::Messages.text("M-COURSE-INGESTED", state: report["state"], courses: report["courses"], files: report["files"], sources: report["sources"], tombstoned: report["tombstoned"])
          return %w[disabled failed].include?(report["state"]) ? 1 : 0
        else
          warn "usage: reach reference list | show <path> | search <words> | links | ingest [--force]"
          return 1
        end
        0
      end

      def cmd_directive(args)
        listing, remaining = parse_bare_flag(args, "list")
        options, remaining = parse_flags(remaining, [:format])
        if listing
          Reach::Directives.rows.each { |row| puts Reach::Directives.render_row(row) }
          return 0
        end
        opcode = remaining.first
        unless opcode
          warn "usage: reach directive <OPCODE> [--format text|json] | --list"
          return 1
        end
        result = Reach::Directives.show(opcode, workspace: Reach::Gate.focus_workspace)
        if (options[:format] || "text") == "json"
          puts JSON.generate(result)
        else
          puts result["body"]
        end
        0
      end

      def current_workspace_basename
        cwd = File.realpath(Dir.pwd)
        workspace_path = Reach::Workspace.current_slices.find do |workspace|
          real_workspace = File.realpath(workspace)
          cwd == real_workspace || cwd.start_with?(real_workspace + File::SEPARATOR)
        end
        return nil unless workspace_path

        File.basename(workspace_path)
      rescue StandardError
        nil
      end
    end
  end
end
