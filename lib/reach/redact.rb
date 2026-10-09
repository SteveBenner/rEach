require "digest"

module Reach
  module Redact
    PRIVATE_TOOLS = %w[
      reach_profile_show reach_profile_save reach_profile_forget reach_recall reach_remember reach_memory_forget reach_import
    ].freeze
    PRIVATE_TOOL_PATTERN = /(?:\A|[^A-Za-z0-9])(?:#{PRIVATE_TOOLS.join('|')})\z/.freeze
    PRIVATE_VERBS = %w[profile recall remember memory import].freeze
    PRIVATE_SHELL_PATTERN = %r{(?:\A|[\s;&|(`'"=/\\])reach(?:\.(?:cmd|exe|bat))?\s+(?:-\S+\s+)*(?:#{PRIVATE_VERBS.join('|')})(?![A-Za-z0-9_-])}.freeze
    PRIVATE_SHELL_EXTRACURRICULAR = %r{(?:\A|[\s='"/\\])extracurricular(?:[/\\]|(?=[\s'"]|\z))}.freeze
    PRIVATE_SUMMARY = "[private tool call withheld]".freeze
    PRIVATE_OUTPUT_NOTE = "private output withheld".freeze
    PATH_KEYS = %w[file_path notebook_path path directory dir root pattern glob].freeze
    TEXT_FIELDS = %w[text summary].freeze
    NOTE_LIMIT = 200

    KEYWORDS = {
      "password" => "pass(?:word|wd|phrase)?",
      "secret" => "secret(?:[_-]?key)?",
      "token" => "token",
      "api_key" => "api[_-]?key",
      "access_key" => "access[_-]?key",
      "private_key" => "private[_-]?key",
      "auth" => "auth(?:orization|entication)?(?!or(?:s|ed|ing)?(?![a-z]))",
      "cookie" => "cookie",
      "session" => "session"
    }.freeze
    KEYWORD_PATTERN = KEYWORDS.map { |name, source| "(?<#{name}>#{source})" }.join("|").freeze
    KEY_VALUE = /
      (?<![A-Za-z0-9_])
      (?<key>[A-Za-z0-9_.\-]*?(?:#{KEYWORD_PATTERN})(?![a-z])[A-Za-z0-9_.\-]*)
      (?<sep>["']?[ \t]*[:=][ \t]*)
      (?:(?<q>["'])(?<qv>[^\n]*?)\k<q>|(?<v>[^\s"',;&<>)}\]]+))
    /xi.freeze
    FLAG_VALUE = /
      (?<![A-Za-z0-9_])
      (?<key>--[A-Za-z0-9\-]*?(?:#{KEYWORD_PATTERN})(?![a-z])[A-Za-z0-9\-]*)
      (?<sep>[ \t]+|=)
      (?:(?<q>["'])(?<qv>[^\n]*?)\k<q>|(?<v>[^\s"',;&<>)}\]\-][^\s"',;&<>)}\]]*))
    /xi.freeze
    PEM = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\z)/m.freeze
    CONNECTION = %r{\b((?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqps?|mssql|sqlserver)://)[^\s/@'"]*:[^\s/@'"]+@}i.freeze
    URL_USERINFO = %r{\b([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/@:'"]+:[^\s/@'"]+@}.freeze
    AUTHORIZATION = /(\b(?:proxy-)?authorization["']?[ \t]*[:=][ \t]*["']?)(?:(?:bearer|basic|token|digest|negotiate)[ \t]+)?[^\s"',;]+/i.freeze
    BEARER = /\b(bearer|basic)([ \t]+)(?=[A-Za-z0-9\-._~+\/]*\d)[A-Za-z0-9\-._~+\/]{12,}=*/i.freeze
    COOKIE_HEADER = /(\b(?:set-)?cookie["']?[ \t]*:[ \t]*["']?)[^\r\n"']+/i.freeze
    JWT = /(?<![A-Za-z0-9_\-])eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*/.freeze
    TOKEN_SHAPES = [
      /(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}/,
      /(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{20,}/,
      /(?<![A-Za-z0-9_])sk-ant-[A-Za-z0-9_\-]{16,}/,
      /(?<![A-Za-z0-9_])sk-[A-Za-z0-9_\-]{20,}/,
      /(?<![A-Za-z0-9_])xox[abposr]-[A-Za-z0-9\-]{10,}/,
      /(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])/,
      /(?<![A-Za-z0-9_])AIza[0-9A-Za-z_\-]{35}/,
      /(?<![A-Za-z0-9_])glpat-[A-Za-z0-9_\-]{20,}/,
      /(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36}/
    ].freeze
    INERT_VALUE = /\A(?:true|false|nil|null|none|undefined|yes|no)\z/i.freeze
    CODE_VALUE = /\A(?:[$%<@]|\{\{|[A-Za-z_]\w*(?:\(|\[|::)|[A-Z][A-Za-z0-9]*\.[a-z_]\w*[?!]?\z|(?:params|ENV|env|self|this|options|opts|config|args|input|data|request|req|os|process|settings|context|ctx|form|user|creds|credentials)\.[A-Za-z_]\w*)/.freeze
    COUNTED_SKIP = %w[session auth token cookie].freeze
    METRIC_KEY = /(?:count|limit|length|size|max|min|ttl|expires?|timeout|age|total)\z/i.freeze

    module_function

    def marker(klass)
      "[redacted:#{klass}]"
    end

    def text(value)
      counts = {}
      return [value, counts] unless value.is_a?(String) && !value.empty?

      out = value.dup
      out = out.scrub("�") unless out.valid_encoding?
      out = sweep(out, PEM, counts, "private_key")
      out = out.gsub(CONNECTION) { counts["connection_string"] = counts.fetch("connection_string", 0) + 1; "#{Regexp.last_match(1)}#{marker('connection_string')}@" }
      out = out.gsub(URL_USERINFO) { counts["url_credentials"] = counts.fetch("url_credentials", 0) + 1; "#{Regexp.last_match(1)}#{marker('url_credentials')}@" }
      out = out.gsub(AUTHORIZATION) do
        head = Regexp.last_match(1)
        counts["authorization"] = counts.fetch("authorization", 0) + 1
        "#{head}#{marker('authorization')}"
      end
      out = out.gsub(BEARER) { counts["bearer"] = counts.fetch("bearer", 0) + 1; "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{marker('bearer')}" }
      out = out.gsub(COOKIE_HEADER) do
        head = Regexp.last_match(1)
        counts["cookie"] = counts.fetch("cookie", 0) + 1
        "#{head}#{marker('cookie')}"
      end
      TOKEN_SHAPES.each { |shape| out = sweep(out, shape, counts, "token") }
      out = sweep(out, JWT, counts, "jwt")
      out = pairs(out, KEY_VALUE, counts)
      out = pairs(out, FLAG_VALUE, counts)
      [out, counts]
    end

    def sweep(value, pattern, counts, klass)
      value.gsub(pattern) do
        counts[klass] = counts.fetch(klass, 0) + 1
        marker(klass)
      end
    end

    def pairs(value, pattern, counts)
      value.gsub(pattern) do
        found = Regexp.last_match
        secret = found[:qv] || found[:v]
        klass = KEYWORDS.keys.find { |name| found[name] }
        if secret.nil? || secret.empty? || secret.start_with?("[redacted:") || INERT_VALUE.match?(secret) || CODE_VALUE.match?(secret) ||
           (COUNTED_SKIP.include?(klass) && secret.match?(/\A\d+\z/)) || METRIC_KEY.match?(found[:key])
          found[0]
        else
          counts[klass] = counts.fetch(klass, 0) + 1
          quote = found[:q].to_s
          "#{found[:key]}#{found[:sep]}#{quote}#{marker(klass)}#{quote}"
        end
      end
    end

    def note(counts)
      return nil if counts.nil? || counts.empty?

      text = "redacted: #{counts.sort.map { |klass, n| "#{klass} x#{n}" }.join(', ')}"
      text.bytesize > NOTE_LIMIT ? text.byteslice(0, NOTE_LIMIT).scrub("") : text
    end

    def merge_counts(*sets)
      sets.each_with_object({}) do |set, total|
        (set || {}).each { |klass, n| total[klass] = total.fetch(klass, 0) + n }
      end
    end

    def join_notes(*notes)
      parts = notes.map { |item| item.to_s }.reject(&:empty?).uniq
      return nil if parts.empty?

      joined = parts.join("; ")
      joined.bytesize > NOTE_LIMIT ? joined.byteslice(0, NOTE_LIMIT).scrub("") : joined
    end

    def private_tool?(name)
      PRIVATE_TOOL_PATTERN.match?(name.to_s)
    end

    def private_roots
      home = Reach::Paths.home
      legacy = Reach::Paths.legacy_home
      roots = [Reach::Paths.extracurricular_root]
      [home, legacy].each do |base|
        roots.concat([File.join(base, "profile.yml"), File.join(base, "brain"), File.join(base, "brain-store"), File.join(base, "corpora")])
      end
      roots << File.join(Reach::Paths.state_dir, "hello")
      roots.compact.uniq
    rescue StandardError
      []
    end

    def resolve(path, base)
      expanded = File.expand_path(path.to_s, base || Dir.pwd)
      current = expanded
      rest = []
      until File.exist?(current) || current == File.dirname(current)
        rest.unshift(File.basename(current))
        current = File.dirname(current)
      end
      real = File.exist?(current) ? File.realpath(current) : current
      File.join(real, *rest)
    rescue StandardError
      nil
    end

    def inside_private_root?(path, base = nil)
      return false if path.nil? || path.to_s.empty?

      resolved = resolve(path, base)
      return false if resolved.nil?

      private_roots.any? do |root|
        [File.expand_path(root), resolve(root, nil)].compact.uniq.any? do |candidate|
          resolved == candidate || resolved.start_with?("#{candidate}#{File::SEPARATOR}")
        end
      end
    rescue StandardError
      false
    end

    def shell_text(input)
      value = input["command"] || input["cmd"] || input["raw"]
      value.is_a?(Array) ? value.join(" ") : value.to_s
    end

    def private_shell?(command)
      text = command.to_s
      return true if PRIVATE_SHELL_PATTERN.match?(text)
      return true if PRIVATE_SHELL_EXTRACURRICULAR.match?(text)

      private_roots.any? { |root| !root.to_s.empty? && text.include?(root.to_s) }
    end

    def private_call?(tool_name, input, base = nil)
      return true if private_tool?(tool_name)

      input = input.is_a?(Hash) ? input : {}
      return true if private_shell?(shell_text(input))

      PATH_KEYS.any? do |key|
        value = input[key]
        next false unless value.is_a?(String) && !value.empty?

        inside_private_root?(value, base) || private_roots.any? { |root| value.include?(root) }
      end
    rescue StandardError
      false
    end

    def private_entry?(entry)
      return false unless entry.is_a?(Hash)
      return true if entry["withheld"] == true

      %w[action output].include?(entry["kind"].to_s) && private_tool?(entry["tool"])
    end

    def digest(text)
      Digest::SHA256.hexdigest(text)
    end

    def entry(source)
      return source unless source.is_a?(Hash)

      result = source.dup
      if private_entry?(result)
        result["withheld"] = true
        if result["kind"].to_s == "action"
          result["summary"] = PRIVATE_SUMMARY
        else
          result["text"] = nil
          result["bytes"] = 0
          result["truncated"] = false
          result["digest"] = nil
          result["note"] = PRIVATE_OUTPUT_NOTE
        end
        result.delete("part")
        result.delete("restore")
        return result
      end

      total = {}
      TEXT_FIELDS.each do |field|
        next unless result[field].is_a?(String)

        cleaned, counts = text(result[field])
        next if counts.empty?

        result[field] = cleaned
        total = merge_counts(total, counts)
        next unless field == "text"

        if result["truncated"] == true
          result["bytes"] = [result["bytes"].to_i, cleaned.bytesize].max
        else
          result["bytes"] = cleaned.bytesize
        end
        result["digest"] = digest(cleaned)
      end
      result["note"] = join_notes(result["note"], note(total)) unless total.empty?
      result
    end
  end
end
