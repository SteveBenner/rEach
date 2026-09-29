require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Submit
    ROUTE = "/api/v1/submissions"

    class << self
      def submit(slice:)
        workspace = resolve_workspace(slice)
        run_preconditions(workspace)

        meta = Reach::Workspace.metadata(workspace)
        manifest = build_manifest(workspace, meta)
        install = Reach::Enrol.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROL") unless install

        tail = Reach::Ledger.tail_text(workspace)
        Reach::Ledger.append(workspace, "submit", "manifest_digest" => Reach::Crypto.digest_hex(JSON.generate(manifest)))
        tar_bytes = Reach::Tarball.write(submission_entries(manifest, workspace, tail))
        envelope = seal_submission(install, meta, tar_bytes)
        idempotency_key = SecureRandom.uuid
        body = {
          "cutout_id" => meta["cutout_id"],
          "slice" => meta["slice"],
          "assignment" => meta["assignment"],
          "package" => envelope,
          "client_created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
        outbox_path = write_outbox(idempotency_key, "submission", ROUTE, body)

        begin
          response = client(install).post_json(ROUTE, body, idempotency_key: idempotency_key)
          result = handle_response(response.json || {})
          FileUtils.rm_f(outbox_path)
          result
        rescue Reach::RemoteRefused => e
          FileUtils.rm_f(outbox_path)
          { "submission_id" => nil, "state" => "rejected", "receipt" => nil, "rejection" => { "code" => e.code, "reason" => e.message } }
        rescue Reach::Offline, Reach::NetworkError
          { "submission_id" => nil, "state" => "queued", "receipt" => nil, "rejection" => nil }
        end
      end

      def retry_outbox
        results = []
        Dir.glob(File.join(Reach::Paths.outbox_dir, "*.json")).sort.each do |path|
          entry = JSON.parse(File.read(path))
          install = Reach::Enrol.current
          next unless install

          begin
            response = client(install).post_json(entry.fetch("route"), entry.fetch("body"), idempotency_key: entry.fetch("idempotency_key"))
            body = response.json || {}
            if entry["kind"] == "submission"
              results << handle_response(body)
            elsif entry["kind"] == "integrity"
              results << { "state" => "sent", "event_id" => body["event_id"] }
            else
              results << { "hand_id" => body["hand_id"], "state" => body["state"] }
            end
            FileUtils.rm_f(path)
          rescue Reach::RemoteRefused => e
            FileUtils.rm_f(path)
            results << { "state" => "rejected", "rejection" => { "code" => e.code, "reason" => e.message } }
          rescue Reach::Offline, Reach::NetworkError
            next
          end
        end
        results
      end

      private

      def handle_response(body)
        state = body["state"]
        if state == "ingested"
          receipt = body["receipt"]
          Reach::Receipts.verify!(receipt) if receipt
          Reach::Receipts.store(receipt) if receipt
          record_in_corpus(receipt) if receipt
          { "submission_id" => body["submission_id"], "state" => "ingested", "receipt" => receipt, "rejection" => nil }
        else
          { "submission_id" => body["submission_id"], "state" => "rejected", "receipt" => nil, "rejection" => body["rejection"] }
        end
      end

      def record_in_corpus(receipt)
        Reach::Corpus.new(Reach.ports).receipt(receipt)
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

      def run_preconditions(workspace)
        begin
          Reach::Gate.session(harness: "cli")
        rescue Reach::GateBlocked => e
          raise Reach::Refused, e.message
        end

        unless Reach::Workspace.verify(workspace)
          raise Reach::Refused, "reach: a read-only course file was changed; submission refused"
        end

        findings = Reach::Check.run(workspace, format: :agent)
        meta = Reach::Workspace.metadata(workspace)
        check_gate!(workspace, meta, findings.reject { |finding| finding[:id] == "CK-SHAPE" })
        if meta["slice"].to_s == "panel" && Array(findings).any? { |finding| finding[:classification] == :visible }
          raise Reach::Refused, "reach: the shape check still finds visible problems; fix them before submitting"
        end
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
          Reach::Hands.raise_hand(trigger: "check_gate", summary: summary, slice: File.basename(workspace))
        rescue StandardError
          nil
        end
        FileUtils.rm_f(gate_file)
        raise Reach::Refused, Reach::Messages.text("M-SUBMIT-BLOCKED-CHECK", hand: hand_id ? Reach::Messages.text("M-HAND-RAISED") : Reach::Messages.text("M-OFFLINE"))
      end

      def build_manifest(workspace, meta)
        owned = Array(meta["owned_files"])
        digests = {}
        owned.each do |relative_path|
          full_path = File.join(workspace, relative_path)
          digests[relative_path] = File.file?(full_path) ? Reach::Crypto.digest_hex(File.binread(full_path)) : nil
        end
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

      def seal_block(workspace)
        {
          "guardrails_version" => Reach::Guardrails.version,
          "ledger_key" => Reach::Seal.ledger_key ? "teach" : "local",
          "ledger_head" => Reach::Ledger.head(workspace),
          "ledger_count" => Reach::Ledger.count(workspace),
          "witnessed" => Reach::Ledger.witnessed(workspace),
          "marks" => Reach::Seal.verify(workspace),
          "harness" => Reach::Ledger.last_harness(workspace) || "unknown",
          "sidecar_id" => Reach::Sidecar.id,
          "integrity_events" => Reach::Ledger.integrity_count(workspace)
        }
      rescue StandardError
        { "ledger_key" => "local", "marks" => {}, "witnessed" => {} }
      end

      def submission_entries(manifest, workspace, tail)
        entries = { "manifest.json" => JSON.generate(manifest) }
        Array(manifest["owned_files"]).each do |relative_path|
          full_path = File.join(workspace, relative_path)
          next unless File.file?(full_path)

          entries["files/#{relative_path}"] = File.binread(full_path)
        end
        entries["ledger.jsonl"] = tail unless tail.to_s.empty?
        entries
      end

      def seal_submission(install, meta, tar_bytes)
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
          signer_private_key: Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
        )
      end

      def write_outbox(idempotency_key, kind, route, body)
        FileUtils.mkdir_p(Reach::Paths.outbox_dir)
        path = File.join(Reach::Paths.outbox_dir, "#{idempotency_key}.json")
        File.write(path, JSON.generate("kind" => kind, "route" => route, "idempotency_key" => idempotency_key, "body" => body))
        path
      end

      def client(install)
        Reach::Client.for_install(install)
      end
    end
  end
end
