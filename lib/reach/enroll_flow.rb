require "json"
require "time"
require "rbconfig"
require "fileutils"

module Reach
  module EnrollFlow
    SCHEMA = "reach.enroll-flow/v1".freeze
    RESTART_WORDS = ["start over", "restart", "cancel"].freeze
    FIRST_MESSAGES = {
      "not_enrolled" => "M-ENR-WELCOME",
      "revoked" => "M-GATE-REVOKED",
      "stamp_invalid" => "M-ENR-STAMP-INVALID",
      "moved" => "M-ENR-MOVED",
      "restamp" => "M-ENR-RESTAMP"
    }.freeze

    module_function

    def evaluate(event:, harness:)
      lock = Reach::EnrollmentLock.state
      return nil unless lock["locked"]

      event = {} unless event.is_a?(Hash)
      text = event["prompt"].is_a?(String) ? event["prompt"] : nil
      return block(Reach::Messages.text("M-ENR-COURSE-ENDED")) if lock["reason"] == "course_ended"

      begin
        step(text, lock, harness)
      rescue StandardError
        block(safe_ask)
      end
    rescue StandardError
      block(Reach::Messages.text("M-ENR-ASK-CODE"))
    end

    def step(text, lock, harness)
      now = Time.now.utc
      flow = read_flow
      return block(Reach::Support.message(told: nil)) if Reach::Login.crisis_match?(text)

      if flow.nil?
        write_flow(fresh_flow)
        return block(Reach::Messages.text(FIRST_MESSAGES.fetch(lock["reason"], "M-ENR-WELCOME")))
      end

      remaining = locked_minutes(flow, now)
      return block(Reach::Messages.text("M-ENR-LOCKED", minutes: remaining)) if remaining

      if RESTART_WORDS.include?(Reach::Login.normalize(text))
        write_flow(fresh_flow.merge("refusals" => Array(flow["refusals"])))
        return block(Reach::Messages.text("M-ENR-RESTART"))
      end

      message = case flow["state"]
                when "awaiting_username" then step_username(flow, text)
                when "awaiting_student_id" then step_student_id(flow, text)
                when "awaiting_confirm" then step_confirm(flow, text, now, harness)
                else step_code(flow, text)
                end
      block(message)
    end

    def step_code(flow, text)
      parsed = Reach::Identity.parse_course_code(text)
      if parsed.nil? && Reach::Login.yes?(text) && flow["pending_code"]
        parsed = Reach::Identity.parse_course_code(flow["pending_code"])
      end
      unless parsed
        course_id = Reach::Identity.bare_course_id(text)
        return Reach::Messages.text("M-ENR-CODE-COURSE-ONLY", course_id: course_id) if course_id

        return Reach::Messages.text("M-ENR-CODE-FORMAT")
      end

      url = teach_url
      return Reach::Messages.text("M-ENR-FAILED", reason: "No course server address is configured.") unless url

      begin
        body = Reach::Enroll.preview(parsed["code"], url)
      rescue Reach::RemoteRefused => e
        return refusal_text(e)
      rescue Reach::NetworkError
        write_flow(flow.merge("pending_code" => parsed["code"], "updated_at" => iso(Time.now.utc)))
        return Reach::Messages.text("M-ENR-OFFLINE")
      rescue Reach::Error => e
        return Reach::Messages.text("M-ENR-FAILED", reason: e.message)
      end

      course = body["course"]
      next_flow = flow.merge(
        "state" => "awaiting_username",
        "code" => parsed["code"],
        "pending_code" => nil,
        "course" => { "id" => course["id"].to_s, "title" => course["title"].to_s, "term" => course["term"].to_s },
        "expires_at" => body["expires_at"],
        "identity" => Reach::Identity.rules(body["identity"]),
        "username" => nil,
        "student_id" => nil,
        "updated_at" => iso(Time.now.utc)
      )
      write_flow(next_flow)
      ask_username(next_flow)
    end

    def refusal_text(error)
      case error.code
      when "course_code_unknown"
        details = error.details.is_a?(Hash) ? error.details : {}
        suggestion = details["did_you_mean"].to_s
        suggestion.empty? ? Reach::Messages.text("M-ENR-CODE-UNKNOWN") : Reach::Messages.text("M-ENR-CODE-SUGGEST", course_id: suggestion)
      when "course_code_expired"
        Reach::Messages.text("M-ENR-CODE-EXPIRED")
      else
        Reach::Messages.text("M-ENR-FAILED", reason: error.message)
      end
    end

    def step_username(flow, text)
      rules = flow["identity"] || Reach::Identity.rules
      username = Reach::Identity.normalize_username(text, rules)
      unless username
        return Reach::Messages.text("M-ENR-USERNAME-FORMAT", institution: rules["institution_name"], domain: rules["username_domain"])
      end

      next_flow = flow.merge("state" => "awaiting_student_id", "username" => username, "updated_at" => iso(Time.now.utc))
      write_flow(next_flow)
      Reach::Messages.text("M-ENR-ASK-ID", institution: rules["institution_name"])
    end

    def step_student_id(flow, text)
      rules = flow["identity"] || Reach::Identity.rules
      student_id = Reach::Identity.normalize_student_id(text, rules)
      return Reach::Messages.text("M-ENR-ID-FORMAT", institution: rules["institution_name"]) unless student_id

      next_flow = flow.merge("state" => "awaiting_confirm", "student_id" => student_id, "updated_at" => iso(Time.now.utc))
      write_flow(next_flow)
      confirm_text(next_flow)
    end

    def step_confirm(flow, text, now, harness)
      if Reach::Login.yes?(text)
        register(flow, now, harness)
      elsif Reach::Login.no?(text)
        write_flow(fresh_flow.merge("refusals" => Array(flow["refusals"])))
        Reach::Messages.text("M-ENR-RESTART")
      else
        confirm_text(flow)
      end
    end

    def register(flow, now, harness)
      url = teach_url
      return Reach::Messages.text("M-ENR-FAILED", reason: "No course server address is configured.") unless url

      begin
        install = Reach::Enroll.register_v2(
          course_code: flow["code"], username: flow["username"], student_id: flow["student_id"],
          teach_url: url, harness: harness.to_s.empty? ? "unknown" : harness.to_s, enrolled_via: "chat"
        )
      rescue Reach::RemoteRefused => e
        return refused(flow, now) if e.code == "enrollment_refused"

        return Reach::Messages.text("M-ENR-FAILED", reason: e.message)
      rescue Reach::NetworkError
        return Reach::Messages.text("M-ENR-OFFLINE")
      rescue Reach::Error => e
        return Reach::Messages.text("M-ENR-FAILED", reason: e.message)
      end

      FileUtils.rm_f(Reach::Paths.enroll_flow_file)
      spawn_sync
      first_name = install["display_name"].to_s.split(/\s+/).first || "there"
      Reach::Messages.text(
        "M-ENR-DONE",
        course_title: (install["course"] || {})["title"], first_name: first_name, launch: Reach::Runtime.hook_command("work")
      )
    end

    def consume_notice
      path = Reach::Paths.enroll_notice_file
      return nil unless File.file?(path)

      data = Reach::Login.read_json(path)
      FileUtils.rm_f(path)
      title = data.is_a?(Hash) ? data["course_title"] : nil
      Reach::Messages.text("M-ENR-AGENT-ENROLLED", course_title: title || "the course")
    rescue StandardError
      nil
    end

    def refused(flow, now)
      minutes = lockout_minutes
      cutoff = now - (minutes * 60)
      recent = Array(flow["refusals"]).select do |stamp|
        Time.iso8601(stamp) > cutoff
      rescue ArgumentError
        false
      end
      recent << iso(now)
      next_flow = flow.merge("state" => "awaiting_username", "username" => nil, "student_id" => nil, "refusals" => recent, "updated_at" => iso(now))
      if recent.length >= lockout_refusals
        write_flow(next_flow.merge("refusals" => [], "locked_until" => iso(now + (minutes * 60))))
        return Reach::Messages.text("M-ENR-LOCKED", minutes: minutes)
      end

      write_flow(next_flow)
      Reach::Messages.text("M-ENR-REFUSED", course_id: (flow["course"] || {})["id"])
    end

    def spawn_sync
      pid = Process.spawn(RbConfig.ruby, Reach::Runtime.exe_path, "sync", in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
      Process.detach(pid)
    rescue StandardError
      nil
    end

    def next_message(lock)
      return Reach::Messages.text("M-ENR-COURSE-ENDED") if lock["reason"] == "course_ended"

      flow = read_flow
      return ask(flow) if flow

      Reach::Messages.text(FIRST_MESSAGES.fetch(lock["reason"], "M-ENR-WELCOME"))
    rescue StandardError
      Reach::Messages.text("M-ENR-WELCOME")
    end

    def safe_ask
      flow = read_flow
      flow ? ask(flow) : Reach::Messages.text("M-ENR-ASK-CODE")
    rescue StandardError
      Reach::Messages.text("M-ENR-ASK-CODE")
    end

    def ask(flow)
      case flow["state"]
      when "awaiting_username" then ask_username(flow)
      when "awaiting_student_id" then Reach::Messages.text("M-ENR-ASK-ID", institution: (flow["identity"] || {})["institution_name"])
      when "awaiting_confirm" then confirm_text(flow)
      else Reach::Messages.text("M-ENR-ASK-CODE")
      end
    end

    def ask_username(flow)
      course = flow["course"] || {}
      rules = flow["identity"] || {}
      Reach::Messages.text(
        "M-ENR-ASK-USERNAME",
        course_title: course["title"], course_id: course["id"], term: course["term"],
        institution: rules["institution_name"], domain: rules["username_domain"]
      )
    end

    def confirm_text(flow)
      course = flow["course"] || {}
      Reach::Messages.text(
        "M-ENR-CONFIRM",
        username: flow["username"], student_id: flow["student_id"], course_title: course["title"],
        course_id: course["id"], term: course["term"]
      )
    end

    def teach_url
      Reach::Runtime.default_teach_url
    end

    def settings
      value = Reach::Runtime.load_config["enrollment"]
      value.is_a?(Hash) ? value : {}
    end

    def lockout_refusals
      value = settings["lockout_refusals"].to_i
      value.positive? ? value : 5
    end

    def lockout_minutes
      value = settings["lockout_minutes"].to_i
      value.positive? ? value : 15
    end

    def locked_minutes(flow, now)
      return nil unless flow["locked_until"]

      until_time = Time.iso8601(flow["locked_until"])
      return nil unless until_time > now

      ((until_time - now) / 60.0).ceil
    rescue ArgumentError
      nil
    end

    def block(message)
      { "action" => "block", "message" => message }
    end

    def fresh_flow
      { "schema" => SCHEMA, "state" => "awaiting_code", "refusals" => [], "locked_until" => nil, "updated_at" => iso(Time.now.utc) }
    end

    def read_flow
      data = Reach::Login.read_json(Reach::Paths.enroll_flow_file)
      data.is_a?(Hash) && data["schema"] == SCHEMA ? data : nil
    end

    def write_flow(flow)
      Reach::Login.write_json(Reach::Paths.enroll_flow_file, flow.merge("schema" => SCHEMA))
    end

    def iso(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
