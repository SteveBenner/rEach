require "securerandom"

module Reach
  module Session
    HARNESSES = %w[claude-code codex hermes unknown].freeze

    module_function

    def resolve_session_id(event)
      raw = event.is_a?(Hash) ? event["session_id"].to_s : ""
      cleaned = raw.gsub(/[^A-Za-z0-9._:-]/, "_")[0, 128]
      cleaned.empty? ? fallback_session_id : cleaned
    end

    def fallback_session_id
      @fallback_session_id ||= "unknown-#{Time.now.utc.strftime('%Y%m%d')}-#{Process.pid}-#{SecureRandom.hex(4)}"
    end

    CODEX_ENV_KEYS = %w[CODEX_THREAD_ID CODEX_SESSION_ID CODEX_SHELL].freeze

    def codex_env?
      CODEX_ENV_KEYS.any? { |key| ENV[key].to_s != "" }
    end

    def detect_harness
      return "codex" if codex_env?
      return "claude-code" if ENV["CLAUDE_CODE_ENTRYPOINT"].to_s != ""
      return "codex" if ENV["PLUGIN_ROOT"].to_s != "" && ENV["CLAUDE_PROJECT_DIR"].to_s.empty?
      return "claude-code" if ENV["CLAUDE_PLUGIN_ROOT"].to_s != "" || ENV["CLAUDE_PROJECT_DIR"].to_s != ""
      return "hermes" if ENV["HERMES_HOME"].to_s != ""

      "unknown"
    end

    def resolve_harness(flag)
      return flag if flag && HARNESSES.include?(flag)

      detect_harness
    end
  end
end
