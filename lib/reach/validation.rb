require "json"
require "time"
require "uri"
require "base64"
require "securerandom"
require "fileutils"
require "open3"
require "rbconfig"
require "timeout"
require "shellwords"

module Reach
  module Validation
    ROUTE = "/api/v1/validation".freeze
    SCHEMA = "teach.security-validation/v1".freeze
    ANNOUNCE = "Before we enroll, I will run a security validation pass using made-up answers to check that your work can reach Teach and that its receipt comes back. This does not submit your assignment or affect your grade.".freeze
    BLOCKED = "The security validation pass could not verify the connection to Teach. This may be a connection problem, or this software might be someone impersonating rEach or Teach. Please wait and contact your instructor through the contact details you already have before continuing to enroll.".freeze
    PASSED = "Security validation pass complete. Teach received the made-up submission, and rEach verified its receipt. You can continue to enroll.".freeze
    OWNED = %w[answers.json README.md].freeze
    HARNESSES = %w[claude-code codex antigravity hermes].freeze
    MAX_INPUT = 128 * 1024

    module_function

    def directory
      File.join(Reach::Paths.root_state_dir, "validation")
    end

    def state_file
      File.join(directory, "current.json")
    end

    def read
      return nil unless File.file?(state_file)

      JSON.parse(File.read(state_file))
    rescue JSON::ParserError
      nil
    end

    def write(state)
      Reach::StateFile.write_atomic(state_file, JSON.generate(state))
      state
    end

    def configured_url
      url = Reach::Runtime.default_teach_url.to_s.sub(%r{/+\z}, "")
      uri = URI.parse(url)
      raise Reach::Refused, BLOCKED unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.query && !uri.fragment && ["", "/"].include?(uri.path)

      url
    rescue URI::InvalidURIError
      raise Reach::Refused, BLOCKED
    end

    def harness(value = nil)
      label = value.to_s.empty? ? Reach::HarnessIdentity.detect["label"] : value.to_s
      label = "codex" if label.to_s.start_with?("codex-")
      label = "claude-code" if label.to_s.start_with?("claude-code-")
      raise Reach::Refused, BLOCKED unless HARNESSES.include?(label)

      label
    end

    def key(state)
      Reach::Crypto.load_private_key(File.read(File.join(directory, state.fetch("local_id"), "key.pem")))
    end

    def client(state)
      raise Reach::Refused, BLOCKED unless state["teach_url"] == configured_url

      Reach::Client.for_attempt(state["teach_url"], state.fetch("session_id"), key(state), connect_timeout: 5, read_timeout: 15, max_retries: 1)
    end

    def fresh?(state, course_code: nil, harness: nil)
      state.is_a?(Hash) && state["schema"] == SCHEMA && state["reach_version"] == Reach::VERSION &&
        state["teach_url"] == configured_url && Time.iso8601(state.fetch("expires_at")) > Time.now.utc &&
        (!course_code || state["course_digest"] == Reach::Crypto.digest_hex(course_code)) &&
        (!harness || state["harness"] == harness)
    rescue StandardError
      false
    end

    def start(course_code:, harness: nil, restart: false)
      raise Reach::Refused, BLOCKED if ENV["REACH_VALIDATION_DISABLE"] == "1"
      label = self.harness(harness)
      parsed = Reach::Identity.parse_course_code(course_code)
      raise Reach::Refused, BLOCKED unless parsed

      code = parsed["code"]
      held = read
      return status if !restart && fresh?(held, course_code: code, harness: label) && held["phase"] != "consumed"

      local = SecureRandom.hex(16)
      root = File.join(directory, local)
      FileUtils.mkdir_p(root, mode: 0o700)
      private_key = Reach::Crypto.generate_install_key
      Reach::StateFile.write_atomic(File.join(root, "key.pem"), private_key.to_pem)
      nonce = SecureRandom.hex(32)
      reply = Reach::Client.anonymous(configured_url, connect_timeout: 5, read_timeout: 15, max_retries: 1, link: false).post_json(
        ROUTE, { "course_code" => code, "public_key" => private_key.public_key.to_pem, "nonce" => nonce,
                 "harness" => label, "reach_version" => Reach::VERSION }, idempotency_key: local
      ).json
      raise Reach::VerificationFailed, BLOCKED unless reply.is_a?(Hash) && reply["schema"] == SCHEMA && reply["nonce"] == nonce && reply["session_id"].to_s.match?(/\Avld_[0-9a-f]{24}\z/)

      state = reply.merge("local_id" => local, "teach_url" => configured_url, "course_digest" => Reach::Crypto.digest_hex(code),
                          "harness" => label, "reach_version" => Reach::VERSION, "phase" => "handoff")
      raise Reach::VerificationFailed, BLOCKED unless fresh?(state)
      raise Reach::VerificationFailed, BLOCKED unless state["course_id"].is_a?(String) && state["course_id"].match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/)
      questions = state["questions"]
      valid_questions = questions.is_a?(Array) && questions.length.between?(1, 64) && questions.all? do |item|
        item.is_a?(Hash) && item["id"].is_a?(String) && item["id"].match?(/\A[a-z0-9_]{1,64}\z/) && item["shape"] == "text" &&
          item["question"].is_a?(String) && item["question"].bytesize <= 2000 && item["min_words"].is_a?(Integer) && item["min_words"].between?(1, 2000)
      end
      raise Reach::VerificationFailed, BLOCKED unless valid_questions && questions.map { |item| item["id"] }.uniq.length == questions.length

      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(File.join(workspace, ".reach"))
      marker = { "course" => state["course_id"], "assignment" => "security-validation", "cutout_id" => state["session_id"], "slice" => "validation", "owned_files" => OWNED }
      Reach::StateFile.write_atomic(File.join(workspace, ".reach", "slice.json"), JSON.generate(marker))
      write(state)
      Reach::Debug.emit("gate", "check" => "security_validation", "outcome" => "started")
      status
    end

    def workspace(state)
      id = state["local_id"].to_s
      raise Reach::Refused, BLOCKED unless id.match?(/\A[0-9a-f]{32}\z/)

      File.join(directory, id, "workspace")
    end

    def status
      return { "phase" => "blocked", "text" => BLOCKED } if ENV["REACH_VALIDATION_DISABLE"] == "1"
      state = read
      return { "phase" => "required", "text" => ANNOUNCE, "next" => "Run reach validate --course-code COURSE_CODE --harness YOUR_HARNESS before asking for identity or a password." } unless fresh?(state)
      verify_receipt!(state, state["receipt"]) if state["phase"] == "passed"

      result = { "phase" => state["phase"], "text" => state["phase"] == "passed" ? PASSED : ANNOUNCE,
                 "workspace" => workspace(state), "questions" => state["questions"], "readme_sections" => Reach::ReadmeCheck::SECTIONS,
                 "readme_min_words_per_section" => Reach::ReadmeCheck::MIN_WORDS }
      result["next"] = case state["phase"]
                       when "handoff" then "Act as the smoke student: fabricate one answer per provided shape. Call reach validate answer --question ID --text TEXT for each. Never use real student answers."
                       when "plan" then "Call reach validate plan --text TEXT describing how you will preserve the fabricated answers in answers.json and explain them in README.md."
                       when "build" then "Use reach validate artifact --question answers.json --text JSON to write an object mapping question ids to the exact fabricated answer texts, then the same command with --question README.md and its text to explain the fictional decision under each required section. Then run reach validate check."
                       when "checked" then "Run reach validate qualify to have Teach independently check the sealed practice work."
                       when "qualified" then "Run reach validate submit, then reach validate finish."
                       when "received" then "Run reach validate finish to fetch and verify Teach's receipt. Relay its text verbatim to the student."
                       when "passed" then "Relay the passed message verbatim, then continue enrollment."
                       end
      if state["phase"] == "passed"
        flow = Reach::EnrollFlow.read_flow
        result["enrollment_question"] = Reach::EnrollFlow.ask_username(flow) if flow && flow["state"] == "awaiting_username"
      end
      if state["phase"] == "consumed"
        result["text"] = "This security validation pass was used for enrollment. A new enrollment requires a new pass."
        result["next"] = "For a new enrollment, run reach validate --restart --course-code COURSE_CODE --harness YOUR_HARNESS."
      end
      result
    end

    def locked
      FileUtils.mkdir_p(directory, mode: 0o700)
      result = Reach::Locks.exclusive(File.join(directory, "operation.lock"), wait_s: 2.0) { yield }
      raise Reach::Refused, BLOCKED if result == :busy

      result
    end

    def advance(action, question: nil, text: nil)
      raise Reach::Refused, BLOCKED if ENV["REACH_VALIDATION_DISABLE"] == "1"
      locked do
        state = read
        raise Reach::Refused, BLOCKED unless fresh?(state)

        case action
        when "artifact"
          raise Reach::Refused, BLOCKED unless %w[build checked qualified].include?(state["phase"]) && OWNED.include?(question) && text.is_a?(String) && text.bytesize <= MAX_INPUT

          Reach::StateFile.write_atomic(File.join(workspace(state), question), text)
          state["phase"] = "build"
          state.delete("qualification_id")
          state.delete("checked_digest")
          state.delete("pending_submission")
        when "answer"
          raise Reach::Refused, BLOCKED unless state["phase"] == "handoff"

          item = Array(state["questions"]).find { |entry| entry["id"] == question }
          raise Reach::Refused, BLOCKED unless item && text.is_a?(String) && text.bytesize <= MAX_INPUT

          answer = Reach::Part.build_answer(item, { "text" => text, "session_id" => state["session_id"], "seq" => 1 }, "synthetic:#{state['session_id']}")
          state["answers"] ||= {}
          state["answers"][question] = answer.reject { |name, _| name == "student_id" }
          state["phase"] = "plan" if Array(state["questions"]).all? { |entry| state["answers"].key?(entry["id"]) }
        when "plan"
          raise Reach::Refused, BLOCKED unless state["phase"] == "plan" && text.is_a?(String) && text.strip.length.between?(10, 400)

          worker(state, "plan", text)
          state["phase"] = "build"
        when "check"
          raise Reach::Refused, BLOCKED unless %w[build checked qualified].include?(state["phase"])

          artifact = JSON.parse(files(state).fetch("answers.json"))
          expected_answers = state.fetch("answers").to_h { |id, answer| [id, answer["text"]] }
          raise Reach::Refused, "reach: answers.json must preserve every fabricated answer exactly" unless artifact == expected_answers
          worker(state, "check")
          state["checked_digest"] = files_digest(state)
          state["phase"] = "checked"
        when "qualify", "submit"
          expected = action == "qualify" ? "checked" : "qualified"
          raise Reach::Refused, BLOCKED unless state["phase"] == expected && state["checked_digest"] == files_digest(state)

          entries = submission_entries(state)
          body = action == "submit" && state["pending_submission"] ? state["pending_submission"] : package(state, entries)
          body["qualification_id"] = state["qualification_id"] if action == "submit"
          if action == "submit"
            state["pending_submission"] = body
            write(state)
          end
          reply = client(state).post_json("#{ROUTE}/#{state['session_id']}/#{action}", body, idempotency_key: "#{state['session_id']}:#{action}:#{state['checked_digest']}").json
          raise Reach::VerificationFailed, BLOCKED unless reply.is_a?(Hash)

          if action == "qualify"
            raise Reach::VerificationFailed, BLOCKED unless reply["passed"] == true && reply["qualification_id"].to_s.match?(/\Avq_[0-9a-f]{24}\z/)

            state["qualification_id"] = reply["qualification_id"]
            state["phase"] = "qualified"
          else
            verify_receipt!(state, reply["receipt"])
            state["receipt"] = reply["receipt"]
            state["phase"] = "received"
          end
        when "finish"
          raise Reach::Refused, BLOCKED unless %w[received passed].include?(state["phase"])

          reply = client(state).get("#{ROUTE}/#{state['session_id']}/receipt").json
          receipt = reply.is_a?(Hash) ? reply["receipt"] : nil
          verify_receipt!(state, receipt)
          raise Reach::VerificationFailed, BLOCKED unless receipt == state["receipt"]

          state["phase"] = "passed"
        else
          raise Reach::Refused, "reach: unknown validation step"
        end
        write(state)
        Reach::Debug.emit("gate", "check" => "security_validation", "outcome" => state["phase"])
        Reach::EnrollFlow.validation_completed! if action == "finish"
        status
      end
    end

    def files(state)
      OWNED.to_h do |relative|
        data = Reach::SafeFiles.read(workspace(state), relative)
        raise Reach::Refused, "reach: complete #{relative} in the validation workspace" unless data && data.bytesize <= MAX_INPUT

        [relative, data]
      end
    end

    def files_digest(state)
      Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(files(state).transform_values { |bytes| Reach::Crypto.digest_hex(bytes) }))
    end

    def submission_entries(state)
      owned = files(state)
      part = { "schema" => Reach::Part::SCHEMA, "assignment" => "security-validation", "student_id" => "synthetic:#{state['session_id']}", "answers" => state.fetch("answers").values.sort_by { |item| item["question_id"] } }
      manifest = { "schema" => "reach.submission/v1", "course" => state["course_id"], "assignment" => "security-validation", "cutout_id" => state["session_id"], "slice" => "validation", "owned_files" => OWNED,
                   "digests" => owned.transform_values { |data| Reach::Crypto.digest_hex(data) }, "reach_version" => Reach::VERSION }
      { "manifest.json" => JSON.generate(manifest), "part.json" => JSON.generate(part) }.merge(owned.to_h { |relative, data| ["files/#{relative}", data] })
    end

    def package(state, entries)
      plaintext = Reach::Tarball.write(entries)
      state["content_digest"] = Reach::Crypto.digest_hex(plaintext)
      recipient = state.fetch("encryption_key")
      install = { "encryption_key" => recipient, "student_id" => "synthetic:#{state['session_id']}", "install_id" => state["session_id"] }
      meta = { "course" => state["course_id"], "assignment" => "security-validation" }
      { "package" => Reach::Submit.seal_package(install, meta, plaintext, key(state)) }
    end

    def verify_receipt!(state, receipt)
      raise Reach::VerificationFailed, BLOCKED unless receipt.is_a?(Hash)

      expected = { "schema" => SCHEMA, "kind" => "security-validation", "session_id" => state["session_id"], "nonce" => state["nonce"], "course_id" => state["course_id"],
                   "harness" => state["harness"], "reach_version" => Reach::VERSION, "files_digest" => state["checked_digest"], "expires_at" => state["expires_at"],
                   "public_key_digest" => Reach::Crypto.digest_hex(key(state).public_key.to_der) }
      expected["content_digest"] = state["content_digest"]
      raise Reach::VerificationFailed, BLOCKED unless expected.all? { |name, value| receipt[name] == value } && receipt["receipt_id"].to_s.match?(/\Avrc_[0-9a-f]{24}\z/)

      signer = Array(state["signing_public_keys"]).find { |item| item["key_id"] == receipt["signing_key_id"] }
      signature = Base64.strict_decode64(receipt.fetch("signature"))
      valid = signer && Reach::Crypto.verify_pss(Reach::Crypto.load_public_key(signer.fetch("pem")), signature, Reach::Crypto.canonical_json(receipt.reject { |name, _| name == "signature" }))
      raise Reach::VerificationFailed, BLOCKED unless valid && fresh?(state)

      receipt
    rescue KeyError, ArgumentError, TypeError, OpenSSL::OpenSSLError
      raise Reach::VerificationFailed, BLOCKED
    end

    def enrollment_key!(course_code:, teach_url:, harness:)
      raise Reach::Refused, BLOCKED if ENV["REACH_VALIDATION_DISABLE"] == "1"
      state = read
      label = if harness == "cli"
                begin
                  self.harness
                rescue Reach::Refused
                  self.harness(state.is_a?(Hash) ? state["harness"] : nil)
                end
              else
                self.harness(harness)
              end
      parsed = Reach::Identity.parse_course_code(course_code)
      raise Reach::Refused, BLOCKED unless parsed && teach_url.to_s.sub(%r{/+\z}, "") == configured_url && fresh?(state, course_code: parsed["code"], harness: label) && state["phase"] == "passed"

      verify_receipt!(state, state["receipt"])
      [key(state), state["receipt"]["receipt_id"], state["session_id"]]
    end

    def consumed!
      state = read
      write(state.merge("phase" => "consumed")) if state
    end

    def shell_command?(text)
      segments = Reach::Gate.shell_segments(text)
      return false unless segments.length == 1

      segment, before, after = segments.first
      return false if before || after

      parsed = Reach::Gate.parse_segment(segment)
      return false unless parsed[:ins].empty? && parsed[:outs].empty? && parsed[:words].none?(&:dynamic)

      tokens = parsed[:words].map(&:text)
      index = Reach::Gate.shim_index(tokens)
      !index.nil? && tokens[index + 1] == "validate"
    rescue StandardError
      false
    end

    def worker(state, action, text = nil)
      root = File.dirname(workspace(state))
      env = { "REACH_HOME" => File.join(root, "home"), "REACH_WORKSPACE_ROOT" => File.join(root, "work"), "REACH_PERSONA" => nil }
      script = 'require "reach"; Reach::Validation.work(ARGV.fetch(0), ARGV.fetch(1), STDIN.read)'
      output = nil
      Open3.popen3(env, RbConfig.ruby, "-I", File.expand_path("..", __dir__), "-e", script, action, workspace(state)) do |input, stdout, stderr, waiter|
        input.write(text.to_s)
        input.close
        out_reader = Thread.new { stdout.read(MAX_INPUT) }
        err_reader = Thread.new { stderr.read(MAX_INPUT) }
        begin
          Timeout.timeout(45) { output = [out_reader.value, err_reader.value, waiter.value] }
        rescue Timeout::Error
          Process.kill("KILL", waiter.pid) rescue nil
          raise
        ensure
          stdout.close unless stdout.closed?
          stderr.close unless stderr.closed?
          out_reader.join
          err_reader.join
        end
      end
      raise Reach::Refused, "reach: validation #{action} did not pass; correct the practice files and retry" unless output[2].success?

      output[0]
    end

    def work(action, workspace, text)
      if action == "plan"
        Reach::Plan.save(workspace, "behaviour" => text)
      elsif action == "check"
        findings = Reach::Check.run(workspace, format: :agent)
        raise Reach::Refused, JSON.generate(findings) unless findings.empty?

        Reach::Checkpoint.save(workspace, note: "synthetic security validation")
      else
        raise Reach::Refused, BLOCKED
      end
      puts JSON.generate("passed" => true)
    end
  end
end
