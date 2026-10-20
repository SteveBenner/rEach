require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require_relative "course_matrix"

module CourseMatrixCheck
  KEY = OpenSSL::PKey::RSA.new(2048)
  OTHER_KEY = OpenSSL::PKey::RSA.new(2048)
  STARTED = "2026-10-18T12:00:00Z"
  SCRIPT = File.expand_path("course_matrix.rb", __dir__)
  BASELINE = "8b9904b2b4353bf0d4b9ec0605cf2e5a8bc4d4dad64ecfdb00dce6e49078bc77"
  CORRECTIVE = "9916901d5109535317381b60347ae7c13f2c2712d803b0001b3832005c39cbff"
  STAGES = CourseMatrix::CONFIG.fetch("stages")
  SPECIAL = { "security_validation" => "stages/security_validation.json", "module_selection" => "stages/module_selection.json", "student_receipt" => "stages/student_receipt.txt" }.freeze

  def self.at(seconds)
    (Time.iso8601(STARTED) + seconds).utc.iso8601
  end

  def self.passed(scenarios)
    scenarios.map { |s| s.merge("result" => "passed") }
  end

  def self.sign(receipt, key = KEY)
    receipt.delete("signature")
    receipt["signature"] = Base64.strict_encode64(Reach::Crypto.sign_pss(key, Reach::Crypto.canonical_json(receipt)))
    receipt
  end

  class Proof
    attr_reader :kase, :evidence, :security, :selection, :answers, :shape, :rows, :manifest, :ingest, :grade, :student, :overrides, :graded, :local
    attr_accessor :message, :public_pem

    def initialize(slice: "backend", course: "SMOKECHOICEFA26", mode: "student_choice")
      @graded = [{ "feature" => "features/finance/privacy.feature", "name" => "Group totals hide individual amounts" },
                 { "feature" => "features/finance/privacy.feature", "name" => "Groups smaller than three are suppressed" }]
      @local = slice == "panel" ? [{ "feature" => "features/practice/finance/finance.a3s2.feature", "name" => "Practice panel lists synthetic group totals" },
                                   { "feature" => "features/practice/finance/finance.a3s2.feature", "name" => "Practice panel withholds a two-person group" }] : @graded
      owned = slice == "panel" ? ["web/finance/PrivacyPanel.svelte"] : ["app/finance/privacy.rb", "app/finance/aggregate.rb"]
      @kase = { "id" => [course, mode, "finance.a3s2", slice].join("/"), "course" => course, "selection_mode" => mode, "module" => "finance",
                "assignment" => "a3", "cutout" => "finance.a3s2", "slice" => slice, "owned_paths" => owned,
                "questions" => [{ "id" => "q1", "min_words" => 6 }, { "id" => "q2", "min_words" => 3 }],
                "scenarios" => @graded, "local_scenarios" => @local, "nonce" => "0123456789abcdef0123456789abcdef",
                "student_id" => CourseMatrix::STUDENT_ID, "username" => "smok001", "database" => "reach_smoke_00112233445566778899",
                "started_at" => STARTED, "budget_usd" => 4.5, "stages" => STAGES }
      @answers = { "q1" => "Totals are suppressed below three people always.", "q2" => "Typed Money amounts reduce." }
      @shape = { "errors" => 0 }
      @rows = { "local_qualify" => CourseMatrixCheck.passed(@local), "teach_qualify" => CourseMatrixCheck.passed(@graded), "grade" => CourseMatrixCheck.passed(@graded) }
      @selection = { "course" => course, "mode" => mode, "modules" => %w[finance health] }
      @manifest = { "course" => course, "assignment" => "a3", "cutout_id" => "finance.a3s2", "slice" => slice, "partial" => false, "owned_files" => owned + ["README.md"] }
      @security = { "phase" => "passed", "receipt" => CourseMatrixCheck.sign({ "kind" => "security-validation", "course_id" => course, "challenge_id" => "val_synthetic",
                                                                               "issued_at" => CourseMatrixCheck.at(5), "expires_at" => CourseMatrixCheck.at(3600) }) }
      @ingest = CourseMatrixCheck.sign({ "kind" => "ingest", "receipt_id" => "rcpt_ingest_7f3a", "submission_id" => "sub_000042", "student_id" => CourseMatrix::STUDENT_ID,
                                         "cutout_id" => "finance.a3s2", "assignment" => "a3", "slice" => slice, "partial" => false, "issued_at" => CourseMatrixCheck.at(1800) })
      @grade = CourseMatrixCheck.sign(@ingest.reject { |key, _| key == "signature" }.merge("kind" => "grade", "receipt_id" => "rcpt_grade_91c2", "issued_at" => CourseMatrixCheck.at(1900),
                                                                                         "scenarios" => CourseMatrixCheck.passed(@graded), "score" => 1))
      @student = {}
      @message = "Your work is submitted. Receipt number rcpt_ingest_7f3a.\n"
      @public_pem = KEY.public_key.to_pem
      @overrides = {}
      @evidence = { "id" => @kase["id"], "nonce" => @kase["nonce"], "database" => @kase["database"], "synthetic" => true, "cost_usd" => 0.75,
                    "submission_id" => "sub_000042", "stages" => STAGES.map { |name| { "name" => name, "status" => "passed", "evidence" => SPECIAL.fetch(name, "stages/#{name}.log") } },
                    "answers" => "answers.json", "shape" => "shape.json", "local_qualify" => "local_qualify.json", "teach_qualify" => "teach_qualify.json",
                    "grade" => "grade.json", "submission_manifest" => "submission_manifest.json", "teach_public_key" => "teach_public_key.pem",
                    "receipts" => { "ingest" => { "teach" => "receipts/teach/ingest.json", "student" => "receipts/student/ingest.json" },
                                    "grade" => { "teach" => "receipts/teach/grade.json", "student" => "receipts/student/grade.json" } } }
    end

    def stage(name)
      @evidence["stages"].find { |s| s["name"] == name }
    end

    def files
      out = STAGES.to_h { |name| ["stages/#{name}.log", "#{name}: native output for #{@kase['id']}\n"] }
      out.merge!("answers.json" => @answers, "shape.json" => @shape, "submission_manifest.json" => @manifest, "teach_public_key.pem" => @public_pem,
                 SPECIAL["security_validation"] => @security, SPECIAL["module_selection"] => @selection, SPECIAL["student_receipt"] => @message,
                 "receipts/teach/ingest.json" => @ingest, "receipts/student/ingest.json" => @student.fetch("ingest", @ingest),
                 "receipts/teach/grade.json" => @grade, "receipts/student/grade.json" => @student.fetch("grade", @grade))
      @rows.each { |kind, rows| out["#{kind}.json"] = rows }
      out.transform_values { |value| value.nil? || value.is_a?(String) ? value : JSON.pretty_generate(value) + "\n" }
         .merge("evidence.json" => JSON.generate(@evidence), "case.json" => JSON.generate(@kase)).merge(@overrides)
    end

    def write(directory)
      FileUtils.mkdir_p(directory)
      files.each do |path, content|
        next if content.nil?
        target = File.join(directory, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, content)
      end
      directory
    end
  end

  module Scratch
    def setup
      @root = File.realpath(Dir.mktmpdir("course-matrix-check"))
      @count = 0
    end

    def teardown
      FileUtils.remove_entry(@root)
    end

    def next_dir
      File.join(@root, "case-#{@count += 1}")
    end

    def verify(proof, dir: next_dir, on_disk: nil)
      proof.write(dir)
      on_disk&.call(dir)
      CourseMatrix::Evidence.new(proof.kase, dir).verify!
    end

    def assert_rejects(pattern, proof = Proof.new, dir: next_dir, on_disk: nil)
      yield proof if block_given?
      error = assert_raises(CourseMatrix::Failure) { verify(proof, dir: dir, on_disk: on_disk) }
      assert_match pattern, error.message
      error
    end
  end
