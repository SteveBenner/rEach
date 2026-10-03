module Reach
  module Session
    HARNESSES = %w[claude-code codex hermes unknown].freeze

    module_function

    def resolve_session_id(event)
      raw = event.is_a?(Hash) ? event["session_id"].to_s : ""
      cleaned = raw.gsub(/[^A-Za-z0-9._:-]/, "_")[0, 128]
      cleaned.empty? ? "unknown-#{Time.now.utc.strftime('%Y%m%d')}" : cleaned
    end

    def resolve_harness(flag)
      return flag if flag && HARNESSES.include?(flag)
      return "claude-code" if ENV["CLAUDE_PROJECT_DIR"].to_s != ""

      "unknown"
    end
  end
end
