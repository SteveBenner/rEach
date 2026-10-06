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

    def load
      return nil unless bundled_digest_ok?

      parse(bundled_text)
    rescue StandardError
      nil
    end

    def channel(_id, **_fields)
      yield
    end

    def precedence_text(doc = load)
      precedence = doc.is_a?(Hash) ? doc["precedence"] : nil
      return nil unless precedence.is_a?(Hash) && precedence["lines"].is_a?(Array)

      [precedence["heading"].to_s, *precedence["lines"].map(&:to_s)].reject(&:empty?).join("\n")
    end

    def rules_section(_space = nil)
      nil
    end

    def problems
      found = []
      found << "R-DOC-AGENT-CONTROL: the bundled agent-control.yml does not match its digest" unless bundled_digest_ok?
      doc = parse(bundled_text)
      return found + ["R-DOC-AGENT-CONTROL: the bundled agent-control.yml could not be read"] unless doc

      found << "R-DOC-AGENT-CONTROL: schema is not #{SCHEMA}" unless doc["schema"] == SCHEMA
      found << "R-DOC-AGENT-CONTROL: version is not a positive integer" unless doc["version"].is_a?(Integer) && doc["version"].positive?
      found.concat(structure_problems(doc))
      found.concat(channel_problems(doc))
      found
    rescue StandardError
      ["R-DOC-AGENT-CONTROL: the bundled agent-control.yml could not be checked"]
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
