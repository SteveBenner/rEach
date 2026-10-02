require "json"

module Reach
  module Hello
    MINIMAL_CONTEXT = "rEach session context (from reach hello)\n" \
                       "- You are rEach, the student's academic assistant. Load the reach-assistant skill.".freeze

    module_function

    def run(harness: nil, source: nil, format: "hook", cwd: Dir.pwd)
      Reach::Runtime.ensure_shim!

      event = {}
      if !STDIN.tty? && format.to_s == "hook"
        event = read_stdin_json
        source = event["source"] if source.nil?
        cwd = event["cwd"] if event["cwd"]
      end

      Reach::RuntimeAuto.start
      harness_id = resolve_harness(harness)
      Reach::Debug.begin_hook(event, harness_id)
      Reach::Debug.session(harness_id, source)
      greeting_id, greeting_text, banner, context = session_parts(harness_id, format, source, cwd, event)

      emit(format, context, banner, greeting_id, greeting_text)
    rescue StandardError
      emit(format, MINIMAL_CONTEXT, nil, nil, nil)
    end

    def context_text(harness:, cwd:, source: "startup", event: nil)
      harness_id = resolve_harness(harness)
      session_parts(harness_id, "text", source, cwd, event).last
    rescue StandardError
      MINIMAL_CONTEXT
    end

    def session_parts(harness_id, format, source, cwd, event = nil)
      lock = Reach::EnrollmentLock.state
      if lock["locked"]
        message = Reach::EnrollFlow.next_message(lock)
        return [nil, message, message, locked_context(format)]
      end

      maybe_refresh_status
      workspace = find_workspace(cwd)
      configure_workspace(workspace)

      session_id = event.is_a?(Hash) && !event["session_id"].to_s.empty? ? Reach::Transcript.resolve_session_id(event) : nil

      if login_pending?(event)
        updating = safe_update_start(session_id, source)
        greeting_text = [nil, "startup", "clear"].include?(source) ? Reach::Greetings.text("G-LOGIN") : nil
        return [greeting_text && "G-LOGIN", greeting_text, nil, login_context(updating)]
      end

      greeting_id, greeting_text, banner = choose_greeting(source)
      updating = safe_update_start(session_id, source)
      if updating && greeting_text
        greeting_text = "#{Reach::Greetings.text("G-UPDATING", version: updating)}\n\n#{greeting_text}"
      end
      if greeting_text && in_course_folder?(cwd)
        greeting_text = "#{greeting_text}\n\n#{Reach::Greetings.text("G-TRANSCRIPT-NOTICE")}"
      end
      if greeting_text && safe_memory_notice_due?
        greeting_text = "#{greeting_text}\n\n#{Reach::Greetings.text("G-MEMORY-NOTICE")}"
        Reach::Brain.memory_notice_shown!
      end
      context = build_context(harness_id, format, greeting_id, greeting_text, updating)
      [greeting_id, greeting_text, banner, context]
    end

    def safe_memory_notice_due?
      Reach::Brain.memory_notice_due?
    rescue StandardError
      false
    end

    def safe_session_context
      Reach::Brain.session_context
    rescue StandardError
      nil
    end

    def locked_context(format = "hook")
      guide = Reach::Messages.text("M-ENR-AGENT-GUIDE", command: Reach::Runtime.hook_command("guide"))
      text = "#{Reach::Messages.text("M-ENR-AGENT-CONTEXT")}\n#{guide}"
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

    def login_context(updating = nil)
      text = "#{MINIMAL_CONTEXT}\n- #{Reach::Messages.text('M-LOGIN-NEEDED')}"
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

    def build_context(harness_id, format, _greeting_id, greeting_text, updating = nil)
      lines = []
      lines << "rEach session context (from reach hello)"
      lines << "- You are rEach, the student's academic assistant. Load the reach-assistant skill for how to greet, interview and save."
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
      memory = safe_session_context
      lines << memory if memory
      question = safe_course_question
      lines << course_question_line(question) if question

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
