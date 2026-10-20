require "json"
require "time"

module Reach
  module PlanAudit
    SCHEMA = "reach.plan-audit/v1".freeze
    PACKET_SCHEMA = "reach.plan-audit-packet/v1".freeze
    FILE = "plan-audit.json".freeze
    DIGEST_FIELDS = %w[behaviour input output steps edge_cases scenarios].freeze
    LIST_DIGEST_FIELDS = %w[steps edge_cases scenarios].freeze
    VERDICTS = %w[pass fail].freeze
    AUDITORS = %w[subagent separate_pass].freeze
    MODES = %w[enforce advise off].freeze
    MAX_FINDINGS = 12
    MAX_REASONS = 8
    MAX_PART = 300
    UNUSED_PORTS = %w[ports.clock. ports.logger.].freeze

    module_function

    def path(workspace)
      File.join(workspace, Reach::Workspace::MARKER_DIR, FILE)
    end

    def normalized(plan)
      DIGEST_FIELDS.map do |field|
        value = LIST_DIGEST_FIELDS.include?(field) ? Array(plan[field]).map(&:to_s) : plan[field].to_s
        [field, value]
      end.to_h
    end

    def plan_digest(plan)
      return nil unless plan.is_a?(Hash)

      Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(normalized(plan)))
    end

    def read_json(file)
      return nil unless File.file?(file)

      data = JSON.parse(File.read(file))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def required_apis(slice_api, instructor_apis, panel)
      return [] if panel

      given = slice_api["required_apis"]
      return Array(given).map(&:to_s) if given.is_a?(Array)

      instructor_apis.select { |line| line.start_with?("ports.") && UNUSED_PORTS.none? { |prefix| line.start_with?(prefix) } }
    end

    def constraints(workspace)
      meta = Reach::Workspace.metadata(workspace)
      slice_api = read_json(File.join(workspace, "api", "slice-api.json")) || {}
      contract_file = File.join(workspace, "contract", "README.md")
      operation = slice_api["operation"].is_a?(Hash) ? slice_api["operation"] : nil
      instructor_apis = Array(slice_api["instructor_apis"]).map(&:to_s)
      panel = meta["slice"].to_s == "panel" || slice_api["slice"].to_s == "panel"
      {
        "cutout_id" => meta["cutout_id"].to_s,
        "slice" => meta["slice"].to_s,
        "behavior" => meta["behavior"].to_s,
        "operation" => operation,
        "contract" => File.file?(contract_file) ? File.read(contract_file) : "",
        "instructor_apis" => instructor_apis,
        "required_apis" => required_apis(slice_api, instructor_apis, panel),
        "constraints" => Array(slice_api["constraints"]).map(&:to_s),
        "graded_scenarios" => Array(meta["scenarios"]).map { |item| item.is_a?(Hash) ? item["name"] : item }.compact.map(&:to_s),
        "owned_files" => Array(meta["owned_files"]).map(&:to_s)
      }
    end

    def constraints_digest(workspace)
      Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(constraints(workspace)))
    end

    def packet(workspace)
      plan = Reach::Plan.load(workspace)
      {
        "schema" => PACKET_SCHEMA,
        "plan" => plan ? normalized(plan) : nil,
        "plan_digest" => plan_digest(plan),
        "constraints" => constraints(workspace),
        "constraints_digest" => constraints_digest(workspace),
        "instructions" => Reach::Messages.text("M-PLAN-AUDIT-PACKET")
      }
    end

    def parse_finding(text)
      parts = text.to_s.split("|", 3).map { |part| part.strip[0, MAX_PART] }
      { "constraint" => parts[0].to_s, "plan_item" => parts[1].to_s, "problem" => parts[2].to_s }
    end

    def record!(workspace, verdict:, reasons: [], findings: [], auditor: nil, harness: nil)
      verdict = verdict.to_s
      raise Reach::Refused, Reach::Messages.text("M-PLAN-AUDIT-VERDICT") unless VERDICTS.include?(verdict)

      plan = Reach::Plan.load(workspace)
      raise Reach::Refused, Reach::Messages.text("M-PLAN-NONE") unless plan

      parsed = Array(findings).map(&:to_s).reject { |text| text.strip.empty? }.first(MAX_FINDINGS).map { |text| parse_finding(text) }
      raise Reach::Refused, Reach::Messages.text("M-PLAN-AUDIT-FINDINGS") if verdict == "fail" && parsed.empty?

      auditor = AUDITORS.include?(auditor.to_s) ? auditor.to_s : "separate_pass"
      record = {
        "schema" => SCHEMA,
        "plan_digest" => plan_digest(plan),
        "constraints_digest" => constraints_digest(workspace),
        "verdict" => verdict,
        "reasons" => Array(reasons).map { |text| text.to_s[0, MAX_PART] }.reject(&:empty?).first(MAX_REASONS),
        "findings" => parsed,
        "auditor" => auditor,
        "harness" => (harness || Reach::Session.detect_harness).to_s,
        "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
      Reach::StateFile.write_atomic(path(workspace), JSON.generate(record))
      Reach::Ledger.append(workspace, "plan_audit", "verdict" => verdict, "plan_digest" => record["plan_digest"])
      record
    end

    def load(workspace)
      read_json(path(workspace))
    end

    def current(workspace)
      record = load(workspace)
      return nil unless record

      plan = Reach::Plan.load(workspace)
      return nil unless plan
      return nil unless record["plan_digest"] == plan_digest(plan)
      return nil unless record["constraints_digest"] == constraints_digest(workspace)

      record
    end

    def mode
      value = Reach::CourseProfile.section("qualify")["plan_audit"].to_s
      MODES.include?(value) ? value : "advise"
    end

    def render(record)
      return Reach::Messages.text("M-PLAN-AUDIT-NONE") unless record

      lines = ["Verdict: #{record['verdict']}", "When: #{record['at']}", "Auditor: #{record['auditor']}"]
      Array(record["reasons"]).each { |reason| lines << "Reason: #{reason}" }
      Array(record["findings"]).each do |finding|
        lines << "Finding: #{[finding['constraint'], finding['plan_item'], finding['problem']].join(' - ')}"
      end
      lines.join("\n")
    end
  end
end
