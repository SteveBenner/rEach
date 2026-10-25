#!/usr/bin/env ruby
require "webrick"
require "json"
require "yaml"
require "optparse"
require "tmpdir"
require "fileutils"
require "openssl"
require "securerandom"
require "base64"
require "time"

ROOT = File.expand_path("../..", __dir__)
require File.join(ROOT, "lib", "reach", "crypto.rb")
require File.join(ROOT, "lib", "reach", "tarball.rb")
require File.join(ROOT, "lib", "reach", "readme_check.rb")

module FakeTeach
  MINIMUM_REACH_VERSION = "0.12.0".freeze
  VALIDATION_FROM = "0.61.0".freeze
  VALIDATION_SCHEMA = "teach.security-validation/v1".freeze
  VALIDATION_TTL_S = 3600
  VALIDATION_OWNED = %w[answers.json README.md].freeze
  VALIDATION_HARNESSES = %w[claude-code codex antigravity hermes].freeze
  SIGN_KEY_ID = "fake-sign-1".freeze
  ENC_KEY_ID = "fake-enc-1".freeze
  RATE_LIMIT = 30
  RATE_WINDOW_S = 60
  MAX_BODY_BYTES = 1_048_576
  CLOCK_SKEW_S = 300
  NONCE_TTL_S = 600
  PLATFORMS = %w[macos windows linux].freeze
  HEX64 = /\A[0-9a-f]{64}\z/.freeze
  LEGACY_TRIGGERS = %w[attempt_gate attempt_ladder student_request check_gate wellbeing].freeze
  NEWER_TRIGGERS = %w[
    late_work late_submission concept_question assignment_question deadline_question grade_question submission_question
    technical_issue setup_issue access_issue extension_request feedback integrity_question other issue
  ].freeze
  BUNDLE_TRIGGERS = %w[issue technical_issue setup_issue access_issue].freeze

  class Failure < StandardError
    attr_reader :status, :code, :details, :headers

    def initialize(status, code, message, details: nil, headers: {})
      super(message)
      @status = status
      @code = code
      @details = details
      @headers = headers
    end
  end

  module Text
    module_function

    def normalize_course_id(text)
      text.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    end

    def parse_code(text)
      chars = text.to_s.upcase.gsub(/[^A-Z0-9]/, "")
      return nil if chars.length < 9

      course_id = chars[0...-8]
      return nil if course_id.length > 16

      secret = chars[-8..-1].tr("OIL", "011")
      { "course_id" => course_id, "secret" => secret }
    end

    def distance(a, b)
      a = a.chars
      b = b.chars
      d = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }
      (0..a.length).each { |i| d[i][0] = i }
      (0..b.length).each { |j| d[0][j] = j }
      (1..a.length).each do |i|
        (1..b.length).each do |j|
          cost = a[i - 1] == b[j - 1] ? 0 : 1
          d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
          if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]
            d[i][j] = [d[i][j], d[i - 2][j - 2] + 1].min
          end
        end
      end
      d[a.length][b.length]
    end

    def version_at_least?(have, minimum)
      Gem::Version.new(have.to_s) >= Gem::Version.new(minimum)
    rescue ArgumentError
      false
    end
  end

  Reply = Struct.new(:status, :body, :etag)

  class Store
    PACKAGE_KINDS = %w[guardrails workspace].freeze
    PACKAGE_VERSION = 1
    PACKAGE_COURSE_ID = "demo.a1".freeze
    PACKAGE_SLICE = "backend".freeze
    PACKAGE_ASSIGNMENT = "A1".freeze
    PACKAGE_OWNED_FILE = "lib/greeter.rb".freeze

    def initialize(home)
      @home = home
      @mutex = Mutex.new
      @nonces = Hash.new { |h, k| h[k] = {} }
      @hits = Hash.new { |h, k| h[k] = [] }
      FileUtils.mkdir_p(@home, mode: 0o700)
      FileUtils.mkdir_p(File.join(@home, "keys"), mode: 0o700)
      @courses = load_courses
      @rosters = YAML.safe_load(File.read(File.join(__dir__, "fixtures", "roster.yml")))["rosters"]
      @signing_key = load_key("signing")
      @encryption_key = load_key("encryption")
      @installs = load_installs
      @wire_sha = Reach::Crypto.digest_hex(File.binread(File.join(ROOT, "specs", "wire.yml")))
      @wire_sha = ENV["FAKE_TEACH_WIRE_SHA"] unless ENV["FAKE_TEACH_WIRE_SHA"].to_s.empty?
      @submissions = []
      @replays = {}
      @hands = []
      @hand_replays = {}
      @feedback = []
      @feedback_replays = {}
      @packages = {}
      @validations = {}
    end

    def fixture(*parts)
      File.binread(File.join(__dir__, "fixtures", "packages", *parts))
    end

    def late_assignment
      value = ENV["FAKE_TEACH_LATE_ASSIGNMENT"].to_s
      value.empty? ? nil : value
    end

    def current_assignment_id
      late_assignment ? late_assignment.succ : PACKAGE_ASSIGNMENT
    end

    def cutout_for(assignment)
      "demo.#{assignment.downcase}"
    end

    def package_kinds
      late_assignment ? PACKAGE_KINDS + ["shape"] : PACKAGE_KINDS
    end

    def package_version_for(assignment)
      return PACKAGE_VERSION unless late_assignment

      return PACKAGE_VERSION + 1 unless assignment == late_assignment

      ENV["FAKE_TEACH_LATE_VERSION_FIRST"] == "1" ? PACKAGE_VERSION + 2 : PACKAGE_VERSION
    end

    def late_due_text
      base = due_time || (Time.now.utc + 7 * 86_400)
      (base - 86_400).strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def current_due_text
      due_text || (Time.now.utc + 7 * 86_400).strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def package_entries(kind, install_id, assignment = PACKAGE_ASSIGNMENT)
      cutout = cutout_for(assignment)
      if kind == "shape"
        return { "#{cutout}/shape.json" => JSON.generate("cutout_id" => cutout, "assignment" => assignment) }
      end

      if kind == "guardrails"
        seal = {
          "schema" => "teach.seal/v1",
          "ledger_key" => Reach::Crypto.digest_hex("ledger:#{install_id}"),
          "marks" => { PACKAGE_COURSE_ID => { PACKAGE_OWNED_FILE => Reach::Crypto.digest_hex("mark:#{install_id}")[0, 16] } }
        }
        {
          "course.yml" => fixture("guardrails", "course.yml"),
          "directives.yml" => fixture("guardrails", "directives.yml"),
          "seal.yml" => YAML.dump(seal)
        }
      else
        root = "#{cutout}-#{PACKAGE_SLICE}"
        manifest = {
          "course" => "DEMO101",
          "assignment" => assignment,
          "slices" => [
            { "cutout_id" => cutout, "slice" => PACKAGE_SLICE, "root" => root, "owned_files" => [PACKAGE_OWNED_FILE] }
          ]
        }
        {
          "slices.json" => JSON.generate(manifest),
          "#{root}/#{PACKAGE_OWNED_FILE}" => fixture("workspace", "lib", "greeter.rb")
        }
      end
    end

    def package_envelope(install_id, install, kind, assignment = current_assignment_id)
      @mutex.synchronize do
        @packages[[install_id, kind, assignment]] ||= begin
          header = {
            "schema" => "teach.package/v1",
            "kind" => kind,
            "id" => "pkgenv_#{SecureRandom.hex(10)}",
            "version" => package_version_for(assignment),
            "course" => install["course_id"],
            "assignment" => assignment,
            "student_id" => install["student_id"],
            "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "signing_key_id" => SIGN_KEY_ID
          }
          Reach::Crypto.seal(
            header: header,
            plaintext: Reach::Tarball.write(package_entries(kind, install_id, assignment)),
            recipient_public_key: OpenSSL::PKey::RSA.new(install["public_key_pem"]),
            signer_private_key: @signing_key
          )
        end
      end
    end

    def package(req, body, kind)
      install = authenticate!(req, body)
      raise Failure.new(404, "not_found", "no such route") unless package_kinds.include?(kind)

      assignment = current_assignment_id
      asked = req.query["assignment"].to_s
      if late_assignment && !asked.empty? && asked != assignment
        raise Failure.new(403, "not_released", "assignment is not open for work") unless asked == late_assignment
        raise Failure.new(404, "not_found", "no such route") if kind == "guardrails"

        assignment = asked
      end

      envelope = package_envelope(req["X-Teach-Install"], install, kind, assignment)
      etag = "\"#{envelope['header']['content_digest']}\""
      return Reply.new(304, "", etag) if req["If-None-Match"] == etag

      Reply.new(200, JSON.generate(envelope), etag)
    end

    def log_request(req, status)
      line = JSON.generate("at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "method" => req.request_method, "path" => req.path.to_s, "status" => status, "reach_version" => req["X-Reach-Version"])
      File.open(File.join(@home, "requests.jsonl"), "a") { |file| file.puts(line) }
    end

    def triggers
      ENV["FAKE_TEACH_HANDS_LEGACY"].to_s == "1" ? LEGACY_TRIGGERS : LEGACY_TRIGGERS + NEWER_TRIGGERS
    end

    def raise_hand(req, body)
      install = authenticate!(req, body)
      key = req["Idempotency-Key"].to_s
      raise Failure.new(400, "invalid_request", "Idempotency-Key is required") if key.empty?

      request = JSON.parse(body)
      raise Failure.new(400, "invalid_request", "body must be a JSON object") unless request.is_a?(Hash)
      raise Failure.new(403, "hands_disabled", "hand-raises are switched off") if ENV["FAKE_TEACH_HANDS_DISABLE"].to_s == "1"
      raise Failure.new(400, "invalid_request", "trigger is not recognized") unless triggers.include?(request["trigger"])
      raise Failure.new(400, "invalid_request", "summary is too long") if request["summary"].to_s.bytesize > 2000

      @mutex.synchronize do
        replay = @hand_replays[[install["student_id"], key]]
        next replay if replay

        id = "hand_#{SecureRandom.hex(10)}"
        row = {
          "id" => id, "student_id" => install["student_id"], "cutout_id" => request["cutout_id"], "slice" => request["slice"],
          "trigger" => request["trigger"], "originator" => request["originator"], "summary" => request["summary"],
          "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
        row["bundle"] = open_hand_bundle(install, request["bundle"]) if BUNDLE_TRIGGERS.include?(request["trigger"])
        @hands << row
        File.open(File.join(@home, "hands.jsonl"), "a") { |file| file.puts(JSON.generate(row)) }
        answer = { "hand_id" => id, "state" => "open" }
        @hand_replays[[install["student_id"], key]] = answer
        answer
      end
    rescue JSON::ParserError
      raise Failure.new(400, "invalid_request", "body is not valid JSON")
    end

    FEEDBACK_CATEGORIES = %w[general praise suggestion request question complaint problem pace].freeze

    def create_feedback(req, body)
      install = authenticate!(req, body)
      key = req["Idempotency-Key"].to_s
      raise Failure.new(400, "invalid_request", "Idempotency-Key is required") if key.empty?
      raise Failure.new(503, "unavailable", "feedback is switched off", headers: { "Retry-After" => "300" }) if ENV["FAKE_TEACH_FEEDBACK_DISABLE"].to_s == "1"

      request = parse_body(body)
      unless (request.keys - %w[category message anonymous written_at]).empty? && FEEDBACK_CATEGORIES.include?(request["category"]) &&
             request["message"].is_a?(String) && !request["message"].strip.empty? && request["message"].bytesize <= 4000 &&
             [true, false].include?(request["anonymous"])
        raise Failure.new(400, "invalid_request", "feedback is not valid")
      end

      @mutex.synchronize do
        replay_key = [install["student_id"], key]
        replay = @feedback_replays[replay_key]
        next replay if replay

        id = "fb_#{SecureRandom.hex(10)}"
        received = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        @feedback << {
          "feedback_id" => id, "student_id" => request["anonymous"] ? nil : install["student_id"], "category" => request["category"],
          "anonymous" => request["anonymous"], "received_at" => received
        }
        answer = { "feedback_id" => id, "state" => "new", "received_at" => received }
        @feedback_replays[replay_key] = answer
        answer
      end
    end

    def list_feedback(req, body)
      install = authenticate!(req, body)
      raise Failure.new(503, "unavailable", "feedback is switched off", headers: { "Retry-After" => "300" }) if ENV["FAKE_TEACH_FEEDBACK_DISABLE"].to_s == "1"

      path = File.join(@home, "feedback.json")
      config = File.file?(path) ? JSON.parse(File.read(path)) : {}
      raise Failure.new(404, "not_found", "no such route") if config["mode"] == "404"

      overrides = config["items"].is_a?(Hash) ? config["items"] : {}
      rows = @feedback.select { |row| row["student_id"] == install["student_id"] }.reverse.first(100).map do |row|
        over = overrides[row["feedback_id"]].is_a?(Hash) ? overrides[row["feedback_id"]] : {}
        {
          "feedback_id" => row["feedback_id"], "category" => row["category"], "state" => over["state"] || "new",
          "reply" => over["reply"], "updated_at" => over["updated_at"] || row["received_at"]
        }
      end
      { "entries" => rows, "as_of" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
    end

    def open_hand_bundle(install, envelope)
      _header, plaintext = Reach::Crypto.open_envelope(
        envelope, expected_kind: "hand_bundle", expected_student_id: install["student_id"],
        recipient_private_key: @encryption_key,
        signer_public_key_for: lambda { |_id| OpenSSL::PKey::RSA.new(install["public_key_pem"]) }
      )
      bundle = JSON.parse(Reach::Tarball.read(plaintext).fetch("bundle.json"))
      raise Failure.new(400, "invalid_request", "bundle is not an object") unless bundle.is_a?(Hash)

      bundle
    rescue Reach::Error, JSON::ParserError, KeyError
      raise Failure.new(400, "invalid_request", "bundle could not be opened")
    end

    def hand_state(req, body, id)
      install = authenticate!(req, body)
      row = @hands.find { |hand| hand["id"] == id && hand["student_id"] == install["student_id"] }
      raise Failure.new(404, "not_found", "no such hand") unless row

      path = File.join(@home, "issues.json")
      extra = row["trigger"] == "issue" && File.file?(path) ? JSON.parse(File.read(path)) : {}
      { "state" => extra["state"] || "open", "reply" => extra["reply"] }.merge(extra.select { |name, _| %w[issue_state fix_version].include?(name) })
    end

    def grades(req, body)
      install = authenticate!(req, body)
      path = File.join(@home, "grades.json")
      config = File.file?(path) ? JSON.parse(File.read(path)) : {}
      raise Failure.new(404, "not_found", "no such route") if config["mode"] == "404"
      raise Failure.new(403, "grades_disabled", "grades are switched off") if config["mode"] == "disabled"

      rows = Array(config["grades"]).select { |row| row["student_id"].nil? || row["student_id"] == install["student_id"] }
      rows = rows.map { |row| row.reject { |key, _| key == "student_id" } }
      total = nil
      unless rows.empty?
        possible = rows.any? { |row| row["points_possible"].nil? } ? nil : rows.sum { |row| row["points_possible"] }
        total = { "points" => rows.sum { |row| row["points"] }, "points_possible" => possible }
      end
      { "available" => !rows.empty?, "grades" => rows, "total" => total, "as_of" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
    end

    def fixture_json(name)
      home_path = File.join(@home, name)
      path = File.file?(home_path) ? home_path : File.join(__dir__, "fixtures", name)
      JSON.parse(File.read(path))
    end

    def controls(req, body)
      authenticate!(req, body)
      config = fixture_json("controls.json")
      raise Failure.new(404, "not_found", "no such route") if config["mode"] == "404"
      raise Failure.new(503, "unavailable", "controls are switched off on this course server") if config["mode"] == "disabled"

      {
        "controls" => Array(config["controls"]),
        "server_time" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "time_zone" => config["time_zone"]
      }
    end

    def tests_current(req, body)
      authenticate!(req, body)
      config = fixture_json("tests.json")
      raise Failure.new(404, "not_found", "no such route") if config["mode"] == "404"
      raise Failure.new(503, "unavailable", "tests are switched off on this course server") if config["mode"] == "disabled"

      { "test" => config["test"], "server_time" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
    end

    def tests_open(req, body, control_id)
      authenticate!(req, body)
      config = fixture_json("tests.json")
      raise Failure.new(404, "not_found", "no such route") if config["mode"] == "404"

      test = config["test"]
      raise Failure.new(409, "conflict", "outside the window") unless test.is_a?(Hash) && test["control_id"] == control_id

      opened = Time.now.utc
      deadline = [opened + test["time_limit_s"].to_i, Time.iso8601(test["window_end"]).utc].min
      {
        "attempt" => { "id" => "tat_#{control_id.delete_prefix("ctl_")[0, 20].ljust(20, "0")}", "opened_at" => opened.strftime("%Y-%m-%dT%H:%M:%SZ"), "deadline_at" => deadline.strftime("%Y-%m-%dT%H:%M:%SZ") },
        "questions" => Array(config["questions"])
      }
    end

    def tests_answer(req, body, attempt_id)
      authenticate!(req, body)
      data = JSON.parse(body.to_s.empty? ? "{}" : body)
      raise Failure.new(400, "invalid_request", "question_id must be a question of this test") if data["question_id"].to_s.empty?
      raise Failure.new(400, "invalid_request", "answer is required") if data["answer"].to_s.empty?

      { "recorded" => { "question_id" => data["question_id"], "seq" => 1, "recorded_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") } }
    end

    def tests_submit(req, body, attempt_id)
      authenticate!(req, body)
      { "attempt" => { "id" => attempt_id, "submitted_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "ended_reason" => "submitted", "answered" => 0 } }
    end

    def announcements(req, body)
      authenticate!(req, body)
      config = fixture_json("announcements.json")
      raise Failure.new(404, "not_found", "no such route") if config["mode"] == "404"

      now = Time.now.utc
      rows = Array(config["announcements"]).reject { |row| row["show_until"] && Time.iso8601(row["show_until"]).utc <= now }
      { "announcements" => rows, "server_time" => now.strftime("%Y-%m-%dT%H:%M:%SZ") }
    end

    def due_time
      value = ENV["FAKE_TEACH_DUE"].to_s
      value.empty? ? nil : Time.iso8601(value).utc
    end

    def due_text
      due = due_time
      due && due.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def resubmit_state
      due = due_time
      due && Time.now.utc >= due ? "closed" : "open"
    end

    def submit(req, body)
      install = authenticate!(req, body)
      key = req["Idempotency-Key"].to_s
      raise Failure.new(400, "invalid_request", "Idempotency-Key is required") if key.empty?

      request = JSON.parse(body)
      raise Failure.new(400, "invalid_request", "body must be a JSON object") unless request.is_a?(Hash)

      @mutex.synchronize do
        replay = @replays[[install["student_id"], key]]
        next replay.merge("resubmit" => resubmit_state, "due" => due_text) if replay

        group = @submissions.select do |row|
          row["student_id"] == install["student_id"] && row["cutout_id"] == request["cutout_id"] && row["slice"] == request["slice"] && row["assignment"] == request["assignment"]
        end
        late = resubmit_state == "closed"

        id = "sub_#{SecureRandom.hex(10)}"
        attempt = group.length + 1
        row = { "id" => id, "student_id" => install["student_id"], "cutout_id" => request["cutout_id"], "slice" => request["slice"], "assignment" => request["assignment"] }
        @submissions << row
        receipt = {
          "receipt_id" => "rcpt_#{SecureRandom.hex(10)}",
          "kind" => "ingest",
          "submission_id" => id,
          "student_id" => install["student_id"],
          "cutout_id" => request["cutout_id"],
          "slice" => request["slice"],
          "assignment" => request["assignment"],
          "issued_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "signing_key_id" => SIGN_KEY_ID,
          "received_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "content_digest" => Reach::Crypto.digest_hex(JSON.generate(request["package"])),
          "file_list" => [],
          "late" => late,
          "attempt" => attempt
        }
        receipt["signature"] = Base64.strict_encode64(Reach::Crypto.sign_pss(@signing_key, Reach::Crypto.canonical_json(receipt.reject { |k, _| k == "signature" })))
        answer = { "submission_id" => id, "state" => "ingested", "receipt" => receipt, "rejection" => nil, "attempt" => attempt }
        @replays[[install["student_id"], key]] = answer
        answer.merge("resubmit" => resubmit_state, "due" => due_text)
      end
    rescue JSON::ParserError
      raise Failure.new(400, "invalid_request", "body is not valid JSON")
    end

    attr_reader :wire_sha

    def load_courses
      list = YAML.safe_load(File.read(File.join(__dir__, "fixtures", "courses.yml")))["courses"]
      list.each do |course|
        parsed = Text.parse_code(course["course_code"])
        course["normalized_id"] = parsed["course_id"]
        course["secret"] = parsed["secret"]
        y, m, d = course["ends_on"].split("-").map(&:to_i)
        course["expires_at_time"] = Time.new(y, m, d, 23, 59, 59, course["utc_offset"]).utc
      end
      list
    end

    def load_key(name)
      path = File.join(@home, "keys", "#{name}.pem")
      if File.file?(path)
        OpenSSL::PKey::RSA.new(File.read(path))
      else
        key = OpenSSL::PKey::RSA.new(Reach::Crypto::RSA_KEY_BITS)
        File.open(path, "w", 0o600) { |f| f.write(key.to_pem) }
        key
      end
    end

    def installs_path
      File.join(@home, "installs.json")
    end

    def load_installs
      return {} unless File.file?(installs_path)

      JSON.parse(File.read(installs_path))
    rescue JSON::ParserError
      {}
    end

    def save_installs
      tmp = "#{installs_path}.tmp"
      File.open(tmp, "w", 0o600) { |f| f.write(JSON.pretty_generate(@installs)) }
      File.rename(tmp, installs_path)
    end

    def key_doc(id, key)
      { "key_id" => id, "pem" => key.public_key.to_pem }
    end

    def signing_public_keys
      [key_doc(SIGN_KEY_ID, @signing_key)]
    end

    def encryption_key
      key_doc(ENC_KEY_ID, @encryption_key)
    end

    def rate_limit!(ip)
      @mutex.synchronize do
        now = Time.now.to_f
        hits = @hits[ip]
        hits.reject! { |t| now - t >= RATE_WINDOW_S }
        if hits.length >= RATE_LIMIT
          wait = [(RATE_WINDOW_S - (now - hits.first)).ceil, 1].max
          raise Failure.new(429, "rate_limited", "too many attempts", headers: { "Retry-After" => wait.to_s })
        end
        hits << now
      end
    end

    def resolve_code(raw)
      parsed = Text.parse_code(raw)
      unknown = Failure.new(400, "course_code_unknown", "no live course code matches")
      raise unknown unless parsed

      course = @courses.find { |c| c["secret"] == parsed["secret"] }
      if course && Text.distance(parsed["course_id"], course["normalized_id"]) <= 2
        if Time.now.utc > course["expires_at_time"]
          raise Failure.new(400, "course_code_expired", "this course code has expired")
        end

        return course
      end

      live = @courses.select { |c| Time.now.utc <= c["expires_at_time"] }
      near = live.select { |c| Text.distance(parsed["course_id"], c["normalized_id"]) <= 2 }
      details = near.length == 1 ? { "did_you_mean" => near.first["normalized_id"] } : nil
      raise Failure.new(400, "course_code_unknown", "no live course code matches", details: details)
    end

    def preview(raw)
      course = resolve_code(raw)
      {
        "course" => {
          "id" => course["normalized_id"],
          "title" => course["title"],
          "term" => course["term"],
          "ends_on" => course["ends_on"]
        },
        "expires_at" => course["expires_at_time"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        "identity" => course["identity"]
      }
    end

    def stamp_time(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def validation_open(body)
      invalid = Failure.new(400, "invalid_request", "invalid validation request")
      raise invalid unless body.keys.sort == %w[course_code harness nonce public_key reach_version]
      raise invalid unless VALIDATION_HARNESSES.include?(body["harness"]) && body["nonce"].to_s =~ HEX64
      raise invalid unless body["reach_version"].is_a?(String) && body["public_key"].is_a?(String) && body["public_key"].length <= 4096

      public_key = begin
        OpenSSL::PKey::RSA.new(body["public_key"])
      rescue OpenSSL::PKey::PKeyError
        raise invalid
      end
      raise invalid if public_key.private? || public_key.n.num_bits < 2048

      course = resolve_code(body["course_code"])
      id = "vld_#{SecureRandom.hex(12)}"
      session = {
        "id" => id,
        "course_id" => course["normalized_id"],
        "public_key_pem" => public_key.to_pem,
        "key_digest" => Reach::Crypto.digest_hex(public_key.public_key.to_der),
        "expires_at" => stamp_time(Time.now + VALIDATION_TTL_S),
        "nonce" => body["nonce"],
        "harness" => body["harness"],
        "reach_version" => body["reach_version"],
        "questions" => [{
          "id" => "practice_1",
          "question" => "Invent a fictional business decision, its inputs, expected output, and a case to check. Use made-up names and values only.",
          "shape" => "text",
          "min_words" => 25
        }]
      }
      @mutex.synchronize { @validations[id] = session }
      session.slice("nonce", "harness", "reach_version", "questions", "course_id", "expires_at").merge(
        "schema" => VALIDATION_SCHEMA, "session_id" => id,
        "signing_public_keys" => signing_public_keys, "encryption_key" => encryption_key
      )
    end

    def live_validation(id)
      session = @validations[id]
      raise Failure.new(403, "validation_required", "the security validation pass is required") unless session && Time.iso8601(session["expires_at"]) > Time.now.utc

      session
    end

    def validation_session!(req, body, id)
      session = live_validation(id)
      raise Failure.new(401, "unauthenticated", "validation identity does not match") unless req["X-Reach-Attempt"].to_s == id

      verify_signature!(req, body, "validation:#{id}", session["public_key_pem"])
      session
    end

    def word_count(text)
      text.to_s.split(/\s+/).count { |token| token =~ /[[:alnum:]]/ }
    end

    def validation_unpack!(session, body)
      id = session["id"]
      request = JSON.parse(body)
      raise KeyError unless request.is_a?(Hash) && (request.keys - %w[package qualification_id]).empty?

      _header, plaintext = Reach::Crypto.open_envelope(
        request["package"], expected_kind: "submission", expected_student_id: "synthetic:#{id}",
        recipient_private_key: @encryption_key,
        signer_public_key_for: lambda { |_key_id| OpenSSL::PKey::RSA.new(session["public_key_pem"]) }
      )
      entries = Reach::Tarball.read(plaintext)
      raise KeyError unless entries.keys.sort == (%w[manifest.json part.json] + VALIDATION_OWNED.map { |name| "files/#{name}" }).sort

      digests = VALIDATION_OWNED.to_h { |name| [name, Reach::Crypto.digest_hex(entries.fetch("files/#{name}"))] }
      manifest = JSON.parse(entries.fetch("manifest.json"))
      raise KeyError unless manifest["course"] == session["course_id"] && manifest["assignment"] == "security-validation" &&
                            manifest["cutout_id"] == id && manifest["reach_version"] == session["reach_version"] && manifest["digests"] == digests

      part = JSON.parse(entries.fetch("part.json"))
      answers = part.fetch("answers")
      questions = session["questions"]
      raise KeyError unless part["student_id"] == "synthetic:#{id}" && answers.map { |answer| answer["question_id"] }.sort == questions.map { |question| question["id"] }.sort

      answers.each do |answer|
        question = questions.find { |item| item["id"] == answer["question_id"] }
        words = word_count(answer["text"])
        raise KeyError unless words >= question["min_words"] && answer["words"] == words && answer["digest"] == Reach::Crypto.digest_hex(answer["text"])
      end
      raise KeyError unless JSON.parse(entries.fetch("files/answers.json")) == answers.to_h { |answer| [answer["question_id"], answer["text"]] }
      raise KeyError unless Reach::ReadmeCheck.problems(entries.fetch("files/README.md")).empty?

      [request, Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(digests)), Reach::Crypto.digest_hex(plaintext)]
    rescue Reach::Error, JSON::ParserError, KeyError, TypeError, NoMethodError
      raise Failure.new(400, "invalid_request", "invalid validation package")
    end

    def validation_qualify(req, body, id)
      session = validation_session!(req, body, id)
      raise Failure.new(403, "validation_required", "this pass was used for enrollment") if session["install_id"]

      _request, digest, = validation_unpack!(session, body)
      @mutex.synchronize do
        raise Failure.new(409, "conflict", "validation already submitted") if session["receipt"]

        session["qualification_id"] = "vq_#{SecureRandom.hex(12)}" unless session["qualification_digest"] == digest
        session["qualification_digest"] = digest
        { "passed" => true, "qualification_id" => session["qualification_id"] }
      end
    end

    def validation_submit(req, body, id)
      session = validation_session!(req, body, id)
      raise Failure.new(403, "validation_required", "this pass was used for enrollment") if session["install_id"]

      request, digest, content_digest = validation_unpack!(session, body)
      @mutex.synchronize do
        unless session["qualification_digest"] == digest && !request["qualification_id"].to_s.empty? && session["qualification_id"] == request["qualification_id"]
          raise Failure.new(409, "not_qualified", "validation has not qualified")
        end
        if session["receipt"]
          raise Failure.new(409, "conflict", "validation submission changed") unless session["receipt"]["content_digest"] == content_digest

          next { "receipt" => session["receipt"] }
        end

        receipt = session.slice("nonce", "harness", "reach_version", "course_id", "expires_at").merge(
          "schema" => VALIDATION_SCHEMA, "kind" => "security-validation", "session_id" => id,
          "public_key_digest" => session["key_digest"], "receipt_id" => "vrc_#{SecureRandom.hex(12)}",
          "files_digest" => digest, "content_digest" => content_digest,
          "issued_at" => stamp_time(Time.now), "signing_key_id" => SIGN_KEY_ID
        )
        receipt["signature"] = Base64.strict_encode64(Reach::Crypto.sign_pss(@signing_key, Reach::Crypto.canonical_json(receipt)))
        session["receipt"] = receipt
        { "receipt" => receipt }
      end
    end

    def validation_receipt(req, body, id)
      session = validation_session!(req, body, id)
      raise Failure.new(404, "not_found", "no receipt yet") unless session["receipt"]

      { "receipt" => session["receipt"] }
    end

    def enrollment_validation!(body, course, public_key)
      return nil unless Text.version_at_least?(body["reach_version"], VALIDATION_FROM)

      session = live_validation(body["validation_session"].to_s)
      receipt = session["receipt"]
      label = body.dig("fingerprint", "descriptive", "harness").to_s
      family = label.start_with?("codex-") ? "codex" : (label.start_with?("claude-code-") ? "claude-code" : label)
      matches = session["course_id"] == course["normalized_id"] && session["key_digest"] == Reach::Crypto.digest_hex(public_key.public_key.to_der) &&
                receipt && receipt["receipt_id"] == body["validation_receipt"] && session["reach_version"] == body["reach_version"] && session["harness"] == family
      raise Failure.new(403, "validation_required", "the security validation pass is required") unless matches && !session["install_id"]

      session
    end

    def enroll(body)
      shape = body["shape"] || "v1"
      unless shape == "v2"
        raise Failure.new(400, "invalid_request", "shape v1 is not served by the fake")
      end

      password = body["password"]
      unless password.is_a?(String) && password.length >= 8 && password.length <= 256
        raise Failure.new(400, "password_required", "choose a password of 8 to 256 characters")
      end

      %w[course_code username student_id public_key_pem reach_version platform].each do |field|
        unless body[field].is_a?(String) && !body[field].empty?
          raise Failure.new(400, "invalid_request", "#{field} is required")
        end
      end
      fingerprint = body["fingerprint"]
      unless fingerprint.is_a?(Hash) && fingerprint["digest"].to_s =~ HEX64 && fingerprint["strict_digest"].to_s =~ HEX64
        raise Failure.new(400, "invalid_request", "fingerprint is malformed")
      end
      raise Failure.new(400, "invalid_request", "unknown platform") unless PLATFORMS.include?(body["platform"])
      raise Failure.new(400, "invalid_request", "public_key_pem is too long") if body["public_key_pem"].length > 4096

      public_key = begin
        OpenSSL::PKey::RSA.new(body["public_key_pem"])
      rescue OpenSSL::PKey::PKeyError
        raise Failure.new(400, "invalid_request", "public_key_pem is not a public key")
      end
      if public_key.private?
        raise Failure.new(400, "invalid_request", "public_key_pem must not carry a private key")
      end

      unless Text.version_at_least?(body["reach_version"], MINIMUM_REACH_VERSION)
        raise Failure.new(
          400, "reach_outdated",
          "Reach #{body['reach_version']} is older than the minimum #{MINIMUM_REACH_VERSION}; update Reach and enroll again"
        )
      end

      course = resolve_code(body["course_code"])
      entry = (@rosters[course["normalized_id"]] || []).find do |s|
        s["username"] == body["username"] && s["student_id"] == body["student_id"]
      end
      raise Failure.new(403, "enrollment_refused", "enrollment was refused") unless entry
      validation = enrollment_validation!(body, course, public_key)
      password_enroll!(entry["student_id"], password)

      install_id = "ins_#{SecureRandom.hex(10)}"
      issued = Time.now.utc
      stamp = {
        "schema" => "teach.enrollment-stamp/v1",
        "stamp_id" => "stm_#{SecureRandom.hex(10)}",
        "install_id" => install_id,
        "student_id" => entry["student_id"],
        "username" => entry["username"],
        "course_id" => course["normalized_id"],
        "fingerprint_digest" => fingerprint["digest"],
        "fingerprint_strict_digest" => fingerprint["strict_digest"],
        "issued_at" => issued.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expires_at" => course["expires_at_time"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        "signing_key_id" => SIGN_KEY_ID
      }
      signature = Reach::Crypto.sign_pss(@signing_key, Reach::Crypto.canonical_json(stamp))
      stamp["signature"] = Base64.strict_encode64(signature)

      @mutex.synchronize do
        @installs[install_id] = {
          "student_id" => entry["student_id"],
          "display_name" => entry["display_name"],
          "course_id" => course["normalized_id"],
          "public_key_pem" => public_key.to_pem,
          "fingerprint_digest" => fingerprint["digest"],
          "stamp_id" => stamp["stamp_id"],
          "revoked" => false,
          "enrolled_at" => issued.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
        validation["install_id"] = install_id if validation
        save_installs
      end

      {
        "install_id" => install_id,
        "student_id" => entry["student_id"],
        "course" => {
          "id" => course["normalized_id"],
          "title" => course["title"],
          "term" => course["term"],
          "timezone" => course["timezone"]
        },
        "signing_public_keys" => signing_public_keys,
        "encryption_key" => encryption_key,
        "minimum_reach_version" => MINIMUM_REACH_VERSION,
        "wire_contract_sha256" => @wire_sha,
        "display_name" => entry["display_name"],
        "enrollment_stamp" => stamp
      }
    end

    def password_digest(password)
      Reach::Crypto.digest_hex("fake-teach-password\n#{password}")
    end

    def password_resets
      path = File.join(@home, "password_resets.json")
      list = File.file?(path) ? JSON.parse(File.read(path)) : []
      list.is_a?(Array) ? list : []
    rescue JSON::ParserError
      []
    end

    def password_store!(student_id, password)
      @mutex.synchronize { (@passwords ||= {})[student_id] = password_digest(password) }
      path = File.join(@home, "password_resets.json")
      File.write(path, JSON.generate(password_resets - [student_id])) if File.file?(path)
    end

    def password_enroll!(student_id, password)
      held = (@passwords ||= {})[student_id]
      if held && held != password_digest(password) && !password_resets.include?(student_id)
        raise Failure.new(403, "password_wrong", "that is not this student's password")
      end

      password_store!(student_id, password)
    end

    def password_verify(req, body)
      install = authenticate!(req, body)
      password = parse_body(body)["password"]
      held = (@passwords ||= {})[install["student_id"]]
      raise Failure.new(409, "password_not_set", "this student has not chosen a password") unless held
      raise Failure.new(403, "password_wrong", "that is not this student's password") unless password.is_a?(String) && held == password_digest(password)

      { "verified" => true }
    end

    def password_reset_state(req, body)
      install = authenticate!(req, body)
      { "allowed" => password_resets.include?(install["student_id"]), "password_set" => (@passwords ||= {}).key?(install["student_id"]) }
    end

    def password_reset(req, body)
      install = authenticate!(req, body)
      password = parse_body(body)["password"]
      unless password.is_a?(String) && password.length >= 8 && password.length <= 256
        raise Failure.new(400, "password_required", "choose a password of 8 to 256 characters")
      end
      unless password_resets.include?(install["student_id"])
        raise Failure.new(403, "password_reset_not_allowed", "no password reset is allowed for this student right now")
      end

      password_store!(install["student_id"], password)
      { "password_set_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
    end

    def parse_body(body)
      data = JSON.parse(body.to_s)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      raise Failure.new(400, "invalid_request", "body is not valid JSON")
    end

    def authenticate!(req, body)
      install_id = req["X-Teach-Install"].to_s
      install = @installs[install_id]
      raise Failure.new(403, "not_enrolled", "install is not enrolled") unless install
      raise Failure.new(403, "revoked", "install was revoked") if install["revoked"]

      verify_signature!(req, body, install_id, install["public_key_pem"])
      install
    end

    def verify_signature!(req, body, scope, public_key_pem)
      timestamp = req["X-Teach-Timestamp"].to_s
      nonce = req["X-Teach-Nonce"].to_s
      signature = req["X-Teach-Signature"].to_s
      unauth = lambda { |why| Failure.new(401, "unauthenticated", why) }

      raise unauth.call("nonce is malformed") unless nonce =~ /\A[0-9a-f]{32}\z/
      stamped = begin
        Time.iso8601(timestamp)
      rescue ArgumentError
        raise unauth.call("timestamp is malformed")
      end
      raise unauth.call("timestamp is outside the allowed window") if (Time.now - stamped).abs > CLOCK_SKEW_S

      target = req.path.to_s
      target += "?#{req.query_string}" unless req.query_string.to_s.empty?
      payload = [req.request_method.to_s.upcase, target, timestamp, nonce, Reach::Crypto.digest_hex(body)].join("\n")
      public_key = OpenSSL::PKey::RSA.new(public_key_pem)
      raw = begin
        Base64.strict_decode64(signature)
      rescue ArgumentError
        raise unauth.call("signature is malformed")
      end
      raise unauth.call("signature does not verify") unless Reach::Crypto.verify_pss(public_key, raw, payload)

      @mutex.synchronize do
        seen = @nonces[scope]
        now = Time.now.to_f
        seen.reject! { |_, t| now - t > NONCE_TTL_S }
        raise unauth.call("nonce was already used") if seen.key?(nonce)

        seen[nonce] = now
      end
    end

    def late_assignments_status(install_id, install)
      return nil unless late_assignment

      [{
        "id" => late_assignment,
        "due" => late_due_text,
        "slices" => [{ "cutout_id" => cutout_for(late_assignment), "slice" => PACKAGE_SLICE, "assignment" => late_assignment }],
        "packages" => %w[workspace shape].map do |kind|
          { "kind" => kind, "version" => package_version_for(late_assignment), "content_digest" => package_envelope(install_id, install, kind, late_assignment)["header"]["content_digest"] }
        end
      }]
    end

    def status(req, body)
      install = authenticate!(req, body)
      header = req["X-Reach-Fingerprint"]
      if header && !header.empty? && header != install["fingerprint_digest"]
        raise Failure.new(403, "fingerprint_mismatch", "this computer is not the one the install was enrolled from")
      end

      document = {
        "install_id" => req["X-Teach-Install"],
        "student" => { "id" => install["student_id"], "display_name" => install["display_name"], "group" => nil },
        "course" => { "id" => install["course_id"] },
        "current_assignment" => (late_assignment ? { "id" => current_assignment_id, "due" => current_due_text } : (due_text ? { "id" => "A1", "due" => due_text } : nil)),
        "slices" => [{ "cutout_id" => cutout_for(current_assignment_id), "slice" => PACKAGE_SLICE, "assignment" => current_assignment_id }],
        "packages" => package_kinds.map do |kind|
          { "kind" => kind, "version" => package_version_for(current_assignment_id), "content_digest" => package_envelope(req["X-Teach-Install"], install, kind)["header"]["content_digest"] }
        end,
        "outstanding_receipts" => [],
        "server_time" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "signing_public_keys" => signing_public_keys,
        "encryption_key" => encryption_key,
        "minimum_reach_version" => MINIMUM_REACH_VERSION,
        "wire_contract_sha256" => @wire_sha,
        "transcripts" => { "kinds" => ["prompt"], "max_text_bytes" => 131_072 },
        "modules" => nil,
        "module_selection" => { "mode" => "instructor", "open" => false, "closes_at" => nil, "chosen" => false },
        "transfer" => nil
      }
      late = late_assignments_status(req["X-Teach-Install"], install)
      document = document.each_with_object({}) do |(key, value), merged|
        merged[key] = value
        merged["late_assignments"] = late if key == "current_assignment" && late
      end
      document
    end
  end

  class Servlet < WEBrick::HTTPServlet::AbstractServlet
    def initialize(server, store)
      super(server)
      @store = store
    end

    def service(req, res)
      delay = ENV["FAKE_TEACH_DELAY_S"].to_f
      sleep(delay) if delay.positive?
      body = read_body(req)
      payload = route(req, body)
      if payload.is_a?(Reply)
        res.status = payload.status
        res["Content-Type"] = "application/json"
        res["ETag"] = payload.etag
        res.body = payload.body
        @store.log_request(req, payload.status)
      else
        respond(res, 200, payload)
        @store.log_request(req, 200)
      end
    rescue Failure => e
      @store.log_request(req, e.status)
      fail_with(res, e)
    rescue StandardError => e
      @logger = @server.logger
      @logger.error("#{e.class}: #{e.message}")
      fail_with(res, Failure.new(500, "internal", "internal error"))
    end

    private

    def read_body(req)
      length = req["Content-Length"].to_i
      raise Failure.new(413, "too_large", "body is too large") if length > MAX_BODY_BYTES

      req.body.to_s
    end

    def parse_json(body)
      parsed = JSON.parse(body)
      raise Failure.new(400, "invalid_request", "body must be a JSON object") unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise Failure.new(400, "invalid_request", "body is not valid JSON")
    end

    def route(req, body)
      method = req.request_method
      path = req.path.to_s
      if method == "GET" && path == "/api/v1/health"
        { "status" => "ok", "database" => true, "blob_store" => true }
      elsif method == "GET" && path == "/api/v1/enrollment/preview"
        @store.rate_limit!(req.peeraddr[3])
        @store.preview(req.query["course_code"].to_s)
      elsif method == "POST" && path == "/api/v1/validation"
        @store.rate_limit!(req.peeraddr[3])
        @store.validation_open(parse_json(body))
      elsif method == "POST" && path =~ %r{\A/api/v1/validation/(vld_[0-9a-f]{24})/qualify\z}
        @store.validation_qualify(req, body, Regexp.last_match(1))
      elsif method == "POST" && path =~ %r{\A/api/v1/validation/(vld_[0-9a-f]{24})/submit\z}
        @store.validation_submit(req, body, Regexp.last_match(1))
      elsif method == "GET" && path =~ %r{\A/api/v1/validation/(vld_[0-9a-f]{24})/receipt\z}
        @store.validation_receipt(req, body, Regexp.last_match(1))
      elsif method == "POST" && path == "/api/v1/enroll"
        @store.rate_limit!(req.peeraddr[3])
        @store.enroll(parse_json(body))
      elsif method == "GET" && path == "/api/v1/status"
        @store.status(req, body)
      elsif method == "GET" && path =~ %r{\A/api/v1/packages/([A-Za-z0-9_]+)\z}
        @store.package(req, body, Regexp.last_match(1))
      elsif method == "POST" && path == "/api/v1/submissions"
        @store.submit(req, body)
      elsif method == "POST" && path == "/api/v1/hands"
        @store.raise_hand(req, body)
      elsif method == "GET" && path =~ %r{\A/api/v1/hands/([A-Za-z0-9_]+)\z}
        @store.hand_state(req, body, Regexp.last_match(1))
      elsif method == "POST" && path == "/api/v1/feedback"
        @store.create_feedback(req, body)
      elsif method == "GET" && path == "/api/v1/feedback"
        @store.list_feedback(req, body)
      elsif method == "GET" && path == "/api/v1/grades"
        @store.grades(req, body)
      elsif method == "GET" && path == "/api/v1/controls"
        @store.controls(req, body)
      elsif method == "GET" && path == "/api/v1/tests/current"
        @store.tests_current(req, body)
      elsif method == "POST" && path =~ %r{\A/api/v1/tests/attempts/([A-Za-z0-9_]+)/answers\z}
        @store.tests_answer(req, body, Regexp.last_match(1))
      elsif method == "POST" && path =~ %r{\A/api/v1/tests/attempts/([A-Za-z0-9_]+)/submit\z}
        @store.tests_submit(req, body, Regexp.last_match(1))
      elsif method == "POST" && path =~ %r{\A/api/v1/tests/([A-Za-z0-9_]+)/open\z}
        @store.tests_open(req, body, Regexp.last_match(1))
      elsif method == "GET" && path == "/api/v1/announcements"
        @store.announcements(req, body)
      elsif method == "POST" && path == "/api/v1/password/verify"
        @store.password_verify(req, body)
      elsif method == "GET" && path == "/api/v1/password/reset"
        @store.password_reset_state(req, body)
      elsif method == "POST" && path == "/api/v1/password/reset"
        @store.password_reset(req, body)
      else
        raise Failure.new(404, "not_found", "no such route")
      end
    end

    def respond(res, status, payload)
      res.status = status
      res["Content-Type"] = "application/json"
      res.body = JSON.generate(payload)
    end

    def fail_with(res, failure)
      error = { "code" => failure.code, "message" => failure.message }
      error["details"] = failure.details if failure.details
      failure.headers.each { |k, v| res[k] = v }
      respond(res, failure.status, "error" => error, "request_id" => SecureRandom.hex(8))
    end
  end

  module Tls
    module_function

    def certificate(subject, issuer, public_key, serial, extensions, signer)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = serial
      cert.subject = OpenSSL::X509::Name.parse(subject)
      cert.issuer = issuer ? issuer.subject : cert.subject
      cert.public_key = public_key
      cert.not_before = Time.now - 300
      cert.not_after = Time.now + 86_400
      factory = OpenSSL::X509::ExtensionFactory.new
      factory.subject_certificate = cert
      factory.issuer_certificate = issuer || cert
      extensions.each { |name, value, critical| cert.add_extension(factory.create_extension(name, value, critical)) }
      cert.sign(signer, OpenSSL::Digest::SHA256.new)
      cert
    end

    def material(dir)
      FileUtils.mkdir_p(dir, mode: 0o700)
      ca_key = OpenSSL::PKey::RSA.new(2048)
      ca = certificate("/CN=fake teach smoke CA", nil, ca_key, 1,
                       [["basicConstraints", "CA:TRUE", true], ["keyUsage", "keyCertSign,cRLSign", true], ["subjectKeyIdentifier", "hash", false]], ca_key)
      key = OpenSSL::PKey::RSA.new(2048)
      cert = certificate("/CN=127.0.0.1", ca, key, 2,
                         [["basicConstraints", "CA:FALSE", true], ["keyUsage", "digitalSignature,keyEncipherment", true], ["extendedKeyUsage", "serverAuth", false],
                          ["subjectAltName", "IP:127.0.0.1,DNS:localhost", false], ["authorityKeyIdentifier", "keyid:always", false]], ca_key)
      File.write(File.join(dir, "ca.pem.tmp"), ca.to_pem)
      File.rename(File.join(dir, "ca.pem.tmp"), File.join(dir, "ca.pem"))
      [cert, key]
    end
  end
end

options = { port: 9480, home: nil, tls: nil }
OptionParser.new do |opts|
  opts.banner = "usage: server.rb [--port N] [--home DIR] [--tls DIR]"
  opts.on("--port N", Integer) { |v| options[:port] = v }
  opts.on("--home DIR") { |v| options[:home] = v }
  opts.on("--tls DIR") { |v| options[:tls] = v }
end.parse!

home = options[:home] || Dir.mktmpdir("fake-teach-")
store = FakeTeach::Store.new(File.expand_path(home))
config = {
  BindAddress: "127.0.0.1",
  Port: options[:port],
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
}
if options[:tls]
  require "webrick/https"
  cert, key = FakeTeach::Tls.material(File.expand_path(options[:tls]))
  config.merge!(SSLEnable: true, SSLCertificate: cert, SSLPrivateKey: key)
end
server = WEBrick::HTTPServer.new(config)
server.mount("/", FakeTeach::Servlet, store)
%w[INT TERM].each { |sig| trap(sig) { server.shutdown } }
$stdout.puts("fake teach listening on #{options[:tls] ? 'https' : 'http'}://127.0.0.1:#{options[:port]} home=#{File.expand_path(home)}")
$stdout.flush
server.start
