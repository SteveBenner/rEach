require "json"
require "time"
require "fileutils"
require "open3"
require "rbconfig"
require "base64"

module Reach
  module Receipts
    POLL_INTERVAL_S = 30

    class << self
      def wait(submission_id:, kind: "ingest", timeout_s: 300)
        deadline = Time.now + timeout_s
        loop do
          receipt = stored_for_submission(submission_id, kind)
          return receipt if receipt

          fetched = fetch_receipt(submission_id, kind)
          if fetched
            verify!(fetched)
            store(fetched)
            record_in_corpus(fetched)
            acknowledge(fetched)
            return fetched
          end

          return nil if Time.now >= deadline

          sleep([POLL_INTERVAL_S, deadline - Time.now].min)
        end
      rescue Reach::Offline
        nil
      end

      def verify!(receipt)
        signature = receipt["signature"]
        raise Reach::VerificationFailed, "reach: receipt carries no signature" unless signature

        unsigned = receipt.reject { |key, _| key == "signature" }
        signable = Reach::Crypto.canonical_json(unsigned)
        key_id = receipt["signing_key_id"]

        public_key = signer_public_key_for(key_id)
        unless public_key && Reach::Crypto.verify_pss(public_key, Base64.strict_decode64(signature), signable)
          raise Reach::VerificationFailed, "reach: receipt signature does not verify"
        end
      end

      def store(receipt)
        FileUtils.mkdir_p(Reach::Paths.receipts_dir)
        id = receipt["receipt_id"]
        File.write(File.join(Reach::Paths.receipts_dir, "#{id}.json"), JSON.generate(receipt))
        begin
          Reach::ReceiptAcks.record(receipt)
        rescue StandardError
          nil
        end
        Reach::LateWork.note_receipt(receipt)
      end

      def accept(receipt)
        verify!(receipt)
        store(receipt)
        record_in_corpus(receipt)
        receipt
      end

      def acknowledge(receipt)
        Reach::ReceiptAcks.deliver(receipt["receipt_id"])
      rescue StandardError
        nil
      end

      def list
        FileUtils.mkdir_p(Reach::Paths.receipts_dir)
        Dir.glob(File.join(Reach::Paths.receipts_dir, "*.json")).map { |path| JSON.parse(File.read(path)) }
          .sort_by { |receipt| receipt["issued_at"] || "" }
          .reverse
      end

      def show(id)
        path = File.join(Reach::Paths.receipts_dir, "#{id}.json")
        return nil unless File.file?(path)

        JSON.parse(File.read(path))
      end

      def latest_for(cutout_id:, slice:)
        list.find { |receipt| receipt["cutout_id"] == cutout_id && receipt["slice"] == slice }
      end

      def announce(receipt)
        text = message_for(receipt)
        notify_desktop(text)
        text
      end

      def refresh_grades(now: Time.now)
        outstanding = list.select { |receipt| receipt["kind"] == "ingest" && !stored_for_submission(receipt["submission_id"], "grade") }
        outstanding.each_with_object([]) do |ingest, announced|
          submission_id = ingest["submission_id"].to_s
          next if submission_id.empty? || polled_recently?(submission_id, now)

          mark_polled(submission_id, now)
          fetched = fetch_receipt(submission_id, "grade")
          next unless fetched

          verify!(fetched)
          store(fetched)
          record_in_corpus(fetched)
          acknowledge(fetched)
          announced << announce(fetched)
        end
      end

      private

      def poll_marker(submission_id)
        File.join(Reach::Paths.state_dir, "grade-polls", "#{submission_id.gsub(/[^A-Za-z0-9_-]/, '_')}.at")
      end

      def polled_recently?(submission_id, now)
        path = poll_marker(submission_id)
        return false unless File.file?(path)

        now - Time.iso8601(File.read(path).strip) < POLL_INTERVAL_S
      rescue ArgumentError
        false
      end

      def mark_polled(submission_id, now)
        path = poll_marker(submission_id)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, now.utc.iso8601)
      end

      def stored_for_submission(submission_id, kind)
        list.find { |receipt| receipt["submission_id"] == submission_id && receipt["kind"] == kind }
      end

      def fetch_receipt(submission_id, kind)
        response = teach_client.get("/api/v1/submissions/#{submission_id}")
        body = response.json || {}
        Array(body["receipts"]).find { |receipt| receipt["kind"] == kind }
      rescue Reach::NetworkError
        nil
      end

      def signer_public_key_for(key_id)
        install = Reach::Enroll.current
        return nil unless install

        key = Array(install["signing_public_keys"]).find { |k| k["key_id"] == key_id }
        return Reach::Crypto.load_public_key(key["pem"]) if key

        Reach::Sync.refresh_status(quick: false)
        install = Reach::Enroll.current
        key = Array(install["signing_public_keys"]).find { |k| k["key_id"] == key_id }
        key ? Reach::Crypto.load_public_key(key["pem"]) : nil
      rescue StandardError
        nil
      end

      def teach_client
        Reach::Client.for_install(Reach::Enroll.current)
      end

      def record_in_corpus(receipt)
        Reach::Corpus.new(Reach.ports).receipt(receipt)
      rescue StandardError => e
        Reach::BrainSpool.log("receipt_write_failed", "error" => e.class.name, "message" => e.message)
        nil
      end

      def message_for(receipt)
        kind = receipt["kind"].to_s
        if kind == "grade"
          scenarios = Array(receipt["scenarios"])
          Reach::Messages.text(
            "M-GRADED",
            slice: receipt["slice"],
            cutout: receipt["cutout_id"],
            passed: scenarios.count { |s| s["result"] == "passed" },
            total: scenarios.size
          )
        else
          Reach::Messages.text(
            "M-SUBMIT-RECEIVED",
            slice: receipt["slice"],
            cutout: receipt["cutout_id"],
            time: Reach::Messages.course_time(receipt["received_at"])
          )
        end
      end

      def notify_desktop(text)
        Reach::Desktop.notify(text)
      end
    end
  end
end
