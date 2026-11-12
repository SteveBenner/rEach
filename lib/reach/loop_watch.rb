# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module Reach
  module LoopWatch
    DEFAULTS = {
      "enabled" => true, "prompt_repeat" => true, "reply_repeat" => true, "similarity" => 80, "min_words" => 4,
      "history" => 12, "hand_at" => 3, "alert_repeats" => 3, "alert_minutes" => 60, "reset_after_misses" => 2,
      "excerpt_chars" => 400
    }.freeze
    INTEGER_KEYS = %w[similarity min_words history hand_at alert_repeats alert_minutes reset_after_misses excerpt_chars].freeze
    REPLY_MIN_WORDS = 12
    REPLY_MAX_BYTES = 65_536
    STATE_MAX_BYTES = 262_144

    module_function

    def settings
      given = DEFAULTS.merge(Reach::BehaviorPolicy.parameters("loop_watch"))
      resolved = DEFAULTS.each_with_object({}) do |(key, default), memo|
        value = given[key]
        memo[key] = if INTEGER_KEYS.include?(key)
                      value.is_a?(Integer) && value.positive? ? value : default
                    else
                      value == false ? false : true
                    end
      end
      resolved["similarity"] = resolved["similarity"].clamp(50, 100)
      resolved
    rescue KeyError
      DEFAULTS
    rescue StandardError => e
      fault(e, "settings")
      DEFAULTS
    end

    def enabled?
      return false if ENV["REACH_LOOP_WATCH"] == "0"

      settings["enabled"] != false && Reach::Enroll.current ? true : false
    rescue StandardError => e
      fault(e, "enabled")
      false
    end

    def fault(error, where)
      Reach::Debug.fault(error, "loop_watch:#{where}")
      nil
    end

    def stamp(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def parse_time(value)
      text = value.to_s
      return nil unless text.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)

      Time.strptime(text.sub(/Z\z/, "+0000"), "%Y-%m-%dT%H:%M:%S%z")
    rescue ArgumentError
      nil
    end

    def default_state
      {
        "chain" => nil, "repeats" => 0, "misses" => 0, "recent_prompts" => [], "last_reply" => nil,
        "turn_counted" => false, "hand" => nil, "alerted_at" => nil, "updated_at" => nil
      }
    end

    def path(workspace)
      File.join(Reach::Paths.state_dir, "loop-watch", "#{File.basename(workspace)}.json")
    end

    def load(workspace)
      file = path(workspace)
      return default_state unless File.file?(file) && File.size(file) <= STATE_MAX_BYTES

      data = JSON.parse(File.read(file))
      data.is_a?(Hash) ? default_state.merge(data) : default_state
    rescue JSON::ParserError
      default_state
    end

    def save(workspace, state)
      file = path(workspace)
      FileUtils.mkdir_p(File.dirname(file))
      state["updated_at"] = stamp(Time.now)
      temp = "#{file}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate(state))
      File.rename(temp, file)
      state
    end

    def words(text)
      text.to_s.scrub.downcase.gsub(/[^\p{L}\p{N}\s]/, "").split(/\s+/).reject { |word| word.length < 2 }.uniq.sort
    end

    def similar?(first, second, percent)
      return false if !first.is_a?(Array) || !second.is_a?(Array) || first.empty? || second.empty?

      (first & second).length * 100 >= percent * (first | second).length
    end

    def reset(workspace, reason)
      return nil unless File.file?(path(workspace))

      current = load(workspace)
      return nil if current.reject { |key, _value| key == "updated_at" } == default_state.reject { |key, _value| key == "updated_at" }

      save(workspace, default_state)
      reason
    rescue StandardError => e
      fault(e, "reset")
      nil
    end

    def reset_for_hand(hand_id)
      Reach::Workspace.current_slices.each do |workspace|
        hand = load(workspace)["hand"]
        reset(workspace, "instructor_reply") if hand.is_a?(Hash) && !hand_id.nil? && hand["id"] == hand_id
      end
      nil
    rescue StandardError => e
      fault(e, "reset_for_hand")
      nil
    end

    def observe_prompt(state, prompt, config, now)
      return false unless config["prompt_repeat"]

      tokens = words(prompt)
      return false if tokens.length < config["min_words"]

      chain = state["chain"]
      percent = config["similarity"]
      matched = (chain.is_a?(Hash) && similar?(chain["tokens"], tokens, percent)) ||
                Array(state["recent_prompts"]).any? { |entry| entry.is_a?(Hash) && similar?(entry["tokens"], tokens, percent) }
      if matched
        first_at = chain.is_a?(Hash) ? chain["first_at"] : nil
        state["chain"] = { "tokens" => tokens, "first_at" => first_at || stamp(now), "last_at" => stamp(now) }
        state["repeats"] = state["repeats"].to_i + 1
        state["misses"] = 0
        state["turn_counted"] = true
      elsif chain.is_a?(Hash)
        state["misses"] = state["misses"].to_i + 1
        if state["misses"] >= config["reset_after_misses"]
          state["chain"] = nil
          state["repeats"] = 0
          state["misses"] = 0
          state["hand"] = nil
          state["alerted_at"] = nil
          state["turn_counted"] = false
        end
      end
      state["recent_prompts"] = (Array(state["recent_prompts"]) + [{ "at" => stamp(now), "tokens" => tokens }]).last(config["history"])
      matched ? true : false
    end

    def for_prompt(space:, session:, prompt:)
      return nil unless enabled?
      return nil unless space.is_a?(Hash) && space["kind"] == "slice" && space["path"] && prompt.is_a?(String)

      workspace = space["path"]
      config = settings
      now = Time.now.utc
      state = load(workspace)
      matched = observe_prompt(state, prompt, config, now)
      save(workspace, state)
      notice = evaluate(workspace, state, config, now, prompt: prompt, matched: matched)
      save(workspace, state)
      notice
    rescue StandardError => e
      fault(e, "for_prompt")
      nil
    end

    def note_reply(event)
      return nil unless enabled?

      config = settings
      return nil unless config["reply_repeat"] && event.is_a?(Hash) && event["stop_hook_active"] != true

      message = event["last_assistant_message"]
      return nil unless message.is_a?(String) && message.valid_encoding? && message.bytesize < REPLY_MAX_BYTES

      workspace = Reach::Gate.current_workspace_path
      return nil unless workspace

      now = Time.now.utc
      state = load(workspace)
      tokens = words(message)
      if tokens.length < REPLY_MIN_WORDS
        state["last_reply"] = nil
        save(workspace, state)
        return nil
      end

      previous = state["last_reply"]
      active = state["chain"].is_a?(Hash) || state["repeats"].to_i.positive? || !Array(state["recent_prompts"]).empty?
      if previous.is_a?(Hash) && similar?(previous["tokens"], tokens, config["similarity"]) && state["turn_counted"] != true && active
        state["repeats"] = state["repeats"].to_i + 1
        state["chain"] = { "tokens" => previous["tokens"], "first_at" => stamp(now), "last_at" => stamp(now) } unless state["chain"].is_a?(Hash)
      end
      state["last_reply"] = { "at" => stamp(now), "tokens" => tokens }
      state["turn_counted"] = false
      save(workspace, state)
      nil
    rescue StandardError => e
      fault(e, "note_reply")
      nil
    end

    def evaluate(workspace, state, config, now, prompt: nil, matched: false)
      repeats = state["repeats"].to_i
      hand = state["hand"]
      return nil if repeats < config["hand_at"] && !hand.is_a?(Hash)
      return raise_hand(workspace, state, config, now, prompt) if !hand.is_a?(Hash) && repeats >= config["hand_at"]
      return nil unless state["alerted_at"].nil?

      raised = parse_time(hand["at"]) || now
      hour = state["chain"].is_a?(Hash) && now - raised >= config["alert_minutes"] * 60
      due = repeats >= hand["repeats"].to_i + config["alert_repeats"] && matched
      return nil unless due || hour

      state["alerted_at"] = stamp(now)
      Reach::Messages.text("M-LOOP-ALERT", contact: Reach::Hands.contact_text)
    end

    def open_hand_id(workspace)
      ladder = Reach::Ladder.state(workspace)["hand_id"]
      return ladder if ladder

      slice = File.basename(workspace)
      found = Reach::Hands.open_hands.find { |_id, record| record.is_a?(Hash) && record["slice"] == slice }
      found ? found.first : nil
    end

    def raise_hand(workspace, state, config, now, prompt)
      repeats = state["repeats"].to_i
      existing = open_hand_id(workspace)
      if existing
        state["hand"] = { "id" => existing, "ref" => nil, "at" => stamp(now), "repeats" => repeats, "shared" => true, "queued" => false }
        return Reach::Messages.text("M-LOOP-HAND")
      end

      meta = Reach::Workspace.metadata(workspace)
      first = parse_time(state["chain"].is_a?(Hash) ? state["chain"]["first_at"] : nil) || now
      minutes = [((now - first) / 60).floor, 1].max
      excerpt = prompt.to_s.scrub[0, config["excerpt_chars"]]
      record = Reach::Hands.raise_record(
        trigger: "student_request", originator: "agent",
        summary: Reach::Messages.text("M-LOOP-HAND-SUMMARY", cutout_id: meta["cutout_id"], slice: meta["slice"], repeats: repeats),
        slice: workspace,
        details: {
          "task" => Reach::Messages.text("M-LOOP-HAND-REQUEST", request: excerpt),
          "agent_summary" => Reach::Messages.text("M-LOOP-HAND-DETAIL", repeats: repeats, minutes: minutes),
          "last_step" => nil, "saw" => nil
        }
      )
      return Reach::Hands.refused_text(record["refused"]["message"]) if record["refused"]

      if record["queued"]
        state["hand"] = { "id" => nil, "ref" => record["hand_ref"], "at" => stamp(now), "repeats" => repeats, "shared" => false, "queued" => true }
        return Reach::Messages.text("M-LOOP-HAND-QUEUED")
      end

      created = parse_time(record["created_at"]) || now
      state["hand"] = { "id" => record["hand_id"], "ref" => record["hand_ref"], "at" => stamp(created), "repeats" => repeats, "shared" => false, "queued" => false }
      Reach::Messages.text("M-LOOP-HAND")
    rescue StandardError => e
      fault(e, "raise_hand")
      nil
    end
  end
end
