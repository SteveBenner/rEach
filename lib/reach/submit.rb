require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Submit
    ROUTE = "/api/v1/submissions"
    DELIVERED_STATES = %w[grading graded grade_failed validated orphaned awaiting_grade].freeze
    UPLOAD_READ_TIMEOUT_S = 120
    POLL_READ_TIMEOUT_S = 10
    POLL_WAITS_S = [3, 6, 12].freeze

    class << self
      def submit(slice:, partial: false)
        Reach::BehaviorPolicy.ensure!
        Reach::Login.require_active!
        Reach::HookLiveness.require_hooks!
        workspace = resolve_workspace(slice)
        meta = Reach::Workspace.metadata(workspace)
        document = Reach::DocumentFiles.document_meta?(meta)
        if document
          run_document_preconditions(workspace, meta, partial: partial)
          qualification = nil
        elsif partial
          raise Reach::Refused, Reach::Messages.text("M-SUBMIT-PARTIAL-UNSUPPORTED") unless Reach::Compat.accepts_partial?

          run_partial_preconditions(workspace)
          qualification = Reach::Qualify.read_record(workspace)
        else
          run_preconditions(workspace)
          qualification = Reach::Qualify.current?(workspace)
          raise Reach::Refused, Reach::Messages.text("M-SUBMIT-UNQUALIFIED") unless qualification
        end

        require_part!(meta["assignment"]) unless partial
        install = Reach::Enroll.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

        Reach::Controls.check_submit!
        pending = approve!(workspace, meta, partial: partial)
        if pending
          Reach::Debug.submit("state" => pending["state"])
          return pending
        end

        flush_transcript(meta["assignment"])
        manifest = build_manifest(workspace, meta)
        manifest = manifest.merge("partial" => true) if partial
        tail = Reach::Ledger.tail_text(workspace)
        Reach::Ledger.append(workspace, "submit", "manifest_digest" => Reach::Crypto.digest_hex(JSON.generate(manifest)))
        tar_bytes = Reach::Tarball.write(submission_entries(manifest, workspace, tail, qualification, meta["assignment"], document: document))
        if document && Reach::DocumentFiles.encoded_too_large?(tar_bytes.bytesize)
          raise Reach::Refused, Reach::Messages.text("M-SUBMIT-DOC-BODY", limit_mb: Reach::DocumentFiles::BODY_LIMIT_BYTES / (1024 * 1024))
        end
        envelope = seal_submission(install, meta, tar_bytes)
        idempotency_key = SecureRandom.uuid
        body = {
          "cutout_id" => meta["cutout_id"],
          "slice" => meta["slice"],
          "assignment" => meta["assignment"],
          "package" => envelope,
          "client_created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
        body["partial"] = true if partial
        outbox_path = write_outbox(idempotency_key, "submission", ROUTE, body, workspace: workspace, external: document)
        supersede_queued(outbox_path, body)

        begin
          answer = document ? upload_document(install, body, idempotency_key) : client(install).post_json(ROUTE, body, idempotency_key: idempotency_key).json
          result = handle_response(answer || {})
          result = result.merge("archive" => Reach::Archive.write!(workspace, meta)) if result["state"] == "ingested"
          result = result.merge("text" => student_text(result)) if result["state"] == "ingested"
          result = result.merge("text" => rejection_text(result["rejection"], workspace)) if result["state"] == "rejected"
          drop_outbox(outbox_path) unless result["state"] == "queued"
          Reach::Debug.submit(result)
          result
        rescue Reach::RemoteRefused => e
          drop_outbox(outbox_path)
          Reach::Debug.submit("state" => "rejected", "rejection" => { "code" => e.code })
          rejection = { "code" => e.code, "reason" => e.message }
          { "submission_id" => nil, "state" => "rejected", "receipt" => nil, "rejection" => rejection, "text" => rejection_text(rejection, workspace) }
        rescue Reach::Offline, Reach::NetworkError
          Reach::Debug.submit("state" => "queued")
          { "submission_id" => nil, "state" => "queued", "receipt" => nil, "rejection" => nil }
        end
      end

      def upload_document(install, body, idempotency_key)
        Reach::Client.for_install(install, read_timeout: UPLOAD_READ_TIMEOUT_S, max_retries: 0).post_json(ROUTE, body, idempotency_key: idempotency_key).json
      rescue Reach::Offline
        raise
      rescue Reach::NetworkError
        answer = poll_submission(install, idempotency_key)
        raise unless answer

        answer
      end

      def poll_submission(install, idempotency_key)
        POLL_WAITS_S.each do |wait|
          sleep(wait)
          begin
            probe = Reach::Client.for_install(install, read_timeout: POLL_READ_TIMEOUT_S, max_retries: 0)
            return probe.get(ROUTE, query: { "idempotency_key" => idempotency_key }).json || {}
          rescue Reach::RemoteRefused => e
            raise unless e.code == "not_found"
          rescue Reach::NetworkError
            next
          end
        end
        nil
      end

      def archive_again(assignment: nil)
        submitted = submitted_assignments
        available = (submitted + workspace_assignments).uniq.sort
        name = assignment.to_s.strip
        name = default_archive_assignment(available) if name.empty?
        if name.empty?
          raise Reach::Refused, Reach::Messages.text("M-SUBMIT-ARCHIVE-NONE", assignment: "this course") if available.empty?

          raise Reach::Refused, Reach::Messages.text("M-SUBMIT-ARCHIVE-WHICH", assignments: available.join(", "))
        end
        raise Reach::Refused, Reach::Messages.text("M-SUBMIT-ARCHIVE-NONE", assignment: name) unless available.include?(name)

        workspace = archive_workspace(name)
        archive = workspace ? Reach::Archive.write!(workspace, Reach::Workspace.metadata(workspace)) : { "state" => "failed" }
        result = { "state" => "archive", "assignment" => name, "archive" => archive, "receipt" => { "assignment" => name },
                   "submitted" => submitted.include?(name) }
        result["text"] = submitted.include?(name) ? followup_text(result) : export_text(result)
        result
      end

      def archive_scope(scope, course: nil)
        scope = scope.to_s
        raise Reach::Error, "reach: unknown archive scope" unless Reach::Archive::SCOPES.include?(scope)

        if scope == "course"
          names = Reach::Archive.course_names
          unless names.include?(course.to_s)
            raise Reach::Refused, Reach::Messages.text("M-SUBMIT-ARCHIVE-NOCOURSE", course: course.to_s, courses: names.empty? ? "none" : names.join(", "))
          end
        end

        archive = Reach::Archive.write_scope!(scope, course: course)
        result = { "state" => "archive", "scope" => scope, "course" => scope == "course" ? course.to_s : nil, "archive" => archive, "submitted" => false }
        result["text"] = scope_text(result)
        result
      end

      def scope_text(result)
        archive = result["archive"].is_a?(Hash) ? result["archive"] : {}
        scope = result["scope"]
        case archive["state"]
        when "saved"
          id = { "all" => "M-SUBMIT-EXPORTED-ALL", "course" => "M-SUBMIT-EXPORTED-COURSE" }.fetch(scope, "M-SUBMIT-EXPORTED-EXTRA")
          Reach::Messages.text(id, course: result["course"], name: archive["name"])
        when "skipped"
          limit = scope == "all" ? Reach::Archive.all_max_mb : Reach::Archive.max_mb
          max = limit == limit.to_i ? limit.to_i : limit
          Reach::Messages.text(scope == "all" ? "M-SUBMIT-EXPORT-TOO-LARGE-ALL" : "M-SUBMIT-EXPORT-TOO-LARGE", max: max)
        when "empty"
          Reach::Messages.text("M-SUBMIT-EXPORT-EMPTY")
        else
          Reach::Messages.text("M-SUBMIT-EXPORT-FAILED", send: export_send)
        end
      end

      def retry_outbox
        results = []
        queued_in_order.each do |path, entry|
          next if entry["issue"]

          install = Reach::Enroll.current
          next unless install

          if entry["kind"] == "submission"
            begin
              Reach::Controls.check_submit!
            rescue Reach::Error
              next
            end
          end

          begin
            body = if entry["body_file"]
                     upload_document(install, outbox_body(entry), entry.fetch("idempotency_key")) || {}
                   else
                     client(install).post_json(entry.fetch("route"), entry.fetch("body"), idempotency_key: entry.fetch("idempotency_key")).json || {}
                   end
            if entry["kind"] == "submission"
              results << settle_submission(path, entry, body)
              next
            elsif entry["kind"] == "integrity"
              results << { "state" => "sent", "event_id" => body["event_id"] }
            else
              Reach::Hands.track(body["hand_id"], slice: entry["slice"], hand_ref: entry["hand_ref"], originator: entry.dig("body", "originator") || "student")
              results << { "hand_id" => body["hand_id"], "state" => body["state"] }
            end
            drop_outbox(path)
          rescue Reach::RemoteRefused => e
            if entry["kind"] == "submission"
              shelve_rejected(path, entry, "code" => e.code, "reason" => e.message, "status" => e.status)
            else
              drop_outbox(path)
            end
            results << { "state" => "rejected", "rejection" => { "code" => e.code, "reason" => e.message } }
          rescue Reach::Offline, Reach::NetworkError
            next
          end
        end
        results
      end

      def rejected_notices
        notices = []
        Dir.glob(File.join(rejected_dir, "*.json")).sort.each do |path|
          entry = begin
            JSON.parse(File.read(path))
          rescue StandardError
            next
          end
          next unless entry.is_a?(Hash) && !entry["reported"]

          body = entry["body"].is_a?(Hash) ? entry["body"] : {}
          rejection = entry["rejection"].is_a?(Hash) ? entry["rejection"] : {}
          reason = rejection["reason"].to_s.strip.empty? ? rejection["code"] : rejection["reason"]
          notices << if entry["disagreement"].is_a?(Hash)
                       Reach::Messages.text(
                         "M-SUBMIT-REJECTED-LATER-DISAGREE",
                         slice: body["slice"], cutout: body["cutout_id"], reason: reason, disagree: disagreement_text(entry["disagreement"])
                       )
                     else
                       Reach::Messages.text("M-SUBMIT-REJECTED-LATER", slice: body["slice"], cutout: body["cutout_id"], reason: reason)
                     end
          write_json_atomic(path, entry.merge("reported" => true))
        end
        notices
      rescue StandardError
        []
      end

      def rejection_text(rejection, workspace)
        rejection = rejection.is_a?(Hash) ? rejection : {}
        disagreement = qualification_disagreement(rejection["code"], workspace)
        code = rejection["code"].to_s == "too_large" && Reach::DocumentFiles.document?(workspace) ? "too_large_document" : rejection["code"]
        fix = disagreement ? disagreement_text(disagreement) : Reach::Messages.rejection_fix(code)
        Reach::Messages.text("M-SUBMIT-REJECTED", reason: rejection["reason"], fix: fix)
      end

      def student_text(result)
        receipt = result["receipt"].is_a?(Hash) ? result["receipt"] : {}
        received_id = receipt["partial"] == true ? "M-SUBMIT-PARTIAL-RECEIVED" : "M-SUBMIT-RECEIVED"
        received_id = "M-SUBMIT-DOC-RECEIVED" if receipt["slice"] == Reach::DocumentFiles::SLICE
        received = Reach::Messages.text(
          received_id,
          slice: receipt["slice"], cutout: receipt["cutout_id"], assignment: receipt["assignment"], time: Reach::Messages.course_time(receipt["received_at"])
        )
        received = [received, Reach::Receipts.reference_text(receipt)].reject { |text| text.empty? }.join(" ")
        rest = followup_text(result).lines.map(&:chomp).reject(&:empty?)
        ["#{received} #{rest.shift}".strip, *rest].join("\n")
      end

      def followup_text(result)
        lines = []
        archive = result["archive"].is_a?(Hash) ? result["archive"] : nil
        document = result["receipt"].is_a?(Hash) && result["receipt"]["slice"] == Reach::DocumentFiles::SLICE
        if archive
          case archive["state"]
          when "saved"
            lines << Reach::Messages.text("M-SUBMIT-ARCHIVED", assignment: archive_assignment(result), name: archive["name"], credit: document ? "" : Reach::Archive.credit("M-LMS-UPLOAD-ZIP"))
          when "skipped"
            lines << Reach::Messages.text("M-SUBMIT-ARCHIVE-SKIPPED", credit: document ? "" : Reach::Archive.credit("M-LMS-UPLOAD-WORK"))
          else
            lines << Reach::Messages.text("M-SUBMIT-ARCHIVE-FAILED", credit: document ? "" : Reach::Archive.credit("M-LMS-UPLOAD-WORK"))
          end
        end
        due = result["due"].to_s.empty? ? nil : Reach::Messages.course_time(result["due"])
        case result["resubmit"]
        when "open"
          lines << (due && !due.empty? ? Reach::Messages.text("M-SUBMIT-AGAIN-OPEN", attempt: result["attempt"], due: due) : Reach::Messages.text("M-SUBMIT-AGAIN-OPEN-NODUE", attempt: result["attempt"]))
        when "closed"
          lines << Reach::Messages.text("M-SUBMIT-AGAIN-CLOSED")
        end
        lines.join("\n")
      end

      private

      def rejected_dir
        File.join(Reach::Paths.outbox_dir, "rejected")
      end

      def queued_in_order
        rows = Dir.glob(File.join(Reach::Paths.outbox_dir, "*.json")).map do |path|
          entry = begin
            JSON.parse(File.read(path))
          rescue StandardError
            nil
          end
          next unless entry.is_a?(Hash)

          [path, entry, queued_time(path, entry)]
        end
        rows.compact.sort_by { |path, _entry, time| [time, path] }.map { |path, entry, _time| [path, entry] }
      end

      def queued_time(path, entry)
        stamp = entry["queued_at"].to_s
        return Time.parse(stamp) unless stamp.empty?

        File.mtime(path)
      rescue ArgumentError, SystemCallError
        Time.at(0)
      end

      def supersede_queued(keep_path, body)
        key = [body["cutout_id"], body["slice"], body["assignment"]]
        Dir.glob(File.join(Reach::Paths.outbox_dir, "*.json")).each do |path|
          next if path == keep_path

          entry = begin
            JSON.parse(File.read(path))
          rescue StandardError
            next
          end
          next unless entry.is_a?(Hash) && entry["kind"] == "submission" && entry["body"].is_a?(Hash)

          other = [entry["body"]["cutout_id"], entry["body"]["slice"], entry["body"]["assignment"]]
          drop_outbox(path) if other == key
        end
      end

      def outbox_companion(path)
        path.sub(/\.json\z/, ".body")
      end

      def drop_outbox(path)
        FileUtils.rm_f(outbox_companion(path))
        FileUtils.rm_f(path)
      end

      def outbox_body(entry)
        JSON.parse(File.read(File.join(Reach::Paths.outbox_dir, entry.fetch("body_file"))))
      end

      def settle_submission(path, entry, body)
        handled = handle_response(body)
        case handled["state"]
        when "queued"
          handled
        when "rejected"
          shelve_rejected(path, entry, handled["rejection"])
          handled
        else
          handled = handled.merge("archive" => archive_for_outbox(entry["workspace"])) if handled["state"] == "ingested" && entry["workspace"]
          handled = handled.merge("text" => student_text(handled)) if handled["state"] == "ingested"
          drop_outbox(path)
          handled
        end
      end

      def shelve_rejected(path, entry, rejection)
        FileUtils.mkdir_p(rejected_dir)
        record = entry.merge(
          "rejection" => rejection,
          "rejected_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "reported" => false
        )
        disagreement = qualification_disagreement(rejection["code"], entry["workspace"])
        record["disagreement"] = disagreement if disagreement
        write_json_atomic(File.join(rejected_dir, File.basename(path)), record)
        drop_outbox(path)
      end

      def qualification_disagreement(code, workspace)
        return nil unless code.to_s == "not_qualified" && workspace.is_a?(String) && File.directory?(workspace)

        record = Reach::Qualify.current?(workspace)
        return nil unless record && !record["qualification_id"].to_s.empty?

        rows = record.dig("steps", "remote", "rows")
        stub = rows.is_a?(Hash) ? Array(rows["stub"]) : []
        names = stub.select { |row| row.is_a?(Hash) && row["result"] == "passed" }.map { |row| row["name"] }.compact.uniq
        { "qualification_id" => record["qualification_id"], "scenarios" => names }
      rescue StandardError
        nil
      end

      def disagreement_text(disagreement)
        names = Array(disagreement["scenarios"]).map { |name| "\"#{name}\"" }
        scenarios = names.empty? ? "" : " #{Reach::Messages.text('M-SUBMIT-DISAGREE-SCENARIOS', names: names.join(', '))}"
        Reach::Messages.text("M-SUBMIT-DISAGREE", qualification: disagreement["qualification_id"], scenarios: scenarios)
      end

      def write_json_atomic(path, data)
        temp = "#{path}.tmp.#{Process.pid}"
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |handle|
          handle.write(JSON.generate(data))
          handle.flush
          handle.fsync
        end
        File.rename(temp, path)
      end

      def submitted_assignments
        Reach::Receipts.list.select { |receipt| receipt["kind"] == "ingest" }.map { |receipt| receipt["assignment"].to_s }.reject(&:empty?).uniq.sort
      end

      def workspace_assignments
        Reach::Workspace.current_slices.map { |path| Reach::Workspace.metadata(path)["assignment"].to_s }.reject(&:empty?).uniq.sort
      end

      def default_archive_assignment(candidates)
        workspace = Reach::Gate.focus_workspace
        here = workspace ? Reach::Workspace.metadata(workspace)["assignment"].to_s : ""
        return here if candidates.include?(here)

        candidates.length == 1 ? candidates.first : ""
      end

      def export_text(result)
        archive = result["archive"].is_a?(Hash) ? result["archive"] : {}
        case archive["state"]
        when "saved"
          Reach::Messages.text("M-SUBMIT-EXPORTED", assignment: result["assignment"], name: archive["name"], send: export_send)
        when "skipped"
          Reach::Messages.text("M-SUBMIT-EXPORT-SKIPPED", send: export_send)
        else
          Reach::Messages.text("M-SUBMIT-EXPORT-FAILED", send: export_send)
        end
      end

      def export_send
        lms = Reach::Archive.lms_name
        lms ? Reach::Messages.text("M-SUBMIT-EXPORT-SEND-LMS", lms: lms) : Reach::Messages.text("M-SUBMIT-EXPORT-SEND")
      end

      def archive_workspace(assignment)
        Reach::Workspace.current_slices.sort.find do |path|
          Reach::Workspace.metadata(path)["assignment"].to_s == assignment
        end
      end

      def archive_assignment(result)
        receipt = result["receipt"].is_a?(Hash) ? result["receipt"] : {}
        receipt["assignment"].to_s
      end

      def handle_response(body)
        state = body["state"]
        if state == "ingested" || DELIVERED_STATES.include?(state)
          receipt = body["receipt"]
          Reach::Receipts.verify!(receipt) if receipt
          Reach::Receipts.store(receipt) if receipt
          record_in_corpus(receipt) if receipt
          Reach::Receipts.acknowledge(receipt) if receipt
          {
            "submission_id" => body["submission_id"], "state" => receipt ? "ingested" : "delivered", "receipt" => receipt, "rejection" => nil,
            "attempt" => body["attempt"], "due" => body["due"], "resubmit" => body["resubmit"]
          }
        elsif state == "received"
          { "submission_id" => body["submission_id"], "state" => "queued", "receipt" => nil, "rejection" => nil }
        else
          { "submission_id" => body["submission_id"], "state" => "rejected", "receipt" => nil, "rejection" => refusal_of(body) }
        end
      end

      def refusal_of(body)
        rejection = body["rejection"]
        return rejection if rejection.is_a?(Hash) && !rejection["code"].to_s.empty?

        { "code" => "unexpected_state", "reason" => Reach::Messages.text("M-SUBMIT-ODD-ANSWER", state: body["state"].to_s.empty? ? "none" : body["state"]) }
      end

      def record_in_corpus(receipt)
        Reach::Corpus.new(Reach.ports).receipt(receipt)
      rescue StandardError => e
        Reach::BrainSpool.log("receipt_write_failed", "error" => e.class.name, "message" => e.message)
        nil
      end

      def resolve_workspace(slice)
        return slice if slice.is_a?(String) && File.directory?(File.join(slice, ".reach"))

        Reach::Workspace.named_slice!(slice)
      end

      def run_partial_preconditions(workspace)
        run_preconditions(workspace, safety_only: true)
      end

      def run_preconditions(workspace, safety_only: false)
        begin
          Reach::Gate.session(harness: "cli")
        rescue Reach::GateBlocked => e
          raise Reach::Refused, e.message
        end

        unless Reach::Workspace.verify(workspace)
          raise Reach::Refused, "reach: a read-only course file was changed; submission refused"
        end

        meta = Reach::Workspace.metadata(workspace)
        owned = Array(meta["owned_files"])
        unsafe = owned.reject { |relative| Reach::SafeFiles.safe?(workspace, relative) }
        unless unsafe.empty?
          raise Reach::Refused, Reach::Messages.text("M-SUBMIT-UNSAFE", list: unsafe.map { |relative| "- #{relative}" }.join("\n"))
        end
        missing = owned.reject { |relative| File.file?(File.join(workspace, relative)) }
        unless missing.empty?
          raise Reach::Refused, Reach::Messages.text("M-SUBMIT-MISSING", list: missing.map { |relative| "- #{relative}" }.join("\n"))
        end
        return if safety_only

        findings = Array(Reach::Check.run(workspace, format: :agent)).select { |finding| owned.include?(finding[:file].to_s) }
        readme = findings.select { |finding| finding[:id] == "CK-README" }
        unless readme.empty?
          raise Reach::Refused, Reach::Messages.text(
            "M-SUBMIT-README", min: Reach::ReadmeCheck::MIN_WORDS, list: readme.map { |finding| "- #{finding[:message]}" }.join("\n")
          )
        end
        enforce = Reach::Patterns.mode == "enforce"
        check_gate!(workspace, meta, findings.reject do |finding|
          %w[CK-SHAPE CK-README].include?(finding[:id]) || (finding[:id] == "CK-PATTERN" && !(enforce && finding[:severity] == "error"))
        end)
        if meta["slice"].to_s == "panel" && Array(findings).any? { |finding| finding[:classification] == :visible }
          raise Reach::Refused, "reach: the shape check still finds visible problems; fix them before submitting"
        end
      end

      def run_document_preconditions(workspace, meta, partial:)
        raise Reach::Refused, Reach::Messages.text("M-SUBMIT-DOC-PARTIAL") if partial
        raise Reach::Refused, Reach::Messages.text("M-SUBMIT-ELSEWHERE", note: elsewhere_note(meta)) if meta["submit"] == "elsewhere"

        begin
          Reach::Gate.session(harness: "cli")
        rescue Reach::GateBlocked => e
          raise Reach::Refused, e.message
        end
        raise Reach::Refused, "reach: a read-only course file was changed; submission refused" unless Reach::Workspace.verify(workspace)

        id, fields = Reach::DocumentFiles.problem(workspace, meta)
        raise Reach::Refused, Reach::Messages.text(id, **fields) if id
      end

      def elsewhere_note(meta)
        note = meta["submit_note"].to_s.strip
        note.empty? ? Reach::Messages.text("M-SUBMIT-ELSEWHERE-NONOTE") : note
      end

      def check_gate!(workspace, meta, findings)
        gate_file = File.join(Reach::Paths.submit_gate_dir, "#{File.basename(workspace)}.json")
        if findings.empty?
          FileUtils.rm_f(gate_file)
          return
        end

        digest = Reach::Crypto.digest_hex(findings.map { |finding| finding[:finding_id] }.sort.join("\n"))
        state = File.file?(gate_file) ? JSON.parse(File.read(gate_file)) : {}
        count = state["digest"] == digest ? state["count"].to_i + 1 : 1
        FileUtils.mkdir_p(File.dirname(gate_file))
        File.write(gate_file, JSON.generate("digest" => digest, "count" => count))

        listed = findings.map { |finding| "#{finding[:id]} #{finding[:file]}: #{finding[:message]}. #{finding[:fix]}." }.join("\n")
        if count < 2
          raise Reach::Refused, "#{Reach::Messages.text('M-SUBMIT-FIX-FIRST')}\n#{listed}"
        end

        summary = "reach check still reports #{findings.length} finding(s) at submit: #{findings.map { |finding| finding[:id] }.uniq.join(', ')}"
        hand_id = begin
          Reach::Hands.raise_hand(trigger: Reach::Hands::CHECK_GATE, summary: summary, slice: File.basename(workspace))
        rescue StandardError
          nil
        end
        FileUtils.rm_f(gate_file)
        raise Reach::Refused, Reach::Messages.text("M-SUBMIT-BLOCKED-CHECK", hand: hand_id ? Reach::Messages.text("M-HAND-RAISED") : Reach::Messages.text("M-OFFLINE"))
      end

      def owned_bytes(workspace, relative_path)
        Reach::SafeFiles.read(workspace, relative_path)
      rescue Reach::SafeFiles::Unsafe => e
        raise Reach::Refused, Reach::Messages.text("M-SUBMIT-UNSAFE", list: "- #{e.relative}")
      end

      def owned_digests(workspace, meta)
        return Reach::DocumentFiles.digests(workspace) if Reach::DocumentFiles.document_meta?(meta)

        digests = {}
        Array(meta["owned_files"]).each do |relative_path|
          data = owned_bytes(workspace, relative_path)
          digests[relative_path] = data ? Reach::Crypto.digest_hex(data) : nil
        end
        digests
      end

      def build_manifest(workspace, meta)
        document = Reach::DocumentFiles.document_meta?(meta)
        owned = document ? Reach::DocumentFiles.list(workspace) : Array(meta["owned_files"])
        digests = document ? Reach::DocumentFiles.digests(workspace, owned) : owned_digests(workspace, meta)
        {
          "schema" => "reach.submission/v1",
          "course" => meta["course"],
          "assignment" => meta["assignment"],
          "cutout_id" => meta["cutout_id"],
          "slice" => meta["slice"],
          "owned_files" => owned,
          "digests" => digests,
          "reach_version" => Reach::VERSION,
          "client_created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "seal" => seal_block(workspace)
        }
      end

      ALLOWED_HARNESSES = %w[claude-code codex antigravity hermes].freeze

      def seal_block(workspace)
        {
          "guardrails_version" => Reach::Guardrails.version,
          "ledger_key" => Reach::Seal.ledger_key ? "teach" : "local",
          "ledger_head" => Reach::Ledger.head(workspace),
          "ledger_count" => Reach::Ledger.count(workspace),
          "witnessed" => Reach::Ledger.witnessed(workspace),
          "marks" => Reach::Seal.verify(workspace),
          "hooked" => Reach::Ledger.records(workspace).any? { |record| record["kind"] == "session" },
          "harness" => Reach::Ledger.last_harness(workspace) || env_harness || detected_harness || "unknown",
          "sidecar_id" => Reach::Sidecar.id,
          "integrity_events" => Reach::Ledger.integrity_count(workspace)
        }
      rescue StandardError
        { "ledger_key" => "local", "marks" => {}, "witnessed" => {} }
      end

      def env_harness
        value = ENV["REACH_HARNESS"]
        ALLOWED_HARNESSES.include?(value) ? value : nil
      end

      def detected_harness
        value = Reach::Session.detect_harness
        ALLOWED_HARNESSES.include?(value) ? value : nil
      end

      def require_part!(assignment)
        return unless Reach::Part.required?(assignment)

        open_questions = Reach::Part.missing(assignment)
        return if open_questions.empty?

        raise Reach::Refused, Reach::Messages.text("M-SUBMIT-NO-PART", missing: open_questions.map { |question| question["question"] }.join("; "))
      end

      def flush_transcript(assignment)
        return unless Reach::Part.required?(assignment)

        begin
          Reach::Transcript.flush(quick: false)
        rescue Reach::Offline, Reach::NetworkError
          nil
        end
      end

      def submission_entries(manifest, workspace, tail, qualification, assignment, document: false)
        entries = { "manifest.json" => JSON.generate(manifest) }
        entries["part.json"] = JSON.generate(Reach::Part.document(assignment)) unless Reach::Part.questions(assignment).empty?
        Reach::Qualify.test_files(workspace).each { |relative, data| entries["evidence/#{relative}"] = data } unless document
        entries["evidence/qualification.json"] = JSON.generate(qualification.reject { |key, _| key == "ladder" }) if qualification
        receipt = File.join(workspace, Reach::Workspace::MARKER_DIR, Reach::Packet::RECEIPT_FILE)
        entries["evidence/sidecar-receipt.json"] = File.binread(receipt) if File.file?(receipt) && !document
        Array(manifest["owned_files"]).each do |relative_path|
          data = owned_bytes(workspace, relative_path)
          next unless data

          entries["files/#{relative_path}"] = data
        end
        entries["ledger.jsonl"] = tail unless tail.to_s.empty?
        entries
      end

      def seal_submission(install, meta, tar_bytes)
        seal_package(install, meta, tar_bytes, Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file)))
      end

      def seal_package(install, meta, tar_bytes, private_key)
        encryption_key = install.fetch("encryption_key")
        header = {
          "schema" => "teach.package/v1",
          "kind" => "submission",
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
          signer_private_key: private_key
        )
      end

      public :seal_package

      def write_outbox(idempotency_key, kind, route, body, workspace: nil, external: false)
        FileUtils.mkdir_p(Reach::Paths.outbox_dir)
        path = File.join(Reach::Paths.outbox_dir, "#{idempotency_key}.json")
        entry = { "kind" => kind, "route" => route, "idempotency_key" => idempotency_key, "body" => body, "queued_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ") }
        if external
          write_json_atomic(outbox_companion(path), body)
          entry["body_file"] = File.basename(outbox_companion(path))
          entry["body"] = body.reject { |key, _| key == "package" }
        end
        entry["workspace"] = workspace if workspace
        write_json_atomic(path, entry)
        path
      end

      def archive_for_outbox(workspace)
        return nil unless File.directory?(workspace.to_s)

        Reach::Archive.write!(workspace, Reach::Workspace.metadata(workspace))
      end

      def due_for(meta)
        Reach::LateWork.due_for_meta(meta)
      rescue StandardError
        nil
      end

      def approval_mode
        return "terminal" if $stdin.tty? && $stdout.tty?
        return "agent" if ENV["REACH_HARNESS"] == "antigravity"

        "hook"
      end

      def ask_fields(meta, partial: false, workspace: nil)
        due = due_for(meta)
        prefix = partial ? "M-SUBMIT-PARTIAL-ASK" : "M-SUBMIT-ASK"
        again = if due.nil?
                  partial ? Reach::Messages.text("M-SUBMIT-PARTIAL-ASK-ANY") : ""
                elsif Reach::Pace.server_now < due
                  Reach::Messages.text("#{prefix}-OPEN", due: Reach::Messages.course_time(due))
                else
                  Reach::Messages.text("#{prefix}-LATE", due: Reach::Messages.course_time(due))
                end
        document = Reach::DocumentFiles.document_meta?(meta)
        files = document && workspace ? Reach::DocumentFiles.list(workspace).join(", ") : ""
        { slice: meta["slice"], cutout: meta["cutout_id"], assignment: meta["assignment"], again: again, files: files, credit: document ? "" : Reach::Archive.credit("M-LMS-UPLOAD-THAT") }
      end

      def approve!(workspace, meta, partial: false)
        kind = partial ? "submission_partial" : "submission"
        message_id = partial ? "M-SUBMIT-PARTIAL-ASK" : "M-SUBMIT-ASK"
        message_id = "M-SUBMIT-ASK-DOC" if Reach::DocumentFiles.document_meta?(meta)
        case approval_mode
        when "agent"
          nil
        when "terminal"
          puts Reach::Messages.text(message_id, **ask_fields(meta, partial: partial, workspace: workspace)).strip
          print Reach::Messages.text("M-SUBMIT-TERMINAL-PROMPT")
          $stdout.flush
          answer = $stdin.gets
          Reach::Consent.yes?(answer.to_s) ? nil : { "state" => "declined", "text" => Reach::Messages.text("M-CONSENT-DECLINED") }
        else
          subject = { "workspace" => File.basename(workspace), "digests" => owned_digests(workspace, meta) }
          if Reach::Consent.declined?(kind: kind, subject: subject)
            Reach::Consent.clear_declined!(kind: kind, subject: subject)
            return { "state" => "declined", "text" => Reach::Messages.text("M-CONSENT-DECLINED") }
          end
          return nil if Reach::Consent.take!(kind: kind, subject: subject)

          question = Reach::Consent.ask!(kind: kind, subject: subject, message_id: message_id, fields: ask_fields(meta, partial: partial, workspace: workspace), replay: { "slice_id" => File.basename(workspace) })
          { "state" => "asked", "text" => Reach::Messages.text("M-CONSENT-NEEDED", question: question) }
        end
      end

      def client(install)
        Reach::Client.for_install(install)
      end
    end
  end
end
