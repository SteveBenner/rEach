require "yaml"
require "time"
require "fileutils"

module Reach
  module Plan
    SCHEMA = "reach.plan/v1".freeze
    TEXT_FIELDS = %w[behaviour input output evidence progress next].freeze
    LIST_FIELDS = %w[steps edge_cases scenarios].freeze
    TEXT_LIMIT = 400
    LIST_LIMIT = 12
    ITEM_LIMIT = 200
    STEP_STATES = %w[todo doing done].freeze

    module_function

    def path(workspace)
      File.join(workspace, Reach::Workspace::MARKER_DIR, "plan.yml")
    end

    def load(workspace)
      return nil unless File.file?(path(workspace))

      data = YAML.safe_load(File.read(path(workspace)))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def save(workspace, fields)
      current = load(workspace) || { "schema" => SCHEMA }
      fields.each do |key, value|
        name = key.to_s.tr("-", "_")
        if TEXT_FIELDS.include?(name)
          text = value.to_s.strip
          raise Reach::Error, Reach::Messages.text("M-PLAN-TOO-LONG", field: name, limit: TEXT_LIMIT) if text.length > TEXT_LIMIT

          current[name] = text
        elsif LIST_FIELDS.include?(name)
          items = value.is_a?(Array) ? value.map(&:to_s) : value.to_s.split("|")
          items = items.map(&:strip).reject(&:empty?)
          raise Reach::Error, Reach::Messages.text("M-PLAN-TOO-LONG", field: name, limit: LIST_LIMIT) if items.length > LIST_LIMIT
          raise Reach::Error, Reach::Messages.text("M-PLAN-TOO-LONG", field: name, limit: ITEM_LIMIT) if items.any? { |item| item.length > ITEM_LIMIT }

          current[name] = items
        else
          raise Reach::Error, Reach::Messages.text("M-PLAN-UNKNOWN-FIELD", field: name, fields: (TEXT_FIELDS + LIST_FIELDS).join(", "))
        end
      end
      raise Reach::Error, Reach::Messages.text("M-PLAN-NEEDS-BEHAVIOUR") if current["behaviour"].to_s.empty?

      prune_step_state!(current)
      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      current["saved_at"] ||= now
      current["updated_at"] = now
      FileUtils.mkdir_p(File.dirname(path(workspace)))
      File.write(path(workspace), YAML.dump(current))
      Reach::Ledger.append(workspace, "plan", "action" => "save")
      current
    end

    def prune_step_state!(data)
      state = data["step_state"]
      return data unless state.is_a?(Hash)

      steps = Array(data["steps"])
      kept = {}
      state.each do |key, entry|
        number = key.to_s.to_i
        next unless entry.is_a?(Hash) && number.between?(1, steps.length) && entry["text"] == steps[number - 1]

        kept[number.to_s] = entry
      end
      kept.empty? ? data.delete("step_state") : data["step_state"] = kept
      data
    rescue StandardError
      data
    end

    def step_state(data)
      steps = Array(data["steps"])
      raw = data["step_state"].is_a?(Hash) ? data["step_state"] : {}
      steps.each_with_index.map do |text, index|
        entry = raw[(index + 1).to_s] || raw[index + 1]
        if entry.is_a?(Hash) && entry["text"] == text && STEP_STATES.include?(entry["state"].to_s)
          { "number" => index + 1, "state" => entry["state"].to_s, "text" => text, "evidence" => entry["evidence"].to_s, "at" => entry["at"].to_s }
        else
          { "number" => index + 1, "state" => "todo", "text" => text, "evidence" => "", "at" => "" }
        end
      end
    rescue StandardError
      []
    end

    def set_step(workspace, number, state, evidence: nil)
      data = load(workspace)
      raise Reach::Error, Reach::Messages.text("M-PLAN-NONE") unless data

      steps = Array(data["steps"])
      index = number.to_s.match?(/\A\d{1,4}\z/) ? number.to_s.to_i : 0
      raise Reach::Error, Reach::Messages.text("M-PLAN-STEP-BAD-NUMBER", count: steps.length) unless index.between?(1, steps.length)

      state = state.to_s
      raise Reach::Error, Reach::Messages.text("M-PLAN-STEP-BAD-STATE") unless STEP_STATES.include?(state)

      note = evidence.to_s.strip
      raise Reach::Error, Reach::Messages.text("M-PLAN-STEP-NEEDS-EVIDENCE", limit: ITEM_LIMIT) if state == "done" && (note.empty? || note.length > ITEM_LIMIT)

      note = note[0, ITEM_LIMIT]
      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      views = step_state(data)
      table = {}
      views.each do |view|
        next if view["state"] == "todo"

        table[view["number"].to_s] = { "state" => view["state"], "text" => view["text"], "evidence" => view["evidence"], "at" => view["at"] }
      end
      if state == "doing"
        table.each_value { |entry| entry["state"] = "todo" if entry["state"] == "doing" }
      end
      table[index.to_s] = { "state" => state, "text" => steps[index - 1], "evidence" => state == "todo" ? "" : note, "at" => now }
      data["step_state"] = table
      data["updated_at"] = now
      FileUtils.mkdir_p(File.dirname(path(workspace)))
      File.write(path(workspace), YAML.dump(data))
      Reach::Ledger.append(workspace, "plan", "action" => "step", "step" => index, "state" => state)
      data
    end

    def step_view(workspace)
      data = load(workspace)
      return nil unless data

      items = step_state(data)
      return nil if items.empty?

      doing = items.find { |item| item["state"] == "doing" }
      finished = items.select { |item| item["state"] == "done" }
      {
        "total" => items.length,
        "done" => finished.length,
        "doing_number" => doing && doing["number"],
        "doing_text" => doing && doing["text"],
        "last_done_evidence" => finished.empty? ? nil : finished.max_by { |item| item["at"] }["evidence"],
        "items" => items
      }
    rescue StandardError
      nil
    end

    def render(workspace)
      data = load(workspace)
      return Reach::Messages.text("M-PLAN-NONE") unless data

      lines = []
      lines << "Behaviour: #{data['behaviour']}"
      lines << "Input: #{data['input']}" unless data["input"].to_s.empty?
      lines << "Output: #{data['output']}" unless data["output"].to_s.empty?
      LIST_FIELDS.each do |field|
        items = Array(data[field])
        next if items.empty?

        next if field == "steps"

        lines << "#{field.tr('_', ' ').capitalize}:"
        items.each_with_index { |item, index| lines << "  #{index + 1}. #{item}" }
      end
      steps_block = step_state(data)
      unless steps_block.empty?
        lines << "Steps:"
        steps_block.each do |item|
          line = "  #{item['number']}. [#{item['state']}] #{item['text']}"
          line += " (#{item['evidence']})" unless item["evidence"].empty?
          lines << line
        end
      end
      lines << "Evidence: #{data['evidence']}" unless data["evidence"].to_s.empty?
      lines << "Progress: #{data['progress']}" unless data["progress"].to_s.empty?
      lines << "Next: #{data['next']}" unless data["next"].to_s.empty?
      lines << "Updated: #{data['updated_at']}"
      lines.join("\n")
    end
  end
end
