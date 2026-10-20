require "json"
require "time"
require "securerandom"

module Reach
  module QualifyFaults
    SCHEMA = "reach.qualify-fault/v1".freeze
    ROUTE = "/api/v1/qualify-faults".freeze
    FILE = "qualify-faults.jsonl".freeze
    STATE_FILE = "qualify-faults-state.json".freeze
    KEEP = 200
    BATCH = 20
    RATE_PER_HOUR = 60
    LINE_LIMIT = 500
    RECORD_LIMIT = 65_536
    FINDINGS_LIMIT = 20
    BACKOFF_S = 86_400
    SEND_BUDGET_S = 5
    PRE_RUN_STEPS = %w[plan_audit passes patterns check coverage].freeze
    ERROR_CLASS = /\b((?:[A-Z][A-Za-z0-9]*::)+[A-Z][A-Za-z0-9]*|[A-Z][A-Za-z0-9]*(?:Error|Exception|Failure))\b/.freeze
    BODY = %r{(?:(?!:\d)[^\n"'<>|()])*[/\\]}.freeze
    FINAL = %r{([^\s/\\:"'<>|()]*)}.freeze
    HOME_PATH = %r{(?<!\w)~(?=[/\\])#{BODY}#{FINAL}}.freeze
    DRIVE_PATH = %r{(?<![A-Za-z0-9])[A-Za-z]:#{BODY}#{FINAL}|(?<!\\)\\\\(?=[^\\\s])#{BODY}#{FINAL}}.freeze
    PATH_TOKEN = %r{(?<![\w./~\\-])(?=/[^\s/])#{BODY}#{FINAL}}.freeze
    DROPPED = "[path left out]".freeze
    HOME_MASK = "~/\u2026".freeze

    module_function

    def path(workspace)
      File.join(workspace, Reach::Workspace::MARKER_DIR, FILE)
    end

    def state_path(workspace)
      File.join(workspace, Reach::Workspace::MARKER_DIR, STATE_FILE)
    end

    def disabled?
      ENV["REACH_QUALIFY_FAULTS_DISABLE"].to_s == "1"
    end

    def capture(workspace, record, local_only:, counted:)
      return nil if disabled?

      fault = nil
      if record["passed"] == false && record["pending"] == false
        fault = build(workspace, record, local_only, counted)
        append(workspace, fault)
        record["fault_id"] = fault["fault_id"]
      end
      flush(workspace)
      fault
    rescue StandardError
      nil
    end

    def records(workspace)
      file = path(workspace)
      return [] unless File.file?(file)

      File.readlines(file).map do |line|
        data = JSON.parse(line)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end.compact
    end

    def read_state(workspace)
      data = JSON.parse(File.read(state_path(workspace)))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def append(workspace, fault)
      list = records(workspace) + [fault]
      Reach::StateFile.write_atomic(path(workspace), list.last(KEEP).map { |entry| JSON.generate(entry) }.join("\n") + "\n")
    end

    def build(workspace, record, local_only, counted)
      meta = Reach::Workspace.metadata(workspace)
      previous = records(workspace).last
      steps = record["steps"].is_a?(Hash) ? record["steps"] : {}
      failed_pre = PRE_RUN_STEPS.find { |id| steps[id].is_a?(Hash) && steps[id]["ran"] && !steps[id]["passed"] }
      scrubber = scrubber_for
      fault = {
        "schema" => SCHEMA,
        "fault_id" => "qf_#{SecureRandom.hex(10)}",
        "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cutout_id" => meta["cutout_id"],
        "slice" => meta["slice"],
        "assignment" => meta["assignment"],
        "attempt" => record["attempt"],
        "counted" => counted,
        "local_only" => local_only == true,
        "refused_by" => failed_pre,
        "steps" => steps.map { |id, step| [id, { "ran" => step["ran"] == true, "passed" => step["passed"] == true, "ms" => step["ms"] }] }.to_h,
        "findings" => Array(record["findings"]).first(FINDINGS_LIMIT).map { |finding| finding_row(workspace, meta, finding, scrubber) },
        "pattern_matches" => Array(record["pattern_matches"]).map { |row| row.slice("id", "severity", "file", "line") },
        "probe" => Array(record["probe"]).map { |row| row.slice("scenario", "port", "sensitive") },
        "passes" => passes_summary(workspace, record),
        "plan_digest" => plan_digest(workspace, record),
        "constraints_digest" => Reach::PlanAudit.constraints_digest(workspace),
        "files_digest" => record["files_digest"],
        "tests_digest" => record["tests_digest"],
        "package_version" => meta["package_version"],
        "kit_digest" => kit_digest(workspace),
        "suite_version" => record["suite_version"],
        "environment" => environment,
        "previous_fault_id" => previous && previous["fault_id"],
        "qualification_id" => record["qualification_id"]
      }
      fit(fault)
    end

    def fit(fault)
      return fault if JSON.generate(fault).bytesize <= RECORD_LIMIT

      fault["findings"] = fault["findings"].first(5).map { |row| row.merge("first_error_line" => row["first_error_line"].to_s[0, 120]) }
      return fault if JSON.generate(fault).bytesize <= RECORD_LIMIT

      fault.merge("findings" => [], "probe" => [], "pattern_matches" => fault["pattern_matches"].first(20))
    end

    def finding_row(workspace, meta, finding, scrubber)
      code = finding["code"].to_s
      hidden = code == "QF-HIDDEN"
      detail = hidden ? "" : clean(workspace, finding["detail"].to_s, scrubber)
      step = hidden ? nil : clean(workspace, finding["step"].to_s, scrubber)
      {
        "code" => code,
        "scenario" => hidden ? nil : finding["name"],
        "step_text" => step.to_s.empty? ? nil : step[0, LINE_LIMIT],
        "error_class" => detail[ERROR_CLASS, 1],
        "first_error_line" => first_line(detail),
        "location" => location_of(meta, finding, detail)
      }
    end

    def first_line(text)
      line = text.to_s.lines.map(&:strip).find { |candidate| !candidate.empty? }
      line ? line[0, LINE_LIMIT] : nil
    end

    def location_of(meta, finding, detail)
      allowed = Array(meta["owned_files"]).map(&:to_s)
      explicit = finding["location"].to_s
      return explicit if !explicit.empty? && (explicit.start_with?("qualify/") || allowed.include?(explicit.sub(/:\d+\z/, "")))

      found = detail.scan(%r{(?:qualify/[\w./\-]+|#{allowed.map { |file| Regexp.escape(file) }.join('|')})(?::\d+)?}).first if allowed.any?
      found ||= detail[%r{qualify/[\w./\-]+(?::\d+)?}]
      found
    end

    def scrubber_for
      install = Reach::Enroll.current
      return nil unless install

      Reach::Deidentify.scrubber(install, Reach::Sync.cached_status || {})
    rescue StandardError
      nil
    end

    def clean(workspace, text, scrubber)
      value = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      root = File.expand_path(workspace)
      value = value.gsub("#{root}/", "").gsub("#{root.tr('/', '\\')}\\", "")
      home = begin
        Reach::Paths.user_home.to_s
      rescue StandardError
        ""
      end
      value = value.gsub(home, "~") unless home.length < 3
      value = value.gsub(HOME_PATH) { HOME_MASK + File.extname(Regexp.last_match(1).to_s) }
      value = value.gsub(DRIVE_PATH, DROPPED)
      value = value.gsub(PATH_TOKEN, DROPPED)
      value = Reach::Hands.scrub(value)
      value = Reach::Deidentify.scrub(value, scrubber, RECORD_LIMIT)["text"] if scrubber
      value
    rescue StandardError
      DROPPED
    end

    def passes_summary(workspace, record)
      Hash(record["passes"]).map do |point, pick|
        score = Reach::Passes.read_json(Reach::Passes.score_path(workspace, point))
        row = score && Array(score["candidates"]).find { |candidate| candidate["lens"] == pick["lens"] }
        [point, { "lens" => pick["lens"], "confidence" => pick["confidence"], "criteria" => row ? row["criteria"] : {} }]
      end.to_h
    end

    def plan_digest(workspace, record)
      audit = record["plan_audit"]
      return audit["plan_digest"] if audit.is_a?(Hash) && audit["plan_digest"]

      Reach::PlanAudit.plan_digest(Reach::Plan.load(workspace))
    end

    def kit_digest(workspace)
      dir = File.join(workspace, Reach::Qualify::KIT_DIR)
      return nil unless File.directory?(dir)

      map = Dir.glob(File.join(dir, "**", "*")).sort.first(2000).select { |file| File.file?(file) && !File.symlink?(file) }.map do |file|
        [file.sub("#{dir}/", ""), Reach::Crypto.digest_hex(File.binread(file))]
      end.to_h
      Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(map))
    end

    def environment
      fields = Reach::Environment.fields
      identity = Reach::HarnessIdentity.detect
      {
        "reach_version" => Reach::VERSION,
        "ruby" => fields["ruby"],
        "platform" => [fields["os"], fields["arch"]].compact.join("-"),
        "harness" => fields["harness"],
        "harness_confidence" => identity["confidence"]
      }
    rescue StandardError
      { "reach_version" => Reach::VERSION, "ruby" => RUBY_VERSION, "platform" => nil, "harness" => nil, "harness_confidence" => nil }
    end

    def flush(workspace)
      return nil if disabled?

      install = Reach::Enroll.current
      return nil unless install

      state = read_state(workspace)
      now = Time.now.to_i
      return nil if state["unsupported_until"].to_i > now

      sent = Array(state["sent"])
      pending = records(workspace).reject { |entry| sent.include?(entry["fault_id"]) }
      return nil if pending.empty?

      window = Array(state["window"]).select { |stamp| stamp.to_i > now - 3600 }
      room = RATE_PER_HOUR - window.length
      if room <= 0
        state["deferred"] = state["deferred"].to_i + pending.length
        write_state(workspace, state.merge("window" => window))
        return nil
      end

      batch = pending.first([room, BATCH].min)
      result = Reach::Client.with_deadline(SEND_BUDGET_S) do
        Reach::Client.for_install(install).post_json(ROUTE, { "faults" => batch }, idempotency_key: batch.first["fault_id"])
      end
      body = result.json || {}
      settled = Array(body["accepted"]) + Array(body["duplicate"]) + Array(body["rejected"]).map { |row| row.is_a?(Hash) ? row["fault_id"] : nil }.compact
      settled = batch.map { |entry| entry["fault_id"] } if settled.empty?
      kept = records(workspace).map { |entry| entry["fault_id"] }
      write_state(workspace, state.merge("sent" => ((sent + settled) & kept), "window" => window + Array.new(settled.length, now)))
      settled
    rescue Reach::RemoteRefused => e
      state = read_state(workspace)
      write_state(workspace, state.merge("unsupported_until" => Time.now.to_i + BACKOFF_S)) if e.code == "not_found"
      nil
    rescue StandardError
      nil
    end

    def write_state(workspace, state)
      Reach::StateFile.write_atomic(state_path(workspace), JSON.generate(state))
    end
  end
end
