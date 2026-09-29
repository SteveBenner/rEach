require "json"
require "time"
require "fileutils"

module Reach
  module Ladder
    NOTICE_FROM = 2
    HAND_AT = 3
    HARD_STOP = 10
    HISTORY_LIMIT = 20

    module_function

    def state_path(workspace)
      File.join(Reach::Paths.state_dir, "ladder", "#{File.basename(workspace)}.json")
    end

    def state(workspace)
      path = state_path(workspace)
      data = File.file?(path) ? JSON.parse(File.read(path)) : {}
      data.is_a?(Hash) ? default_state.merge(data) : default_state
    rescue JSON::ParserError
      default_state
    end

    def default_state
      { "failed" => 0, "history" => [], "hand_id" => nil, "hand_ref" => nil, "hand_created_at" => nil, "consent_at" => nil }
    end

    def save(workspace, data)
      path = state_path(workspace)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(data.merge("updated_at" => now)))
      data
    end

    def now
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def next_attempt(workspace)
      state(workspace)["failed"].to_i + 1
    end

    def blocked_message(workspace)
      current = state(workspace)
      failed = current["failed"].to_i
      return "M-LADDER-STOPPED" if failed >= HARD_STOP
      return "M-LADDER-ASK" if failed >= HAND_AT && current["consent_at"].nil?

      nil
    end

    def continue_notice(workspace)
      current = state(workspace)
      failed = current["failed"].to_i
      return nil unless failed >= HAND_AT && failed < HARD_STOP && current["consent_at"]

      Reach::Messages.text("M-LADDER-CONTINUE", attempt: failed + 1, limit: HARD_STOP)
    end

    def record(workspace, record)
      current = state(workspace)
      if record["passed"]
        reset!(workspace, "pass")
        return { "failed" => 0, "rung" => "passed", "message_id" => nil, "message" => nil }
      end

      failed = current["failed"].to_i + 1
      history = Array(current["history"]) + [{
        "n" => record["attempt"], "at" => record["at"], "passed" => false,
        "steps" => failed_steps(record), "files_digest" => record["files_digest"]
      }]
      current = current.merge("failed" => failed, "history" => history.last(HISTORY_LIMIT))
      save(workspace, current)

      if failed >= HARD_STOP
        witness(workspace, failed, "stopped")
        return rung(failed, "stopped", "M-LADDER-STOPPED")
      end

      if failed == HAND_AT
        hand = raise_ladder_hand(workspace, record, current)
        witness(workspace, failed, "hand")
        return rung(failed, "hand", "M-LADDER-HAND").merge("hand_id" => hand && hand["hand_id"])
      end

      if failed > HAND_AT
        return rung(failed, "continue", nil)
      end

      if failed >= NOTICE_FROM
        witness(workspace, failed, "notice")
        return rung(failed, "notice", "M-LADDER-NOTICE")
      end

      rung(failed, "silent", nil)
    end

    def rung(failed, name, message_id)
      text = message_id ? Reach::Messages.text(message_id, attempt: failed, limit: HARD_STOP) : nil
      { "failed" => failed, "rung" => name, "message_id" => message_id, "message" => text }
    end

    def failed_steps(record)
      steps = record["steps"].is_a?(Hash) ? record["steps"] : {}
      steps.select { |_id, step| step["ran"] && !step["passed"] }.keys
    end

    def raise_ladder_hand(workspace, record, current)
      meta = Reach::Workspace.metadata(workspace)
      summary = "The AI partner could not get #{meta['cutout_id']} (#{meta['slice']}) to pass its checks after #{HAND_AT} tries."
      hand = Reach::Hands.raise_record(
        trigger: "attempt_ladder", originator: "agent", summary: summary, slice: workspace,
        details: {
          "task" => record["task"], "agent_summary" => record["agent_summary"],
          "qualification" => record, "history" => current["history"]
        }
      )
      save(workspace, state(workspace).merge(
        "hand_id" => hand && hand["hand_id"], "hand_ref" => hand && hand["hand_ref"],
        "hand_created_at" => hand ? hand["created_at"] : now, "consent_at" => nil
      ))
      hand
    rescue StandardError
      save(workspace, state(workspace).merge("hand_created_at" => now, "consent_at" => nil))
      nil
    end

    def continue!(workspace)
      current = state(workspace)
      failed = current["failed"].to_i
      raise Reach::Refused, Reach::Messages.text("M-LADDER-STOPPED", attempt: failed, limit: HARD_STOP) if failed >= HARD_STOP
      raise Reach::Refused, Reach::Messages.text("M-LADDER-NOT-NEEDED") if failed < HAND_AT
      return current if current["consent_at"]

      since = current["hand_created_at"].to_s
      unless student_prompt_since?(workspace, since)
        raise Reach::Refused, Reach::Messages.text("M-LADDER-ASK", attempt: failed, limit: HARD_STOP)
      end

      updated = save(workspace, current.merge("consent_at" => now))
      witness(workspace, failed, "consent")
      updated
    end

    def reset!(workspace, reason)
      current = state(workspace)
      return current if current["failed"].to_i.zero? && current["hand_id"].nil?

      witness(workspace, 0, "reset")
      save(workspace, default_state.merge("reset_reason" => reason))
    end

    def reset_for_hand(hand_id)
      return if hand_id.nil?

      Reach::Workspace.current_slices.each do |workspace|
        reset!(workspace, "instructor_reply") if state(workspace)["hand_id"] == hand_id
      end
    rescue StandardError
      nil
    end

    def student_prompt_since?(workspace, since)
      meta = Reach::Workspace.metadata(workspace)
      Dir.glob(File.join(Reach::Paths.transcripts_dir, "*.jsonl")).any? do |path|
        next false if path.end_with?(".rejected.jsonl")

        File.foreach(path).any? do |line|
          entry = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          entry.is_a?(Hash) && entry["kind"] == "prompt" && entry["gate"] == "allowed" &&
            !entry["text"].to_s.strip.empty? && entry["cutout_id"] == meta["cutout_id"] &&
            entry["slice"] == meta["slice"] && entry["at"].to_s > since
        end
      end
    rescue StandardError
      false
    end

    def last_student_prompt(workspace)
      meta = Reach::Workspace.metadata(workspace)
      latest = nil
      Dir.glob(File.join(Reach::Paths.transcripts_dir, "*.jsonl")).each do |path|
        next if path.end_with?(".rejected.jsonl")

        File.foreach(path) do |line|
          entry = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          next unless entry.is_a?(Hash) && entry["kind"] == "prompt" && entry["cutout_id"] == meta["cutout_id"] && entry["slice"] == meta["slice"]
          next if entry["text"].to_s.strip.empty?

          latest = entry if latest.nil? || entry["at"].to_s >= latest["at"].to_s
        end
      end
      latest && latest["text"]
    rescue StandardError
      nil
    end

    def witness(workspace, failed, action)
      Reach::Ledger.append(workspace, "ladder", "failed" => failed, "action" => action)
    rescue StandardError
      nil
    end
  end
end
