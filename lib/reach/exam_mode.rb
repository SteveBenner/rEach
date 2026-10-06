require "json"
require "time"
require "securerandom"

module Reach
  module ExamMode
    FILE = "exam.json".freeze
    CURRENT_ROUTE = "/api/v1/tests/current".freeze
    OPEN_ROUTE = "/api/v1/tests/%s/open".freeze
    ANSWER_ROUTE = "/api/v1/tests/attempts/%s/answers".freeze
    SUBMIT_ROUTE = "/api/v1/tests/attempts/%s/submit".freeze
    PROMPT_WINDOW_S = 1800
    UNSUPPORTED_WAIT_S = 21_600

    module_function

    def enabled?
      Reach::AgentControl.flag?("test_mode")
    end

    def read
      state = Reach::StateFile.read(FILE)
      state.is_a?(Hash) ? state : {}
    end

    def server_now(state = read)
      Time.now.utc + state["server_offset_s"].to_f
    end

    def deadline(state = read)
      value = state["deadline_at"]
      value.is_a?(String) ? Time.iso8601(value).utc : nil
    rescue ArgumentError
      nil
    end

    def attempt?(state = read)
      state["attempt_id"].is_a?(String) && !state["attempt_id"].empty?
    end

    def submitted?(state = read)
      !state["submitted_at"].nil?
    end

    def remaining(state = read)
      due = deadline(state)
      due ? due - server_now(state) : 0
    end

    def open_attempt?(state = read)
      attempt?(state) && !submitted?(state) && remaining(state) > 0
    end

    def active?
      enabled? && open_attempt?
    end

    def minutes_left(state = read)
      [(remaining(state) / 60.0).ceil, 0].max
    end

    def deadline_text(state = read)
      Reach::CourseTime.format(state["deadline_at"])
    end

    def close_out!
      Reach::StateFile.update(FILE) do |state|
        next unless attempt?(state) && !submitted?(state) && remaining(state) <= 0

        state["total"] = Array(state["questions"]).size if state["total"].nil?
        state["questions"] = []
        state["ended_reason"] = "deadline"
        state["ended_at"] ||= Reach::StateFile.now_s
      end
    end

    def fetch!
      return nil unless enabled?

      install = Reach::Enroll.current
      return nil unless install
      return { "skipped" => "unsupported" } if read["unsupported_until"].to_i > Time.now.to_i

      response = Reach::Client.for_install(install).get(CURRENT_ROUTE)
      synchronize!(response.json || {})
      close_out!
      { "offered" => !read["offered"].nil?, "open" => open_attempt? }
    rescue Reach::RemoteRefused => e
      raise unless e.status == 404 || e.code == "unavailable"

      Reach::StateFile.update(FILE) { |state| state["unsupported_until"] = Time.now.to_i + UNSUPPORTED_WAIT_S } if e.status == 404
      { "skipped" => e.status == 404 ? "unsupported" : "switched_off" }
    end

    def synchronize!(body)
      test = body["test"].is_a?(Hash) ? body["test"] : nil
      offset = offset_from(body["server_time"])
      Reach::StateFile.update(FILE) do |state|
        state.delete("unsupported_until")
        state["server_offset_s"] = offset unless offset.nil?
        state["offered"] = test ? test.slice("control_id", "test_id", "title", "window_end", "time_limit_s") : nil
        attempt = test && test["attempt"].is_a?(Hash) ? test["attempt"] : nil
        next unless attempt && attempt["id"] == state["attempt_id"]

        state["deadline_at"] = attempt["deadline_at"] if attempt["deadline_at"].is_a?(String)
        mark_submitted(state, attempt["submitted_at"]) if attempt["submitted_at"].is_a?(String)
      end
    end

    def offset_from(server_time)
      return nil unless server_time.is_a?(String)

      Time.iso8601(server_time).utc - Time.now.utc
    rescue ArgumentError
      nil
    end

    def mark_submitted(state, submitted_at)
      return if state["submitted_at"]

      state["total"] = Array(state["questions"]).size if state["total"].nil?
      state["submitted_at"] = submitted_at
      state["ended_reason"] = "submitted"
      state["questions"] = []
    end

    def questions(state = read)
      Array(state["questions"]).select { |item| item.is_a?(Hash) && item["id"].is_a?(String) }
    end

    def number_of(state, question_id)
      index = questions(state).index { |item| item["id"] == question_id }
      index ? index + 1 : nil
    end

    def require_open!
      raise Reach::Refused, Reach::Messages.text("M-TEST-NONE") unless enabled?

      close_out!
      state = read
      raise Reach::Refused, Reach::Messages.text("M-TEST-NONE") unless attempt?(state)
      raise Reach::Refused, Reach::Messages.text("M-TEST-ENDED") unless open_attempt?(state)

      state
    end

    def open!
      raise Reach::Refused, Reach::Messages.text("M-TEST-NONE") unless enabled?

      close_out!
      state = read
      return state if open_attempt?(state) && !questions(state).empty?

      install = Reach::Enroll.current
      raise Reach::Refused, Reach::Messages.text("M-TEST-NONE") unless install

      client = Reach::Client.for_install(install)
      synchronize!(client.get(CURRENT_ROUTE).json || {})
      offered = read["offered"]
      raise Reach::Refused, Reach::Messages.text("M-TEST-NONE") unless offered.is_a?(Hash)

      response = refused_as_ended { client.post_json(format(OPEN_ROUTE, offered["control_id"]), {}, idempotency_key: SecureRandom.uuid) }
      store_attempt!(offered, response.json || {})
      read
    end

    def refused_as_ended
      yield
    rescue Reach::RemoteRefused => e
      raise unless e.status == 409

      raise Reach::Refused, Reach::Messages.text("M-TEST-ENDED")
    end

    def store_attempt!(offered, body)
      attempt = body["attempt"].is_a?(Hash) ? body["attempt"] : {}
      offset = offset_from(body["server_time"]) || offset_from(attempt["opened_at"]) || 0
      rows = Array(body["questions"]).select { |item| item.is_a?(Hash) && item["id"].is_a?(String) && item["text"].is_a?(String) }
      Reach::StateFile.update(FILE) do |state|
        state["attempt_id"] = attempt["id"]
        state["control_id"] = offered["control_id"]
        state["test_id"] = offered["test_id"]
        state["title"] = offered["title"]
        state["deadline_at"] = attempt["deadline_at"]
        state["opened_at"] = attempt["opened_at"]
        state["submitted_at"] = nil
        state["questions"] = rows.map { |item| { "id" => item["id"], "text" => item["text"] } }
        state["total"] = rows.size
        state["answers"] = {}
        state["server_offset_s"] = offset
        state.delete("ended_reason")
        state.delete("ended_at")
        state.delete("answered")
      end
    end

    def latest_prompt(state)
      entry = begin
        JSON.parse(File.read(Reach::Part.pending_path))
      rescue StandardError
        nil
      end
      return nil unless entry.is_a?(Hash) && entry["text"].is_a?(String) && entry["at"].is_a?(String)

      install = Reach::Enroll.current
      student = install && install["student_id"]
      return nil unless entry["student_id"].nil? || entry["student_id"] == student

      at = Time.parse(entry["at"]).utc
      return nil if Time.now.utc - at > PROMPT_WINDOW_S

      opened = state["opened_at"].is_a?(String) ? Time.iso8601(state["opened_at"]).utc : nil
      return nil if opened && at < opened

      entry
    rescue ArgumentError
      nil
    end

    def record!(question_id)
      state = require_open!
      id = question_id.to_s
      number = number_of(state, id)
      raise Reach::Refused, Reach::Messages.text("M-TEST-USAGE") unless number

      entry = latest_prompt(state)
      raise Reach::Refused, Reach::Messages.text("M-TEST-NEEDS-ANSWER", number: number) unless entry

      response = refused_as_ended do
        Reach::Client.for_install.post_json(
          format(ANSWER_ROUTE, state["attempt_id"]), { "question_id" => id, "answer" => entry["text"] }, idempotency_key: SecureRandom.uuid
        )
      end
      recorded = (response.json || {})["recorded"]
      recorded = {} unless recorded.is_a?(Hash)
      Reach::StateFile.update(FILE) do |current|
        current["answers"] = {} unless current["answers"].is_a?(Hash)
        current["answers"][id] = recorded["seq"]
      end
      { "number" => number, "seq" => recorded["seq"], "recorded_at" => recorded["recorded_at"] }
    end

    def submit!
      state = require_open!
      response = refused_as_ended do
        Reach::Client.for_install.post_json(format(SUBMIT_ROUTE, state["attempt_id"]), {}, idempotency_key: SecureRandom.uuid)
      end
      attempt = (response.json || {})["attempt"]
      attempt = {} unless attempt.is_a?(Hash)
      kept = read["answers"].is_a?(Hash) ? read["answers"].size : 0
      answered = attempt["answered"].is_a?(Integer) && attempt["answered"] > 0 ? attempt["answered"] : kept
      total = [state["total"].to_i, questions(state).size].max
      Reach::StateFile.update(FILE) do |current|
        mark_submitted(current, attempt["submitted_at"] || Reach::StateFile.now_s)
        current["answered"] = answered
      end
      { "answered" => answered, "total" => total }
    end

    def status_text
      close_out!
      state = read
      return Reach::Messages.text("M-TEST-NONE") unless enabled? && attempt?(state)
      return Reach::Messages.text("M-TEST-SUBMITTED", answered: state["answered"].to_i, total: state["total"].to_i) if submitted?(state)
      return Reach::Messages.text("M-TEST-ENDED") unless open_attempt?(state)

      Reach::Messages.text("M-TEST-CLOCK", minutes: minutes_left(state), deadline: deadline_text(state))
    end

    def questions_text(state)
      lines = [Reach::Messages.text("M-TEST-OPENED", title: state["title"], minutes: minutes_left(state), deadline: deadline_text(state))]
      questions(state).each_with_index { |item, index| lines << "#{index + 1}. #{item["text"]}" }
      lines.join("\n\n")
    end

    def dispatch(action, question_id)
      case action.to_s
      when "", "status"
        { "text" => status_text, "active" => active? }
      when "open"
        state = open!
        { "text" => questions_text(state), "relay_verbatim" => true, "attempt_id" => state["attempt_id"], "deadline_at" => state["deadline_at"] }
      when "questions"
        state = require_open!
        raise Reach::Refused, Reach::Messages.text("M-TEST-NONE") if questions(state).empty?

        { "text" => questions_text(state), "relay_verbatim" => true, "deadline_at" => state["deadline_at"] }
      when "record"
        result = record!(question_id)
        { "text" => Reach::Messages.text("M-TEST-RECORDED", number: result["number"]), "relay_verbatim" => true, "seq" => result["seq"] }
      when "submit"
        result = submit!
        { "text" => Reach::Messages.text("M-TEST-SUBMITTED", answered: result["answered"], total: result["total"]), "relay_verbatim" => true }
      else
        { "text" => Reach::Messages.text("M-TEST-USAGE"), "relay_verbatim" => true }
      end
    end

    def cli(args)
      args = args.dup
      action = args.shift.to_s
      result = dispatch(action, args.shift)
      puts result["text"]
      0
    rescue Reach::Refused => e
      warn e.message
      1
    end

    def tool(arguments)
      arguments = {} unless arguments.is_a?(Hash)
      dispatch(arguments["action"], arguments["question_id"])
    end

    def context_entries
      return [] unless enabled?

      close_out!
      state = read
      return [] unless open_attempt?(state)

      text = Reach::Messages.text("M-TEST-CLOCK", minutes: minutes_left(state), deadline: deadline_text(state))
      [[text, Reach::AgentControl.time_fields("ends", deadline_text(state))]]
    rescue ArgumentError
      []
    end

    def context_lines
      context_entries.map(&:first)
    end

    def context_blocks(id)
      context_entries.map { |text, fields| Reach::AgentControl.channel(id, **fields) { text } }
    end
  end
end
