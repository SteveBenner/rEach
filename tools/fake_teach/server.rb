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

module FakeTeach
  MINIMUM_REACH_VERSION = "0.12.0".freeze
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
    technical_issue setup_issue access_issue extension_request feedback integrity_question other
  ].freeze

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

  class Store
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
    end

    def log_request(req, status)
      line = JSON.generate("at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "method" => req.request_method, "path" => req.path.to_s, "status" => status)
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
        @hands << row
        File.open(File.join(@home, "hands.jsonl"), "a") { |file| file.puts(JSON.generate(row)) }
        answer = { "hand_id" => id, "state" => "open" }
        @hand_replays[[install["student_id"], key]] = answer
        answer
      end
    rescue JSON::ParserError
      raise Failure.new(400, "invalid_request", "body is not valid JSON")
    end

    def hand_state(req, body, id)
      install = authenticate!(req, body)
      row = @hands.find { |hand| hand["id"] == id && hand["student_id"] == install["student_id"] }
      raise Failure.new(404, "not_found", "no such hand") unless row

      { "state" => "open", "reply" => nil }
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
        raise Failure.new(403, "deadline_passed", "the due time has passed") if late && !group.empty?

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

    def authenticate!(req, body)
      install_id = req["X-Teach-Install"].to_s
      install = @installs[install_id]
      raise Failure.new(403, "not_enrolled", "install is not enrolled") unless install
      raise Failure.new(403, "revoked", "install was revoked") if install["revoked"]

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
      public_key = OpenSSL::PKey::RSA.new(install["public_key_pem"])
      raw = begin
        Base64.strict_decode64(signature)
      rescue ArgumentError
        raise unauth.call("signature is malformed")
      end
      raise unauth.call("signature does not verify") unless Reach::Crypto.verify_pss(public_key, raw, payload)

      @mutex.synchronize do
        seen = @nonces[install_id]
        now = Time.now.to_f
        seen.reject! { |_, t| now - t > NONCE_TTL_S }
        raise unauth.call("nonce was already used") if seen.key?(nonce)

        seen[nonce] = now
      end
      install
    end

    def status(req, body)
      install = authenticate!(req, body)
      header = req["X-Reach-Fingerprint"]
      if header && !header.empty? && header != install["fingerprint_digest"]
        raise Failure.new(403, "fingerprint_mismatch", "this computer is not the one the install was enrolled from")
      end

      {
        "install_id" => req["X-Teach-Install"],
        "student" => { "id" => install["student_id"], "display_name" => install["display_name"], "group" => nil },
        "course" => { "id" => install["course_id"] },
        "current_assignment" => due_text ? { "id" => "A1", "due" => due_text } : nil,
        "slices" => [],
        "packages" => [],
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
      respond(res, 200, payload)
      @store.log_request(req, 200)
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
      elsif method == "POST" && path == "/api/v1/enroll"
        @store.rate_limit!(req.peeraddr[3])
        @store.enroll(parse_json(body))
      elsif method == "GET" && path == "/api/v1/status"
        @store.status(req, body)
      elsif method == "POST" && path == "/api/v1/submissions"
        @store.submit(req, body)
      elsif method == "POST" && path == "/api/v1/hands"
        @store.raise_hand(req, body)
      elsif method == "GET" && path =~ %r{\A/api/v1/hands/([A-Za-z0-9_]+)\z}
        @store.hand_state(req, body, Regexp.last_match(1))
      elsif method == "GET" && path == "/api/v1/grades"
        @store.grades(req, body)
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
end

options = { port: 9480, home: nil }
OptionParser.new do |opts|
  opts.banner = "usage: server.rb [--port N] [--home DIR]"
  opts.on("--port N", Integer) { |v| options[:port] = v }
  opts.on("--home DIR") { |v| options[:home] = v }
end.parse!

home = options[:home] || Dir.mktmpdir("fake-teach-")
store = FakeTeach::Store.new(File.expand_path(home))
server = WEBrick::HTTPServer.new(
  BindAddress: "127.0.0.1",
  Port: options[:port],
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
)
server.mount("/", FakeTeach::Servlet, store)
%w[INT TERM].each { |sig| trap(sig) { server.shutdown } }
$stdout.puts("fake teach listening on http://127.0.0.1:#{options[:port]} home=#{File.expand_path(home)}")
$stdout.flush
server.start
