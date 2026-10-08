module Reach
  module HarnessMove
    KIND = "harness_move".freeze
    TARGETS = %w[claude-code codex antigravity hermes].freeze
    NAMES = {
      "claude-code" => "Claude Code",
      "codex" => "Codex",
      "antigravity" => "Antigravity",
      "hermes" => "Hermes"
    }.freeze
    ALIASES = {
      "claude" => "claude-code",
      "claude code" => "claude-code",
      "claude-code" => "claude-code",
      "codex" => "codex",
      "antigravity" => "antigravity",
      "agy" => "antigravity",
      "gemini" => "antigravity",
      "hermes" => "hermes"
    }.freeze
    FALLBACK_FROM = "the app you use now".freeze

    module_function

    def normalize(name)
      ALIASES[name.to_s.downcase.strip.gsub(/\s+/, " ")]
    end

    def display(id)
      NAMES.fetch(id.to_s)
    end

    def current
      label = (Reach::KnownIssues.harness || Reach::Fingerprint.harness_label(nil)).to_s
      return "claude-code" if label.start_with?("claude-")
      return "codex" if label.start_with?("codex-")
      return "hermes" if label == "hermes"
      return "antigravity" if label == "antigravity"

      nil
    rescue StandardError
      nil
    end

    def hookless?(source)
      source == "antigravity" || Reach::KnownIssues.harness.nil?
    rescue StandardError
      false
    end

    def refusal(state, message_id, **fields)
      { "state" => state, "ok" => false, "text" => Reach::Messages.text(message_id, **fields) }
    end

    def check(to, from)
      return refusal("unknown", "M-HARNESS-MOVE-UNKNOWN") if to.nil?
      return refusal("same", "M-HARNESS-MOVE-SAME", app: display(to)) if from == to

      nil
    end

    def prepare(to, from)
      target = normalize(to)
      source = from.to_s.strip.empty? ? current : normalize(from)
      [target, source]
    end

    def from_text(from)
      from ? display(from) : FALLBACK_FROM
    end

    def ask_text(to:, from:)
      Reach::Messages.text("M-HARNESS-MOVE-ASK", app: display(to), from_app: from_text(from)).strip
    end

    def declined_text
      Reach::Messages.text("M-HARNESS-MOVE-DECLINED")
    end

    def ask_chat(to:, from: nil)
      target, source = prepare(to, from)
      refused = check(target, source)
      return refused if refused

      if hookless?(source)
        command = Reach::Hello.terminal_command("harness", "move", "--to", target)
        return { "state" => "terminal", "ok" => false, "text" => Reach::Messages.text("M-HARNESS-MOVE-TERMINAL", app: display(target), command: command) }
      end

      subject = { "to" => target, "from" => source }
      asked = Reach::Consent.ask!(
        kind: KIND, subject: subject, message_id: "M-HARNESS-MOVE-ASK",
        fields: { app: display(target), from_app: from_text(source) }
      )
      { "state" => "asked", "ok" => true, "question" => asked, "text" => Reach::Messages.text("M-CONSENT-NEEDED", question: asked) }
    end

    def follow_up!(observed)
      subject = observed["subject"].is_a?(Hash) ? observed["subject"] : {}
      if observed["answer"] == "yes"
        Reach::Consent.take!(kind: KIND, subject: subject)
        return apply!(to: subject["to"], from: subject["from"], via: "chat")["text"]
      end

      Reach::Consent.clear_declined!(kind: KIND, subject: subject)
      declined_text
    rescue StandardError => e
      Reach::Debug.fault(e, "harness_move:follow_up")
      nil
    end

    def apply!(to:, from: nil, via: "terminal")
      target, source = prepare(to, from)
      refused = check(target, source)
      return refused if refused

      result = Reach::Setup.run_harness(target, Reach::Runtime.root)
      unless result[:ok]
        outcome = refusal("failed", "M-HARNESS-MOVE-FAILED", app: display(target), reason: result[:message])
        record(source, target, false, via)
        return outcome.merge("to" => target, "from" => source)
      end

      Reach::Paths.ensure_workspace_dirs!
      configure_spaces
      lines = [Reach::Messages.text("M-HARNESS-MOVE-DONE", app: display(target), folder: Reach::Sandbox.course_folder, setup: result[:message])]
      extra = codex_step(target)
      lines << extra if extra
      record(source, target, true, via)
      { "state" => "moved", "ok" => true, "text" => lines.join("\n\n"), "to" => target, "from" => source }
    end

    def codex_step(target)
      return nil unless target == "codex" && Reach::CodexSetup.enabled? && !Reach::CodexSetup.satisfied?

      Reach::Messages.text("M-HARNESS-MOVE-CODEX-NEXT", command: "reach codex configure")
    rescue StandardError
      nil
    end

    def configure_spaces
      root = Reach::Paths.root
      groups = [[nil, Reach::Paths.with_persona(nil) { Reach::Relocation.space_targets }]]
      Reach::Relocation.persona_dirs(root).each_key do |id|
        groups << [id, Reach::Paths.with_persona(id) { Reach::Relocation.space_targets }]
      end
      groups.each do |id, targets|
        Reach::Paths.with_persona(id) do
          targets.each do |target|
            begin
              Reach::Harness.configure_all(target)
            rescue StandardError
              nil
            end
          end
        end
      end
    rescue StandardError
      nil
    end

    def record(from, to, ok, via)
      Reach::Debug.emit("command", "command" => "harness move", "from" => from, "to" => to, "ok" => ok, "via" => via)
    rescue StandardError
      nil
    end
  end
end
