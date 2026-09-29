require "yaml"
require "time"

module Reach
  module Profile
    FIELDS = %w[
      preferred_name studies year coding_experience ai_experience course_question
      course_answer goal explanation_style creative_lead work_times deadline_reminders notes
    ].freeze

    module_function

    def path
      File.join(Reach::Paths.home, "profile.yml")
    end

    def load
      return default unless File.file?(path)

      data = YAML.safe_load(File.read(path))
      data.is_a?(Hash) ? normalize(data) : default
    rescue StandardError
      default
    end

    def save(fields:, status:)
      raise Reach::Error, "reach: status must be partial or complete" unless %w[partial complete].include?(status.to_s)

      unknown = fields.keys.map(&:to_s) - FIELDS
      unless unknown.empty?
        valid = FIELDS.map { |field| field.tr("_", "-") }.join(", ")
        raise Reach::Error, "reach: unknown profile field(s) #{unknown.join(", ")}; valid fields are #{valid}"
      end

      current = load
      merged = current["fields"].dup

      fields.each do |key, value|
        text = value.to_s.strip
        text = text[0, 500] if text.length > 500
        if text.empty?
          merged.delete(key.to_s)
        else
          merged[key.to_s] = text
        end
      end

      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      result = {
        "schema" => "reach.profile/v1",
        "status" => status.to_s,
        "fields" => merged,
        "started_at" => current["started_at"] || now,
        "completed_at" => status.to_s == "complete" ? now : current["completed_at"],
        "updated_at" => now
      }

      Reach::Paths.ensure_home!
      File.write(path, YAML.dump(result), perm: 0o600)
      begin
        File.chmod(0o600, path)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
      result
    end

    def forget!
      File.delete(path) if File.file?(path)
      true
    end

    def preferred_name
      value = load["fields"]["preferred_name"]
      value && !value.to_s.empty? ? value : nil
    end

    def default
      {
        "schema" => "reach.profile/v1",
        "status" => "not_started",
        "fields" => {},
        "started_at" => nil,
        "completed_at" => nil,
        "updated_at" => nil
      }
    end

    def normalize(data)
      {
        "schema" => data["schema"] || "reach.profile/v1",
        "status" => data["status"] || "not_started",
        "fields" => data["fields"].is_a?(Hash) ? data["fields"] : {},
        "started_at" => data["started_at"],
        "completed_at" => data["completed_at"],
        "updated_at" => data["updated_at"]
      }
    end
  end
end
