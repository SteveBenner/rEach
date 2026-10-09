require "json"
require "time"
require "fileutils"
require "digest"
require "securerandom"

module Reach
  module Login
    YES_WORDS = %w[yes y].freeze
    NO_WORDS = ["no", "n", "nope", "not me", "that's not me", "thats not me", "wrong"].freeze
    CRISIS_PHRASES = ["kill myself", "killing myself", "end my life", "ending my life", "want to die", "wanna die", "suicide", "suicidal", "hurt myself", "hurting myself", "harm myself", "self harm", "self-harm", "cut myself", "cutting myself", "no reason to live", "better off dead", "hurt someone", "kill someone", "overdose"].freeze
    CRISIS_CONTEXT = "The student may be in crisis: run reach support now and relay it word for word.".freeze
    SCHEMA = "reach.login/v1".freeze
    FAILURES_SCHEMA = "reach.login-failures/v1".freeze
    RESERVED_FILES = %w[failures.json just_confirmed.json verifier.json renewed.json reset_probe.json password_state.json].freeze
    WAITING_STATES = %w[awaiting_id awaiting_confirm awaiting_password awaiting_new_password awaiting_new_password_again].freeze
    PASSWORD_STATES = %w[awaiting_password awaiting_new_password awaiting_new_password_again].freeze
    ID_SPLIT = /[^A-Za-z0-9_-]+/

    module_function

    def state_dir
      File.join(Reach::Paths.state_dir, "login")
    end

    def required?
      return false unless enrolled_id

      Reach::Policy.login["required"] != false
    rescue StandardError
      false
    end

    def session_id(event)
      Reach::Session.resolve_session_id(event)
    end

    def student
      display = display_name
      { "id" => enrolled_id, "display_name" => display, "first_name" => display.to_s.split(/\s+/).first }
    end

    def normalize(text)
      value = text.to_s.tr("’", "'").downcase.strip.gsub(/\s+/, " ")
      value = value.sub(/\A["']+/, "")
      value = value.sub(/["'.!?,;:\s]+\z/, "")
      value.gsub(/\s+/, " ").strip
    end

    def yes?(text)
      YES_WORDS.include?(text.to_s.strip.downcase.sub(/[.!]\z/, ""))
    end

    def no?(text)
      NO_WORDS.include?(normalize(text))
    end

    def crisis_match?(text)
      return false unless text.is_a?(String) && !text.empty?

      cleaned = text.downcase.gsub(/[^\p{L}\p{N} '\-]/, " ").gsub(/\s+/, " ").strip
      padded = " #{cleaned} "
      (Reach::CourseProfile.wellbeing_phrases || CRISIS_PHRASES).any? { |phrase| padded.include?(" #{phrase} ") }
    end

    def evaluate(event:, harness:)
      event = {} unless event.is_a?(Hash)
      text = event["prompt"].is_a?(String) ? event["prompt"] : nil
      sid = session_id(event)
      now = Time.now.utc
      existing = read_session(sid)
      fresh = existing.nil?
      state = existing || fresh_state(sid, harness)
      crisis = crisis_match?(text)
      confirmed = confirmed_state?(state, now)

      if crisis && !confirmed
        return decision("block", Reach::Support.message(told: :queued), "support", nil, state, crisis: true, persist: false)
      end

      return decision("pass", nil, nil, crisis ? CRISIS_CONTEXT : nil, state, crisis: crisis, persist: false) if confirmed

      if state["state"] == "confirmed"
        state = state.merge("state" => "awaiting_id", "updated_at" => iso(now))
        return decision("block", Reach::Messages.text("M-LOGIN-ASK"), "login", nil, state, persist: true)
      end

      failures = failures_data
      window = window_failures(failures, now)
      locked = locked_remaining(failures, now)
      if locked
        freed = teach_unlock(state, failures, now, harness)
        return freed if freed

        return decision("block", Reach::Messages.text("M-LOGIN-LOCKED", minutes: locked), "login", nil, state, persist: false).merge("stuck" => true)
      end

      return decision("block", Reach::Messages.text("M-LOGIN-DENIED"), "login", nil, state, persist: false).merge("stuck" => true) if state["state"] == "denied"

      if state["state"] == "awaiting_confirm"
        return evaluate_confirm(text, state, now, harness)
      end
      if PASSWORD_STATES.include?(state["state"])
        return password_terminal(state) if harness.to_s == "hermes"
        return evaluate_password(text, state, failures, window, now, harness) if state["state"] == "awaiting_password"

        return evaluate_new_password(text, state, now)
      end

      evaluate_id(text, state, fresh, failures, window, now, harness)
    rescue StandardError
      decision("block", Reach::Messages.text("M-LOGIN-ASK"), "login", nil, { "state" => "awaiting_id" }, persist: false)
    end

    def evaluate_confirm(text, state, now, harness)
      if yes?(text)
        if Reach::Password.required?
          return reset_required_decision(state, now, harness) if Reach::Password.pickup == :required

          next_state = state.merge("state" => "awaiting_password", "updated_at" => iso(now))
          return password_terminal(next_state, persist: true) if harness.to_s == "hermes"

          return decision("block", Reach::Messages.text("M-LOGIN-ASK-PASSWORD"), "login", nil, next_state, persist: true)
        end
        confirm(state, now, "M-LOGIN-OK")
      elsif no?(text)
        next_state = state.merge("state" => "denied", "denied_at" => precise(now), "updated_at" => iso(now))
        out = decision("block", Reach::Messages.text("M-LOGIN-DENIED"), "login", nil, next_state, persist: true)
        out["events"] = [["identity_denied", { "session_id" => state["session_id"], "harness" => harness.to_s }]]
        out
      else
        decision("block", confirm_text, "login", nil, state, persist: false)
      end
    end

    def teach_unlock(state, failures, now, harness)
      return nil if state["state"] == "denied" || !Reach::Password.required?
      return nil unless Reach::Password.reset_allowed_cached == :allowed

      Reach::Password.drop_probe!
      lifted = Reach::Messages.text("M-LOGIN-UNLOCKED-BY-TEACH")
      if PASSWORD_STATES.include?(state["state"])
        Reach::Password.drop! if Reach::Password.reset_required?
        next_state = without_reset(state).merge("state" => "awaiting_new_password", "reset_required" => Reach::Password.reset_required?, "updated_at" => iso(now))
        prompt = if harness.to_s == "hermes"
          Reach::Messages.text("M-LOGIN-PASSWORD-TERMINAL", command: Reach::Runtime.hook_command("login", "password"))
        else
          Reach::Messages.text("M-LOGIN-RESET-NEW")
        end
        out = decision("block", "#{lifted}\n\n#{prompt}", "login", nil, next_state, persist: true)
      elsif state["state"] == "awaiting_confirm"
        out = decision("block", "#{lifted}\n\n#{confirm_text}", "login", nil, state, persist: false)
      else
        next_state = state.merge("state" => "awaiting_id", "updated_at" => iso(now))
        out = decision("block", "#{lifted}\n\n#{Reach::Messages.text("M-LOGIN-ASK")}", "login", nil, next_state, persist: true)
      end
      out["failures_data"] = failures.merge("failures" => [], "locked_until" => nil)
      out
    rescue StandardError
      nil
    end

    def lift_lockout_for_reset
      data = failures_data
      return nil unless locked_remaining(data, Time.now.utc)

      Reach::Password.drop_probe!
      clear_failures
      Reach::Messages.text("M-LOGIN-UNLOCKED-BY-TEACH")
    end

    def reset_required_decision(state, now, harness)
      Reach::Password.drop!
      next_state = without_reset(state).merge("state" => "awaiting_new_password", "reset_required" => true, "updated_at" => iso(now))
      text = harness.to_s == "hermes" ? Reach::Messages.text("M-LOGIN-PASSWORD-TERMINAL", command: Reach::Runtime.hook_command("login", "password")) : Reach::Messages.text("M-LOGIN-RESET-REQUIRED")
      decision("block", text, "login", nil, next_state, persist: true)
    end

    def require_reset_sessions(states, now)
      Reach::Password.drop!
      states.each do |held|
        write_session(held["session_id"], without_reset(held).merge("state" => "awaiting_new_password", "reset_required" => true, "updated_at" => iso(now)))
      end
    end

    def confirmed_session_state(state, now)
      without_reset(state).reject { |key, _| key == "reset_required" }.merge(
        "state" => "confirmed", "confirmed_at" => precise(now), "expires_at" => iso(now + (max_hours * 3600)),
        "updated_at" => iso(now)
      )
    end

    def sign_in_session(sid, harness)
      state = read_session(sid) || fresh_state(sid, harness)
      write_session(sid, confirmed_session_state(state, Time.now.utc).merge("session_id" => sid, "harness" => harness.to_s))
      add_just_confirmed(sid)
      sid
    end

    def waiting_session
      sessions.select { |state| WAITING_STATES.include?(state["state"]) }.max_by { |state| state["updated_at"].to_s }
    end

    def clear_lockouts
      data = failures_data
      cleared = { "login_failures" => !Array(data["failures"]).empty?, "login_lockout" => !locked_remaining(data, Time.now.utc).nil? }
      clear_failures if cleared["login_failures"] || data["locked_until"]
      cleared
    end

    def confirm(state, now, message_id)
      next_state = confirmed_session_state(state, now)
      out = decision("block", Reach::Messages.text(message_id, first_name: student["first_name"] || "there"), "login", nil, next_state, persist: true)
      out["confirmed_now"] = true
      out
    end

    def without_reset(state)
      state.reject { |key, _| key == "password_salt" || key == "password_sha256" }
    end

    def password_terminal(state, persist: false)
      text = Reach::Messages.text("M-LOGIN-PASSWORD-TERMINAL", command: Reach::Runtime.hook_command("login", "password"))
      decision("block", text, "login", nil, state, persist: persist)
    end

    def evaluate_password(text, state, failures, window, now, harness)
      if Reach::Password.forgot?(text)
        return decision("block", Reach::Messages.text("M-LOGIN-RESET-BY-INSTRUCTOR"), "login", nil, state, persist: false)
      end
      return reset_required_decision(state, now, harness) if Reach::Password.reset_required?

      case Reach::Password.check(Reach::Password.trimmed(text))
      when :ok then confirm(state, now, "M-LOGIN-OK")
      when :unset then reset_required_decision(state, now, harness)
      when :wrong then failed(state, failures, window, now, harness, "M-LOGIN-PASSWORD-WRONG")
      when :limited then decision("block", Reach::Messages.text("M-LOGIN-LOCKED", minutes: lockout_minutes), "login", nil, state, persist: false)
      else decision("block", Reach::Messages.text("M-LOGIN-PASSWORD-OFFLINE"), "login", nil, state, persist: false)
      end
    end

    def evaluate_new_password(text, state, now)
      if Reach::Password.cancel?(text)
        if state["reset_required"] || Reach::Password.reset_required?
          return decision("block", Reach::Messages.text("M-LOGIN-RESET-REQUIRED"), "login", nil, state, persist: false)
        end

        next_state = without_reset(state).merge("state" => "awaiting_password", "updated_at" => iso(now))
        return decision("block", Reach::Messages.text("M-LOGIN-ASK-PASSWORD"), "login", nil, next_state, persist: true)
      end

      password = Reach::Password.trimmed(text)
      if state["state"] == "awaiting_new_password"
        return decision("block", Reach::Messages.text("M-ENR-PASSWORD-SHORT"), "login", nil, state, persist: false) unless Reach::Password.range?(password)

        salt = SecureRandom.hex(16)
        next_state = state.merge(
          "state" => "awaiting_new_password_again", "password_salt" => salt,
          "password_sha256" => Reach::EnrollFlow.password_digest(salt, password), "updated_at" => iso(now)
        )
        return decision("block", Reach::Messages.text("M-LOGIN-RESET-AGAIN"), "login", nil, next_state, persist: true)
      end

      stored = state["password_sha256"].to_s
      again = without_reset(state).merge("state" => "awaiting_new_password", "updated_at" => iso(now))
      unless !stored.empty? && Reach::EnrollFlow.digest_equal?(Reach::EnrollFlow.password_digest(state["password_salt"], password), stored)
        return decision("block", Reach::Messages.text("M-LOGIN-RESET-MISMATCH"), "login", nil, again, persist: true)
      end

      case Reach::Password.reset!(password)
      when :ok then confirm(state, now, "M-LOGIN-RESET-OK")
      when :not_allowed
        back = without_reset(state).merge("state" => "awaiting_password", "updated_at" => iso(now))
        decision("block", Reach::Messages.text("M-LOGIN-RESET-BY-INSTRUCTOR"), "login", nil, back, persist: true)
      else decision("block", Reach::Messages.text("M-LOGIN-RESET-OFFLINE"), "login", nil, again, persist: true)
      end
    end

    def terminal_password(password)
      now = Time.now.utc
      failures = failures_data
      locked = locked_remaining(failures, now)
      return [false, Reach::Messages.text("M-LOGIN-LOCKED", minutes: locked)] if locked

      waiting = sessions.select { |state| state["state"] == "awaiting_password" }
      return [false, Reach::Messages.text("M-LOGIN-TERMINAL-NONE")] if waiting.empty?

      case Reach::Password.check(Reach::Password.trimmed(password))
      when :unset
        require_reset_sessions(waiting, now)
        [false, Reach::Messages.text("M-LOGIN-RESET-REQUIRED")]
      when :ok
        waiting.each do |state|
          out = confirm(state, now, "M-LOGIN-OK")
          write_session(state["session_id"], out["state"])
          add_just_confirmed(state["session_id"])
        end
        clear_failures
        Reach::Progress.mark("setup.signin")
        [true, Reach::Messages.text("M-LOGIN-TERMINAL-OK")]
      when :wrong
        out = failed(waiting.first, failures, window_failures(failures, now), now, "cli", "M-LOGIN-PASSWORD-WRONG-TERMINAL")
        commit!(out, event: { "session_id" => waiting.first["session_id"] }, harness: waiting.first["harness"])
        [false, out["message"]]
      when :limited then [false, Reach::Messages.text("M-LOGIN-LOCKED", minutes: lockout_minutes)]
      else [false, Reach::Messages.text("M-LOGIN-PASSWORD-OFFLINE-TERMINAL")]
      end
    end

    def terminal_signin(id_text, password)
      now = Time.now.utc
      failures = failures_data
      locked = locked_remaining(failures, now)
      return [false, Reach::Messages.text("M-LOGIN-LOCKED", minutes: locked)] if locked

      sid = "terminal-#{SecureRandom.hex(8)}"
      unless contains_id?(id_text)
        out = failed(fresh_state(sid, "cli"), failures, window_failures(failures, now), now, "cli", "M-LOGIN-WRONG")
        commit!(out, event: { "session_id" => sid }, harness: "cli")
        return [false, out["message"]]
      end

      case Reach::Password.check(Reach::Password.trimmed(password))
      when :unset
        held = fresh_state(sid, "cli").merge("session_id" => sid)
        require_reset_sessions([held], now)
        [false, Reach::Messages.text("M-LOGIN-RESET-REQUIRED")]
      when :ok
        sign_in_session(sid, "cli")
        clear_failures
        Reach::Progress.mark("setup.signin")
        [true, Reach::Messages.text("M-LOGIN-OK", first_name: student["first_name"] || "there")]
      when :wrong
        out = failed(fresh_state(sid, "cli"), failures, window_failures(failures, now), now, "cli", "M-LOGIN-PASSWORD-WRONG-TERMINAL")
        commit!(out, event: { "session_id" => sid }, harness: "cli")
        [false, out["message"]]
      when :limited then [false, Reach::Messages.text("M-LOGIN-LOCKED", minutes: lockout_minutes)]
      else [false, Reach::Messages.text("M-LOGIN-PASSWORD-OFFLINE-TERMINAL")]
      end
    end

    def terminal_reset
      waiting = sessions.select { |state| PASSWORD_STATES.include?(state["state"]) }
      return [:none, Reach::Messages.text("M-LOGIN-TERMINAL-NONE")] if waiting.empty?

      return [:allowed, lift_lockout_for_reset] if Reach::Password.reset_required?

      case Reach::Password.reset_allowed
      when :allowed then [:allowed, lift_lockout_for_reset]
      when :not_allowed then [:refused, Reach::Messages.text("M-LOGIN-RESET-BY-INSTRUCTOR")]
      else [:refused, Reach::Messages.text("M-LOGIN-PASSWORD-OFFLINE-TERMINAL")]
      end
    end

    def terminal_new_password(password)
      now = Time.now.utc
      case Reach::Password.reset!(password)
      when :ok
        sessions.select { |state| PASSWORD_STATES.include?(state["state"]) }.each do |state|
          out = confirm(state, now, "M-LOGIN-OK")
          write_session(state["session_id"], out["state"])
          add_just_confirmed(state["session_id"])
        end
        clear_failures
        Reach::Progress.mark("setup.signin")
        [true, Reach::Messages.text("M-LOGIN-TERMINAL-RESET-OK")]
      when :not_allowed then [false, Reach::Messages.text("M-LOGIN-RESET-BY-INSTRUCTOR")]
      else [false, Reach::Messages.text("M-LOGIN-PASSWORD-OFFLINE-TERMINAL")]
      end
    end

    def evaluate_id(text, state, fresh, failures, window, now, harness)
      if contains_id?(text)
        next_state = state.merge("state" => "awaiting_confirm", "updated_at" => iso(now))
        return decision("block", confirm_text, "login", nil, next_state, persist: true)
      end

      if fresh
        next_state = state.merge("state" => "awaiting_id", "updated_at" => iso(now))
        return decision("block", Reach::Messages.text("M-LOGIN-ASK"), "login", nil, next_state, persist: true)
      end

      failed(state, failures, window, now, harness, "M-LOGIN-WRONG")
    end

    def failed(state, failures, window, now, harness, message_id)
      recent = window + [iso(now)]
      if recent.length >= lockout_failures
        minutes = lockout_minutes
        data = failures.merge("failures" => recent, "locked_until" => iso(now + (minutes * 60)))
        out = decision("block", Reach::Messages.text("M-LOGIN-LOCKED", minutes: minutes), "login", nil, state, persist: false)
        out["failures_data"] = data
        out["events"] = [["login_failed", { "session_id" => state["session_id"], "failures" => recent.length, "harness" => harness.to_s }]]
        return out
      end

      out = decision("block", Reach::Messages.text(message_id), "login", nil, state, persist: false)
      out["failures_data"] = failures.merge("failures" => recent, "locked_until" => nil)
      out
    end

    def claim(event:, harness:)
      event = {} unless event.is_a?(Hash)
      sid = session_id(event)
      turn = event["turn_id"].to_s
      return step!(event, harness) if turn.empty?

      key = Digest::SHA256.hexdigest("#{sid}\n#{turn}")
      turns = File.join(state_dir, "turns")
      FileUtils.mkdir_p(turns)
      name = sid.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
      path = File.join(turns, "#{name}.json")
      result = Reach::Locks.exclusive(File.join(turns, "#{name}.lock")) do
        held = read_json(path)
        if held.is_a?(Hash) && held["turn"] == key
          :elsewhere
        elsif session_confirmed?(sid)
          step!(event, harness)
        else
          write_json(path, "turn" => key, "at" => iso(Time.now.utc))
          step!(event, harness)
        end
      end
      result == :busy ? :elsewhere : result
    end

    def step!(event, harness)
      out = evaluate(event: event, harness: harness)
      commit!(out, event: event, harness: harness)
      out
    end

    def commit!(decision, event:, harness:)
      event = {} unless event.is_a?(Hash)
      sid = session_id(event)
      state = decision["state"]
      if decision["persist"] && state.is_a?(Hash)
        write_session(sid, state.merge("session_id" => sid, "harness" => harness.to_s))
      end
      if decision["failures_data"]
        write_json(File.join(state_dir, "failures.json"), decision["failures_data"])
      end
      if decision["confirmed_now"]
        clear_failures
        add_just_confirmed(sid)
        Reach::Progress.mark("setup.signin")
      end
      Array(decision["events"]).each { |kind, detail| queue_event(sid, kind, detail) }
      if decision["crisis"] && !confirmed_state?(state.is_a?(Hash) ? state : {}, Time.now.utc)
        begin
          Reach::Support.queue_from_hook!(harness: harness, space: Reach::Gate.current_space)
        rescue StandardError
          nil
        end
      end
      nil
    rescue StandardError
      nil
    end

    def session_confirmed?(session_id)
      state = read_session(session_id)
      !state.nil? && confirmed_state?(state, Time.now.utc)
    rescue StandardError
      false
    end

    def any_active?
      now = Time.now.utc
      hours = max_hours
      latest_confirmed = nil
      latest_denied = nil
      sessions.each do |state|
        if state["state"] == "confirmed" && state["confirmed_at"]
          at = Time.iso8601(state["confirmed_at"])
          next if now - at > hours * 3600

          latest_confirmed = at if latest_confirmed.nil? || at > latest_confirmed
        elsif state["state"] == "denied" && state["denied_at"]
          at = Time.iso8601(state["denied_at"])
          latest_denied = at if latest_denied.nil? || at > latest_denied
        end
      end
      return false unless latest_confirmed

      latest_denied.nil? || latest_denied < latest_confirmed
    rescue StandardError
      false
    end

    SESSION_ENV_KEYS = %w[CODEX_THREAD_ID CODEX_SESSION_ID CLAUDE_CODE_SESSION_ID].freeze

    def current_session_id
      hooked = Reach::EnrollmentLock.pass_session
      return hooked unless hooked.to_s.empty?

      SESSION_ENV_KEYS.each do |key|
        value = ENV[key].to_s
        return Reach::Session.resolve_session_id("session_id" => value) unless value.empty?
      end
      nil
    end

    def require_active!(session_id: current_session_id)
      return unless required?
      return if session_id.to_s.empty? ? any_active? : session_confirmed?(session_id)

      raise Reach::Refused, Reach::Messages.text("M-LOGIN-NEEDED")
    end

    def just_confirmed?(session_id)
      data = read_json(File.join(state_dir, "just_confirmed.json"))
      ids = data.is_a?(Hash) ? Array(data["session_ids"]) : []
      ids.include?(session_id)
    rescue StandardError
      false
    end

    def clear_just_confirmed(session_id)
      path = File.join(state_dir, "just_confirmed.json")
      data = read_json(path)
      ids = data.is_a?(Hash) ? Array(data["session_ids"]) : []
      return false unless ids.include?(session_id)

      write_json(path, "session_ids" => ids - [session_id])
      true
    rescue StandardError
      false
    end

    def last_session_state
      sessions.max_by { |state| state["updated_at"].to_s }
    rescue StandardError
      nil
    end

    def enrolled_id
      install = Reach::Enroll.current
      install && install["student_id"]
    rescue StandardError
      nil
    end

    def display_name
      status = begin
        Reach::Sync.cached_status
      rescue StandardError
        nil
      end
      name = status && status["student"].is_a?(Hash) ? status["student"]["display_name"] : nil
      return name.to_s unless name.to_s.empty?

      install = Reach::Enroll.current || {}
      fallback = install["display_name"] || (install["student"].is_a?(Hash) ? install["student"]["display_name"] : nil)
      fallback.to_s.empty? ? nil : fallback.to_s
    rescue StandardError
      nil
    end

    def confirm_text
      Reach::Messages.text("M-LOGIN-CONFIRM", name: display_name || "the enrolled student")
    end

    def contains_id?(text)
      id = enrolled_id.to_s.downcase
      return false if id.empty? || !text.is_a?(String)

      text.split(ID_SPLIT).any? { |token| token.downcase == id }
    end

    def decision(action, message, note, context, state, crisis: false, persist: false)
      {
        "action" => action, "message" => message, "note" => note, "context" => context,
        "state" => state, "crisis" => crisis, "persist" => persist
      }
    end

    def fresh_state(sid, harness)
      {
        "schema" => SCHEMA, "student_id" => enrolled_id, "session_id" => sid, "harness" => harness.to_s,
        "state" => "awaiting_id", "confirmed_at" => nil, "expires_at" => nil, "denied_at" => nil, "updated_at" => nil
      }
    end

    def confirmed_state?(state, now)
      return false unless state.is_a?(Hash) && state["state"] == "confirmed" && state["expires_at"]

      Time.iso8601(state["expires_at"]) > now
    rescue ArgumentError
      false
    end

    def max_hours
      value = Reach::Policy.login["max_hours"].to_i
      value.positive? ? value : 12
    end

    def lockout_failures
      value = Reach::Policy.login["lockout_failures"].to_i
      value.positive? ? value : 3
    end

    def lockout_minutes
      value = Reach::Policy.login["lockout_minutes"].to_i
      value.positive? ? value : 15
    end

    def failures_data
      data = read_json(File.join(state_dir, "failures.json"))
      data = {} unless data.is_a?(Hash) && data["student_id"] == enrolled_id
      {
        "schema" => FAILURES_SCHEMA, "student_id" => enrolled_id, "failures" => Array(data["failures"]),
        "locked_until" => data["locked_until"], "reported_sessions" => Array(data["reported_sessions"])
      }
    end

    def window_failures(data, now)
      cutoff = now - (lockout_minutes * 60)
      Array(data["failures"]).select do |stamp|
        Time.iso8601(stamp) > cutoff
      rescue ArgumentError
        false
      end
    end

    def locked_remaining(data, now)
      return nil unless data["locked_until"]

      until_time = Time.iso8601(data["locked_until"])
      return nil unless until_time > now

      ((until_time - now) / 60.0).ceil
    rescue ArgumentError
      nil
    end

    def clear_failures
      data = failures_data
      write_json(File.join(state_dir, "failures.json"), data.merge("failures" => [], "locked_until" => nil))
    end

    def add_just_confirmed(sid)
      path = File.join(state_dir, "just_confirmed.json")
      data = read_json(path)
      ids = data.is_a?(Hash) ? Array(data["session_ids"]) : []
      write_json(path, "session_ids" => (ids + [sid]).uniq)
    end

    def queue_event(sid, kind, detail)
      data = failures_data
      reported = data["reported_sessions"]
      key = "#{kind}:#{sid}"
      return if reported.include?(key)

      queued = Reach::Integrity.queue(kind, detail: detail, once: false)
      return unless queued

      write_json(File.join(state_dir, "failures.json"), data.merge("reported_sessions" => (reported + [key]).last(500)))
    end

    def session_path(sid)
      File.join(state_dir, "#{sid.to_s.gsub(/[^A-Za-z0-9._:-]/, '_')}.json")
    end

    def read_session(sid)
      data = read_json(session_path(sid))
      return nil unless data.is_a?(Hash) && data["schema"] == SCHEMA
      return nil unless data["student_id"] == enrolled_id

      data
    end

    def write_session(sid, state)
      write_json(session_path(sid), state.merge("schema" => SCHEMA, "student_id" => enrolled_id))
    end

    def sessions
      return [] unless File.directory?(state_dir)

      Dir.glob(File.join(state_dir, "*.json")).map do |path|
        next nil if RESERVED_FILES.include?(File.basename(path))

        data = read_json(path)
        data.is_a?(Hash) && data["schema"] == SCHEMA && data["student_id"] == enrolled_id ? data : nil
      end.compact
    end

    def read_json(path)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end

    def write_json(path, data)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      begin
        File.chmod(0o700, dir)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      Reach::StateFile.rename_into_place(tmp, path)
      path
    end

    def precise(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    def iso(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
