module Reach
  module ExamMode
    FILE = "exam.json".freeze

    module_function

    def enabled?
      Reach::AgentControl.flag?("test_mode")
    end

    def active?
      false
    end

    def fetch!
      nil
    end

    def cli(_args)
      puts Reach::Messages.text("M-TEST-NONE")
      0
    end

    def tool(_arguments)
      { "text" => Reach::Messages.text("M-TEST-NONE"), "relay_verbatim" => true }
    end

    def context_lines
      []
    end
  end
end
