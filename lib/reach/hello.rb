require "json"
require "fileutils"
require "timeout"

module Reach
  module Hello
    CONTEXT_KEEP = 20
    BACKGROUND_LIMIT_S = 300
    MINIMAL_CONTEXT = "rEach session context (from reach hello)\n" \
                       "- You are rEach, the student's academic assistant. Load the reach-assistant skill.".freeze

    module_function

    def run(harness: nil, source: nil, format: "hook", cwd: Dir.pwd, mcp: false)
      Reach::Runtime.ensure_shim!

      event = {}
      if !STDIN.tty? && format.to_s == "hook"
        event = read_stdin_json
        Reach::KnownIssues.session_started!(Reach::Fingerprint.harness_label(harness || resolve_harness(nil)), event["source"])
        source = event["source"] if source.nil?
        cwd = event["cwd"] if event["cwd"]
      end

      observe_home_env
      if Reach::Relocation.due?
        Reach::Relocation.start
      else
        Reach::RuntimeAuto.start
      end
      hookless = hookless?(harness, format, mcp)
      harness_id = resolve_harness(harness == "antigravity" ? nil : harness)
      Reach::Debug.begin_hook(event, harness_id)
      Reach::Debug.session(harness_id, source)
      Reach::KnownIssues.refresh_if_stale!(quick: true) if mcp
      greeting_id, greeting_text, banner, context = session_parts(harness_id, format, source, cwd, event, local: format.to_s == "hook", mcp: mcp, hookless: hookless)

      emit(format, context, banner, greeting_id, greeting_text)
    rescue StandardError
      emit(format, MINIMAL_CONTEXT, nil, nil, nil)
    end

    def observe_home_env
      return nil unless Reach::Paths.windows_host?

      env_home = ENV["HOME"].to_s
      return nil if env_home.empty?

      mine = Reach::Paths.realish(Reach::Paths.user_home)
      theirs = Reach::Paths.realish(Reach::Paths.windows_slashes(env_home))
      return nil if theirs.casecmp(mine).zero?

      profile = Reach::Paths.windows_slashes(ENV["USERPROFILE"])
      differs = !profile.empty? && Reach::Paths.realish(profile).casecmp(mine) != 0
      fields = {
        "where" => "paths.user_home", "exception" => nil, "errno" => nil, "message_id" => nil, "cause" => "home_env_mismatch",
        "frames" => [], "shown" => nil
      }
      Reach::Debug.emit_always(
        "fault",
        fields.merge(
          "fault_id" => Reach::Issues.signature(fields), "home_source" => Reach::Paths.user_home_source.to_s,
          "userprofile_differs" => differs, "stray" => Reach::Paths.stray_active?
        )
      )
      nil
    rescue StandardError
      nil
    end

    def context_text(harness:, cwd:, source: "startup", event: nil, session: nil)
      harness_id = resolve_harness(harness)
      session_parts(harness_id, "text", source, cwd, event, local: true, session: session).last
    rescue StandardError
      MINIMAL_CONTEXT
    end

    def background(session: nil, cwd: Dir.pwd)
      Reach::Locks.bound!
      ensure_hello_dir
      Reach::Locks.exclusive(background_lock_path, wait_s: 0) do
        Timeout.timeout(BACKGROUND_LIMIT_S) { run_background(session, cwd) }
      end
      nil
    rescue StandardError
      nil
    end

    def run_background(session, cwd)
      return nil if Reach::EnrollmentLock.state["locked"]

      maybe_refresh_status
      Reach::Subscribe.ensure!
      workspace = find_workspace(cwd)
      Reach::Locks.refill!
      safe_late_retry
      Reach::Locks.refill!
      Reach::CourseCorpus.ingest_if_changed(admit: false)
      Reach::Locks.refill!
      storage = Reach::Locks.free?(Reach::Paths.storage_lock_file("state")) ? safe_storage_context : nil
      Reach::Locks.refill!
      store_context(session, refreshed_context(workspace, storage))
      nil
    rescue StandardError
      nil
    end

    def refreshed_context(workspace, storage)
      lines = ["rEach session context, refreshed in the background (the student needs no new greeting)"]
      lines << course_line
      late = safe_late_line(workspace)
      lines << late if late
      lines << "- #{storage}" if storage
      lines.join("\n")
    end

    def hello_dir
      File.join(Reach::Paths.state_dir, "hello")
    end

    def ensure_hello_dir
      FileUtils.mkdir_p(hello_dir)
      File.chmod(0o700, hello_dir)
    rescue NotImplementedError, Errno::ENOENT, Errno::EPERM
      nil
    end

    def context_path
      File.join(hello_dir, "context.json")
    end

    def background_lock_path
      File.join(hello_dir, "background.lock")
    end

    def spawn_background(session)
      return nil unless defined?(Reach::Storage)

      ensure_hello_dir
      return nil unless Reach::Locks.free?(background_lock_path)

      Reach::Storage.spawn_detached(["hello", "--background", "--session", session.to_s])
    rescue StandardError
      nil
    end

    def read_context_store
      return { "sessions" => {}, "order" => [] } unless File.file?(context_path)

      data = JSON.parse(File.read(context_path))
      data = {} unless data.is_a?(Hash)
      data["sessions"] = {} unless data["sessions"].is_a?(Hash)
      data["order"] = [] unless data["order"].is_a?(Array)
      data
    rescue StandardError
      { "sessions" => {}, "order" => [] }
    end

    def write_context_store(data)
      ensure_hello_dir
      tmp = "#{context_path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      File.rename(tmp, context_path)
    end

    def store_context(session, text)
      return nil if session.to_s.empty? || text.to_s.empty?

      ensure_hello_dir
      Reach::Locks.exclusive("#{context_path}.lock") do
        data = read_context_store
        sessions = data["sessions"]
        key = session.to_s
        sessions[key] = { "text" => text, "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
        order = data["order"] - [key] + [key]
        while order.length > CONTEXT_KEEP
          sessions.delete(order.shift)
        end
        write_context_store("sessions" => sessions, "order" => order)
      end
      nil
    end

    def stored_context(session)
      return nil if session.to_s.empty?

      entry = read_context_store["sessions"][session.to_s]
      text = entry.is_a?(Hash) ? entry["text"].to_s : ""
      text.empty? ? nil : text
    rescue StandardError
      nil
    end

    def clear_stored_context(session)
      return nil if session.to_s.empty?

      Reach::Locks.exclusive("#{context_path}.lock") do
        data = read_context_store
        next unless data["sessions"].key?(session.to_s)

        data["sessions"].delete(session.to_s)
        data["order"] -= [session.to_s]
        write_context_store(data)
      end
      nil
    rescue StandardError
      nil
    end

    def session_parts(harness_id, format, source, cwd, event = nil, local: false, session: nil, mcp: false, hookless: false)
      lock = Reach::EnrollmentLock.state
      if lock["locked"]
        if hookless && lock["reason"] != "course_ended"
          message = Reach::Messages.text("M-ENR-NOHOOK-STUDENT")
          return [nil, message, message, hookless_context(mcp: mcp)]
        end
        message = Reach::EnrollFlow.next_message(lock)
        safe_transcript_export
        return [nil, message, message, locked_context(format, mcp: mcp)]
      end

      maybe_refresh_status unless local
      workspace = find_workspace(cwd)
      configure_workspace(workspace)
      safe_late_retry unless local
      safe_transcript_export unless local
      spawn_background(session || Reach::Session.resolve_session_id(event)) if local

      session_id = event.is_a?(Hash) && !event["session_id"].to_s.empty? ? Reach::Session.resolve_session_id(event) : nil

      if login_pending?(event)
        updating = safe_update_start(session_id, source)
        greeting_text = [nil, "startup", "clear"].include?(source) ? Reach::Greetings.text("G-LOGIN") : nil
        return [greeting_text && "G-LOGIN", greeting_text, nil, login_context(updating, mcp: mcp)]
      end

      greeting_id, greeting_text, banner = choose_greeting(source)
      updating = safe_update_start(session_id, source)
      if updating && greeting_text
        greeting_text = "#{Reach::Greetings.text("G-UPDATING", version: updating)}\n\n#{greeting_text}"
      end
      if greeting_text && safe_memory_notice_due?
        greeting_text = "#{greeting_text}\n\n#{Reach::Greetings.text("G-MEMORY-NOTICE")}"
        Reach::Brain.memory_notice_shown!
      end
      Reach::CourseCorpus.ingest_if_changed(admit: false) unless local
      context = build_context(harness_id, format, greeting_id, greeting_text, updating, workspace: workspace, local: local, mcp: mcp)
      [greeting_id, greeting_text, banner, context]
    end

    def safe_transcript_export
      Reach::TranscriptExport.spawn_auto_if_due
      nil
    rescue StandardError
      nil
    end

    def safe_late_retry
      Reach::LateWork.session_start
    rescue StandardError
      nil
    end

    def safe_late_line(workspace)
      workspace ? Reach::LateWork.hello_line(workspace) : nil
    rescue StandardError
      nil
    end

    def safe_memory_notice_due?
      Reach::Brain.memory_notice_due?
    rescue StandardError
      false
    end

    def safe_storage_context
      Reach::ExportImport.session_start
      Reach::Storage.session_start
    rescue StandardError
      nil
    end

    def safe_session_context
      Reach::Brain.session_context
    rescue StandardError
      nil
    end

    def known_issue_lines(mcp)
      Reach::KnownIssues.context_lines(mcp: mcp).map { |line| "- #{line}" }
    rescue StandardError
      []
    end

    def hookless?(harness, format, mcp)
      return false if format.to_s == "hook" || mcp
      return true if harness == "antigravity"

      resolve_harness(harness) == "unknown" && Reach::KnownIssues.harness.nil?
    rescue StandardError
      false
    end

    def terminal_command(*args)
      command = Reach::Runtime.hook_command(*args)
      Reach::Runtime.windows? ? "& #{command}" : command
    end

    def hookless_context(mcp: false)
      guide = Reach::Messages.text("M-ENR-AGENT-NOHOOK-GUIDE", command: Reach::Runtime.hook_command("guide"), enroll_command: terminal_command("enroll"))
      ["#{Reach::Messages.text("M-ENR-AGENT-NOHOOK-CONTEXT")}\n#{guide}\n#{Reach::Messages.text("M-AGENT-TALK")}", *known_issue_lines(mcp)].join("\n")
    end

    def locked_context(format = "hook", mcp: false)
      guide = Reach::Messages.text("M-ENR-AGENT-GUIDE", command: Reach::Runtime.hook_command("guide"), enroll_command: terminal_command("enroll"))
      text = ["#{Reach::Messages.text("M-ENR-AGENT-CONTEXT")}\n#{guide}\n#{Reach::Messages.text("M-AGENT-TALK")}", *known_issue_lines(mcp)].join("\n")
      return text if format.to_s == "hook" || !Reach::CodexCache.repaired?

      "#{text}\n#{Reach::Messages.text("M-ENR-AGENT-CODEX-REPAIRED")}"
    end

    def login_pending?(event)
      return false unless safe_enrol_current
      return false unless Reach::Login.required?

      if event.is_a?(Hash) && event["session_id"]
        !Reach::Login.session_confirmed?(Reach::Login.session_id(event))
      else
        !Reach::Login.any_active?
      end
    rescue StandardError
      false
    end

    def login_context(updating = nil, mcp: false)
      needed = mcp && Reach::KnownIssues.signin_hook_dead? ? "M-LOGIN-NEEDED-NO-HOOK" : "M-LOGIN-NEEDED"
      text = ["#{MINIMAL_CONTEXT}\n- #{Reach::Messages.text(needed)}\n- #{Reach::Messages.text('M-AGENT-TALK')}", *known_issue_lines(mcp)].join("\n")
      updating ? "#{text}\n#{update_line(updating)}" : text
    end

    def update_line(version)
      "- rEach is installing an update (version #{version}) in the background. Course work waits until it finishes; tell the student it is required and their work is safe."
    end

    def safe_update_start(session_id, source)
      return nil unless [nil, "startup", "clear"].include?(source)

      Reach::Update.on_session_start(session_id)
    rescue StandardError
      nil
    end

    def read_stdin_json
      data = STDIN.read
      return {} if data.nil? || data.strip.empty?

      JSON.parse(data)
    rescue StandardError
      {}
    end

    def resolve_harness(harness)
      return harness if harness

      if ENV["PLUGIN_ROOT"] && !ENV["CLAUDE_PROJECT_DIR"]
        "codex"
      elsif ENV["CLAUDE_PLUGIN_ROOT"] || ENV["CLAUDE_PROJECT_DIR"]
        "claude-code"
      elsif ENV["HERMES_HOME"].to_s != ""
        "hermes"
      else
        "unknown"
      end
    end

    def maybe_refresh_status
      return unless defined?(Reach::Enroll) && defined?(Reach::Sync)
      return unless Reach::Enroll.current
      return if ENV["REACH_OFFLINE"] == "1"

      age = Reach::Sync.status_age_s
      return unless age.nil? || age > 21_600

      Reach::Sync.refresh_status(quick: true)
    rescue StandardError
      nil
    end

    def find_workspace(cwd)
      return nil unless defined?(Reach::Workspace) && cwd

      real_cwd = File.realpath(cwd)
      Reach::Workspace.current_slices.find do |workspace_path|
        real_workspace = File.realpath(workspace_path)
        real_cwd == real_workspace || real_cwd.start_with?(real_workspace + File::SEPARATOR)
      end
    rescue StandardError
      nil
    end

    def in_course_folder?(cwd)
      return false unless defined?(Reach::Workspace) && cwd

      !Reach::Workspace.space_for(cwd).nil?
    rescue StandardError
      false
    end

    def configure_workspace(workspace)
      return unless defined?(Reach::Harness) && workspace

      Reach::Harness.configure_all(workspace)
    rescue StandardError
      nil
    end

    def choose_greeting(source)
      return [nil, nil, nil] unless [nil, "startup", "clear"].include?(source)

      profile = Reach::Profile.load
      status = profile["status"]

      if status == "not_started"
        [
          "G-FIRST-RUN",
          Reach::Greetings.text("G-FIRST-RUN"),
          Reach::Greetings.text("G-BANNER-FIRST")
        ]
      elsif status == "partial"
        name = Reach::Profile.preferred_name
        if name
          ["G-RESUME", Reach::Greetings.text("G-RESUME", name: name), nil]
        else
          ["G-RESUME-NONAME", Reach::Greetings.text("G-RESUME-NONAME"), nil]
        end
      else
        complete_greeting(profile)
      end
    rescue StandardError
      [nil, nil, nil]
    end

    def complete_greeting(profile)
      name = Reach::Profile.preferred_name || "there"
      install = safe_enrol_current

      unless install
        text = Reach::Greetings.text("G-NOT-ENROLLED", name: name)
        return ["G-NOT-ENROLLED", text, nil]
      end

      text = returning_text(name)
      ["G-RETURNING", text, nil]
    end

    def returning_text(name)
      status = safe_cached_status
      current_assignment = status && status["current_assignment"]
      slices = current_assignment_slices(current_assignment)

      if slices.empty?
        Reach::Greetings.text("G-RETURNING-PLAIN", name: name)
      elsif slices.length == 1
        workspace = slices.first
        meta = safe_metadata(workspace)
        Reach::Greetings.text(
          "G-RETURNING",
          name: name,
          assignment: current_assignment && current_assignment["id"],
          due: Reach::Messages.course_time(current_assignment && current_assignment["due"]),
          slice: meta && meta["slice"],
          state: safe_state_word(workspace)
        )
      else
        summary = slices.map { |workspace| "#{safe_metadata(workspace) && safe_metadata(workspace)["slice"]} #{safe_state_word(workspace)}" }.join(", ")
        Reach::Greetings.text(
          "G-RETURNING-MANY",
          name: name,
          assignment: current_assignment && current_assignment["id"],
          due: Reach::Messages.course_time(current_assignment && current_assignment["due"]),
          slices: summary
        )
      end
    end

    def current_assignment_slices(current_assignment)
      all = Reach::Workspace.current_slices
      return all unless current_assignment

      all.select do |workspace|
        meta = safe_metadata(workspace)
        meta && meta["assignment"] == current_assignment["id"]
      end
    rescue StandardError
      []
    end

    def course_question_line(question)
      answer = (Reach::Profile.load["fields"] || {})["course_answer"]
      return "- Course question (already answered): #{question}" unless answer.nil? || answer.to_s.empty?

      "- Still to ask, once, in a message of its own and not while the student is in the middle of something: #{Reach::Greetings.text("G-COURSE-QUESTION", question: question)}"
    rescue StandardError
      "- Course question: #{question}"
    end

    def safe_enrol_current
      Reach::Enroll.current
    rescue StandardError
      nil
    end

    def safe_cached_status
      Reach::Sync.cached_status
    rescue StandardError
      nil
    end

    def safe_metadata(workspace)
      Reach::Workspace.metadata(workspace)
    rescue StandardError
      nil
    end

    def safe_state_word(workspace)
      Reach::Workspace.state_word(workspace)
    rescue StandardError
      nil
    end

    def safe_course_question
      Reach::Guardrails.course_question
    rescue StandardError
      nil
    end

    def build_context(harness_id, format, _greeting_id, greeting_text, updating = nil, workspace: nil, local: false, mcp: false)
      lines = []
      lines << "rEach session context (from reach hello)"
      lines << "- You are rEach, the student's academic assistant. Load the reach-assistant skill for how to greet, interview and save."
      lines << "- #{Reach::Messages.text("M-AGENT-TALK")}"
      lines.concat(known_issue_lines(mcp))
      lines << "- #{Reach::Messages.text("M-AGENT-UPDATE")}"
      if greeting_text
        lines << "- Greeting for this session: open your first reply with exactly this text, then continue as it asks:"
        greeting_text.each_line { |line| lines << "  #{line.chomp}" }
        lines << "- Exception: if the student's first message says they are in crisis or might hurt themselves or someone else, skip the greeting and give reach support's message first (run reach support or the reach_support tool)."
      else
        lines << "- This session continues an earlier one. Do not greet again."
      end
      lines << "- Wherever the skills say `reach <command>`, run `#{Reach::Runtime.hook_command} <command>` if `reach` is not on the path, or use the reach_* tools when you have them."
      lines << update_line(updating) if updating
      lines << profile_line
      lines << course_line
      lines.concat(alignment_lines)
      late = safe_late_line(workspace)
      lines << late if late
      memory = safe_session_context
      lines << memory if memory
      question = safe_course_question
      lines << course_question_line(question) if question
      storage = local ? nil : safe_storage_context
      lines << "- #{storage}" if storage

      text = lines.join("\n")
      if %w[codex hermes unknown].include?(harness_id) || format.to_s == "text"
        text = "#{text}\n\n#{persona_body}"
      end
      text
    end

    def alignment_lines
      return [] unless safe_enrol_current

      lines = []
      ids = Reach::Modules.module_ids
      lines << "- Modules: #{Reach::Modules.names(ids)}" unless ids.empty?
      pending = Reach::Transfer.current
      lines << "- Module move: waiting for the student's instructor (asked #{Reach::Messages.course_time(pending['created_at'])})" if pending
      answer = Reach::Transfer.announcement!
      lines << "- Tell the student about their module move request, in these words: #{answer}" if answer
      lines
    rescue StandardError
      []
    end

    def profile_line
      profile = Reach::Profile.load
      fields = profile["fields"] || {}
      if fields.empty?
        "- Student profile: #{profile["status"]}; nothing saved yet"
      else
        lines = ["- Student profile: #{profile["status"]};"]
        fields.each { |key, value| lines << "  #{key}: #{value}" }
        lines.join("\n")
      end
    rescue StandardError
      "- Student profile: not_started; nothing saved yet"
    end

    def course_line
      install = safe_enrol_current
      return "- Course: not connected yet" unless install

      course = install["course"] || {}
      status = safe_cached_status
      current_assignment = status && status["current_assignment"]
      slices = current_assignment_slices(current_assignment)
      assignment_text = current_assignment ? "#{current_assignment["id"]} due #{Reach::Messages.course_time(current_assignment["due"])}" : "no current assignment"
      slices_text = slices.map { |workspace| "#{safe_metadata(workspace) && safe_metadata(workspace)["slice"]} #{safe_state_word(workspace)}" }.join(", ")
      slices_text = "none" if slices_text.empty?
      "- Course: #{course["title"]} · #{assignment_text} · #{slices_text}"
    rescue StandardError
      "- Course: not connected yet"
    end

    def persona_body
      path = File.join(Reach::Runtime.root, "skills", "reach-assistant", "SKILL.md")
      text = File.read(path)
      text.sub(/\A---.*?---\n/m, "").strip
    rescue StandardError
      ""
    end

    def emit(format, context, banner, greeting_id, greeting_text)
      case format.to_s
      when "hook"
        payload = { "hookSpecificOutput" => { "hookEventName" => "SessionStart", "additionalContext" => context } }
        payload["systemMessage"] = banner if banner
        JSON.generate(payload)
      when "json"
        JSON.generate("greeting_id" => greeting_id, "greeting" => greeting_text, "banner" => banner, "context" => context)
      else
        context
      end
    end
  end
end
