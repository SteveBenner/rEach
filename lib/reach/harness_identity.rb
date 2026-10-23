# SPDX-License-Identifier: MIT

require "json"
require "time"
require "fileutils"

module Reach
  module HarnessIdentity
    CONFIDENCES = %w[verified inferred weak].freeze
    SESSIONS_MAX = 64
    SESSIONS_DAYS = 14
    SESSION_ENV_KEYS = %w[CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID].freeze
    SKIPPED_LABELS = ["terminal", "unknown"].freeze

    module_function

    def sessions_file
      File.join(Reach::Paths.root_state_dir, "harness_sessions.json")
    end

    def usable_label?(label)
      text = label.to_s
      !text.empty? && !SKIPPED_LABELS.include?(text)
    end

    def read_sessions
      return {} unless File.file?(sessions_file)

      parsed = JSON.parse(File.read(sessions_file))
      sessions = parsed.is_a?(Hash) ? parsed["sessions"] : nil
      sessions.is_a?(Hash) ? sessions.select { |key, value| key.is_a?(String) && value.is_a?(Hash) } : {}
    rescue StandardError
      {}
    end

    def write_sessions(sessions)
      path = sessions_file
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate("sessions" => sessions)) }
      File.rename(tmp, path)
      File.chmod(0o600, path)
    end

    def record!(session_id, label)
      id = session_id.to_s
      return nil if id.empty? || id.start_with?("unknown-") || !usable_label?(label)

      now = Time.now.utc
      cutoff = now - (SESSIONS_DAYS * 86_400)
      sessions = read_sessions.reject { |_key, value| (stamp(value["at"]) || Time.at(0)) < cutoff }
      sessions.delete(id)
      sessions[id] = { "label" => label.to_s, "at" => now.iso8601 }
      kept = sessions.sort_by { |_key, value| stamp(value["at"]) || Time.at(0) }.last(SESSIONS_MAX)
      write_sessions(kept.to_h)
      nil
    rescue StandardError
      nil
    end

    def stamp(value)
      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def current_session_id
      SESSION_ENV_KEYS.each do |key|
        raw = ENV[key].to_s
        next if raw.empty?

        cleaned = raw.gsub(/[^A-Za-z0-9._:-]/, "_")[0, 128]
        return cleaned unless cleaned.empty?
      end
      nil
    end

    def hook!(session_id, label)
      return nil unless usable_label?(label)

      @hook_label = label.to_s
      @hook_session_id = session_id.to_s
      record!(session_id, label)
      nil
    rescue StandardError
      nil
    end

    def recorded_label(session_id)
      return nil if session_id.to_s.empty?

      entry = read_sessions[session_id.to_s]
      label = entry ? entry["label"].to_s : ""
      label.empty? ? nil : label
    end

    def detect
      return { "label" => @hook_label, "confidence" => "verified" } if @hook_label

      label = recorded_label(current_session_id)
      return { "label" => label, "confidence" => "verified" } if label

      label = Reach::HookLiveness.marker_harness.to_s
      return { "label" => label, "confidence" => "inferred" } unless label.empty? || label == Reach::Fingerprint::UNKNOWN

      label = (Reach::HookLiveness.parent_harness || Reach::HookLiveness.recorded_harness).to_s
      return { "label" => label, "confidence" => "weak" } unless label.empty?

      { "label" => ($stdin.tty? ? "terminal" : "unknown"), "confidence" => "weak" }
    rescue StandardError
      { "label" => "unknown", "confidence" => "weak" }
    end
  end
end
