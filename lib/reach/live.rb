require "json"
require "time"
require "fileutils"
require "securerandom"
require "digest"
require "rbconfig"

module Reach
  module Live
    KIND = "live_session".freeze
    ACTION_KIND = "live_action".freeze
    SEND_KIND = "live_send".freeze
    KINDS = [KIND, ACTION_KIND, SEND_KIND].freeze
    REQUEST_SUBJECT = { "live" => "request" }.freeze
    DIAGNOSIS_SUBJECT = { "live" => "diagnosis" }.freeze
    DIAGNOSIS = "diagnosis".freeze
    LIVE_STATES = %w[requested offered open].freeze
    COMMANDS = {
      "doctor" => [%w[doctor --report]],
      "status" => [%w[status]],
      "sync" => [%w[sync]],
      "update_check" => [%w[update check]],
      "update" => [%w[update run]],
      "resend" => [%w[issues flush], %w[debug flush]]
    }.freeze
    ACTIONS = (COMMANDS.keys + %w[cache_repair]).freeze
    ACTION_TEXT = {
      "doctor" => "run rEach's self-check (reach doctor)",
      "status" => "look at rEach's status (reach status)",
      "sync" => "sync rEach with the course server (reach sync)",
      "update_check" => "check for a rEach update",
      "update" => "start a rEach update",
      "cache_repair" => "repair the Codex plugin cache",
      "resend" => "send again what rEach has waiting to be sent"
    }.freeze
    ACTION_TIMEOUT_S = 60
    MAX_RESULT_BYTES = 16_000
    MAX_SEND_BYTES = 2000
    ANSWER_WINDOW_S = 1800
    MIN_POLL_S = 2
    MAX_POLL_S = 30
    FAILURES_MAX = 5
    BACKOFF_BASE_S = 2.0
    BACKOFF_CAP_S = 60.0
    CHECK_GAP_S = 60
    DISABLED_GAP_S = 3600
    DEBUG_FLUSH_S = 10
    PENDING_MAX_S = 1800
    MAX_RUN_S = 4 * 3600
    INBOX_KEEP = 400
    WAIT_MAX_S = 45
    WATCH_MAX_S = 840
    WATCH_STEP_S = 1.0
    NOTIFY_GAP_S = 20
    BLOCKED_ASK = /\blive\s+session\b/i.freeze
    BLOCKED_END = /\bend\b.*\blive\s+session\b/i.freeze
    WAIT_STEP_S = 0.5
    STATE_WAIT_S = 2.0
    END_TEXT = {
      "ended_by_student" => "you ended it",
      "ended_by_instructor" => "your instructor ended it",
      "declined_by_student" => "you said no",
      "declined_by_instructor" => "your instructors could not take it right now",
      "expired" => "its time ran out",
      "unanswered" => "nobody answered in time",
      "superseded" => "a newer session replaced it"
    }.freeze
    REFUSALS = {
      "live_capacity" => "M-LIVE-BUSY", "not_open" => "M-LIVE-NOT-OPEN", "co_debug_off" => "M-LIVE-NO-CODEBUG",
      "message_cap" => "M-LIVE-SLOW", "message_rate" => "M-LIVE-SLOW", "not_offered" => "M-LIVE-NOT-OPEN",
      "diagnosis_refused" => "M-LIVE-DIAG-REFUSED"
    }.freeze

    module_function

    def dir
      File.join(Reach::Paths.state_dir, "live")
    end

    def state_file
      File.join(dir, "state.json")
    end

    def state_lock_file
      File.join(dir, "state.lock")
    end

    def inbox_file
      File.join(dir, "inbox.jsonl")
    end

    def runner_lock_file
      File.join(dir, "runner.lock")
    end

    def config
      section = Reach::Runtime.load_config["live"]
      section.is_a?(Hash) ? section : {}
    rescue StandardError
      {}
    end

    def enabled?
      ENV["REACH_LIVE_DISABLE"].to_s != "1" && config["enabled"] != false
    end

    def wake?
      enabled? && config["wake"] != false
    end

    def notify?
      enabled? && config["notify"] != false
    end

    def blocked?
      enabled? && config["blocked"] != false
    end

    def install
      current = Reach::Enroll.current
      current && !current["revoked"] ? current : nil
    rescue StandardError
      nil
    end

    def now
      Time.now.utc
    end

    def stamp(time = now)
      time.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def read_state
      parsed = Reach::Login.read_json(state_file)
      parsed = {} unless parsed.is_a?(Hash)
      parsed["told"] = {} unless parsed["told"].is_a?(Hash)
      parsed
    end

    def update
      FileUtils.mkdir_p(dir)
      result = nil
      held = Reach::Locks.exclusive(state_lock_file, wait_s: STATE_WAIT_S) do
        state = read_state
        result = yield state
        Reach::Login.write_json(state_file, state)
      end
      held == :busy ? nil : result
    end

    def session
      current = read_state["session"]
      current.is_a?(Hash) ? current : nil
    end

    def live?(current = session)
      !current.nil? && LIVE_STATES.include?(current["state"])
    end

    def open?(current = session)
      !current.nil? && current["state"] == "open"
    end

    def diagnosis?(current = session)
      !current.nil? && current["diagnosis"] == true
    end

    def runner_alive?
      File.exist?(runner_lock_file) && !Reach::Locks.free?(runner_lock_file)
    end

    def client
      Reach::Client.for_install(install, bucket: "live", quiet: true)
    end

    def spawn_runner
      return nil unless enabled? && install
      return nil if runner_alive?

      Reach::Storage.spawn_detached(%w[live run --background])
    rescue StandardError
      nil
    end

    def default_hand
      rows = Reach::Hands.list
      chosen = rows.reject { |row| row[:originator] == "reach" }.last || rows.last
      chosen && chosen[:hand_id]
    rescue StandardError
      nil
    end

    def off!
      raise Reach::Refused, Reach::Messages.text("M-LIVE-OFF") unless enabled?
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install
    end

    def ask!(hand_id: nil)
      off!
      current = session
      return { "state" => current["state"], "message" => status_text(current) } if live?(current)

      hand = hand_id.to_s.empty? ? default_hand : hand_id.to_s
      question = Reach::Consent.ask!(kind: KIND, subject: REQUEST_SUBJECT, message_id: "M-LIVE-ASK", replay: { "hand_id" => hand })
      { "state" => "asking", "question" => question, "message" => Reach::Messages.text("M-LIVE-ASK-AGENT", question: question) }
    end

    def diagnose!(course: nil)
      raise Reach::Refused, Reach::Messages.text("M-LIVE-OFF") unless enabled?
      raise Reach::Refused, Reach::Messages.text("M-LIVE-DIAG-NEEDS-UNLOCK") unless Reach::Instructor.active?

      started = install.nil? ? Reach::Persona.start!(kind: "dummy", username: nil, course_id: course) : nil
      off!
      current = session
      return { "state" => current["state"], "message" => status_text(current) } if live?(current)
      raise Reach::Refused, Reach::Messages.text("M-LIVE-ASK-BUSY") unless consent_free?(KIND)

      question = Reach::Consent.ask!(kind: KIND, subject: DIAGNOSIS_SUBJECT, message_id: "M-LIVE-DIAG-ASK")
      result = { "state" => "asking", "question" => question, "message" => Reach::Messages.text("M-LIVE-ASK-AGENT", question: question) }
      return result unless started

      signin = Reach::Messages.text("M-LIVE-DIAG-SIGNIN", student_id: started["persona"]["student_id"], workspace: started["workspace"])
      result.merge("persona" => started["persona"], "workspace" => started["workspace"], "signin" => signin, "message" => "#{result['message']}\n\n#{signin}")
    end

    def wire_consent(observed)
      Reach::Consent::WIRE_KEYS.each_with_object({}) { |key, memo| memo[key] = observed[key] }
    end

    def consent_pending
      pending = Reach::Login.read_json(Reach::Consent.pending_path)
      return nil unless pending.is_a?(Hash)

      now - Time.iso8601(pending["asked_at"].to_s) > Reach::Consent::WINDOW_S ? nil : pending
    rescue StandardError
      nil
    end

    def consent_free?(own = nil)
      pending = consent_pending
      pending.nil? || (!own.nil? && pending["kind"] == own)
    end

    def agent_context(observed, done)
      Reach::Messages.text("M-LIVE-CONSENT-DONE", answer: observed["answer"], text: done)
    end

    def follow_up!(observed)
      return nil unless enabled? && install

      subject = observed["subject"].is_a?(Hash) ? observed["subject"] : {}
      target = subject["live"].to_s
      answer = observed["answer"]
      record = wire_consent(observed)
      if answer == "yes"
        Reach::Consent.take!(kind: observed["kind"], subject: subject)
      else
        Reach::Consent.clear_declined!(kind: observed["kind"], subject: subject)
      end
      return action_follow_up(subject, answer) if observed["kind"] == ACTION_KIND
      return send_follow_up(subject, answer) if observed["kind"] == SEND_KIND

      if target == "request"
        return Reach::Messages.text("M-LIVE-ASK-NO") unless answer == "yes"

        hand = (observed["replay"] || {})["hand_id"]
        update { |state| state["pending"] = { "type" => "request", "hand_id" => hand, "consent" => record, "queued_at" => stamp } }
        spawn_runner
        return Reach::Messages.text("M-LIVE-REQUESTED")
      end

      if target == DIAGNOSIS
        return Reach::Messages.text("M-LIVE-DIAG-NO") unless answer == "yes"

        update { |state| state["pending"] = { "type" => "request", "diagnosis" => true, "consent" => record, "queued_at" => stamp } }
        spawn_runner
        return Reach::Messages.text("M-LIVE-DIAG-REQUESTED")
      end

      update { |state| state["pending"] = { "type" => "consent", "id" => target, "answer" => answer, "consent" => record, "queued_at" => stamp } }
      spawn_runner
      Reach::Messages.text(answer == "yes" ? "M-LIVE-ACCEPTED" : "M-LIVE-DECLINED")
    end

    def action_follow_up(subject, answer)
      current = session
      return Reach::Messages.text("M-LIVE-NOT-OPEN") unless open?(current) && current["id"] == subject["live"]

      found = false
      update do |state|
        Array(state["actions"]).each do |entry|
          next unless entry["id"] == subject["action"] && %w[waiting asked].include?(entry["status"])

          entry["status"] = answer == "yes" ? "approved" : "declined"
          found = true
        end
      end
      return Reach::Messages.text("M-LIVE-NOT-OPEN") unless found

      spawn_runner
      Reach::Messages.text(answer == "yes" ? "M-LIVE-ACTION-YES" : "M-LIVE-ACTION-NO")
    end

    def send_follow_up(subject, answer)
      current = session
      return Reach::Messages.text("M-LIVE-NOT-OPEN") unless open?(current) && current["id"] == subject["live"]

      found = false
      update do |state|
        entry = state["outgoing"]
        next unless entry.is_a?(Hash) && entry["digest"] == subject["send"] && entry["status"] == "asked"

        found = true
        if answer == "yes"
          entry["status"] = "approved"
        else
          state["outgoing"] = nil
        end
      end
      return Reach::Messages.text("M-LIVE-NOT-OPEN") unless found

      spawn_runner
      Reach::Messages.text(answer == "yes" ? "M-LIVE-SEND-YES" : "M-LIVE-SEND-NO")
    end

    def waiting_action(state = read_state)
      Array(state["actions"]).find { |entry| %w[waiting asked].include?(entry["status"]) }
    end

    def action_question(state = read_state)
      current = state["session"]
      return nil unless current.is_a?(Hash) && current["state"] == "open"

      entry = waiting_action(state)
      return nil if entry.nil?

      subject = { "live" => current["id"], "action" => entry["id"] }
      pending = consent_pending
      if pending
        return pending["question"] if pending["kind"] == ACTION_KIND && pending["subject_digest"] == Reach::Consent.digest(subject)

        return nil
      end

      question = Reach::Consent.ask!(kind: ACTION_KIND, subject: subject, message_id: "M-LIVE-ACTION-ASK", fields: { what: ACTION_TEXT.fetch(entry["name"]) })
      update do |fresh|
        Array(fresh["actions"]).each { |row| row["status"] = "asked" if row["id"] == entry["id"] && row["status"] == "waiting" }
      end
      question
    end

    def note_status(status)
      return nil unless enabled?

      hint = status.is_a?(Hash) ? status["live"] : nil
      return nil unless hint.is_a?(Hash) && LIVE_STATES.include?(hint["state"])

      spawn_runner
    rescue StandardError
      nil
    end

    def inbox(after = 0)
      return [] unless File.file?(inbox_file)

      rows = File.readlines(inbox_file).map do |line|
        begin
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
      end
      rows.compact.select { |row| row["seq"].to_i > after.to_i }
    rescue StandardError
      []
    end

    def append_inbox(session_id, messages)
      return nil if messages.empty?

      FileUtils.mkdir_p(dir)
      kept = inbox(0).select { |row| row["session_id"] == session_id }
      rows = (kept + messages.map { |message| message.merge("session_id" => session_id) }).last(INBOX_KEEP)
      temp = "#{inbox_file}.tmp.#{Process.pid}"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| rows.each { |row| file.puts(JSON.generate(row)) } }
      File.rename(temp, inbox_file)
    end

    def unread(state = read_state)
      current = state["session"]
      return [] unless current.is_a?(Hash)

      inbox(state["read"].to_i).select { |row| row["session_id"] == current["id"] }
    end

    def shown(row, diagnosis = false)
      case row["kind"]
      when "note" then { "from" => "instructor", "kind" => "note", "text" => row["text"], "at" => row["at"] }
      when "agent" then { "from" => "instructor_assistant", "kind" => "agent", "text" => row["text"], "at" => row["at"] }
      when "action" then { "from" => "instructor", "kind" => "action_request", "text" => Reach::Messages.text(diagnosis ? "M-LIVE-DIAG-ACTION" : "M-LIVE-ACTION-WANTED", what: ACTION_TEXT[row["name"].to_s] || "run something this rEach does not know"), "at" => row["at"] }
      else { "from" => "course_server", "kind" => "system", "text" => row["text"], "at" => row["at"] }
      end
    end

    def left_s(current)
      return nil unless current["expires_at"]

      [(Time.iso8601(current["expires_at"]) - now).to_i, 0].max
    rescue ArgumentError
      nil
    end

    def status_text(current)
      return Reach::Messages.text("M-LIVE-NONE") if current.nil?

      case current["state"]
      when "requested" then Reach::Messages.text("M-LIVE-WAITING")
      when "offered" then Reach::Messages.text("M-LIVE-OFFER-WAITING")
      when "open" then Reach::Messages.text(diagnosis?(current) ? "M-LIVE-DIAG-IS-OPEN" : "M-LIVE-IS-OPEN", minutes: (left_s(current).to_i / 60.0).ceil)
      else Reach::Messages.text("M-LIVE-CLOSED", reason: END_TEXT[current["end_reason"].to_s] || "it ended")
      end
    end

    def status
      return { "state" => "off", "message" => Reach::Messages.text("M-LIVE-OFF") } unless enabled?

      state = read_state
      current = state["session"].is_a?(Hash) ? state["session"] : nil
      spawn_runner if live?(current) || state["pending"]
      view = {
        "state" => current ? current["state"] : (state["pending"] ? "sending" : "none"),
        "message" => state["pending"] && current.nil? ? Reach::Messages.text("M-LIVE-SENDING") : status_text(current),
        "unread" => unread(state).length
      }
      if current
        view["session_id"] = current["id"]
        view["co_debug"] = current["co_debug"] == true
        view["diagnosis"] = diagnosis?(current)
        view["connected"] = current["connected"] == true
        view["minutes_left"] = (left_s(current).to_i / 60.0).ceil if current["state"] == "open"
      end
      view
    end

    def refusal_text(error)
      details = error.details.is_a?(Hash) ? error.details : {}
      id = REFUSALS[details["reason"].to_s]
      return Reach::Messages.text(id) if id
      return Reach::Messages.text("M-LIVE-OFF-TEACH") if error.status == 404

      Reach::Messages.text("M-LIVE-REFUSED")
    end

    def open_session!
      off!
      current = session
      raise Reach::Refused, Reach::Messages.text("M-LIVE-NOT-OPEN") unless open?(current)

      current
    end

    def cut(text, limit)
      value = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
      value.bytesize > limit ? value.byteslice(0, limit).scrub("") : value
    end

    def send!(kind, text)
      current = open_session!
      body = cut(text.to_s.strip, MAX_SEND_BYTES)
      raise Reach::Refused, Reach::Messages.text("M-LIVE-EMPTY") if body.empty?
      raise Reach::Refused, Reach::Messages.text("M-LIVE-NO-CODEBUG") if kind == "agent" && current["co_debug"] != true
      return send_now(current, kind, body) if diagnosis?(current)
      raise Reach::Refused, Reach::Messages.text("M-LIVE-ASK-BUSY") unless consent_free?(SEND_KIND)

      digest = Reach::Crypto.digest_hex(body)
      question = Reach::Consent.ask!(
        kind: SEND_KIND, subject: { "live" => current["id"], "send" => digest },
        message_id: kind == "agent" ? "M-LIVE-SEND-ASK-AGENT" : "M-LIVE-SEND-ASK", fields: { text: body }
      )
      update do |state|
        state["outgoing"] = { "key" => SecureRandom.hex(16), "kind" => kind, "text" => body, "digest" => digest, "status" => "asked", "queued_at" => stamp }
      end
      spawn_runner
      { "state" => "asking", "question" => question, "message" => Reach::Messages.text("M-LIVE-ASK-AGENT", question: question) }
    end

    def send_now(current, kind, body)
      client.post_json("/api/v1/live/#{current['id']}/messages", { "kind" => kind, "text" => body }, idempotency_key: SecureRandom.hex(16))
      { "state" => "sent", "message" => Reach::Messages.text("M-LIVE-DIAG-SENT") }
    rescue Reach::RemoteRefused => e
      raise Reach::Refused, refusal_text(e)
    end

    def wait(seconds = WAIT_MAX_S)
      off!
      limit = [[seconds.to_f, 0.0].max, WAIT_MAX_S].min
      deadline = clock + limit
      spawn_runner if live? || read_state["pending"]
      rows = []
      loop do
        state = read_state
        rows = unread(state)
        break unless rows.empty? && waiting_action(state).nil? && clock < deadline && live?

        sleep(WAIT_STEP_S)
      end
      update { |state| state["read"] = [state["read"].to_i, rows.last["seq"].to_i].max } unless rows.empty?
      current = session
      question = action_question
      view = {
        "state" => current ? current["state"] : "none", "connected" => current ? current["connected"] == true : false,
        "messages" => rows.map { |row| shown(row, diagnosis?(current)) },
        "rules" => Reach::Messages.text(diagnosis?(current) ? "M-LIVE-DIAG-RULES" : "M-LIVE-RULES"),
        "message" => Reach::Messages.text(rows.empty? ? "M-LIVE-QUIET" : (diagnosis?(current) ? "M-LIVE-DIAG-READ" : "M-LIVE-READ"))
      }
      return view if question.nil?

      view.merge("question" => question, "message" => Reach::Messages.text("M-LIVE-ASK-AGENT", question: question))
    end

    def end!
      off!
      current = session
      update { |state| state["pending"] = nil }
      raise Reach::Refused, Reach::Messages.text("M-LIVE-NONE") unless live?(current)

      response = client.post_json("/api/v1/live/#{current['id']}/end", {})
      closed = (response.json || {})["session"]
      update { |state| state["session"] = closed if closed.is_a?(Hash) }
      { "state" => "closed", "message" => Reach::Messages.text("M-LIVE-ENDED") }
    rescue Reach::RemoteRefused => e
      raise Reach::Refused, refusal_text(e)
    end

    def check_due?(state)
      wall = Time.now.to_f
      return false if state["disabled_until"].to_f > wall

      wall - state["checked_at"].to_f >= CHECK_GAP_S
    end

    def watch!
      return 0 unless wake? && install && live?

      token = SecureRandom.hex(8)
      update { |state| state["watch"] = token }
      deadline = clock + WATCH_MAX_S
      lines = []
      loop do
        return 0 unless read_state["watch"] == token

        lines = prompt_notices(nil, repeat_action: false)
        break unless lines.empty? && live? && clock < deadline

        sleep(WATCH_STEP_S)
      end
      return 0 if lines.empty?

      warn lines.join("\n\n")
      2
    rescue StandardError
      0
    end

    def notify_student(messages)
      return nil unless notify?

      newest = messages.map { |message| message["seq"].to_i }.max.to_i
      state = read_state
      return nil if newest <= state["notified"].to_i || Time.now.to_f - state["notified_at"].to_f < NOTIFY_GAP_S

      update do |fresh|
        fresh["notified"] = newest
        fresh["notified_at"] = Time.now.to_f
      end
      Reach::Desktop.notify(Reach::Messages.text("M-LIVE-NOTIFY"))
    rescue StandardError
      nil
    end

    def blocked_prompt(event)
      return nil unless blocked? && install

      text = event.is_a?(Hash) && event["prompt"].is_a?(String) ? event["prompt"] : ""
      entry = {
        "session_id" => Reach::Session.resolve_session_id(event), "gate" => "blocked", "text" => text, "seq" => nil,
        "digest" => Digest::SHA256.hexdigest(text)
      }
      lines = []
      observed = Reach::Consent.observe_blocked(entry, kinds: KINDS)
      if observed
        lines << Reach::Consent.follow_up!(observed)
      elsif text.match?(BLOCKED_END) && live?
        current = session
        update { |state| state["pending"] = { "type" => "end", "id" => current["id"], "queued_at" => stamp } }
        spawn_runner
        lines << Reach::Messages.text("M-LIVE-ENDING")
      elsif text.match?(BLOCKED_ASK) && !live? && read_state["pending"].nil? && consent_free?(KIND)
        lines << ask!["question"]
      end
      lines.concat(prompt_notices(nil, direct: true))
      lines = lines.compact.map(&:to_s).reject(&:empty?)
      lines.empty? ? nil : lines.join("\n\n")
    rescue StandardError
      nil
    end

    def prompt_notices(_session_id = nil, repeat_action: true, direct: false)
      return [] unless enabled? && install

      state = read_state
      current = state["session"].is_a?(Hash) ? state["session"] : nil
      unless runner_alive?
        if live?(current) || state["pending"] || check_due?(state)
          update { |fresh| fresh["checked_at"] = Time.now.to_f }
          spawn_runner
        end
      end

      lines = []
      told = state["told"]
      changes = {}
      unless state["refusal"].to_s.empty?
        lines << state["refusal"].to_s
        changes["refusal"] = nil
      end
      if current
        id = current["id"]
        case current["state"]
        when "offered"
          if state["offer_asked"] != id && state["pending"].nil? && consent_free?(KIND)
            question = Reach::Consent.ask!(kind: KIND, subject: { "live" => id }, message_id: "M-LIVE-OFFER-ASK")
            lines << (direct ? question : Reach::Messages.text("M-LIVE-OFFER-AGENT", question: question))
            changes["offer_asked"] = id
          end
        when "open"
          if told["open"] != id
            minutes = (left_s(current).to_i / 60.0).ceil
            opened = current["co_debug"] == true ? "M-LIVE-OPEN-AGENT-CODEBUG" : "M-LIVE-OPEN-AGENT"
            opened = "M-LIVE-DIAG-OPEN-AGENT" if diagnosis?(current)
            student = diagnosis?(current) ? "M-LIVE-DIAG-OPEN-STUDENT" : "M-LIVE-OPEN-STUDENT"
            lines << Reach::Messages.text(direct ? student : opened, minutes: minutes)
            changes["told_open"] = id
          end
          waiting = unread(state)
          newest = waiting.empty? ? 0 : waiting.last["seq"].to_i
          if newest > told["unread"].to_i
            if direct
              waiting.select { |row| row["kind"] == "note" }.each { |row| lines << Reach::Messages.text("M-LIVE-NOTE-STUDENT", text: row["text"].to_s) }
              changes["read"] = newest
            else
              lines << Reach::Messages.text("M-LIVE-UNREAD", count: waiting.length)
            end
            changes["told_unread"] = newest
          end
          asked = waiting_action(state)
          question = asked && (asked["status"] == "waiting" || consent_pending.nil?) ? action_question(state) : nil
          if question && (repeat_action || told["action"] != asked["id"])
            lines << (direct ? question : Reach::Messages.text("M-LIVE-ASK-AGENT", question: question))
            changes["told_action"] = asked["id"]
          end
        when "closed"
          if told["closed"] != id && (told["open"] == id || state["offer_asked"] == id || %w[student diagnosis].include?(current["started_by"]))
            lines << Reach::Messages.text("M-LIVE-CLOSED", reason: END_TEXT[current["end_reason"].to_s] || "it ended")
            changes["told_closed"] = id
          end
        end
      end
      unless changes.empty?
        update do |fresh|
          fresh["refusal"] = nil if changes.key?("refusal")
          fresh["offer_asked"] = changes["offer_asked"] if changes["offer_asked"]
          fresh["told"]["open"] = changes["told_open"] if changes["told_open"]
          fresh["told"]["unread"] = changes["told_unread"] if changes["told_unread"]
          fresh["told"]["closed"] = changes["told_closed"] if changes["told_closed"]
          fresh["told"]["action"] = changes["told_action"] if changes["told_action"]
          fresh["read"] = [fresh["read"].to_i, changes["read"]].max if changes["read"]
        end
      end
      lines
    rescue StandardError
      []
    end

    def send_pending(api)
      pending = read_state["pending"]
      return nil unless pending.is_a?(Hash)

      queued = begin
        Time.iso8601(pending["queued_at"].to_s)
      rescue ArgumentError
        nil
      end
      return update { |state| state["pending"] = nil } if queued.nil? || now - queued > PENDING_MAX_S

      response = if pending["type"] == "request" && pending["diagnosis"] == true
                   code = (Reach::Instructor.stored || {})["code"].to_s
                   api.post_json("/api/v1/live", { "consent" => pending["consent"], "diagnosis" => { "code" => code } })
                 elsif pending["type"] == "request"
                   api.post_json("/api/v1/live", { "hand_id" => pending["hand_id"], "consent" => pending["consent"] })
                 elsif pending["type"] == "end"
                   api.post_json("/api/v1/live/#{pending['id']}/end", {})
                 else
                   api.post_json("/api/v1/live/#{pending['id']}/consent", { "answer" => pending["answer"], "consent" => pending["consent"] })
                 end
      answered = (response.json || {})["session"]
      update do |state|
        state["pending"] = nil
        state["session"] = answered if answered.is_a?(Hash)
      end
    rescue Reach::RemoteRefused => e
      text = refusal_text(e)
      update do |state|
        state["pending"] = nil
        state["refusal"] = text
      end
    end

    def absorb(body)
      current = body["session"].is_a?(Hash) ? body["session"] : nil
      messages = Array(body["messages"]).select { |message| message.is_a?(Hash) }
      before = read_state
      previous = before["session"].is_a?(Hash) ? before["session"] : nil
      fresh_session = current && (previous.nil? || previous["id"] != current["id"])
      append_inbox(current["id"], messages) if current
      fresh_messages = messages.select { |message| message["seq"].to_i > before["after"].to_i && message["kind"] != "system" }
      notify_student(fresh_messages) if current && current["state"] == "open" && !fresh_session && !fresh_messages.empty?
      update do |state|
        if current.nil?
          state["session"] = nil if previous && previous["state"] != "closed"
        else
          if fresh_session
            state["read"] = 0
            state["after"] = 0
            state["told"]["unread"] = 0
            state["actions"] = []
            state["outgoing"] = nil
          end
          state["session"] = current
          state["after"] = [state["after"].to_i, body["next_after"].to_i].max
          known = Array(state["actions"]).map { |entry| entry["id"] }
          asked = messages.select { |message| message["kind"] == "action" && !known.include?(message["id"]) }
          state["actions"] = Array(state["actions"]) + asked.map do |message|
            name = message["name"].to_s
            known_status = current["diagnosis"] == true ? "approved" : "waiting"
            { "id" => message["id"], "name" => name, "at" => stamp, "status" => ACTIONS.include?(name) ? known_status : "unknown" }
          end
          if current["state"] == "closed"
            state["actions"] = []
            state["outgoing"] = nil
          end
        end
      end
      nil
    end

    def stale?(value)
      now - Time.iso8601(value.to_s) > ANSWER_WINDOW_S
    rescue ArgumentError
      true
    end

    def settle_actions(api, session_id)
      Array(read_state["actions"]).each do |entry|
        verdict = case entry["status"]
                  when "approved" then :run
                  when "declined" then [false, Reach::Messages.text("M-LIVE-RESULT-NO")]
                  when "unknown" then [false, Reach::Messages.text("M-LIVE-RESULT-UNKNOWN")]
                  else stale?(entry["at"]) ? [false, Reach::Messages.text("M-LIVE-RESULT-SILENT")] : nil
                  end
        next if verdict.nil?

        update { |state| state["actions"] = Array(state["actions"]).reject { |row| row["id"] == entry["id"] } }
        ok, text = verdict == :run ? run_action(entry["name"]) : verdict
        answer_action(api, session_id, entry["id"], ok, text)
      end
    end

    def settle_outgoing(api, session_id)
      entry = read_state["outgoing"]
      return nil unless entry.is_a?(Hash)
      return update { |state| state["outgoing"] = nil } if entry["status"] != "approved" && stale?(entry["queued_at"])
      return nil unless entry["status"] == "approved"

      api.post_json("/api/v1/live/#{session_id}/messages", { "kind" => entry["kind"], "text" => entry["text"] }, idempotency_key: entry["key"])
      update { |state| state["outgoing"] = nil if state["outgoing"].is_a?(Hash) && state["outgoing"]["key"] == entry["key"] }
    rescue Reach::RemoteRefused => e
      text = refusal_text(e)
      update do |state|
        state["outgoing"] = nil
        state["refusal"] = text
      end
    end

    def capture(args)
      FileUtils.mkdir_p(dir)
      exe = File.expand_path("../../exe/reach", __dir__)
      out_file = File.join(dir, "action.#{Process.pid}.out")
      pid = Process.spawn(RbConfig.ruby, exe, *args, in: File::NULL, out: out_file, err: %i[child out])
      deadline = clock + ACTION_TIMEOUT_S
      status = nil
      while clock < deadline
        _done, status = Process.wait2(pid, Process::WNOHANG)
        break if status

        sleep(0.2)
      end
      if status.nil?
        begin
          Process.kill("KILL", pid)
          Process.wait(pid)
        rescue StandardError
          nil
        end
        return [false, "reach #{args.join(' ')} did not finish in #{ACTION_TIMEOUT_S} seconds and was stopped."]
      end
      [status.success?, File.read(out_file).to_s]
    rescue StandardError => e
      [false, "reach #{args.join(' ')} could not be run (#{e.class.name})."]
    ensure
      FileUtils.rm_f(out_file) if out_file
    end

    def run_action(name)
      return [false, "This rEach does not know the action #{name.to_s[0, 40].inspect}."] unless ACTIONS.include?(name.to_s)

      if name == "cache_repair"
        count = Reach::CodexCache.repair
        return [true, "Repaired #{count} Codex plugin cache folder#{count == 1 ? '' : 's'}."]
      end

      parts = COMMANDS.fetch(name).map do |args|
        ok, text = capture(args)
        [ok, "$ reach #{args.join(' ')}\n#{text.to_s.strip}"]
      end
      [parts.all? { |ok, _text| ok }, parts.map { |_ok, text| text }.join("\n\n")]
    rescue StandardError => e
      [false, "The action could not be run (#{e.class.name})."]
    end

    def answer_action(api, session_id, action_id, ok, text)
      tail = cut(text, MAX_RESULT_BYTES)
      api.post_json(
        "/api/v1/live/#{session_id}/messages",
        { "kind" => "action_result", "action_id" => action_id, "ok" => ok, "text" => tail.empty? ? "(no output)" : tail },
        idempotency_key: "live-result-#{action_id}"
      )
    rescue Reach::RemoteRefused
      nil
    end

    def debug_on!(session_id)
      return nil if read_state["debug_for"] == session_id

      Reach::Sync.refresh_status(quick: false)
      Reach::Debug.reset!
      update { |state| state["debug_for"] = session_id }
    rescue Reach::Error
      nil
    end

    def debug_off!
      return nil if read_state["debug_for"].nil?

      Reach::Debug.flush(quick: false)
      Reach::Sync.refresh_status(quick: false)
      Reach::Debug.reset!
      update { |state| state["debug_for"] = nil }
    rescue Reach::Error
      nil
    end

    def run!
      return 0 unless enabled? && install

      FileUtils.mkdir_p(dir)
      Reach::Locks.exclusive(runner_lock_file, wait_s: 1.0) { run_loop }
      0
    end

    def run_loop
      api = client
      began = clock
      failures = 0
      flushed = 0.0
      while clock - began < MAX_RUN_S
        body = nil
        begin
          send_pending(api)
          response = api.get("/api/v1/live", query: { "after" => read_state["after"].to_i })
          body = response.json || {}
          absorb(body) unless body["disabled"] == true
          polled = body["session"].is_a?(Hash) ? body["session"] : nil
          if polled && polled["state"] == "open"
            settle_actions(api, polled["id"])
            settle_outgoing(api, polled["id"])
          end
          failures = 0
        rescue Reach::RemoteRefused => e
          update { |state| state["disabled_until"] = Time.now.to_f + DISABLED_GAP_S } if e.status == 404
          break
        rescue Reach::NetworkError
          failures += 1
          break if failures >= FAILURES_MAX

          sleep(rand * [BACKOFF_CAP_S, BACKOFF_BASE_S * (2**failures)].min)
          next
        end

        if body["disabled"] == true
          update do |state|
            state["disabled_until"] = Time.now.to_f + DISABLED_GAP_S
            state["session"] = nil
          end
          break
        end

        current = body["session"].is_a?(Hash) ? body["session"] : nil
        break if current.nil? && read_state["pending"].nil?
        break if current && current["state"] == "closed"

        if current && current["state"] == "open"
          debug_on!(current["id"])
          if clock - flushed >= DEBUG_FLUSH_S
            Reach::Debug.flush(quick: false)
            flushed = clock
          end
        end
        pace = body["poll_s"].is_a?(Numeric) ? body["poll_s"].to_f : MAX_POLL_S
        sleep([[pace, MIN_POLL_S].max, MAX_POLL_S].min + (rand * 0.5))
      end
      debug_off!
    end
  end
end
