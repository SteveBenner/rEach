module Reach
  module Identity
    RULE_KEYS = %w[institution_name username_domain username_pattern student_id_pattern].freeze
    SECRET_LENGTH = 8
    COURSE_ID_MAX = 16
    TEXT_MAX = 64

    module_function

    def rules(preview_identity = nil)
      configured = Reach::Runtime.load_config["enrollment"]
      configured = {} unless configured.is_a?(Hash)
      given = preview_identity.is_a?(Hash) ? preview_identity : {}
      RULE_KEYS.each_with_object({}) do |key, memo|
        value = given[key].to_s.strip
        value = configured[key].to_s.strip if value.empty?
        memo[key] = value
      end
    end

    def normalize_course_id(text)
      return nil unless text.is_a?(String) && text.length <= TEXT_MAX

      value = text.upcase.gsub(/[^A-Z0-9]/, "")
      value.length.between?(1, COURSE_ID_MAX) ? value : nil
    end

    def bare_course_id(text)
      value = normalize_course_id(text)
      return nil unless value && value.length >= 2
      return nil unless value =~ /[A-Z]/ && value =~ /[0-9]/

      value
    end

    def parse_course_code(text)
      return nil unless text.is_a?(String) && text.length <= TEXT_MAX

      value = text.upcase.gsub(/[^A-Z0-9]/, "")
      return nil if value.length < SECRET_LENGTH + 1

      course_id = value[0...-SECRET_LENGTH]
      return nil if course_id.length > COURSE_ID_MAX

      secret = value[-SECRET_LENGTH, SECRET_LENGTH].tr("OIL", "011")
      { "course_id" => course_id, "secret" => secret, "code" => "#{course_id}-#{secret}" }
    end

    def normalize_username(text, rules)
      return nil unless text.is_a?(String)

      value = text.strip.downcase
      return nil if value.empty? || value.count("@") > 1

      domain = rules["username_domain"].to_s.downcase
      value = "#{value}@#{domain}" unless value.include?("@")
      local, host = value.split("@", 2)
      return nil unless host == domain && !local.to_s.empty?

      pattern = Regexp.new(rules["username_pattern"].to_s)
      local =~ pattern ? value : nil
    rescue RegexpError
      nil
    end

    def normalize_student_id(text, rules)
      return nil unless text.is_a?(String)

      value = text.gsub(/[\s-]/, "")
      return nil if value.empty?

      value =~ Regexp.new(rules["student_id_pattern"].to_s) ? value : nil
    rescue RegexpError
      nil
    end

    def display_code(code)
      parsed = parse_course_code(code)
      return code.to_s unless parsed

      secret = parsed["secret"]
      "#{parsed["course_id"]}-#{secret[0, 4]}-#{secret[4, 4]}"
    end
  end
end
