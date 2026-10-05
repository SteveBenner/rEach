module Reach
  module Identity
    RULE_KEYS = %w[institution_name username_domain username_pattern student_id_pattern].freeze
    SECRET_LENGTH = 8
    COURSE_ID_MAX = 16
    TEXT_MAX = 64
    SECRET_CHARS = /\A[0-9A-TV-Z]{8}\z/.freeze
    CODE_JOIN = /\A[ \t_-]+\z/.freeze
    CODE_ALONE = /\A[ \t_-]*[A-Z0-9][A-Z0-9 \t_-]*\z/.freeze

    module_function

    def rules(preview_identity = nil, preview_hints = nil)
      given = preview_identity.is_a?(Hash) ? preview_identity : {}
      found = RULE_KEYS.each_with_object({}) { |key, memo| memo[key] = given[key].to_s.strip }
      hints = preview_hints.is_a?(Hash) ? preview_hints : {}
      found["email_hint"] = hints["email"].to_s.strip
      found["student_id_hint"] = hints["student_id"].to_s.strip
      found
    end

    def institution(rules)
      name = rules.is_a?(Hash) ? rules["institution_name"].to_s.strip : ""
      name.empty? ? Reach::Messages.text("M-ENR-SCHOOL") : name
    end

    def email_hint(rules)
      return "" unless rules.is_a?(Hash)

      hint = rules["email_hint"].to_s.strip
      return " #{hint}" unless hint.empty?

      domain = rules["username_domain"].to_s.strip
      domain.empty? ? "" : " #{Reach::Messages.text("M-ENR-EMAIL-DOMAIN", domain: domain)}"
    end

    def id_hint(rules)
      hint = rules.is_a?(Hash) ? rules["student_id_hint"].to_s.strip : ""
      hint.empty? ? "" : " #{hint}"
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

      upper = text.upcase
      alone = upper.match?(CODE_ALONE)
      code_shapes(upper).each do |shapes|
        found = shapes.select do |course_id, secret|
          secret.match?(SECRET_CHARS) && "#{course_id}#{secret}".match?(/[0-9]/) && (alone || course_id.match?(/[A-Z]/))
        end.map { |course_id, secret| [course_id, secret.tr("OIL", "011")] }.uniq
        next if found.empty?
        return nil unless found.length == 1

        course_id, secret = found.first
        return { "course_id" => course_id, "secret" => secret, "code" => "#{course_id}-#{secret}" }
      end
      nil
    end

    def code_shapes(upper)
      tokens = []
      upper.scan(/[A-Z0-9]+/) do |word|
        match = Regexp.last_match
        tokens << { "word" => word, "from" => match.begin(0), "to" => match.end(0) }
      end
      shapes = []
      split = []
      tokens.each_with_index do |token, index|
        word = token["word"]
        split << [word[0...-SECRET_LENGTH], word[-SECRET_LENGTH, SECRET_LENGTH]] if word.length.between?(SECRET_LENGTH + 1, COURSE_ID_MAX + SECRET_LENGTH)
        next if word.length > COURSE_ID_MAX

        first = tokens[index + 1]
        next unless first && code_joined?(upper, token, first)

        if first["word"].length == SECRET_LENGTH
          shapes << [word, first["word"]]
        elsif first["word"].length == SECRET_LENGTH / 2
          second = tokens[index + 2]
          shapes << [word, first["word"] + second["word"]] if second && second["word"].length == SECRET_LENGTH / 2 && code_joined?(upper, first, second)
        end
      end
      [shapes, split]
    end

    def code_joined?(upper, left, right)
      upper[left["to"]...right["from"]].match?(CODE_JOIN)
    end

    def normalize_username(text, rules)
      return nil unless text.is_a?(String)

      value = text.strip.downcase
      return nil if value.empty? || value.count("@") > 1

      domain = rules["username_domain"].to_s.downcase
      value = "#{value}@#{domain}" unless value.include?("@") || domain.empty?
      local, host = value.split("@", 2)
      return nil if local.to_s.empty? || host.to_s.empty? || value.match?(/\s/)
      return nil unless domain.empty? || host == domain

      pattern = rules["username_pattern"].to_s
      return value if pattern.empty?

      local =~ Regexp.new(pattern) ? value : nil
    rescue RegexpError
      nil
    end

    def normalize_student_id(text, rules)
      return nil unless text.is_a?(String)

      value = text.gsub(/[\s-]/, "")
      return nil if value.empty? || value.length > TEXT_MAX

      pattern = rules["student_id_pattern"].to_s
      return value if pattern.empty?

      value =~ Regexp.new(pattern) ? value : nil
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
