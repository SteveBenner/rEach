module Reach
  module Policy
    SECTIONS = %w[login limits support student_part module_selection].freeze

    DEFAULTS = {
      "login" => { "required" => true, "max_hours" => 12, "lockout_failures" => 3, "lockout_minutes" => 15 },
      "limits" => {
        "corpus_max_bytes" => 52_428_800,
        "transcript_spool_max_bytes" => 209_715_200,
        "materials_max_bytes" => 209_715_200,
        "import_max_bytes" => 20_971_520,
        "import_max_per_prompt" => 5
      },
      "support" => { "text" => "" },
      "student_part" => { "required" => true, "questions" => {} },
      "module_selection" => {
        "mode" => "instructor",
        "count" => 2,
        "options" => [],
        "opens_at" => nil,
        "closes_at" => nil,
        "capacity_per_module" => nil,
        "slices" => %w[backend panel]
      }
    }.freeze

    module_function

    def all
      version = guardrails_version
      @cache = nil unless @cache_version == version
      return @cache if @cache

      @cache = build
      @cache_version = version
      @cache
    rescue StandardError
      defaults
    end

    def login
      all["login"]
    end

    def limits
      all["limits"]
    end

    def support
      all["support"]
    end

    def student_part
      all["student_part"]
    end

    def module_selection
      all["module_selection"]
    end

    def questions(assignment_id)
      list = (student_part["questions"] || {})[assignment_id.to_s]
      Array(list).select { |item| item.is_a?(Hash) }.map do |item|
        {
          "id" => item["id"].to_s,
          "question" => item["question"].to_s,
          "min_words" => item["min_words"].to_i
        }
      end
    rescue StandardError
      []
    end

    def reset!
      @cache = nil
      @cache_version = nil
    end

    def build
      course = Reach::Guardrails.load["course"]
      course = {} unless course.is_a?(Hash)
      merged = defaults
      SECTIONS.each do |section|
        given = course[section]
        merged[section] = merged[section].merge(given) if given.is_a?(Hash)
      end
      merged["student_part"]["required"] = false unless course.key?("student_part")
      merged["student_part"]["questions"] = {} unless merged["student_part"]["questions"].is_a?(Hash)
      merged
    rescue StandardError
      defaults
    end

    def defaults
      SECTIONS.each_with_object({}) do |section, memo|
        memo[section] = Marshal.load(Marshal.dump(DEFAULTS[section]))
      end
    end

    def guardrails_version
      Reach::Guardrails.version
    rescue StandardError
      nil
    end
  end
end
