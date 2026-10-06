module Reach
  module Controls
    FILE = "controls.json".freeze

    module_function

    def enabled?
      Reach::AgentControl.flag?("controls")
    end

    def fetch!
      nil
    end

    def active
      []
    end

    def check_prompt!(_space)
      nil
    end

    def check_tool!(_kind, _space)
      nil
    end

    def check_submit!
      nil
    end

    def tool_allowed?(_name)
      true
    end

    def context_lines
      []
    end

    def ends_text
      ""
    end
  end
end
