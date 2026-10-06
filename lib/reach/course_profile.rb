module Reach
  module CourseProfile
    TERMS = %w[slice cutout module panel].freeze

    module_function

    def all
      version = Reach::Guardrails.version
      @cache = nil unless @cache_version == version
      return @cache if @cache

      course = Reach::Guardrails.load["course"]
      given = course.is_a?(Hash) ? course["profile"] : nil
      @cache = given.is_a?(Hash) ? given : {}
      @cache_version = version
      @cache
    rescue StandardError
      {}
    end

    def section(name)
      value = all[name]
      value.is_a?(Hash) ? value : {}
    end

    def lms_name
      value = section("submission")["lms_name"].to_s.strip
      value.empty? ? nil : value
    end

    def lms_upload_required?
      section("submission")["lms_upload_required"] == true
    end

    def slices
      value = all["slices"]
      value.is_a?(Array) ? value.map(&:to_s) : []
    end

    def term(name, form = "one")
      forms = section("terms")[name.to_s]
      value = forms.is_a?(Hash) ? forms[form.to_s].to_s.strip : ""
      value.empty? ? nil : value
    end

    def wellbeing_phrases
      value = section("wellbeing")["phrases"]
      list = value.is_a?(Array) ? value.map { |phrase| phrase.to_s.downcase.strip }.reject(&:empty?) : []
      list.empty? ? nil : list
    end

    def wellbeing_support_text
      value = section("wellbeing")["support_text"].to_s.strip
      value.empty? ? nil : value
    end

    def support_contact
      value = section("support")["contact_text"].to_s.strip
      value.empty? ? nil : value
    end

    def hint(hints, name)
      value = hints.is_a?(Hash) ? hints[name.to_s].to_s.strip : ""
      value.empty? ? "" : " #{value}"
    end
  end
end
