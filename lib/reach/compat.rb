module Reach
  module Compat
    LISTS = %w[hand_triggers debug_kinds harnesses].freeze

    module_function

    def accepts
      status = Reach::Sync.cached_status
      value = status.is_a?(Hash) ? status["accepts"] : nil
      value.is_a?(Hash) ? value : nil
    rescue StandardError
      nil
    end

    def list(name)
      lists = accepts
      return nil unless lists && lists[name].is_a?(Array)

      lists[name].map(&:to_s)
    end

    def allows?(name, value)
      values = list(name)
      return values.include?(value.to_s) if values

      Reach::Debug.teach_kinds?
    rescue StandardError
      false
    end

    def accepts_trigger?(trigger)
      allows?("hand_triggers", trigger)
    end

    def accepts_debug_kind?(kind)
      allows?("debug_kinds", kind)
    end

    def accepts_harness?(harness)
      allows?("harnesses", harness)
    end

    def degraded?
      accepts.nil? && !Reach::Debug.teach_kinds?
    rescue StandardError
      true
    end
  end
end
