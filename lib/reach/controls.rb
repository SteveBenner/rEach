require "json"
require "time"

module Reach
  module Controls
    ROUTE = "/api/v1/controls".freeze
    FILE = "controls.json".freeze
    UNSUPPORTED_WAIT_S = 21_600
    KINDS = %w[pause_course_work hold_submissions test].freeze
    PAUSE_SPACES = %w[slice root].freeze
    TEST_TOOLS = %w[reach_test reach_support reach_status].freeze
    TEST_STATE_FILE = "exam.json".freeze

    module_function

    def enabled?
      Reach::AgentControl.flag?("controls")
    end

    def fetch!
      return nil unless enabled?

      install = Reach::Enroll.current
      return nil unless install
      return { "skipped" => "unsupported" } if parked?(Reach::StateFile.read(FILE))

      response = Reach::Client.for_install(install).get(ROUTE)
      body = response.json || {}
      rows = body["controls"]
      raise Reach::Error, "reach: the course server's controls answer was unreadable" unless rows.is_a?(Array)

      store(rows, body)
      { "held" => active.size, "listed" => rows.size }
    rescue Reach::RemoteRefused => e
      raise unless e.status == 404 || e.code == "unavailable"

      clear!(e.status == 404)
      { "skipped" => e.status == 404 ? "unsupported" : "switched_off" }
    rescue Reach::NetworkError => e
      raise unless e.cause_name.to_s == "http_503"

      clear!(false)
      { "skipped" => "switched_off" }
    end

    def parked?(state)
      state["unsupported_until"].to_i > Time.now.to_i
    end

    def store(rows, body)
      offset = server_offset(body["server_time"])
      kept = rows.select { |row| valid_row?(row) }.map do |row|
        row.slice("id", "kind", "starts_at", "ends_at", "test_id", "time_limit_s")
      end
      Reach::StateFile.update(FILE) do |held|
        held["controls"] = kept
        held["offset_s"] = offset
        held["time_zone"] = body["time_zone"].to_s unless body["time_zone"].to_s.empty?
        held["fetched_at"] = Reach::StateFile.now_s
        held.delete("unsupported_until")
      end
    end

    def clear!(park)
      Reach::StateFile.update(FILE) do |held|
        held["controls"] = []
        held["fetched_at"] = Reach::StateFile.now_s
        if park
          held["unsupported_until"] = Time.now.to_i + UNSUPPORTED_WAIT_S
        else
          held.delete("unsupported_until")
        end
      end
    end

    def valid_row?(row)
      row.is_a?(Hash) && row["id"].is_a?(String) && KINDS.include?(row["kind"]) &&
        !instant(row["starts_at"]).nil? && !instant(row["ends_at"]).nil?
    end

    def server_offset(server_time)
      stamp = instant(server_time)
      stamp ? (stamp - Time.now).round : 0
    end

    def instant(value)
      return nil if value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def state
      Reach::StateFile.read(FILE)
    end

    def now(held = state)
      Time.now + held["offset_s"].to_i
    end

    def active(kind = nil)
      return [] unless enabled?

      held = state
      rows = held["controls"].is_a?(Array) ? held["controls"] : []
      moment = now(held)
      rows.select do |row|
        next false unless row.is_a?(Hash) && (kind.nil? || row["kind"] == kind)

        starts = instant(row["starts_at"])
        ends = instant(row["ends_at"])
        starts && ends && starts <= moment && moment < ends
      end.sort_by { |row| instant(row["ends_at"]) }
    rescue StandardError
      []
    end

    def open_attempt
      held = Reach::StateFile.read(TEST_STATE_FILE)
      return nil if held["attempt_id"].to_s.empty? || !held["submitted_at"].to_s.empty?

      deadline = instant(held["deadline_at"])
      deadline && now < deadline ? deadline : nil
    rescue StandardError
      nil
    end

    def test_lock
      rows = active("test")
      return nil if rows.empty?

      deadline = open_attempt
      return nil unless deadline

      [deadline, instant(rows.first["ends_at"])].compact.min
    end

    def zone
      state["time_zone"].to_s.empty? ? nil : state["time_zone"]
    end

    def format_time(value)
      stamp = value.is_a?(Time) ? value : instant(value)
      return "" unless stamp

      Reach::CourseTime.format(stamp, zone: zone)
    end

    def support_line
      Reach::Support.message(told: nil)
    rescue StandardError
      ""
    end

    def refuse!(message_id, check, kind, ends)
      Reach::Debug.emit("control", "check" => check, "outcome" => "block", "control_kind" => kind, "message_id" => message_id)
      fields = { ends: format_time(ends) }
      fields[:support] = support_line if message_id == "M-CONTROL-PAUSED"
      Reach::Gate.raise_blocked!(message_id, **fields)
    end

    def check_pause!(space, check)
      return nil unless space.is_a?(Hash) && PAUSE_SPACES.include?(space["kind"])

      row = active("pause_course_work").last
      return nil unless row

      refuse!("M-CONTROL-PAUSED", check, "pause_course_work", row["ends_at"])
    end

    def check_prompt!(space)
      return nil unless enabled?

      check_pause!(space, "prompt")
      nil
    end

    def check_tool!(kind, space)
      return nil unless enabled?

      lock = test_lock
      refuse!("M-CONTROL-TEST-LOCKED", kind.to_s, "test", lock) if lock
      check_pause!(space, kind.to_s)
      nil
    end

    def check_submit!
      return nil unless enabled?

      row = active("hold_submissions").last
      return nil unless row

      refuse!("M-CONTROL-HOLD", "submit", "hold_submissions", row["ends_at"])
    end

    def allowed_tools
      doc = Reach::AgentControl.load
      section = doc.is_a?(Hash) && doc["controls"].is_a?(Hash) ? doc["controls"]["test"] : nil
      listed = section.is_a?(Hash) ? section["allowed_tools"] : nil
      listed.is_a?(Array) && !listed.empty? ? listed.map(&:to_s) : TEST_TOOLS
    rescue StandardError
      TEST_TOOLS
    end

    def tool_allowed?(name)
      return true unless enabled?
      return true unless test_lock
      return true if allowed_tools.include?(name.to_s)

      Reach::Debug.emit("control", "check" => "mcp", "outcome" => "block", "control_kind" => "test", "message_id" => "M-CONTROL-TEST-LOCKED")
      false
    rescue StandardError
      true
    end

    def ends_text
      lock = test_lock
      return format_time(lock) if lock

      row = active.last
      row ? format_time(row["ends_at"]) : ""
    end

    def context_lines
      return [] unless enabled?

      lines = []
      pause = active("pause_course_work").last
      lines << Reach::Messages.text("M-CONTROL-PAUSED", ends: format_time(pause["ends_at"]), support: support_line) if pause
      hold = active("hold_submissions").last
      lines << Reach::Messages.text("M-CONTROL-HOLD", ends: format_time(hold["ends_at"])) if hold
      lock = test_lock
      lines << Reach::Messages.text("M-CONTROL-TEST-LOCKED", ends: format_time(lock)) if lock
      lines
    rescue StandardError
      []
    end
  end
end
