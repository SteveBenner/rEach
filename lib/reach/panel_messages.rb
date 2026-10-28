# frozen_string_literal: true

require "json"

module Reach
  module PanelMessages
    CALL = /\bmessages\(\s*(['"])([A-Za-z0-9_.\-]+)\1\s*,\s*/.freeze
    MODULE_SCRIPT = /<script\b[^>]*?(\bmodule\b|context\s*=\s*["']module["'])[^>]*>(.*?)<\/script\s*>/m.freeze
    LOCALE = /\A[a-z]{2,3}-[A-Z]{2}\z/.freeze
    KEY = /\A[A-Za-z0-9_.\-]+\z/.freeze
    MAX_KEYS = 40
    MAX_VALUE = 200
    EN = "en-US"

    module_function

    def blocks(text)
      text = text.to_s
      bodies = []
      text.scan(MODULE_SCRIPT) { bodies << (Regexp.last_match.begin(2)...Regexp.last_match.end(2)) }
      found = []
      text.scan(CALL) do
        match = Regexp.last_match
        found << read_block(text, match, bodies.any? { |range| range.cover?(match.begin(0)) })
      end
      found
    end

    def keys(text)
      blocks(text).each_with_object({}) do |block, all|
        catalog = block[:catalog]
        next unless catalog

        catalog.each_value { |entries| entries.each_key { |key| all[key] = true } }
      end
    end

    def problems(text, cutout_id)
      rows = []
      blocks(text).each_with_index do |block, index|
        line = block[:line]
        add = lambda do |code, message|
          rows << { code: code, line: line, message: message }
        end
        add.call("duplicate_block", "Keep only one messages(...) block in this file; the extra one on line #{line} must go") if index.positive?
        add.call("not_module_script", "Move the messages(...) call on line #{line} into a <script module lang=\"ts\"> block") unless block[:in_module_script]
        if block[:error]
          add.call(block[:error], error_message(block[:error], line))
          next
        end
        add.call("wrong_cutout", "The messages(...) call on line #{line} names #{block[:cutout_id]}, but this cutout is #{cutout_id}") if block[:cutout_id] != cutout_id.to_s
        catalog = block[:catalog]
        english = catalog[EN]
        add.call("missing_en_us", "The messages(...) block on line #{line} needs an en-US entry; other languages fall back to it") unless english
        catalog.each do |locale, entries|
          unless locale.match?(LOCALE)
            add.call("bad_locale", "The language code #{locale.inspect} in the messages(...) block on line #{line} must look like en-US or es-MX")
            next
          end
          add.call("too_many_keys", "The #{locale} entry in the messages(...) block on line #{line} has #{entries.length} keys; the most allowed is #{MAX_KEYS}") if entries.length > MAX_KEYS
          entries.each do |key, value|
            add.call("bad_key", "The key #{key.inspect} in the messages(...) block on line #{line} must start with #{cutout_id}. and use only letters, digits, dots, dashes and underscores") unless key.match?(KEY) && key.start_with?("#{cutout_id}.")
            add.call("bad_value", "The text for #{key.inspect} in #{locale} on line #{line} must be a string of at most #{MAX_VALUE} characters") unless value.is_a?(String) && value.length <= MAX_VALUE
            add.call("extra_key", "The key #{key.inspect} is in #{locale} on line #{line} but not in en-US; add it to en-US first") if english && locale != EN && !english.key?(key)
          end
        end
      end
      rows
    end

    def error_message(code, line)
      case code
      when "not_an_object" then "The messages(...) call on line #{line} must pass a { ... } object as its second argument"
      when "not_closed" then "The messages(...) call on line #{line} is not closed with a matching } and )"
      when "invalid_json" then "The messages(...) object on line #{line} must be strict JSON with double-quoted keys and texts and no trailing commas"
      else "The messages(...) object on line #{line} must map each language code to an object of keys and texts"
      end
    end

    def read_block(text, match, in_module)
      line = line_at(text, match.begin(0))
      block = { cutout_id: match[2], catalog: nil, line: line, first_line: line, last_line: nil, in_module_script: in_module, error: nil }
      start = match.end(0)
      unless text[start] == "{"
        block[:error] = "not_an_object"
        return block
      end
      finish = object_end(text, start)
      if finish.nil?
        block[:error] = "not_closed"
        return block
      end
      closing = text[(finish + 1)..-1].match(/\A\s*\)/)
      unless closing
        block[:error] = "not_closed"
        return block
      end
      block[:last_line] = line_at(text, finish + closing.end(0))
      begin
        parsed = JSON.parse(text[start..finish])
      rescue JSON::ParserError
        block[:error] = "invalid_json"
        return block
      end
      if parsed.is_a?(Hash) && parsed.values.all? { |value| value.is_a?(Hash) }
        block[:catalog] = parsed
      else
        block[:error] = "invalid_shape"
      end
      block
    end

    def object_end(text, start)
      depth = 0
      in_string = false
      index = start
      while index < text.length
        char = text[index]
        if in_string
          if char == "\\"
            index += 1
          elsif char == "\""
            in_string = false
          end
        elsif char == "\""
          in_string = true
        elsif char == "{"
          depth += 1
        elsif char == "}"
          depth -= 1
          return index if depth.zero?
        end
        index += 1
      end
      nil
    end

    def line_at(text, offset)
      text[0...offset].count("\n") + 1
    end
  end
end