end

class CourseMatrixEvidenceCheck < Minitest::Test
  include CourseMatrixCheck
  include CourseMatrixCheck::Scratch

  def test_config_orders_fifteen_stages_from_security_validation_to_grade
    assert_equal 15, STAGES.length
    assert_equal STAGES.uniq, STAGES
    assert_equal %w[security_validation grade], [STAGES.first, STAGES.last]
  end

  def test_complete_backend_proof_returns_its_cost
    assert_equal 0.75, verify(Proof.new)
  end

  def test_panel_proof_passes_with_distinct_practice_and_protected_lanes
    proof = Proof.new(slice: "panel")
    assert_empty proof.local.map { |s| s["name"] } & proof.graded.map { |s| s["name"] }
    refute_equal proof.local.map { |s| s["feature"] }.uniq, proof.graded.map { |s| s["feature"] }.uniq
    assert_equal 0.75, verify(proof)
  end

  def test_instructor_assigned_and_student_choice_profiles_both_pass
    assert_equal 0.75, verify(Proof.new(course: "smoke-assign-fa26", mode: "instructor"))
    assert_equal 0.75, verify(Proof.new(course: "SMOKECHOICEFA26", mode: "student_choice", slice: "panel"))
  end

  def test_exact_minimum_words_cost_at_reservation_zero_cost_and_float_score_are_accepted
    proof = Proof.new
    proof.answers["q1"] = "one two three four five six"
    proof.answers["q2"] = "alpha — beta ! gamma"
    proof.evidence["cost_usd"] = 4.5
    assert_equal 4.5, verify(proof)
    proof = Proof.new
    proof.evidence["cost_usd"] = 0
    assert_equal 0, verify(proof)
    proof = Proof.new
    proof.grade["score"] = 1.0
    CourseMatrixCheck.sign(proof.grade)
    assert_equal 0.75, verify(proof)
  end

  def test_rejects_wrong_case_id_nonce_or_database
    { "id" => "smoke-assign-fa26/instructor/finance.a3s2/backend", "nonce" => "f" * 32, "database" => "reach_smoke_other" }.each do |key, value|
      assert_rejects(/wrong case #{key}/) { |p| p.evidence[key] = value }
    end
  end

  def test_rejects_absent_false_or_string_synthetic_flag
    assert_rejects(/non-synthetic environment/) { |p| p.evidence.delete("synthetic") }
    assert_rejects(/non-synthetic environment/) { |p| p.evidence["synthetic"] = false }
    assert_rejects(/non-synthetic environment/) { |p| p.evidence["synthetic"] = "true" }
  end

  def test_rejects_missing_extra_duplicate_reordered_or_skipped_stages
    changes = { "missing" => ->(s) { s.delete_at(4) }, "extra" => ->(s) { s.insert(7, { "name" => "deploy", "status" => "passed", "evidence" => "stages/build.log" }) },
                "duplicate" => ->(s) { s.insert(3, s[3].dup) }, "reordered" => ->(s) { s[1], s[2] = s[2], s[1] },
                "skipped stage" => ->(s) { s.delete_at(s.index { |x| x["name"] == "check" }) }, "unnamed" => ->(s) { s[5].delete("name") } }
    changes.each_value { |change| assert_rejects(/missing, duplicate, or reordered pipeline stage/) { |p| change.call(p.evidence["stages"]) } }
  end

  def test_rejects_skipped_failed_pending_or_missing_stage_status
    ["skipped", "failed", "pending", nil].each do |status|
      assert_rejects(/enroll did not pass/) { |p| p.stage("enroll")["status"] = status }
    end
    assert_rejects(/grade did not pass/) { |p| p.stage("grade").delete("status") }
  end

  def test_rejects_absent_empty_or_oversized_stage_evidence
    assert_rejects(%r{missing evidence file stages/build\.log}) { |p| p.overrides["stages/build.log"] = nil }
    assert_rejects(%r{empty or oversized evidence stages/check\.log}) { |p| p.overrides["stages/check.log"] = "" }
    assert_rejects(%r{empty or oversized evidence stages/sync\.log}, on_disk: ->(dir) { File.truncate(File.join(dir, "stages/sync.log"), 16 * 1024 * 1024 + 1) })
  end

  def test_rejects_non_string_and_empty_evidence_paths
    [42, "", nil, ["stages/build.log"]].each do |path|
      assert_rejects(/missing evidence path/) { |p| p.stage("build")["evidence"] = path }
    end
    assert_rejects(/missing evidence path/) { |p| p.evidence["answers"] = 7 }
  end

  def test_rejects_directories_traversal_sibling_prefix_and_symlink_escapes
    assert_rejects(/evidence escapes scratch case/) { |p| p.stage("build")["evidence"] = "stages" }
    outside = ->(_dir) { File.write(File.join(@root, "outside.log"), "native output\n") }
    assert_rejects(/evidence escapes scratch case/, on_disk: outside) { |p| p.stage("build")["evidence"] = "../outside.log" }
    assert_rejects(/missing evidence file/, on_disk: outside) { |p| p.stage("build")["evidence"] = File.join(@root, "outside.log") }
    dir = next_dir
    sibling = ->(_d) { FileUtils.mkdir_p("#{dir}-sibling") && File.write("#{dir}-sibling/evil.log", "native output\n") }
    assert_rejects(/evidence escapes scratch case/, dir: dir, on_disk: sibling) { |p| p.stage("build")["evidence"] = "../#{File.basename(dir)}-sibling/evil.log" }
    link = ->(d) { outside.call(d) && File.symlink(File.join(@root, "outside.log"), File.join(d, "stages/link.log")) }
    assert_rejects(/evidence escapes scratch case/, on_disk: link) { |p| p.stage("build")["evidence"] = "stages/link.log" }
    folder = ->(d) { FileUtils.mkdir_p(File.join(@root, "elsewhere")) && File.write(File.join(@root, "elsewhere/x.log"), "x\n") && File.symlink(File.join(@root, "elsewhere"), File.join(d, "stages/out")) }
    assert_rejects(/evidence escapes scratch case/, on_disk: folder) { |p| p.stage("build")["evidence"] = "stages/out/x.log" }
    assert_rejects(/evidence escapes scratch case/, on_disk: ->(d) { File.symlink(File.join(@root, "outside.log"), File.join(d, "teach_public_key.pem.link")) && outside.call(d) }) { |p| p.evidence["teach_public_key"] = "teach_public_key.pem.link" }
  end

  def test_local_file_enforces_one_byte_and_sixteen_mebibyte_limits
    dir = next_dir
    FileUtils.mkdir_p(dir)
    { "zero.bin" => 0, "one.bin" => 1, "max.bin" => 16 * 1024 * 1024, "over.bin" => 16 * 1024 * 1024 + 1 }.each do |name, size|
      File.open(File.join(dir, name), "w") { |f| f.truncate(size) }
    end
    evidence = CourseMatrix::Evidence.new(Proof.new.kase, dir)
    assert_equal File.join(dir, "one.bin"), evidence.local_file("one.bin")
    assert_equal File.join(dir, "max.bin"), evidence.local_file("max.bin")
    %w[zero.bin over.bin].each do |name|
      error = assert_raises(CourseMatrix::Failure) { evidence.local_file(name) }
      assert_match(/empty or oversized evidence #{name}/, error.message)
    end
    error = assert_raises(CourseMatrix::Failure) { evidence.local_file("absent.bin") }
    assert_match(/missing evidence file absent\.bin/, error.message)
  end

  def test_rejects_malformed_json_and_missing_required_fields
    assert_rejects(/invalid evidence/) { |p| p.overrides["evidence.json"] = "{\"id\":" }
    %w[answers.json shape.json local_qualify.json submission_manifest.json receipts/teach/ingest.json].each do |path|
      assert_rejects(/invalid evidence/) { |p| p.overrides[path] = "{not json" }
    end
    %w[stages answers shape local_qualify teach_qualify grade receipts teach_public_key submission_manifest submission_id cost_usd].each do |key|
      assert_rejects(/invalid evidence: key not found: "#{key}"/) { |p| p.evidence.delete(key) }
    end
    assert_rejects(/invalid evidence: key not found: "grade"/) { |p| p.evidence["receipts"].delete("grade") }
    assert_rejects(/invalid evidence: key not found: "student"/) { |p| p.evidence["receipts"]["ingest"].delete("student") }
  end

  def test_rejects_missing_extra_or_non_string_answers
    assert_rejects(/answer IDs differ/) { |p| p.answers.delete("q2") }
    assert_rejects(/answer IDs differ/) { |p| p.answers["q3"] = "An extra answer with plenty of words here." }
    assert_rejects(%r{missing/short answer q1}) { |p| p.answers["q1"] = %w[one two three four five six seven] }
    assert_rejects(%r{missing/short answer q2}) { |p| p.answers["q2"] = nil }
    assert_rejects(/invalid evidence/) { |p| p.overrides["answers.json"] = JSON.generate(["q1", "q2"]) }
  end

  def test_rejects_short_and_punctuation_padded_answers
    assert_rejects(%r{missing/short answer q1}) { |p| p.answers["q1"] = "one two three four five" }
    assert_rejects(%r{missing/short answer q1}) { |p| p.answers["q1"] = "one two three four five — ! ? ..." }
    assert_rejects(%r{missing/short answer q2}) { |p| p.answers["q2"] = "-- !! ?? ;;" }
    assert_rejects(%r{missing/short answer q2}) { |p| p.answers["q2"] = "" }
  end

  def test_rejects_absent_or_nonzero_shape_errors
    [{}, { "errors" => 1 }, { "errors" => "0" }, { "errors" => nil }].each do |shape|
      assert_rejects(/shape check failed or absent/) { |p| p.shape.replace(shape) }
    end
  end

  %w[local_qualify teach_qualify grade].each do |kind|
    define_method("test_#{kind}_rejects_missing_extra_duplicate_or_renamed_pairs") do
      changes = { "missing" => ->(r) { r.pop }, "extra" => ->(r) { r << { "feature" => "features/finance/privacy.feature", "name" => "Unlisted scenario", "result" => "passed" } },
                  "duplicate" => ->(r) { r << r.first.dup }, "feature" => ->(r) { r.first["feature"] = "features/finance/other.feature" },
                  "name" => ->(r) { r.first["name"] = "Renamed scenario" }, "empty" => ->(r) { r.clear } }
      changes.each_value do |change|
        assert_rejects(/#{kind} scenario coverage differs/, Proof.new(slice: "panel")) { |p| change.call(p.rows[kind]) }
      end
    end

    define_method("test_#{kind}_rejects_failed_skipped_or_missing_results") do
      ["failed", "skipped", "pending", nil].each do |result|
        assert_rejects(%r{#{kind} has failed/skipped scenarios}, Proof.new(slice: "panel")) { |p| p.rows[kind].last["result"] = result }
      end
    end
  end

  def test_panel_lanes_cannot_be_exchanged
    assert_rejects(/local_qualify scenario coverage differs/, Proof.new(slice: "panel")) { |p| p.rows["local_qualify"] = CourseMatrixCheck.passed(p.graded) }
    assert_rejects(/teach_qualify scenario coverage differs/, Proof.new(slice: "panel")) { |p| p.rows["teach_qualify"] = CourseMatrixCheck.passed(p.local) }
    assert_rejects(/grade scenario coverage differs/, Proof.new(slice: "panel")) { |p| p.rows["grade"] = CourseMatrixCheck.passed(p.local) }
    assert_rejects(%r{signed grade has missing/failed scenarios}, Proof.new(slice: "panel")) do |p|
      p.grade["scenarios"] = CourseMatrixCheck.passed(p.local)
      CourseMatrixCheck.sign(p.grade)
    end
  end

  def test_legacy_case_without_local_scenarios_falls_back_to_protected_scenarios
    proof = Proof.new
    proof.kase.delete("local_scenarios")
    assert_equal 0.75, verify(proof)
    assert_rejects(/local_qualify scenario coverage differs/, Proof.new(slice: "panel")) { |p| p.kase.delete("local_scenarios") }
  end

  def test_rejects_wrong_course_mode_or_module_selection
    assert_rejects(/wrong module-selection path/) { |p| p.selection["course"] = "smoke-assign-fa26" }
    assert_rejects(/wrong module-selection path/) { |p| p.selection["mode"] = "instructor" }
    assert_rejects(/wrong module-selection path/, Proof.new(course: "smoke-assign-fa26", mode: "instructor")) { |p| p.selection["mode"] = "student_choice" }
    assert_rejects(/wrong module-selection path/) { |p| p.selection["modules"] = %w[health marketing] }
    assert_rejects(/wrong module-selection path/) { |p| p.selection.delete("modules") }
  end

  def test_rejects_mismatched_partial_or_incomplete_submission_manifest
    { "course" => "smoke-assign-fa26", "assignment" => "a4", "cutout_id" => "finance.a3s1", "slice" => "panel" }.each do |key, value|
      assert_rejects(/submission manifest #{key} differs/) { |p| p.manifest[key] = value }
      assert_rejects(/submission manifest #{key} differs/) { |p| p.manifest.delete(key) }
    end
    assert_rejects(/partial submission manifest/) { |p| p.manifest["partial"] = true }
    assert_rejects(/owned files missing from submission/) { |p| p.manifest["owned_files"].delete("app/finance/aggregate.rb") }
    assert_rejects(/owned files missing from submission/) { |p| p.manifest.delete("owned_files") }
  end

  def test_rejects_empty_missing_or_non_string_submission_id
    assert_rejects(/missing submission/) { |p| p.evidence["submission_id"] = "" }
    assert_rejects(/missing submission/) { |p| p.evidence["submission_id"] = 42 }
    assert_rejects(/invalid evidence: key not found: "submission_id"/) { |p| p.evidence.delete("submission_id") }
  end

  def test_rejects_missing_or_invalid_public_key
    assert_rejects(/missing evidence file teach_public_key\.pem/) { |p| p.public_pem = nil }
    assert_rejects(/invalid evidence/) { |p| p.public_pem = "-----BEGIN PUBLIC KEY-----\nnot a key\n-----END PUBLIC KEY-----\n" }
    assert_rejects(/invalid receipt signature/) { |p| p.public_pem = OTHER_KEY.public_key.to_pem }
    assert_rejects(/teach public key file holds a private key/) { |p| p.public_pem = KEY.to_pem }
  end

  def test_security_validation_must_have_passed_for_this_course_and_kind
    assert_rejects(/security validation did not complete/) { |p| p.security["phase"] = "challenge_sent" }
    assert_rejects(/invalid evidence: key not found: "receipt"/) { |p| p.security.delete("receipt") }
    assert_rejects(/security receipt belongs to another course/) { |p| CourseMatrixCheck.sign(p.security["receipt"].merge!("course_id" => "smoke-assign-fa26")) }
    assert_rejects(/security receipt belongs to another course/) { |p| CourseMatrixCheck.sign(p.security["receipt"].merge!("kind" => "ingest")) }
  end

  def test_security_receipt_signature_must_verify
    assert_rejects(/invalid receipt signature/) { |p| CourseMatrixCheck.sign(p.security["receipt"], OTHER_KEY) }
    assert_rejects(/invalid receipt signature/) { |p| p.security["receipt"]["challenge_id"] = "val_other" }
    assert_rejects(/invalid evidence/) { |p| p.security["receipt"]["signature"] = "%%not-base64%%" }
    assert_rejects(/invalid evidence: key not found: "signature"/) { |p| p.security["receipt"].delete("signature") }
  end

  def test_security_receipt_issued_at_tolerance_is_one_second
    proof = Proof.new
    CourseMatrixCheck.sign(proof.security["receipt"].merge!("issued_at" => CourseMatrixCheck.at(-1)))
    assert_equal 0.75, verify(proof)
    assert_rejects(/stale security receipt/) { |p| CourseMatrixCheck.sign(p.security["receipt"].merge!("issued_at" => CourseMatrixCheck.at(-2))) }
  end

  def test_security_receipt_expiry_boundary_is_exclusive
    proof = Proof.new
    CourseMatrixCheck.sign(proof.security["receipt"].merge!("expires_at" => CourseMatrixCheck.at(1)))
    assert_equal 0.75, verify(proof)
    assert_rejects(/stale security receipt/) { |p| CourseMatrixCheck.sign(p.security["receipt"].merge!("expires_at" => STARTED)) }
    assert_rejects(/stale security receipt/) { |p| CourseMatrixCheck.sign(p.security["receipt"].merge!("expires_at" => CourseMatrixCheck.at(-60))) }
  end

  def test_receipt_signatures_reject_invalid_base64_corruption_wrong_key_and_changed_bodies
    %w[ingest grade].each do |kind|
      assert_rejects(/invalid evidence/) { |p| p.send(kind)["signature"] = "@@@" }
      assert_rejects(/invalid receipt signature/) do |p|
        raw = Base64.strict_decode64(p.send(kind)["signature"])
        raw.setbyte(10, raw.getbyte(10) ^ 0xff)
        p.send(kind)["signature"] = Base64.strict_encode64(raw)
      end
      assert_rejects(/invalid receipt signature/) { |p| CourseMatrixCheck.sign(p.send(kind), OTHER_KEY) }
      assert_rejects(/invalid evidence: key not found: "signature"/) { |p| p.send(kind).delete("signature") }
    end
    assert_rejects(/invalid receipt signature/) do |p|
      p.ingest["receipt_id"] = "rcpt_ingest_forged"
      p.message = "Receipt number rcpt_ingest_forged.\n"
    end
    assert_rejects(/invalid receipt signature/) { |p| p.grade["scenarios"].first["note"] = "edited" }
  end

  def test_rejects_mismatched_teach_and_student_copies
    %w[ingest grade].each do |kind|
      assert_rejects(/#{kind} receipt was not delivered unchanged/) do |p|
        p.student[kind] = CourseMatrixCheck.sign(p.send(kind).reject { |key, _| key == "signature" }.merge("issued_at" => CourseMatrixCheck.at(2000)))
      end
      assert_rejects(/#{kind} receipt was not delivered unchanged/) { |p| p.overrides["receipts/student/#{kind}.json"] = "{}" }
      assert_rejects(/missing evidence file receipts\/student\/#{kind}\.json/) { |p| p.overrides["receipts/student/#{kind}.json"] = nil }
    end
  end

  def test_receipts_are_bound_to_kind_submission_student_cutout_assignment_and_slice
    wrong = { "kind" => "receipt", "submission_id" => "sub_000099", "student_id" => CourseMatrix::OTHER_STUDENT_ID, "cutout_id" => "finance.a3s1", "assignment" => "a4", "slice" => "panel" }
    %w[ingest grade].each do |kind|
      wrong.each do |field, value|
        assert_rejects(/#{kind} receipt #{field} differs/) { |p| CourseMatrixCheck.sign(p.send(kind).merge!(field => value)) }
      end
      assert_rejects(/#{kind} receipt kind differs/) { |p| CourseMatrixCheck.sign(p.send(kind).merge!("kind" => kind == "ingest" ? "grade" : "ingest")) }
    end
  end

  def test_rejects_partial_or_predating_receipts
    %w[ingest grade].each do |kind|
      assert_rejects(/partial submission cannot pass/) { |p| CourseMatrixCheck.sign(p.send(kind).merge!("partial" => true)) }
      assert_rejects(/receipt predates this run/) { |p| CourseMatrixCheck.sign(p.send(kind).merge!("issued_at" => CourseMatrixCheck.at(-2))) }
      assert_rejects(/invalid evidence: key not found: "issued_at"/) { |p| p.send(kind).delete("issued_at") && CourseMatrixCheck.sign(p.send(kind)) }
      proof = Proof.new
      CourseMatrixCheck.sign(proof.send(kind).merge!("issued_at" => CourseMatrixCheck.at(-1)))
      assert_equal 0.75, verify(proof)
    end
  end

  def test_signed_grade_rejects_missing_duplicate_failed_scenarios_or_score_other_than_one
    changes = [->(g) { g["scenarios"].pop }, ->(g) { g["scenarios"] << g["scenarios"].first.dup }, ->(g) { g["scenarios"].last["result"] = "failed" },
               ->(g) { g["scenarios"].first["name"] = "Renamed scenario" }, ->(g) { g["score"] = 0.99 }, ->(g) { g["score"] = "1" }, ->(g) { g.delete("score") }]
    changes.each do |change|
      assert_rejects(%r{signed grade has missing/failed scenarios}) do |p|
        change.call(p.grade)
        CourseMatrixCheck.sign(p.grade)
      end
    end
    assert_rejects(/invalid evidence: key not found: "scenarios"/) { |p| p.grade.delete("scenarios") && CourseMatrixCheck.sign(p.grade) }
  end

  def test_student_message_must_contain_ingest_receipt_id
    assert_rejects(/student was not told the receipt number/) { |p| p.message = "Your work is submitted.\n" }
    assert_rejects(/student was not told the receipt number/) { |p| p.message = "Receipt number rcpt_grade_91c2.\n" }
    assert_rejects(%r{missing evidence file stages/student_receipt\.txt}) { |p| p.message = nil }
  end

  def test_rejects_absent_non_numeric_negative_or_over_reservation_cost
    assert_rejects(/invalid evidence: key not found: "cost_usd"/) { |p| p.evidence.delete("cost_usd") }
    ["0.75", nil, true, -0.01, 4.5000001, 5].each do |cost|
      assert_rejects(%r{missing/invalid cost accounting}) { |p| p.evidence["cost_usd"] = cost }
    end
    [Float::NAN, Float::INFINITY].each do |cost|
      assert_rejects(/invalid evidence/) { |p| p.overrides["evidence.json"] = JSON.generate(p.evidence.merge("cost_usd" => cost), allow_nan: true) }
    end
  end

  def test_rejects_non_finite_ruby_costs
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |cost|
      proof = Proof.new
      dir = proof.write(next_dir)
      evidence = CourseMatrix::Evidence.new(proof.kase, dir)
      original = evidence.method(:json)
      evidence.define_singleton_method(:json) { |relative| relative == "evidence.json" ? original.call(relative).merge("cost_usd" => cost) : original.call(relative) }
      error = assert_raises(CourseMatrix::Failure) { evidence.verify! }
      assert_match(%r{missing/invalid cost accounting}, error.message)
    end
  end
end

class CourseMatrixCliCheck < Minitest::Test
  include CourseMatrixCheck
  include CourseMatrixCheck::Scratch

  def run_cli(dir, env = {})
    Open3.capture3({ "REACH_SMOKE_DISABLE" => nil }.merge(env), RbConfig.ruby, SCRIPT, "--verify-case", dir, chdir: @root)
  end

  def test_verify_case_accepts_a_valid_proof
    proof = Proof.new(slice: "panel")
    out, err, status = run_cli(proof.write(next_dir))
    assert_equal 0, status.exitstatus, err
    assert_equal "verified #{proof.kase['id']}; cost_usd=0.75\n", out
  end

  def test_verify_case_fails_closed_on_corrupt_or_missing_evidence
    corrupt = Proof.new
    CourseMatrixCheck.sign(corrupt.grade, OTHER_KEY)
    missing = Proof.new
    missing.overrides["evidence.json"] = nil
    { corrupt => /invalid receipt signature/, missing => /missing evidence file evidence\.json/ }.each do |proof, pattern|
      out, err, status = run_cli(proof.write(next_dir))
      refute_equal 0, status.exitstatus
      refute_match(/verified/, out)
      assert_match pattern, err
    end
    out, err, status = run_cli(next_dir)
    refute_equal 0, status.exitstatus
    refute_match(/verified/, out)
    assert_match(/course_matrix: /, err)
  end

  def test_verify_case_honors_kill_switch
    out, err, status = run_cli(Proof.new.write(next_dir), "REACH_SMOKE_DISABLE" => "1")
    refute_equal 0, status.exitstatus
    refute_match(/verified/, out)
    assert_match(/REACH_SMOKE_DISABLE=1/, err)
  end
end

class CourseMatrixReportCheck < Minitest::Test
  include CourseMatrixCheck
  include CourseMatrixCheck::Scratch

  Inventory = Struct.new(:cases, :sources)
  IDS = (["smoke-assign-fa26/instructor/finance.a3s2/backend", "smoke-assign-fa26/instructor/finance.a3s2/panel"] +
         %w[backend panel].map { |slice| ["SMOKECHOICEFA26", "student_choice", "health.a1", slice].join("/") }).freeze

  def sources(fingerprint = BASELINE)
    { "grokit_ref" => "v0.10.1", "grokit_sha" => "a" * 40, "reach_source_sha256" => fingerprint, "grokit_spec_sha256" => "b" * 64, "teach_spec_sha256" => "c" * 64 }
  end

  def inventory(ids = IDS, fingerprint = BASELINE)
    Inventory.new(ids.map { |id| { "id" => id } }, sources(fingerprint))
  end

  def row(id, status = "passed")
    { "id" => id, "status" => status, "directory" => "/scratch/#{id.tr('/', '_')}", "cost_usd" => 0.0 }
  end

  def failed(id)
    row(id, "failed").merge("reason" => "native check failed", "failure" => { "stage" => "check", "reason" => "CK-PORTS: Grokit::Money.zero is not granted" })
  end

  def shard(rows, fingerprint: BASELINE, kind: "native_fixture", mode: "run")
    dir = File.join(@root, "shard-#{@count += 1}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "report.json"), JSON.generate({ "mode" => mode, "execution_kind" => kind, "sources" => sources(fingerprint), "selected_count" => rows.length,
                                                                "budget_usd" => 0, "cost_usd" => 0.0, "coverage_complete" => false, "cases" => rows }))
    dir
  end

  def merge(paths, inv = inventory)
    output = File.join(@root, "merged-#{@count += 1}")
    code = nil
    capture_io { code = CourseMatrix.merge_reports(paths, inv, output) }
    [code, JSON.parse(File.read(File.join(output, "report.json"))), File.read(File.join(output, "report.md"))]
  end

  def assert_merge_refused(pattern, paths, inv = inventory)
    output = File.join(@root, "refused-#{@count += 1}")
    error = assert_raises(CourseMatrix::Failure) { capture_io { CourseMatrix.merge_reports(paths, inv, output) } }
    assert_match pattern, error.message
    refute File.exist?(output)
  end

  def test_complete_passing_shards_merge_to_complete_coverage
    code, report, = merge([shard(IDS[0, 2].map { |id| row(id) }), shard(IDS[2, 2].map { |id| row(id) })])
    assert_equal 0, code
    assert_equal [true, true, 4, 4], report.values_at("coverage_complete", "execution_complete", "executed_count", "selected_count")
  end

  def test_failed_row_in_full_inventory_executes_completely_without_coverage
    code, report, markdown = merge([shard([row(IDS[0]), failed(IDS[1])]), shard(IDS[2, 2].map { |id| row(id) })])
    assert_equal 1, code
    assert_equal [false, true], report.values_at("coverage_complete", "execution_complete")
    assert_equal({ "stage" => "check", "reason" => "CK-PORTS: Grokit::Money.zero is not granted" }, report["cases"].find { |c| c["id"] == IDS[1] }["failure"])
    assert_includes markdown, "Failed stages: check=1."
    assert_includes markdown, "| #{IDS[1]} | failed | check | CK-PORTS: Grokit::Money.zero is not granted |"
    assert_includes markdown, "| A3 / backend | 1 | 0 | 0 |"
    assert_includes markdown, "| A3 / panel | 0 | 1 | 0 |"
    assert_includes markdown, "| A1 / backend | 1 | 0 | 0 |"
  end

  def test_not_run_rows_are_preserved_and_keep_execution_incomplete
    not_run = row(IDS[3], "not_run").merge("reason" => "budget reservation or STOP")
    code, report, markdown = merge([shard(IDS[0, 3].map { |id| row(id) } + [not_run])])
    assert_equal 1, code
    assert_equal [false, false, 3, 4], report.values_at("coverage_complete", "execution_complete", "executed_count", "selected_count")
    assert_equal "not_run", report["cases"].last["status"]
    assert_includes markdown, "Statuses: passed=3, not_run=1."
    assert_includes markdown, "| A1 / panel | 0 | 0 | 1 |"
    assert_includes markdown, "| #{IDS[3]} | not_run |  | budget reservation or STOP |"
  end

  def test_passing_subset_never_claims_complete_coverage
    code, report, = merge([shard(IDS[0, 2].map { |id| row(id) })])
    assert_equal 1, code
    assert_equal [false, true, 2, 4], report.values_at("coverage_complete", "execution_complete", "selected_count", "inventory_count")
  end

  def test_refuses_duplicate_and_unknown_case_ids
    assert_merge_refused(/duplicate or unknown shard cases/, [shard([row(IDS[0])]), shard([row(IDS[0]), row(IDS[1])])])
    assert_merge_refused(/duplicate or unknown shard cases/, [shard([row(IDS[0]), row("smoke-assign-fa26/instructor/finance.a9s9/backend")])])
  end

  def test_refuses_mixed_baseline_and_corrective_fingerprints
    paths = [shard(IDS[0, 3].map { |id| row(id) }, fingerprint: BASELINE), shard([row(IDS[3])], fingerprint: CORRECTIVE)]
    assert_merge_refused(/same sources and engine/, paths, inventory(IDS, BASELINE))
    assert_merge_refused(/same sources and engine/, paths, inventory(IDS, CORRECTIVE))
  end

  def test_refuses_differing_engines_plan_mode_and_existing_output
    assert_merge_refused(/same sources and engine/, [shard([row(IDS[0])]), shard([row(IDS[1])], kind: "agent_adapter")])
    assert_merge_refused(/same sources and engine/, [shard([row(IDS[0])], mode: "plan")])
    paths = [shard([row(IDS[0])])]
    output = File.join(@root, "existing")
    FileUtils.mkdir_p(output)
    error = assert_raises(CourseMatrix::Failure) { capture_io { CourseMatrix.merge_reports(paths, inventory, output) } }
    assert_match(/output already exists/, error.message)
    assert_empty Dir.children(output)
  end

  def test_save_report_counts_only_passed_and_failed_as_executed
    dir = File.join(@root, "saved")
    FileUtils.mkdir_p(dir)
    report = { "mode" => "plan", "execution_kind" => "plan", "coverage_complete" => false, "selected_count" => 3, "inventory_count" => 280, "budget_usd" => 25, "cost_usd" => 0.0,
               "cases" => [row(IDS[0], "planned"), row(IDS[1], "not_run"), failed(IDS[2])] }
    CourseMatrix.save_report(dir, report)
    saved = JSON.parse(File.read(File.join(dir, "report.json")))
    assert_equal [1, false, false], saved.values_at("executed_count", "execution_complete", "coverage_complete")
    assert_includes File.read(File.join(dir, "report.md")), "Executed: 1/3; inventory: 280;"
  end
end
