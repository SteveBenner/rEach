require "json"
require "digest"
require "rbconfig"

module Reach
  module CodexHookTrust
    EVENT_LABELS = {
      "PreToolUse" => "pre_tool_use",
      "PermissionRequest" => "permission_request",
      "PostToolUse" => "post_tool_use",
      "PreCompact" => "pre_compact",
      "PostCompact" => "post_compact",
      "SessionStart" => "session_start",
      "SessionEnd" => "session_end",
      "UserPromptSubmit" => "user_prompt_submit",
      "SubagentStart" => "subagent_start",
      "SubagentStop" => "subagent_stop",
      "Stop" => "stop",
      "Interrupt" => "interrupt"
    }.freeze
    NO_MATCHER_EVENTS = %w[UserPromptSubmit Stop Interrupt].freeze
    CONTEXT_LIMIT_EVENTS = %w[PreToolUse PostToolUse SessionStart UserPromptSubmit SubagentStart].freeze
    SHORT_EVENTS = %w[SessionEnd Interrupt].freeze
    DEFAULT_TIMEOUT_S = 600
    SHORT_TIMEOUT_S = 1
    SHORT_MAX_TIMEOUT_S = 3
    DEFAULT_CONTEXT_LIMIT = 2500
    PREFIX = "sha256:".freeze
    BAD = %w[modified untrusted].freeze

    module_function

    def windows?
      RbConfig::CONFIG["host_os"].to_s =~ /mswin|mingw|cygwin/ ? true : false
    end

    def canonical(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, sorted| sorted[key] = canonical(value[key]) }
      when Array
        value.map { |item| canonical(item) }
      else
        value
      end
    end

    def timeout_for(event, timeout)
      seconds = timeout.is_a?(Integer) ? timeout : nil
      return (seconds || SHORT_TIMEOUT_S).clamp(1, SHORT_MAX_TIMEOUT_S) if SHORT_EVENTS.include?(event)

      [seconds || DEFAULT_TIMEOUT_S, 1].max
    end

    def normalized_handler(event, handler)
      command = handler["command"].to_s
      command = handler["commandWindows"].to_s if windows? && handler["commandWindows"].is_a?(String)
      entry = {
        "type" => "command",
        "command" => command,
        "timeout" => timeout_for(event, handler["timeout"]),
        "async" => handler["async"] == true
      }
      entry["statusMessage"] = handler["statusMessage"] if handler["statusMessage"].is_a?(String)
      limit = handler["additionalContextLimit"]
      entry["additionalContextLimit"] = limit if CONTEXT_LIMIT_EVENTS.include?(event) && limit.is_a?(Integer) && limit != DEFAULT_CONTEXT_LIMIT
      entry
    end

    def hash(event, group, handler)
      label = EVENT_LABELS.fetch(event.to_s) { event.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase }
      identity = { "event_name" => label, "hooks" => [normalized_handler(event.to_s, handler)] }
      matcher = group["matcher"]
      identity["matcher"] = matcher if matcher.is_a?(String) && !NO_MATCHER_EVENTS.include?(event.to_s)
      "#{PREFIX}#{Digest::SHA256.hexdigest(JSON.generate(canonical(identity)))}"
    end

    def parsed(content)
      return content if content.is_a?(Hash)

      loaded = JSON.parse(content.to_s)
      loaded.is_a?(Hash) ? loaded : {}
    rescue JSON::ParserError
      {}
    end

    def display_path(hooks_path)
      path = File.expand_path(hooks_path.to_s)
      windows? ? path.tr("/", "\\") : path
    end

    def key(hooks_path, event, group_index, handler_index)
      label = EVENT_LABELS.fetch(event.to_s) { event.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase }
      "#{display_path(hooks_path)}:#{label}:#{group_index}:#{handler_index}"
    end

    def keys(hooks_path, content)
      events = parsed(content)["hooks"]
      return [] unless events.is_a?(Hash)

      listed = []
      events.each do |event, groups|
        next unless groups.is_a?(Array)

        groups.each_with_index do |group, group_index|
          next unless group.is_a?(Hash) && group["hooks"].is_a?(Array)

          group["hooks"].each_with_index do |handler, handler_index|
            next unless handler.is_a?(Hash) && handler["type"] == "command" && !handler["command"].to_s.strip.empty?

            listed << [key(hooks_path, event, group_index, handler_index), hash(event, group, handler)]
          end
        end
      end
      listed
    end

    def status(hooks_path, content)
      state = Reach::CodexSetup.trust_state
      keys(hooks_path, content).each_with_object({}) do |(handler_key, current), answers|
        answers[handler_key] = if state.nil?
          "unknown"
        else
          held = state[handler_key]
          trusted = held.is_a?(Hash) ? held["trusted_hash"] : nil
          if trusted.nil?
            "untrusted"
          else
            trusted == current ? "trusted" : "modified"
          end
        end
      end
    end

    def stale?(answers)
      answers.values.any? { |answer| BAD.include?(answer) }
    end
  end
end
