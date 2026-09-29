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

      harness_id = resolve_harness(harness)
      maybe_refresh_status
      maybe_configure(cwd)

      greeting_id, greeting_text, banner = choose_greeting(source)
      context = build_context(harness_id, format, greeting_id, greeting_text)

      emit(format, context, banner, greeting_id, greeting_text)
    rescue StandardError
      emit(format, MINIMAL_CONTEXT, nil, nil, nil)
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
      else
        "unknown"
      end
    end

    def maybe_refresh_status
      return unless defined?(Reach::Enrol) && defined?(Reach::Sync)
      return unless Reach::Enrol.current
      return if ENV["REACH_OFFLINE"] == "1"

      age = Reach::Sync.status_age_s
      return unless age.nil? || age > 21_600

      Reach::Sync.refresh_status(quick: true)
    rescue StandardError
      nil
    end

    def maybe_configure(cwd)
      return unless defined?(Reach::Workspace) && defined?(Reach::Harness)
      return unless cwd

      real_cwd = File.realpath(cwd)
      workspace = Reach::Workspace.current_slices.find do |workspace_path|
        real_workspace = File.realpath(workspace_path)
        real_cwd == real_workspace || real_cwd.start_with?(real_workspace + File::SEPARATOR)
      end
      return unless workspace

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
      Reach::Enrol.current
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

    def build_context(harness_id, format, _greeting_id, greeting_text)
      lines = []
      lines << "rEach session context (from reach hello)"
      lines << "- You are rEach, the student's academic assistant. Load the reach-assistant skill for how to greet, interview and save."
      if greeting_text
        lines << "- Greeting for this session: open your first reply with exactly this text, then continue as it asks:"
        greeting_text.each_line { |line| lines << "  #{line.chomp}" }
      else
        lines << "- This session continues an earlier one. Do not greet again."
      end
      lines << "- Wherever the skills say `reach <command>`, run `#{Reach::Runtime.hook_command} <command>` if `reach` is not on the path, or use the reach_* tools when you have them."
      lines << profile_line
      lines << course_line
      question = safe_course_question
      lines << course_question_line(question) if question

      text = lines.join("\n")
      if harness_id == "codex" || harness_id == "unknown" || format.to_s == "text"
        text = "#{text}\n\n#{persona_body}"
      end
      text
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
