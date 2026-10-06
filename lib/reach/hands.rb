require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Hands
    ROUTE = "/api/v1/hands"
    POLL_INTERVAL_S = 60
    SUPPORT_AUTHORS = %w[service-desk teach-issues].freeze
    BUNDLE_LIMIT = 196_608
    OUTPUT_LIMIT = 65_536
    FILE_CUT = 32_768
    ATTEMPT_GATE = "attempt_gate".freeze
    ATTEMPT_LADDER = "attempt_ladder".freeze
    CHECK_GATE = "check_gate".freeze
    WELLBEING = "wellbeing".freeze
    STUDENT_REQUEST = "student_request".freeze
    LATE_WORK = "late_work".freeze
    LATE_SUBMISSION = "late_submission".freeze
    AGENT_TYPES = %w[
      student_request concept_question assignment_question deadline_question grade_question submission_question
      technical_issue setup_issue access_issue extension_request feedback integrity_question other
    ].freeze
    NEWER_TYPES = ([LATE_WORK, LATE_SUBMISSION] + AGENT_TYPES - [STUDENT_REQUEST]).freeze
    TYPES = ([ATTEMPT_GATE, ATTEMPT_LADDER, CHECK_GATE, WELLBEING, LATE_WORK, LATE_SUBMISSION] + AGENT_TYPES).freeze
    SUMMARY_LIMIT = 2000
    TECHNICAL_TYPES = %w[technical_issue setup_issue access_issue].freeze
    FIELD_LIMIT = 1000
    LEFT_OUT = "[left out]".freeze
    SECRET_LABEL = /(\b(?:password|passkey|passcode|pwd)\b\s*(?:\bis\b\s*)?[:=]?\s*)(["'`]?)([^\s"'`]+)\2/i.freeze
    CODE_WORD = /[A-Za-z0-9]+/.freeze
    CODE_WINDOW_MAX = 3

    class << self
      def raise_hand(trigger:, summary:, slice:, include_profile: false, originator: "student", details: {}, last_step: nil, saw: nil)
        record = raise_record(trigger: trigger, summary: summary, slice: slice, include_profile: include_profile,
                              originator: originator, details: details, last_step: last_step, saw: saw)
        refused = record["refused"]
        raise Reach::Refused, refused_text(refused["message"]) if refused

        record["hand_id"]
      end

      def contact_text
        contact = Reach::CourseProfile.support_contact
        contact ? Reach::Messages.text("M-HAND-CONTACT", contact_text: contact) : ""
      end

      def refused_text(reason)
        Reach::Messages.text("M-HAND-REFUSED", reason: reason, contact: contact_text)
      end

      def queued_text
        Reach::Messages.text("M-HAND-QUEUED", contact: contact_text)
      end

      def sent_text(hand_id)
        Reach::Messages.text("M-HAND-SENT", hand_id: hand_id)
      end

      def validate_type!(type)
        return type.to_s if TYPES.include?(type.to_s)

        raise Reach::Refused, Reach::Messages.text("M-HAND-TYPE-UNKNOWN", type: type.to_s, types: AGENT_TYPES.join(", "))
      end

      def wire_type(type, summary)
        type = validate_type!(type)
        return [type, summary.to_s] unless NEWER_TYPES.include?(type)
        return [type, summary.to_s] if Reach::Compat.accepts_trigger?(type)

        [STUDENT_REQUEST, "[#{type}] #{summary}"]
      end

      def raise_record(trigger:, summary:, slice:, include_profile: false, originator: "student", details: {}, last_step: nil, saw: nil)
        details = (details || {}).merge("technical" => TECHNICAL_TYPES.include?(trigger.to_s),
                                        "last_step" => last_step, "saw" => saw)
        trigger, summary = wire_type(trigger, summary)
        workspace = resolve_workspace(slice)
        meta = Reach::Workspace.metadata(workspace)
        install = Reach::Enroll.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

        bundle = build_bundle(workspace, meta, trigger, summary, include_profile, originator, details || {})
        tar_bytes = Reach::Tarball.write("bundle.json" => JSON.generate(bundle))
        envelope = seal_hand(install, meta, tar_bytes)
        idempotency_key = SecureRandom.uuid
        body = {
          "cutout_id" => meta["cutout_id"],
          "slice" => meta["slice"],
          "trigger" => trigger.to_s,
          "originator" => originator.to_s,
          "summary" => truncate_summary(scrub(summary.to_s, install)),
          "bundle" => envelope
        }
        outbox_path = write_outbox(idempotency_key, ROUTE, body, File.basename(workspace), bundle["hand_ref"])
        record = { "hand_id" => nil, "hand_ref" => bundle["hand_ref"], "created_at" => bundle["created_at"], "queued" => false }

        begin
          response = client(install).post_json(ROUTE, body, idempotency_key: idempotency_key)
          result = response.json || {}
          FileUtils.rm_f(outbox_path)
          track(result["hand_id"], slice: File.basename(workspace), hand_ref: bundle["hand_ref"], originator: originator) if result["hand_id"]
          record.merge("hand_id" => result["hand_id"])
        rescue Reach::RemoteRefused => e
          FileUtils.rm_f(outbox_path)
          record.merge("refused" => { "code" => e.code.to_s, "status" => e.status.to_i, "message" => e.message.to_s })
        rescue Reach::Offline, Reach::NetworkError
          record.merge("queued" => true)
        end
      end

      def raise_wellbeing(harness:, space:, queue_only: false)
        install = Reach::Enroll.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

        workspace = Reach::Gate.focus_workspace
        meta = workspace ? Reach::Workspace.metadata(workspace) : {}
        slice_kind = %w[backend panel verification].include?(meta["slice"]) ? meta["slice"] : nil
        cutout_id = slice_kind ? meta["cutout_id"] : nil
        space_kind = space.is_a?(Hash) ? space["kind"] : space
        space_kind = "outside" if space_kind.to_s.empty?
        raised_at = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        hand_ref = SecureRandom.uuid
        bundle = {
          "schema" => "reach.hand.wellbeing/v1",
          "student_id" => install["student_id"],
          "raised_at" => raised_at,
          "harness" => harness.to_s,
          "space" => space_kind
        }
        tar_bytes = Reach::Tarball.write("bundle.json" => JSON.generate(bundle))
        seal_meta = {
          "course" => meta["course"] || (install["course"].is_a?(Hash) ? install["course"]["id"] : nil),
          "assignment" => meta["assignment"]
        }
        envelope = seal_hand(install, seal_meta, tar_bytes)
        idempotency_key = SecureRandom.uuid
        body = {
          "cutout_id" => cutout_id,
          "slice" => slice_kind,
          "trigger" => WELLBEING,
          "originator" => "agent",
          "summary" => "The student may need support.",
          "bundle" => envelope
        }
        slice_name = workspace && slice_kind ? File.basename(workspace) : nil
        outbox_path = write_outbox(idempotency_key, ROUTE, body, slice_name, hand_ref)
        return :queued if queue_only

        begin
          response = client(install).post_json(ROUTE, body, idempotency_key: idempotency_key)
          result = response.json || {}
          FileUtils.rm_f(outbox_path)
          track(result["hand_id"], slice: slice_name, hand_ref: hand_ref, originator: "agent") if result["hand_id"]
          :sent
        rescue Reach::RemoteRefused => e
          FileUtils.rm_f(outbox_path)
          Reach::Debug.fault(e, "support:wellbeing")
          :refused
        rescue Reach::Offline, Reach::NetworkError
          :queued
        end
      end

      def track(hand_id, slice: nil, hand_ref: nil, originator: "student")
        return if hand_id.nil?

        state = open_hands
        state[hand_id] = { "reply" => nil, "polled_at" => nil, "slice" => slice, "hand_ref" => hand_ref, "originator" => originator }
        write_open_hands(state)
        attach_ladder(hand_ref, hand_id)
      end

      def status(hand_id)
        install = Reach::Enroll.current
        return { state: "unknown", reply: nil } unless install

        response = client(install).get("/api/v1/hands/#{hand_id}")
        body = response.json || {}
        Reach::Issues.record_status(hand_id, body) if body["fix_version"]
        { state: body["state"], reply: body["reply"] }
      rescue Reach::NetworkError, Reach::Offline
        { state: "unknown", reply: nil }
      end

      def list
        open_hands.map do |hand_id, record|
          record = record.is_a?(Hash) ? record : { "reply" => record }
          { hand_id: hand_id, reply: record["reply"], slice: record["slice"], originator: record["originator"] || "student" }
        end
      end

      def reply_from(reply)
        author = reply.is_a?(Hash) ? reply["answered_by"].to_s : ""
        SUPPORT_AUTHORS.include?(author) ? "technical_support" : "instructor"
      end

      def poll_replies
        changed = []
        state = open_hands
        state.each do |hand_id, record|
          record = record.is_a?(Hash) ? record : { "reply" => record, "polled_at" => nil }
          next if record["polled_at"] && (Time.now.utc - Time.parse(record["polled_at"])) < POLL_INTERVAL_S

          begin
            current = status(hand_id)
          rescue Reach::RemoteRefused => e
            remove_open_hand(hand_id) if e.status.to_i == 404
            next
          end
          update_open_hand(hand_id, current[:reply], Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
          if current[:reply] && current[:reply] != record["reply"] && record["originator"] != "reach"
            changed << { hand_id: hand_id, state: current[:state], reply: current[:reply], from: reply_from(current[:reply]) }
            Reach::Ladder.reset_for_hand(hand_id)
          end
          remove_open_hand(hand_id) if %w[resolved closed].include?(current[:state].to_s)
        end
        changed
      end

      def build_bundle(workspace, meta, trigger, summary, include_profile, originator, details)
        files = {}
        Array(meta["owned_files"]).each do |relative_path|
          full_path = File.join(workspace, relative_path)
          files[relative_path] = File.file?(full_path) ? File.read(full_path) : nil
        end

        profile = nil
        if include_profile && defined?(Reach::Profile)
          begin
            profile = Reach::Profile.load["fields"]
          rescue StandardError
            profile = nil
          end
        end

        plan = Reach::Plan.load(workspace)
        qualification = details["qualification"] || Reach::Qualify.read_record(workspace)
        ladder = Reach::Ladder.state(workspace)
        bundle = {
          "schema" => "reach.hand/v2",
          "hand_ref" => SecureRandom.uuid,
          "originator" => originator.to_s,
          "trigger" => trigger.to_s,
          "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "course" => meta["course"],
          "assignment" => meta["assignment"],
          "module" => meta["module"],
          "cutout_id" => meta["cutout_id"],
          "slice" => meta["slice"],
          "task" => {
            "behaviour" => (plan && plan["behaviour"]) || meta["behavior"],
            "plan_step" => plan && plan["next"],
            "description" => cut(details["task"] || summary.to_s, 2000)
          },
          "attempts" => {
            "count" => ladder["failed"].to_i,
            "notice_from" => Reach::Ladder::NOTICE_FROM,
            "hand_at" => Reach::Ladder::HAND_AT,
            "hard_stop" => Reach::Ladder::HARD_STOP,
            "history" => Array(details["history"] || ladder["history"])
          },
          "code" => files,
          "tests" => Reach::Qualify.test_files(workspace).map { |relative, data| [relative, data.dup.force_encoding(Encoding::UTF_8).scrub] }.to_h,
          "last_output" => last_output(qualification),
          "agent_summary" => cut(details["agent_summary"] || summary.to_s, 4000),
          "last_step_ok" => field_text(details["last_step"]),
          "student_saw" => field_text(details["saw"]),
          "student_last_request" => nil,
          "environment" => {
            "reach_version" => Reach::VERSION,
            "ruby_version" => RUBY_VERSION,
            "platform" => RUBY_PLATFORM,
            "harness" => Reach::Ledger.last_harness(workspace) || ENV["REACH_HARNESS"],
            "model" => ENV["REACH_MODEL"]
          },
          "contract_version" => contract_version(workspace),
          "suite_version" => qualification && qualification["suite_version"],
          "plan" => plan,
          "profile" => profile
        }
        if details["technical"] == true
          bundle["capsule"] = Reach::Capsule.build
          bundle["signature_hint"] = Reach::Issues.recent_signature
        end
        fit(redact_bundle(bundle, Reach::Enroll.current))
      end

      def scrub(text, install = Reach::Enroll.current)
        value = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        value = value.gsub(SECRET_LABEL) { "#{Regexp.last_match(1)}#{LEFT_OUT}" }
        value = scrub_codes(value)
        known_secrets(install).each do |secret|
          value = value.gsub(/(?<![A-Za-z0-9])#{Regexp.escape(secret)}(?![A-Za-z0-9])/, LEFT_OUT)
        end
        value
      end

      def seal_bundle(install, meta, tar_bytes)
        seal_hand(install, meta, tar_bytes)
      end

      private

      def field_text(value)
        return nil if value.nil?

        text = cut(value.to_s.strip, FIELD_LIMIT)
        text.empty? ? nil : text
      end

      def known_secrets(install)
        list = []
        list << install["student_id"].to_s.strip if install.is_a?(Hash)
        list.reject { |secret| secret.empty? }.uniq
      end

      def scrub_codes(text)
        spans = text.to_enum(:scan, CODE_WORD).map { Regexp.last_match.then { |m| [m.begin(0), m.end(0)] } }
        covered = []
        index = 0
        while index < spans.length
          hit = nil
          CODE_WINDOW_MAX.downto(1) do |count|
            last = spans[index + count - 1]
            next unless last

            hit = [index, index + count - 1] if Reach::Identity.parse_course_code(text[spans[index][0]...last[1]])
            break if hit
          end
          if hit
            first, last = hit
            first += 1 while first < last && Reach::Identity.parse_course_code(text[spans[first + 1][0]...spans[last][1]])
            last -= 1 while first < last && Reach::Identity.parse_course_code(text[spans[first][0]...spans[last - 1][1]])
            covered << [spans[first][0], spans[last][1]]
            index = last + 1
          else
            index += 1
          end
        end
        result = text.dup
        covered.reverse_each { |from, upto| result[from...upto] = LEFT_OUT }
        result
      end

      def redact_bundle(bundle, install)
        bundle["task"]["description"] = scrub(bundle["task"]["description"], install) if bundle["task"].is_a?(Hash) && bundle["task"]["description"]
        %w[agent_summary last_step_ok student_saw].each do |key|
          bundle[key] = scrub(bundle[key], install) unless bundle[key].nil?
        end
        bundle["last_output"] = scrub_tree(bundle["last_output"], install)
        attempts = bundle["attempts"]
        attempts["history"] = scrub_tree(attempts["history"], install) if attempts.is_a?(Hash)
        bundle
      end

      def scrub_tree(value, install)
        case value
        when String then scrub(value, install)
        when Array then value.map { |item| scrub_tree(item, install) }
        when Hash then value.transform_values { |item| scrub_tree(item, install) }
        else value
        end
      end

      def attach_ladder(hand_ref, hand_id)
        return if hand_ref.nil?

        Reach::Workspace.current_slices.each do |workspace|
          state = Reach::Ladder.state(workspace)
          Reach::Ladder.save(workspace, state.merge("hand_id" => hand_id)) if state["hand_ref"] == hand_ref && state["hand_id"].nil?
        end
      rescue StandardError
        nil
      end

      def resolve_workspace(slice)
        return slice if slice.is_a?(String) && File.directory?(File.join(slice, ".reach"))

        slices = Reach::Workspace.current_slices
        match = slices.find { |path| File.basename(path) == slice.to_s }
        suffixed = slices.select { |path| File.basename(path).end_with?("-#{slice}") }
        match ||= suffixed.first if suffixed.size == 1
        raise Reach::Refused, "reach: no workspace found for slice #{slice.inspect}" unless match

        match
      end

      def cut(text, limit)
        value = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        return value if value.bytesize <= limit

        result = +""
        value.each_char do |char|
          break if result.bytesize + char.bytesize > limit - 5

          result << char
        end
        "#{result}[cut]"
      end

      def last_output(qualification)
        return nil unless qualification.is_a?(Hash)

        steps = qualification["steps"].is_a?(Hash) ? qualification["steps"] : {}
        remote = steps["remote"].is_a?(Hash) ? steps["remote"]["rows"] : nil
        remote = {} unless remote.is_a?(Hash)
        local = Array(qualification["findings"]).map do |finding|
          [finding["code"], finding["name"], finding["step"], finding["detail"]].compact.map(&:to_s).reject(&:empty?).join(" | ")
        end
        output = Reach::Utf8.clean({ "local" => local, "agent" => remote["agent"], "stub" => remote["stub"], "hidden" => remote["hidden"] })
        return output if JSON.generate(output).bytesize <= OUTPUT_LIMIT

        { "local" => local.first(50).map { |line| cut(line, 500) }, "agent" => nil, "stub" => nil, "hidden" => nil }
      end

      def contract_version(workspace)
        path = File.join(workspace, "api", "slice-api.json")
        return nil unless File.file?(path)

        JSON.parse(File.read(path))["contract_version"]
      rescue StandardError
        nil
      end

      def fit(bundle)
        bundle = Reach::Utf8.clean(bundle)
        return bundle if JSON.generate(bundle).bytesize <= BUNDLE_LIMIT

        bundle["last_output"] = nil
        return bundle if JSON.generate(bundle).bytesize <= BUNDLE_LIMIT

        %w[code tests].each do |key|
          bundle[key] = bundle[key].map { |path, text| [path, text.nil? ? nil : cut(text, FILE_CUT)] }.to_h
        end
        bundle
      end

      def truncate_summary(text)
        bytes = text.dup.force_encoding(Encoding::UTF_8)
        return bytes if bytes.bytesize <= SUMMARY_LIMIT

        result = +""
        bytes.each_char do |char|
          break if (result.bytesize + char.bytesize) > SUMMARY_LIMIT

          result << char
        end
        result
      end

      def seal_hand(install, meta, tar_bytes)
        encryption_key = install.fetch("encryption_key")
        header = {
          "schema" => "teach.package/v1",
          "kind" => "hand_bundle",
          "id" => "renv_#{SecureRandom.hex(10)}",
          "version" => 1,
          "course" => meta["course"],
          "assignment" => meta["assignment"],
          "student_id" => install["student_id"],
          "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "signing_key_id" => install["install_id"],
          "recipient_key_id" => encryption_key["key_id"]
        }
        Reach::Crypto.seal(
          header: header,
          plaintext: tar_bytes,
          recipient_public_key: Reach::Crypto.load_public_key(encryption_key["pem"]),
          signer_private_key: Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
        )
      end

      def write_outbox(idempotency_key, route, body, slice, hand_ref)
        FileUtils.mkdir_p(Reach::Paths.outbox_dir)
        path = File.join(Reach::Paths.outbox_dir, "#{idempotency_key}.json")
        File.write(path, JSON.generate("kind" => "hand", "route" => route, "idempotency_key" => idempotency_key,
                                       "body" => body, "slice" => slice, "hand_ref" => hand_ref))
        path
      end

      def client(install)
        Reach::Client.for_install(install)
      end

      def open_hands_file
        File.join(Reach::Paths.home, "hands", "open.json")
      end

      def open_hands
        return {} unless File.file?(open_hands_file)

        JSON.parse(File.read(open_hands_file))
      rescue JSON::ParserError
        {}
      end

      def update_open_hand(hand_id, reply, polled_at)
        state = open_hands
        previous = state[hand_id].is_a?(Hash) ? state[hand_id] : {}
        state[hand_id] = previous.merge("reply" => reply, "polled_at" => polled_at)
        write_open_hands(state)
      end

      def remove_open_hand(hand_id)
        state = open_hands
        state.delete(hand_id)
        write_open_hands(state)
      end

      def write_open_hands(state)
        FileUtils.mkdir_p(File.dirname(open_hands_file))
        File.write(open_hands_file, JSON.generate(state))
      end
    end
  end
end
