require "json"

module Reach
  module DueChanges
    FILE = "due-changes.json".freeze
    KEEP = 20

    module_function

    def note(status)
      current = status.is_a?(Hash) ? status["current_assignment"] : nil
      return nil unless current.is_a?(Hash) && current["id"].is_a?(String) && current["due"].is_a?(String)

      Reach::StateFile.update(FILE) do |state|
        seen = state["seen"].is_a?(Hash) ? state["seen"] : {}
        before = seen[current["id"]]
        seen[current["id"]] = current["due"]
        state["seen"] = seen
        next nil if before.nil? || same_instant?(before, current["due"])

        pending = state["pending"].is_a?(Array) ? state["pending"] : []
        pending.reject! { |entry| entry["assignment"] == current["id"] }
        pending << { "assignment" => current["id"], "before" => before, "after" => current["due"], "at" => Reach::StateFile.now_s }
        state["pending"] = pending.last(KEEP)
        current["id"]
      end
    rescue StandardError
      nil
    end

    def same_instant?(left, right)
      Time.parse(left) == Time.parse(right)
    rescue StandardError
      left == right
    end

    def prompt_notices
      pending = Reach::StateFile.update(FILE) do |state|
        waiting = state["pending"].is_a?(Array) ? state["pending"] : []
        state["pending"] = []
        waiting
      end
      Array(pending).map do |entry|
        Reach::Messages.text(
          "M-DUE-CHANGED", assignment: entry["assignment"].to_s,
                           before: Reach::Messages.course_time(entry["before"]), after: Reach::Messages.course_time(entry["after"])
        )
      end
    end
  end
end
