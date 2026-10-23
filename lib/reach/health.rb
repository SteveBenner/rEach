module Reach
  module Health
    CHECKS = {
      "codex_sandbox" => { "message" => "M-HEALTH-CODEX-SANDBOX", "fix" => ["reach_setup", { "action" => "configure" }], "doctor" => false },
      "signin_hook_not_running" => { "message" => "M-HEALTH-SIGNIN-HOOK", "fix" => nil, "doctor" => true },
      "hooks_not_running" => { "message" => "M-HEALTH-COURSE-HOOKS", "fix" => nil, "doctor" => true },
      "codex_hooks_untrusted" => { "message" => "M-HEALTH-HOOKS-UNTRUSTED", "fix" => ["reach_setup", { "action" => "configure" }], "doctor" => true }
    }.freeze

    module_function

    def detected?(id, env = Reach::HookLiveness.environment, mcp: false)
      case id
      when "codex_sandbox"
        Reach::Sandbox.blocked?
      when "hooks_not_running"
        mcp && !Reach::HookLiveness.signin_pending? && Reach::HookLiveness.prompt_hook_dead?(env)
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
      detected(mcp: mcp).map { |id| line(id) }
    rescue StandardError
      []
    end

    def doctor_problems
      detected(mcp: true).select { |id| CHECKS[id]["doctor"] }.map { |id| "R-DOC-HEALTH: #{line(id)}" }
    rescue StandardError
      []
    end
  end
end
