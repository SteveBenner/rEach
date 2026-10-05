require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module EnrollmentLock
    MESSAGES = {
      "not_enrolled" => "M-GATE-NOENROLL",
      "revoked" => "M-GATE-REVOKED",
      "stamp_invalid" => "M-ENR-STAMP-INVALID",
      "moved" => "M-ENR-MOVED",
      "restamp" => "M-ENR-RESTAMP",
      "course_ended" => "M-ENR-COURSE-ENDED",
      "instructor_revoked" => "M-PERSONA-LOCKED"
    }.freeze
    MOVED_KIND = "fingerprint_mismatch".freeze

    module_function

    def pass_session=(session_id)
      @pass_session = session_id.to_s.empty? ? nil : session_id.to_s
    end

    def pass_session
      @pass_session
    end

    def state
      current = compute_state
      Reach::Debug.lock(current)
      current
    end

    def compute_state
      if Reach::Persona.active?
        return { "locked" => true, "reason" => "instructor_revoked", "message_id" => MESSAGES.fetch("instructor_revoked") } unless Reach::Instructor.active?
      elsif Reach::Instructor.active?
        return { "locked" => false, "reason" => "instructor", "message_id" => nil }
      end

      reason = reason_for_state
      return { "locked" => false, "reason" => nil, "message_id" => nil } unless reason
      return { "locked" => false, "reason" => "instructor_pass", "message_id" => nil } if Reach::Instructor.pass_for(@pass_session)

      { "locked" => true, "reason" => reason, "message_id" => MESSAGES.fetch(reason) }
    rescue StandardError
      { "locked" => true, "reason" => "stamp_invalid", "message_id" => MESSAGES.fetch("stamp_invalid") }
    end

    def locked?
      state["locked"]
    end

    def message(state_hash = state)
      Reach::Messages.text(state_hash["message_id"])
    end

    def check!
      current = state
      return nil unless current["locked"]

      raise Reach::GateBlocked.new(current["message_id"], Reach::Messages.text(current["message_id"]))
    end

    def reason_for_state
      install = Reach::Enroll.current
      return "not_enrolled" unless install
      return "revoked" if install["revoked"]
      return "moved" if File.file?(Reach::Paths.enroll_moved_file)

      stamp = Reach::Stamp.current
      unless install["shape"] == "v2" || stamp
        return Reach::Policy.enrollment["require_stamp"] ? "restamp" : nil
      end
      return "stamp_invalid" unless stamp && stamp_valid?(install, stamp)
      return "course_ended" if Reach::Stamp.expired?(stamp)

      stored = Reach::Fingerprint.stored
      return "stamp_invalid" unless stored

      live = Reach::Fingerprint.live(salt: stored["salt"])
      strict = Reach::Policy.enrollment["fingerprint_match"] == "strict"
      wanted = strict ? stamp["fingerprint_strict_digest"] : stamp["fingerprint_digest"]
      return nil if Reach::Fingerprint.digest_for(live, strict) == wanted

      mark_moved!(Reach::Fingerprint.changed_components(stored, live))
      "moved"
    end

    def stamp_valid?(install, stamp)
      expect = {
        "install_id" => install["install_id"],
        "student_id" => install["student_id"],
        "course_id" => (install["course"].is_a?(Hash) ? install["course"]["id"] : nil)
      }
      expect["username"] = install["username"] if install["username"]
      expect.delete_if { |_, value| value.to_s.empty? }
      Reach::Stamp.verify!(stamp, signing_public_keys: install["signing_public_keys"], expect: expect)
      true
    rescue StandardError
      false
    end

    def mark_moved!(changed)
      stamp = Reach::Stamp.current
      stamp_id = stamp && stamp["stamp_id"]
      first = !File.file?(Reach::Paths.enroll_moved_file)
      Reach::Stamp.drop!
      FileUtils.mkdir_p(Reach::Paths.enroll_state_dir)
      record = { "stamp_id" => stamp_id, "changed" => Array(changed), "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
      path = Reach::Paths.enroll_moved_file
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(record)) }
      File.rename(tmp, path)
      queue_mismatch(record) if first
      record
    rescue StandardError
      nil
    end

    def clear_moved!
      FileUtils.rm_f(Reach::Paths.enroll_moved_file)
    end

    def queue_mismatch(record)
      Reach::Integrity.queue("fingerprint_mismatch", detail: { "stamp_id" => record["stamp_id"], "changed" => record["changed"] })
    end
  end
end
