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
    BODY = %r{(?:(?!:\d)[^\n])*[/\\]}.freeze
    FINAL = %r{([^\s/\\:]*)}.freeze
    HOME_PATH = %r{(?<!\w)~(?=[/\\])#{BODY}#{FINAL}}.freeze
    DRIVE_PATH = %r{(?<![A-Za-z0-9])[A-Za-z]:#{BODY}#{FINAL}|(?<!\\)\\\\(?=[^\\\s])#{BODY}#{FINAL}}.freeze
    PATH_TOKEN = %r{(?<![\w./~\\-])(?=/[^\s/])#{BODY}#{FINAL}}.freeze
    UP_PATH = %r{(?<![\w.])\.\.(?=[/\\])#{BODY}#{FINAL}}.freeze
    FILE_URI = %r{\bfile://#{BODY}#{FINAL}}.freeze
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
      return nil unless scrubber_for

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
      write_state(workspace, read_state(workspace).merge("last_fault_id" => fault["fault_id"]))
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
        "pattern_matches" => Array(record["pattern_matches"]).map { |row| row.slice("id", "severity", "file", "line").merge("file" => clean(workspace, row["file"].to_s, scrubber)) },
        "probe" => Array(record["probe"]).map { |row| row.slice("scenario", "port", "sensitive").merge("scenario" => clean(workspace, row["scenario"].to_s, scrubber)) },
        "passes" => passes_summary(workspace, record),
        "plan_digest" => plan_digest(workspace, record),
        "constraints_digest" => Reach::PlanAudit.constraints_digest(workspace),
        "files_digest" => record["files_digest"],
        "tests_digest" => record["tests_digest"],
        "package_version" => meta["package_version"],
        "kit_digest" => kit_digest(workspace),
        "suite_version" => record["suite_version"],
        "environment" => environment,
        "previous_fault_id" => previous ? previous["fault_id"] : read_state(workspace)["last_fault_id"],
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
        "scenario" => hidden || finding["name"].nil? ? nil : clean(workspace, finding["name"].to_s, scrubber),
        "step_text" => step.to_s.empty? ? nil : step[0, LINE_LIMIT],
        "error_class" => detail[ERROR_CLASS, 1],
        "first_error_line" => first_line(detail),
        "location" => hidden ? nil : safe_location(location_of(meta, finding, detail))
      }
    end

    def safe_location(value)
      text = value.to_s
      return nil if text.empty?
      return nil if text.start_with?("/", "\\", "~") || text.match?(/\A[A-Za-z]:/) || text.include?("\0")
      return nil if text.sub(/:\d+\z/, "").split(%r{[/\\]}).any? { |part| part.empty? || part == ".." || part == "." }

      text
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
      value = value.gsub(/#{Regexp.escape(home)}(?=[\/\\]|$)/, "~") unless home.length < 3
      value = value.gsub(FILE_URI, DROPPED)
      value = value.gsub(UP_PATH, DROPPED)
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
      if ENV["REACH_ENV_REPORT_DISABLE"].to_s == "1"
        return { "reach_version" => Reach::VERSION, "ruby" => nil, "platform" => nil, "harness" => nil, "harness_confidence" => nil }
      end

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

      scrubber = scrubber_for
      return nil unless scrubber

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

      chosen = pending.first([room, BATCH].min)
      batch = chosen.map { |entry| rescrub(entry, scrubber) }.compact
      dropped = chosen.map { |entry| entry["fault_id"] } - batch.map { |entry| entry["fault_id"] }
      if batch.empty?
        prune(workspace, dropped)
        write_state(workspace, state.merge("sent" => ((sent + dropped) & records(workspace).map { |entry| entry["fault_id"] }), "window" => window))
        return nil
      end

      result = Reach::Client.with_deadline(SEND_BUDGET_S) do
        Reach::Client.for_install(install).post_json(ROUTE, { "faults" => batch }, idempotency_key: batch.first["fault_id"])
      end
      body = result.json || {}
      settled = Array(body["accepted"]) + Array(body["duplicate"]) + Array(body["rejected"]).map { |row| row.is_a?(Hash) ? row["fault_id"] : nil }.compact
      settled = batch.map { |entry| entry["fault_id"] } if settled.empty?
      prune(workspace, settled + dropped)
      kept = records(workspace).map { |entry| entry["fault_id"] }
      write_state(workspace, state.merge("sent" => ((sent + settled + dropped) & kept), "window" => window + Array.new(settled.length, now)))
      settled
    rescue Reach::RemoteRefused => e
      state = read_state(workspace)
      write_state(workspace, state.merge("unsupported_until" => Time.now.to_i + BACKOFF_S)) if e.code == "not_found"
      nil
    rescue StandardError
      nil
    end

    def prune(workspace, ids)
      return if ids.empty?

      remaining = records(workspace).reject { |entry| ids.include?(entry["fault_id"]) }
      body = remaining.map { |entry| JSON.generate(entry) }.join("\n")
      Reach::StateFile.write_atomic(path(workspace), remaining.empty? ? "" : body + "\n")
    end

    def rescrub(entry, scrubber)
      copy = JSON.parse(JSON.generate(entry))
      Array(copy["findings"]).each do |row|
        %w[scenario step_text first_error_line location].each do |key|
          row[key] = Reach::Deidentify.scrub(row[key].to_s, scrubber, RECORD_LIMIT).fetch("text") unless row[key].nil?
        end
      end
      Array(copy["pattern_matches"]).each do |row|
        row["file"] = Reach::Deidentify.scrub(row["file"].to_s, scrubber, RECORD_LIMIT).fetch("text") unless row["file"].nil?
      end
      Array(copy["probe"]).each do |row|
        row["scenario"] = Reach::Deidentify.scrub(row["scenario"].to_s, scrubber, RECORD_LIMIT).fetch("text") unless row["scenario"].nil?
      end
      if ENV["REACH_ENV_REPORT_DISABLE"].to_s == "1" && copy["environment"].is_a?(Hash)
        copy["environment"] = copy["environment"].map { |key, value| [key, key == "reach_version" ? value : nil] }.to_h
      end
      copy
    rescue StandardError
      nil
    end

    def write_state(workspace, state)
      Reach::StateFile.write_atomic(state_path(workspace), JSON.generate(state))
    end
  end
end
