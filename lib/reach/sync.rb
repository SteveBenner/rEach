require "json"
require "fileutils"
require "time"

module Reach
  module Sync
    class << self
      def run
        install = Reach::Enrol.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROL") unless install

        summary = {
          "state" => "ok",
          "course" => nil,
          "student" => nil,
          "guardrails_version" => nil,
          "packages" => {},
          "workspaces" => [],
          "outbox_sent" => 0,
          "hand_replies" => [],
          "warnings" => []
        }

        results = safe_call(summary) { Reach::Submit.retry_outbox }
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
            Reach::Enrol.mark_revoked!
            summary["state"] = "revoked"
            return summary
          end
          raise
        end

        unless offline
          Array(status["packages"]).each do |pkg|
            kind = pkg["kind"]
            next unless %w[guardrails shape workspace suite].include?(kind)

            begin
              packages = Reach::Packages.new
              packages.fetch(kind)
              summary["packages"][kind] = packages.latest_version(kind)
            rescue StandardError => e
              summary["warnings"] << "reach: could not fetch #{kind} package (#{e.message})"
            end
          end
        end

        begin
          Reach::Guardrails.heal
          summary["guardrails_version"] = Reach::Guardrails.version
        rescue StandardError => e
          summary["warnings"] << "reach: could not update course rules (#{e.message})"
        end

        begin
          ensure_shape_unpacked
        rescue StandardError => e
          summary["warnings"] << "reach: could not update shapes (#{e.message})"
        end

        begin
          if Reach::Packages.new.latest_version("workspace")
            summary["workspaces"] = Reach::Workspace.provision_from_package
          end
        rescue StandardError => e
          summary["warnings"] << "reach: could not provision your workspace (#{e.message})"
        end

        unless offline
          begin
            summary["hand_replies"] = Reach::Hands.poll_replies
          rescue StandardError => e
            summary["warnings"] << "reach: could not check for hand replies (#{e.message})"
          end

          begin
            summary["grades"] = Reach::Receipts.refresh_grades
          rescue StandardError => e
            summary["warnings"] << "reach: could not check for grades (#{e.message})"
          end
        end

        summary
      end

      def refresh_status(quick: false)
        install = Reach::Enrol.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROL") unless install

        client = Reach::Client.for_install(install, quick: quick)
        response = client.get("/api/v1/status")
        status = response.json || {}

        FileUtils.mkdir_p(Reach::Paths.state_dir)
        cache = status.merge("fetched_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
        File.write(Reach::Paths.status_cache_file, JSON.generate(cache))

        Reach::Enrol.update!(
          "signing_public_keys" => status["signing_public_keys"],
          "encryption_key" => status["encryption_key"],
          "minimum_reach_version" => status["minimum_reach_version"],
          "wire_contract_sha256" => status["wire_contract_sha256"],
          "last_checked_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "revoked" => false
        )

        status
      rescue Reach::RemoteRefused => e
        Reach::Enrol.mark_revoked! if %w[revoked not_enrolled].include?(e.code)
        raise
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

      def ensure_shape_unpacked
        packages = Reach::Packages.new
        version = packages.latest_version("shape")
        return unless version

        marker = File.join(Reach::Paths.shape_vault_dir, ".version")
        current = File.file?(marker) ? File.read(marker).strip.to_i : nil
        return if current == version

        packages.unpack("shape", version, into: Reach::Paths.shape_vault_dir)
        File.write(marker, version.to_s)
      end

      def safe_call(summary)
        yield
      rescue StandardError => e
        summary["warnings"] << "reach: could not retry queued submissions (#{e.message})"
        []
      end
    end
  end
end
