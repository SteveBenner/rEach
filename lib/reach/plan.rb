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

      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      current["saved_at"] ||= now
      current["updated_at"] = now
      FileUtils.mkdir_p(File.dirname(path(workspace)))
      File.write(path(workspace), YAML.dump(current))
      Reach::Ledger.append(workspace, "plan", "action" => "save")
      current
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

        lines << "#{field.tr('_', ' ').capitalize}:"
        items.each_with_index { |item, index| lines << "  #{index + 1}. #{item}" }
      end
      lines << "Evidence: #{data['evidence']}" unless data["evidence"].to_s.empty?
      lines << "Progress: #{data['progress']}" unless data["progress"].to_s.empty?
      lines << "Next: #{data['next']}" unless data["next"].to_s.empty?
      lines << "Updated: #{data['updated_at']}"
      lines.join("\n")
    end
  end
end
