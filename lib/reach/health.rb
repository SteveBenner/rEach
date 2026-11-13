# frozen_string_literal: true

module Reach
  module Health
    CHECKS = {
      "codex_sandbox" => { "message" => "M-HEALTH-CODEX-SANDBOX", "fix" => ["reach_setup", { "action" => "configure" }], "doctor" => false },
      "signin_hook_not_running" => { "message" => "M-HEALTH-SIGNIN-HOOK", "fix" => nil, "doctor" => true },
      "hooks_not_running" => { "message" => "M-HEALTH-COURSE-HOOKS", "fix" => nil, "doctor" => true },
      "codex_hooks_untrusted" => { "message" => "M-HEALTH-HOOKS-UNTRUSTED", "fix" => ["reach_setup", { "action" => "configure" }], "doctor" => true }
    }.freeze

    MCP_ONLY = %w[hooks_not_running signin_hook_not_running codex_hooks_untrusted].freeze

    module_function

    def detected?(id, env = Reach::HookLiveness.environment, mcp: false)
      case id
      when "codex_sandbox"
        Reach::Sandbox.blocked?
      when "hooks_not_running"
        mcp && !Reach::HookLiveness.signin_pending? && (Reach::HookLiveness.prompt_hook_dead?(env) || Reach::HookLiveness.prompt_turns_unseen?(env))
      when "signin_hook_not_running"
        mcp && Reach::HookLiveness.signin_hook_dead?(env)
      when "codex_hooks_untrusted"
        mcp && Reach::HookLiveness.course_hooks_untrusted?(env)
      else
        false
      end
    rescue StandardError
      false
    end

    def detected(mcp: false)
      env = Reach::HookLiveness.environment
      CHECKS.keys.select { |id| detected?(id, env, mcp: mcp) }
    rescue StandardError
      []
    end

    def signin_state
      return nil unless Reach::Device.enrolled_install

      !Reach::HookLiveness.signin_pending?
    rescue StandardError
      nil
    end

    def note!(mcp: false, ids: nil)
      failing = ids || detected(mcp: mcp)
      failing |= (Reach::Device.held_failing & MCP_ONLY) unless mcp
      Reach::Device.note_health(failing, signin_state)
      failing
    rescue StandardError
      nil
    end

    def fix_call(id)
      tool, arguments = CHECKS.dig(id, "fix")
      return nil unless tool

      pairs = arguments.map { |key, value| "#{key} #{value}" }
      pairs.empty? ? tool : "#{tool} with #{pairs.join(', ')}"
    end

    def line(id)
      text = Reach::Messages.text(CHECKS[id]["message"])
      call = fix_call(id)
      call ? "#{text} #{Reach::Messages.text('M-HEALTH-FIX', call: call)}" : text
    end

    def context_lines(mcp: false)
      ids = detected(mcp: mcp)
      note!(mcp: mcp, ids: ids)
      ids.map { |id| line(id) }
    rescue StandardError
      []
    end

    def doctor_problems
      ids = detected(mcp: true)
      note!(mcp: true, ids: ids)
      ids.select { |id| CHECKS[id]["doctor"] }.map { |id| "R-DOC-HEALTH: #{line(id)}" }
    rescue StandardError
      []
    end
  end
end
