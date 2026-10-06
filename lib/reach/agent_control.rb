require "yaml"
require "digest"

module Reach
  module AgentControl
    SCHEMA = "teach.agent-control/v1".freeze
    BUNDLED_FILE = File.expand_path("../../agent-control/agent-control.yml", __dir__).freeze
    BUNDLED_DIGEST_FILE = "#{BUNDLED_FILE}.sha256".freeze
    FLAGS = %w[render controls test_mode].freeze
    FALLBACK_FRAME = "information".freeze
    TIER_IDS = %w[wellbeing control rule student information operational].freeze
    FRAME_IDS = %w[wellbeing control test rule student information announcement operational].freeze
    PRECEDENCE_LINES = 5
    PRECEDENCE_CHANNELS = /\A(hello|gate|notice)\./.freeze
    VAULT_FILE = "agent-control.yml".freeze
    CHANNEL_IDS = [
      "hello.persona",
      "hello.session",
      "hello.course_question",
      "hello.greeting",
      "hello.issues",
      "hello.update",
      "hello.profile",
      "hello.course",
      "hello.modules",
      "hello.module_move",
      "hello.late_work",
      "hello.memory",
      "hello.storage",
      "hello.locked",
      "hello.hookless",
      "hello.login",
      "hello.refreshed",
      "hello.controls",
      "hello.test",
      "rules.slice",
      "rules.root",
      "rules.extracurricular",
      "rules.directives",
      "gate.refusal",
      "gate.login",
      "gate.signin",
      "gate.decision",
      "gate.instructor",
      "gate.control",
      "notice.update",
      "notice.storage",
      "notice.export_import",
      "notice.debug",
      "notice.late_work",
      "notice.announcement",
      "notice.due_change",
      "notice.transcripts",
      "notice.consent",
      "notice.live",
      "notice.import",
      "notice.next",
      "notice.memory",
      "notice.subscribe",
      "notice.control",
      "notice.test",
      "support.message",
      "mcp.relay",
      "mcp.announcements",
      "mcp.control",
      "mcp.test"
    ].freeze

    module_function

    def flag?(name)
      section = Reach::Runtime.load_config["agent_control"]
      section.is_a?(Hash) && section[name.to_s] == true
    rescue StandardError
      false
    end

    def bundled_text
      File.binread(BUNDLED_FILE).force_encoding("UTF-8")
    end

    def bundled_digest_ok?
      expected = File.read(BUNDLED_DIGEST_FILE).split.first.to_s
      !expected.empty? && Digest::SHA256.hexdigest(File.binread(BUNDLED_FILE)) == expected
    rescue StandardError
      false
    end

    def parse(text)
      doc = YAML.safe_load(text)
      doc.is_a?(Hash) ? doc : nil
    rescue StandardError
      nil
    end

    def vault_file
      File.join(Reach::Guardrails.vault_path, VAULT_FILE)
    end

    def vault_candidate(bundled)
      path = vault_file
      return [nil, nil] unless File.file?(path)

      doc = parse(File.binread(path).force_encoding("UTF-8"))
      return [nil, "the course copy could not be read"] unless doc

      found = document_problems(doc)
      return [nil, found.first.to_s.sub("R-DOC-AGENT-CONTROL: ", "")] unless found.empty?
      return [nil, "the course copy is older than the bundled copy"] if bundled.is_a?(Hash) && doc["version"].to_i < bundled["version"].to_i

      [doc, nil]
    rescue StandardError
      [nil, nil]
    end

    def selected
      @selected ||= begin
        bundled = bundled_digest_ok? ? parse(bundled_text) : nil
        vault, refusal = vault_candidate(bundled)
        if vault
          { "doc" => vault, "source" => "vault", "refusal" => nil }
        else
          { "doc" => bundled, "source" => "bundled", "refusal" => refusal }
        end
      end
    rescue StandardError
      @selected = { "doc" => nil, "source" => "none", "refusal" => nil }
    end

    def reset!
      @selected = nil
      @opened = false
      @fallback_reported = false
    end

    def begin_context
      @opened = false
    end

    def load
      chosen = selected
      report_fallback(chosen["refusal"])
      chosen["doc"]
    end

    def report_fallback(reason)
      return if reason.nil? || @fallback_reported

      @fallback_reported = true
      Reach::Debug.emit("control", "check" => "agent_control", "outcome" => "agent_control_fallback", "reason" => reason.to_s)
    rescue StandardError
      nil
    end

    def channel_entry(doc, id)
      Array(doc["channels"]).find { |entry| entry.is_a?(Hash) && entry["id"].to_s == id.to_s }
    end

    def frame_id(doc, id)
      entry = channel_entry(doc, id)
      frames = doc["frames"].is_a?(Hash) ? doc["frames"] : {}
      name = entry ? entry["frame"].to_s : FALLBACK_FRAME
      frames.key?(name) ? name : FALLBACK_FRAME
    end

    def fill(template, fields)
      values = fields.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value.to_s }
      template.to_s.gsub(/\{(\w+)\}/) { values.fetch(Regexp.last_match(1), "") }.gsub(/ {2,}/, " ").gsub(/ +([.,;:])/, "\\1")
    end

    def frame_text(doc, frame, text, fields)
      spec = doc["frames"].is_a?(Hash) ? doc["frames"][frame] : nil
      return text unless spec.is_a?(Hash)

      [fill(spec["open"], fields), text.to_s.chomp, fill(spec["close"], fields)].reject(&:empty?).join("\n")
    end

    def precedence_heading(doc)
      precedence = doc["precedence"]
      precedence.is_a?(Hash) ? precedence["heading"].to_s : ""
    end

    def carries_precedence?(doc, text)
      heading = precedence_heading(doc)
      !heading.empty? && text.include?(heading)
    end

    def channel(id, **fields)
      text = yield
      return text unless flag?("render")
      return text if text.nil? || text.to_s.strip.empty?

      render_block(id.to_s, text.to_s, fields) || text
    rescue StandardError
      text
    end

    def render_block(id, text, fields)
      doc = load
      return nil unless doc

      if carries_precedence?(doc, text)
        @opened = true
        return text
      end
      body = frame_text(doc, frame_id(doc, id), text, fields)
      return body if @opened || !id.match?(PRECEDENCE_CHANNELS)

      @opened = true
      "#{precedence_text(doc)}\n\n#{body}"
    end

    def compose(entries, separator = "\n")
      triples = entries.map { |id, value, fields| [id, value, fields || {}] }
      return triples.map { |_id, value, _fields| value }.join(separator) unless flag?("render")

      doc = load
      return triples.map { |_id, value, _fields| value }.join(separator) unless doc

      groups = []
      triples.each do |id, value, fields|
        frame = frame_id(doc, id)
        if groups.last && groups.last[:frame] == frame && groups.last[:fields] == fields
          groups.last[:values] << value
        else
          groups << { frame: frame, id: id, fields: fields, values: [value] }
        end
      end
      groups.map { |group| channel(group[:id], **group[:fields]) { group[:values].join(separator) } }.join(separator)
    end

    def time_fields(prefix, formatted)
      stamp = formatted.to_s.split(" ")
      {
        "#{prefix}_weekday".to_sym => stamp[0].to_s,
        "#{prefix}_date".to_sym => stamp[1, 2].to_a.join(" "),
        "#{prefix}_time".to_sym => stamp[3, 2].to_a.join(" "),
        :time_zone => stamp[5..-1].to_a.join(" ")
      }
    end

    def precedence_text(doc = load)
      precedence = doc.is_a?(Hash) ? doc["precedence"] : nil
      return nil unless precedence.is_a?(Hash) && precedence["lines"].is_a?(Array)

      [precedence["heading"].to_s, *precedence["lines"].map(&:to_s)].reject(&:empty?).join("\n")
    end

    def rules_section(_space = nil)
      return nil unless flag?("render")

      doc = load
      precedence = doc.is_a?(Hash) ? doc["precedence"] : nil
      return nil unless precedence.is_a?(Hash) && precedence["lines"].is_a?(Array)

      ["# #{precedence["heading"]}", "", *precedence["lines"].map(&:to_s)].join("\n")
    rescue StandardError
      nil
    end

    def problems
      found = []
      found << "R-DOC-AGENT-CONTROL: the bundled agent-control.yml does not match its digest" unless bundled_digest_ok?
      doc = parse(bundled_text)
      return found + ["R-DOC-AGENT-CONTROL: the bundled agent-control.yml could not be read"] unless doc

      found.concat(document_problems(doc))
      found.concat(vault_problems(doc))
      found
    rescue StandardError
      ["R-DOC-AGENT-CONTROL: the bundled agent-control.yml could not be checked"]
    end

    def document_problems(doc)
      found = []
      found << "R-DOC-AGENT-CONTROL: schema is not #{SCHEMA}" unless doc["schema"] == SCHEMA
      found << "R-DOC-AGENT-CONTROL: version is not a positive integer" unless doc["version"].is_a?(Integer) && doc["version"].positive?
      found.concat(structure_problems(doc))
      found.concat(channel_problems(doc))
      found
    end

    def vault_problems(_bundled)
      path = vault_file
      return [] unless File.file?(path)

      doc = parse(File.binread(path).force_encoding("UTF-8"))
      return ["R-DOC-AGENT-CONTROL: the course copy of agent-control.yml could not be read; the bundled copy is in use"] unless doc

      document_problems(doc).map { |line| "#{line} (course copy refused; the bundled copy is in use)" }
    rescue StandardError
      []
    end

    def structure_problems(doc)
      found = []
      tiers = Array(doc["tiers"]).map { |tier| tier.is_a?(Hash) ? tier["id"] : nil }
      found << "R-DOC-AGENT-CONTROL: tiers are not #{TIER_IDS.join(", ")}" unless tiers == TIER_IDS
      frames = doc["frames"].is_a?(Hash) ? doc["frames"] : {}
      (FRAME_IDS - frames.keys).each { |id| found << "R-DOC-AGENT-CONTROL: frame #{id} is missing" }
      lines = doc["precedence"].is_a?(Hash) ? doc["precedence"]["lines"] : nil
      found << "R-DOC-AGENT-CONTROL: the precedence block needs #{PRECEDENCE_LINES} lines" unless lines.is_a?(Array) && lines.size == PRECEDENCE_LINES
      found
    end

    def channel_problems(doc)
      entries = Array(doc["channels"]).select { |entry| entry.is_a?(Hash) }
      declared = entries.map { |entry| entry["id"].to_s }
      frames = doc["frames"].is_a?(Hash) ? doc["frames"] : {}
      found = []
      (CHANNEL_IDS - declared).each { |id| found << "R-DOC-AGENT-CONTROL: channel #{id} is not declared" }
      (declared - CHANNEL_IDS).each { |id| found << "R-DOC-AGENT-CONTROL: channel #{id} is declared but rEach never uses it" }
      entries.each do |entry|
        found << "R-DOC-AGENT-CONTROL: channel #{entry["id"]} names the frame #{entry["frame"].inspect}, which does not exist" unless frames.key?(entry["frame"])
        found << "R-DOC-AGENT-CONTROL: channel #{entry["id"]} names the tier #{entry["tier"].inspect}, which does not exist" unless TIER_IDS.include?(entry["tier"])
      end
      found
    end
  end
end
