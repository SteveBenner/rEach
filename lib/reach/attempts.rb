module Reach
  module Attempts
    module_function

    def settle(slice:)
      []
    end

    def show(workspace)
      state = Reach::Ladder.state(workspace)
      {
        "slice" => File.basename(workspace),
        "failed" => state["failed"].to_i,
        "hand_at" => Reach::Ladder::HAND_AT,
        "hard_stop" => Reach::Ladder::HARD_STOP,
        "hand_id" => state["hand_id"],
        "consented" => !state["consent_at"].nil?,
        "blocked" => Reach::Ladder.blocked_message(workspace)
      }
    end

    def continue(workspace)
      Reach::Ladder.continue!(workspace)
      failed = Reach::Ladder.state(workspace)["failed"].to_i
      Reach::Messages.text("M-LADDER-CONTINUE", attempt: failed + 1, limit: Reach::Ladder::HARD_STOP)
    end
  end
end
