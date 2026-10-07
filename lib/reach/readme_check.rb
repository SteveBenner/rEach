module Reach
  module ReadmeCheck
    FILE = "README.md".freeze
    MIN_WORDS = 25
    SECTIONS = [
      "Business user and decision",
      "Information flow",
      "People and control",
      "Expected, actual, case, and status",
      "Contributions and tools"
    ].freeze
    HEADING = /\A\s{0,3}(\#{1,6})\s+(.+?)\s*#*\s*\z/.freeze
    WORD = /[[:alpha:]][[:alnum:]'’]*/.freeze

    module_function

    def key(text)
      text.to_s.downcase.gsub("&", "and").gsub(/[^a-z0-9]/, "")
    end

    def problems(text)
      lines = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(/<!--.*?-->/m, "").lines.map(&:chomp)
      headings = []
      lines.each_with_index do |line, index|
        match = HEADING.match(line)
        headings << { "index" => index, "level" => match[1].length, "key" => key(match[2]) } if match
      end
      SECTIONS.map do |title|
        heading = headings.find { |item| item["key"] == key(title) }
        next { "section" => title, "line" => 1, "words" => 0, "missing" => true } if heading.nil?

        stop = headings.find { |item| item["index"] > heading["index"] && item["level"] <= heading["level"] }
        body = lines[(heading["index"] + 1)...(stop ? stop["index"] : lines.length)]
        words = body.join("\n").scan(WORD).length
        next nil if words >= MIN_WORDS

        { "section" => title, "line" => heading["index"] + 1, "words" => words, "missing" => false }
      end.compact
    end

    def describe(problem)
      if problem["missing"]
        "README.md has no \"#{problem['section']}\" section"
      else
        "README.md section \"#{problem['section']}\" has #{problem['words']} words; it needs at least #{MIN_WORDS}"
      end
    end
  end
end
