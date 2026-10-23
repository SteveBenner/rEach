require "json"
require "fileutils"
require "time"

module Reach
  module Sync
    class Busy < Reach::Error; end

    LOCK_WAIT_S = 120

    class << self
      def lock_file
        File.join(Reach::Paths.state_dir, "sync.lock")
      end

      def run(wait_s: LOCK_WAIT_S)
        FileUtils.mkdir_p(Reach::Paths.state_dir)
        outcome = Reach::Locks.exclusive(lock_file, wait_s: wait_s) { run_locked }
        raise Busy, "reach: another sync is running" if outcome == :busy

        outcome
      end

      def run_locked
        began = Reach::Debug.clock
        install = Reach::Enroll.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

        summary = {
          "state" => "ok",
          "course" => nil,
          "student" => nil,
          "guardrails_version" => nil,
          "packages" => {},
          "late_packages" => {},
          "workspaces" => [],
          "outbox_sent" => 0,
          "hand_replies" => [],
          "warnings" => []
        }

        results = safe_call(summary) { Reach::Submit.retry_outbox }
        Reach::Issues.flush!(quick: false)
        Reach::Progress.flush!
        summary["outbox_sent"] = Array(results).count { |r| r["state"] == "ingested" }

        transcript_result = safe_call(summary) { Reach::Transcript.flush(quick: false) }
        summary["transcript_sent"] = transcript_result.is_a?(Hash) ? transcript_result["sent"].to_i : 0

        offline = false
        begin
          status = refresh_status(quick: false)
          summary["course"] = status["course"]
          summary["student"] = status["student"]
        rescue Reach::Offline, Reach::NetworkError
          offline = true
          summary["state"] = "offline"
          summary["warnings"] << "reach: could not reach the course server; working from stored packages"
          status = cached_status || {}
        rescue Reach::RemoteRefused => e
          if %w[revoked not_enrolled].include?(e.code)
            Reach::Enroll.mark_revoked!(e.details)
            summary["state"] = "revoked"
            Reach::Debug.sync(summary, began)
            return summary
          end
          raise
        end

        current_id = status.dig("current_assignment", "id")
        current_id = current_id.is_a?(String) ? current_id : nil
        late_entries = late_assignment_entries(status)

        unless offline
          Array(status["packages"]).each do |pkg|
            kind = pkg["kind"]
            next unless %w[guardrails shape workspace patterns].include?(kind)

            begin
              packages = Reach::Packages.new
              packages.fetch(kind, current: current_id)
              summary["packages"][kind] = packages.latest_version(kind)
            rescue StandardError => e
              summary["warnings"] << "reach: could not fetch #{kind} package (#{Reach::Link.reason(e, "sync")})"
            end
          end

          late_entries.each do |entry|
            id = entry["id"]
            kinds = Array(entry["packages"]).map { |pkg| pkg["kind"] }
            %w[workspace shape].each do |kind|
              next unless kinds.include?(kind)

              begin
                packages = Reach::Packages.new
                packages.fetch(kind, assignment: id)
                (summary["late_packages"][id] ||= {})[kind] = packages.latest_version(kind, assignment: id)
              rescue StandardError => e
                summary["warnings"] << "reach: could not fetch #{kind} package for #{id} (#{Reach::Link.reason(e, "sync")})"
              end
            end
          end
        end

        begin
          Reach::Guardrails.heal
          summary["guardrails_version"] = Reach::Guardrails.version
        rescue StandardError => e
          summary["warnings"] << "reach: could not update course rules (#{Reach::Link.reason(e, "sync")})"
        end

        Reach::CourseCorpus.ingest_if_changed

        begin
          ensure_shape_unpacked(current_id, late_entries.map { |entry| entry["id"] })
        rescue StandardError => e
          summary["warnings"] << "reach: could not update shapes (#{Reach::Link.reason(e, "sync")})"
        end

        begin
          migration = Reach::Workspace.migrate_layout!
          summary["warnings"].concat(Array(migration["warnings"]))
        rescue StandardError => e
          summary["warnings"] << "reach: could not migrate your workspace layout (#{Reach::Link.reason(e, "sync")})"
        end

        begin
          if Reach::Packages.new.latest_version("workspace")
            summary["workspaces"] = Reach::Workspace.provision_from_package
          end
        rescue StandardError => e
          summary["warnings"] << "reach: could not provision your workspace (#{Reach::Link.reason(e, "sync")})"
        end

        late_entries.each do |entry|
          id = entry["id"]
          begin
            if Reach::Packages.new.latest_version("workspace", assignment: id)
              summary["workspaces"].concat(Reach::Workspace.provision_from_package(assignment: id))
            end
          rescue StandardError => e
            summary["warnings"] << "reach: could not provision your #{id} workspace (#{Reach::Link.reason(e, "sync")})"
          end
        end

        begin
          Reach::Workspace.provision_extracurricular!
        rescue StandardError => e
          summary["warnings"] << "reach: could not provision your extracurricular folder (#{Reach::Link.reason(e, "sync")})"
        end

        unless offline
          begin
            Reach::ExtraCredit.retry_pending!
            pulled = Reach::ExtraCredit.pull!
            summary["extra_credit"] = pulled["entries"] if pulled
          rescue StandardError => e
            summary["warnings"] << "reach: could not sync your extra credit (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            Reach::Feedback.retry_pending!
            pulled = Reach::Feedback.pull!
            summary["feedback"] = pulled["items"] if pulled
          rescue StandardError => e
            summary["warnings"] << "reach: could not sync your feedback (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            summary["hand_replies"] = Reach::Hands.poll_replies
          rescue StandardError => e
            summary["warnings"] << "reach: could not check for hand replies (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            summary["grades"] = Reach::Receipts.refresh_grades
          rescue StandardError => e
            summary["warnings"] << "reach: could not check for grades (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            summary["receipts_backfilled"] = Reach::ReceiptAcks.backfill["stored"]
          rescue StandardError => e
            summary["warnings"] << "reach: could not fetch receipts from the course server (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            result = Reach::ReceiptAcks.flush
            summary["receipt_acks"] = result
            Array(result["mismatch"]).each do |id|
              summary["warnings"] << "reach: the course server's copy of receipt #{id} does not match the one on this computer; tell your instructors"
            end
          rescue StandardError => e
            summary["warnings"] << "reach: could not confirm receipts with the course server (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            Reach::Modules.refresh!
            Reach::Modules.flush_pending!
            transfer_text = Reach::Transfer.poll!
            summary["modules"] = Reach::Modules.module_ids
            summary["transfer"] = transfer_text if transfer_text
          rescue Reach::Offline, Reach::NetworkError
            nil
          rescue StandardError => e
            summary["warnings"] << "reach: could not check your modules (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            fetched = Reach::Announcements.fetch!
            summary["announcements"] = fetched if fetched
          rescue Reach::Offline, Reach::NetworkError
            nil
          rescue StandardError => e
            summary["warnings"] << "reach: could not check for announcements (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            fetched = Reach::Controls.fetch!
            summary["controls"] = fetched if fetched
          rescue Reach::Offline, Reach::NetworkError
            nil
          rescue StandardError => e
            summary["warnings"] << "reach: could not check for course controls (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            exam = Reach::ExamMode.fetch!
            summary["test"] = exam if exam
          rescue Reach::Offline, Reach::NetworkError
            nil
          rescue StandardError => e
            summary["warnings"] << "reach: could not check for a test (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            Reach::Holdings.report!
          rescue Reach::Offline, Reach::NetworkError
            nil
          rescue StandardError => e
            summary["warnings"] << "reach: could not tell the course server which course files this computer holds (#{Reach::Link.reason(e, "sync")})"
          end

          begin
            Reach::Limits.enforce!
          rescue StandardError => e
            summary["warnings"] << "reach: could not apply the local size limits (#{Reach::Link.reason(e, "sync")})"
          end
        end

        Reach::Debug.sync(summary, began)
        Reach::Debug.flush
        summary
      end

      def refresh_status(quick: false)
        install = Reach::Enroll.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

        client = Reach::Client.for_install(install, quick: quick)
        response = client.get("/api/v1/status", headers: fingerprint_headers)
        status = response.json || {}

        FileUtils.mkdir_p(Reach::Paths.state_dir)
        cache = status.merge("fetched_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
        File.write(Reach::Paths.status_cache_file, JSON.generate(cache))
        Reach::Live.note_status(status)
        Reach::DueChanges.note(status)
        Reach::Password.note_status!(status["password"], install)

        Reach::Enroll.update!(
          "signing_public_keys" => status["signing_public_keys"],
          "encryption_key" => status["encryption_key"],
          "minimum_reach_version" => status["minimum_reach_version"],
          "wire_contract_sha256" => status["wire_contract_sha256"],
          "last_checked_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "revoked" => false
        )

        status
      rescue Reach::RemoteRefused => e
        if e.code == "fingerprint_mismatch"
          Reach::EnrollmentLock.mark_moved!([])
          raise Reach::GateBlocked.new("M-ENR-MOVED", Reach::Messages.text("M-ENR-MOVED"))
        end
        Reach::Enroll.mark_revoked!(e.details) if %w[revoked not_enrolled].include?(e.code)
        raise
      end

      def fingerprint_headers
        stamp = Reach::Stamp.current
        return {} unless stamp

        stored = Reach::Fingerprint.stored
        return {} unless stored

        { "X-Reach-Fingerprint" => Reach::Fingerprint.header_digest(Reach::Fingerprint.live(salt: stored["salt"]), stamp) }
      rescue StandardError
        {}
      end

      def cached_status
        return nil unless File.file?(Reach::Paths.status_cache_file)

        JSON.parse(File.read(Reach::Paths.status_cache_file))
      rescue JSON::ParserError
        nil
      end

      def status_age_s
        status = cached_status
        return nil unless status && status["fetched_at"]

        Time.now.utc - Time.parse(status["fetched_at"]).utc
      rescue StandardError
        nil
      end

      private

      def late_assignment_entries(status)
        Array(status["late_assignments"]).select do |entry|
          entry.is_a?(Hash) && entry["id"].is_a?(String) && entry["id"].match?(/\AA[1-4]\z/)
        end
      end

      def ensure_shape_unpacked(current_id = nil, late_ids = [])
        packages = Reach::Packages.new
        current_version = current_id ? packages.latest_version("shape", assignment: current_id) : packages.latest_version("shape")
        desired = ([current_version] + late_ids.map { |id| packages.latest_version("shape", assignment: id) }).compact.uniq.sort
        return if desired.empty?

        marker = File.join(Reach::Paths.shape_vault_dir, ".version")
        wanted = desired.join(",")
        return if File.file?(marker) && File.read(marker).strip == wanted

        desired.each_with_index do |version, index|
          packages.unpack("shape", version, into: Reach::Paths.shape_vault_dir, keep: index.positive?)
        end
        File.write(marker, wanted)
      end

      def safe_call(summary)
        yield
      rescue StandardError => e
        summary["warnings"] << "reach: could not retry queued submissions (#{Reach::Link.reason(e, "sync")})"
        []
      end
    end
  end
end
