require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Persona
    ROUTE = "/api/v1/enroll/instructor".freeze
    KINDS = %w[dummy copy].freeze
    HARNESSES = %w[claude-code codex hermes unknown].freeze

    module_function

    def pointer_file
      Reach::Paths.persona_pointer_file
    end

    def active?
      !Reach::Paths.persona_id.nil?
    end

    def current
      Reach::Paths.persona_record
    end

    def status
      record = current
      return { "active" => false } unless record

      {
        "active" => true,
        "id" => record["id"],
        "kind" => record["kind"],
        "display_name" => record["display_name"],
        "username" => record["username"],
        "student_id" => record["student_id"],
        "course_id" => record["course_id"],
        "test_of" => record["test_of"],
        "started_at" => record["started_at"],
        "workspace" => Reach::Paths.persona_workspace_for(record["id"])
      }
    end

    def timestamp
      Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def start!(kind:, username: nil, course_id: nil, harness: nil)
      unlock = Reach::Instructor.current
      raise Reach::Refused, Reach::Messages.text("M-PERSONA-NEEDS-UNLOCK") unless unlock

      existing = current
      if existing
        raise Reach::Refused, Reach::Messages.text("M-PERSONA-ACTIVE", display_name: existing["display_name"], id: existing["id"])
      end
      raise Reach::Refused, Reach::Messages.text("M-PERSONA-ENROLLED") unless Reach::Enroll.current.nil?

      teach_url = Reach::Runtime.default_teach_url
      raise Reach::Refused, Reach::Messages.text("M-PERSONA-NO-SERVER") unless teach_url

      id = SecureRandom.hex(4)
      home = Reach::Paths.persona_home_for(id)
      workspace = Reach::Paths.persona_workspace_for(id)
      payload = unlock["payload"]
      record = nil
      begin
        FileUtils.mkdir_p(home, mode: 0o700)
        FileUtils.mkdir_p(workspace)
        Reach::Paths.persona_override = id
        record = enroll!(id, kind, username, course_id, harness, unlock, teach_url)
        write_pointer!(record)
      rescue StandardError => e
        Reach::Paths.persona_override = nil
        retire_failed(id, home, workspace)
        Reach::Instructor.log(
          "instructor.persona_refused",
          "persona_id" => id, "kind" => kind, "course_id" => course_id, "code_id" => payload["id"], "reason" => failure_reason(e)
        )
        raise map_error(e, course_id)
      end
      Reach::Paths.persona_override = nil
      Reach::Paths.reset_persona_memo!
      Reach::Instructor.log(
        "instructor.persona_started",
        "persona_id" => id, "kind" => kind, "course_id" => record["course_id"], "code_id" => payload["id"], "student_id" => record["student_id"]
      )
      summary = begin
        Reach::Sync.run
      rescue StandardError
        nil
      end
      { "persona" => record, "summary" => summary, "workspace" => workspace }
    end

    def enroll!(id, kind, username, course_id, harness, unlock, teach_url)
      Reach::Paths.ensure_home!
      key = Reach::Crypto.generate_install_key
      harness_id = HARNESSES.include?(harness.to_s) ? harness.to_s : Reach::Transcript.resolve_harness(harness)
      harness_id = "unknown" unless HARNESSES.include?(harness_id)
      fingerprint = Reach::Fingerprint.build(install_public_key: key.public_key, harness: harness_id, enrolled_via: "cli")
      persona = { "kind" => kind }
      persona["username"] = username if kind == "copy"
      fields = {
        "shape" => "v2",
        "instructor_code" => unlock["code"],
        "persona" => persona,
        "fingerprint" => fingerprint,
        "public_key_pem" => key.public_key.to_pem,
        "reach_version" => Reach::VERSION,
        "harness" => harness_id,
        "platform" => Reach::Enroll.platform,
        "ruby_version" => RUBY_VERSION
      }
      fields["course_id"] = course_id if course_id && !course_id.to_s.empty?

      response = Reach::Enroll.flow_client(teach_url).post_json(ROUTE, fields)
      body = response.json || {}
      Reach::Enroll.verify_response!(body)
      info = body["persona"]
      incomplete = Reach::Messages.text("M-ENROLL-INCOMPLETE")
      raise Reach::Refused, incomplete unless info.is_a?(Hash) && info["student_id"].to_s == body["student_id"].to_s
      raise Reach::Refused, incomplete unless body["course"].is_a?(Hash) && !body["course"]["id"].to_s.empty?

      stamp = body["enrollment_stamp"]
      begin
        Reach::Stamp.verify!(
          stamp,
          signing_public_keys: body["signing_public_keys"],
          expect: {
            "install_id" => body["install_id"], "student_id" => info["student_id"], "username" => info["username"],
            "course_id" => body["course"]["id"], "fingerprint_digest" => fingerprint["digest"],
            "fingerprint_strict_digest" => fingerprint["strict_digest"]
          }
        )
      rescue Reach::VerificationFailed
        raise Reach::Refused, incomplete
      end

      Reach::Enroll.write_private_key(key)
      Reach::Enroll.write_install_file(body, teach_url, "shape" => "v2", "username" => info["username"], "display_name" => body["display_name"])
      Reach::Fingerprint.store!(fingerprint)
      Reach::Stamp.store!(stamp)
      Reach::Fingerprint.clear_cache!
      Reach::Enroll.write_notice(body)
      Reach::Enroll.announce_sidecar(Reach::Enroll.current)

      {
        "id" => id,
        "kind" => kind,
        "course_id" => body["course"]["id"],
        "student_id" => info["student_id"],
        "username" => info["username"],
        "display_name" => body["display_name"],
        "test_of" => info["test_of"],
        "install_id" => body["install_id"],
        "code_id" => unlock["payload"]["id"],
        "started_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
    end

    def write_pointer!(record)
      path = pointer_file
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(record)) }
      File.rename(tmp, path)
      File.chmod(0o600, path)
      path
    end

    def retire_failed(id, home, workspace)
      stamp = timestamp
      move_aside(home, File.join(Reach::Paths.root, ".backup", "personas", "#{id}-failed-#{stamp}"))
      move_aside(workspace, File.join(Reach::Paths.workspace_base, ".backup", "personas", "#{id}-failed-#{stamp}"))
    rescue StandardError
      nil
    end

    def move_aside(source, target)
      return nil unless File.exist?(source)

      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.mv(source, target)
      target
    end

    def failure_reason(error)
      return error.code.to_s if error.is_a?(Reach::RemoteRefused)

      error.class.name.to_s
    end

    def map_error(error, course_id)
      return error unless error.is_a?(Reach::RemoteRefused)

      details = error.details.is_a?(Hash) ? error.details : {}
      case error.code
      when "instructor_code_refused"
        Reach::Refused.new(Reach::Messages.text("M-PERSONA-CODE-REFUSED", reason: details["reason"].to_s))
      when "course_required"
        Reach::Refused.new(Reach::Messages.text("M-PERSONA-COURSE-NEEDED", courses: Array(details["courses"]).join(", ")))
      when "student_not_found"
        Reach::Refused.new(Reach::Messages.text("M-PERSONA-NO-STUDENT", username: details["username"].to_s))
      when "not_found"
        course_id.nil? || course_id.to_s.empty? ? Reach::Refused.new(Reach::Messages.text("M-PERSONA-TEACH-OLD")) : error
      else
        error
      end
    end

    def exit!
      record = current
      return nil unless record

      id = record["id"]
      stamp = timestamp
      backup = File.join(Reach::Paths.root, ".backup")
      FileUtils.mkdir_p(backup)
      pointer_target = File.join(backup, "persona-#{id}-#{stamp}.json")
      FileUtils.mv(pointer_file, pointer_target)
      Reach::Paths.reset_persona_memo!
      move_aside(Reach::Paths.persona_home_for(id), File.join(backup, "personas", "#{id}-#{stamp}"))
      move_aside(Reach::Paths.persona_workspace_for(id), File.join(Reach::Paths.workspace_base, ".backup", "personas", "#{id}-#{stamp}"))
      Reach::Paths.reset_persona_memo!
      payload = begin
        unlock = Reach::Instructor.stored
        unlock && unlock["payload"].is_a?(Hash) ? unlock["payload"] : {}
      rescue StandardError
        {}
      end
      Reach::Instructor.log(
        "instructor.persona_exited",
        "persona_id" => id, "kind" => record["kind"], "course_id" => record["course_id"], "code_id" => record["code_id"] || payload["id"], "student_id" => record["student_id"]
      )
      record
    end
  end
end
