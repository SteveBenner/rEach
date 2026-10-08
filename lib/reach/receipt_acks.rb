require "json"
require "time"
require "fileutils"
require "base64"
require "securerandom"

module Reach
  module ReceiptAcks
    SCHEMA = "reach.receipt-ack/v1".freeze
    ROUTE = "/api/v1/receipts/%s/acknowledgment".freeze
    SYNC_SEND_LIMIT = 20
    BACKFILL_PAGE_LIMIT = 200
    BACKFILL_MAX_PAGES = 5

    class << self
      def record(receipt)
        install = Reach::Enroll.current
        return nil unless install

        id = receipt["receipt_id"]
        existing = load_record(id)
        return existing if existing && existing["ack"].is_a?(Hash) && existing["ack"]["install_id"] == install["install_id"]

        body = {
          "schema" => SCHEMA,
          "ack_id" => "rack_" + SecureRandom.hex(10),
          "receipt_id" => id,
          "receipt_kind" => receipt["kind"],
          "submission_id" => receipt["submission_id"],
          "student_id" => receipt["student_id"],
          "install_id" => install["install_id"],
          "receipt_digest" => Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(receipt)),
          "receipt_signing_key_id" => receipt["signing_key_id"],
          "acknowledged_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "reach_version" => Reach::VERSION
        }
        key = Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
        body["signature"] = Base64.strict_encode64(Reach::Crypto.sign_pss(key, Reach::Crypto.canonical_json(body)))

        entry = {
          "ack" => body,
          "state" => "pending",
          "linked_at" => nil,
          "teach_ack_id" => nil,
          "last_error" => nil,
          "attempted_at" => nil
        }
        save_record(id, entry)
        entry
      end

      def deliver(receipt_id)
        attempt(receipt_id).first
      end

      def flush(limit: SYNC_SEND_LIMIT)
        result = { "linked" => 0, "pending" => 0, "mismatch" => [], "refused" => [] }
        Reach::Receipts.list.each do |receipt|
          begin
            record(receipt)
          rescue StandardError
            nil
          end
        end
        pending = list.select { |entry| entry["state"] == "pending" }
          .sort_by { |entry| entry["ack"]["acknowledged_at"].to_s }
        pending.first(limit).each do |entry|
          id = entry["ack"]["receipt_id"]
          state, unreachable = attempt(id)
          case state
          when "linked" then result["linked"] += 1
          when "mismatch" then result["mismatch"] << id
          when "refused" then result["refused"] << id
          end
          break if unreachable
        end
        result["pending"] = counts["pending"]
        result
      end

      def backfill
        client = Reach::Client.for_install(Reach::Enroll.current)
        result = { "stored" => 0, "failed" => 0 }
        cursor = nil
        BACKFILL_MAX_PAGES.times do
          query = { "limit" => BACKFILL_PAGE_LIMIT.to_s }
          query["cursor"] = cursor if cursor
          page = Array((client.get("/api/v1/receipts", query: query).json || {})["receipts"])
          page.each do |receipt|
            next unless receipt.is_a?(Hash) && receipt["receipt_id"]
            next if Reach::Receipts.show(receipt["receipt_id"])

            begin
              Reach::Receipts.accept(receipt)
              result["stored"] += 1
            rescue Reach::VerificationFailed
              result["failed"] += 1
            end
          end
          break if page.size < BACKFILL_PAGE_LIMIT

          cursor = page.last["receipt_id"]
        end
        result
      end

      def list
        FileUtils.mkdir_p(Reach::Paths.receipt_acks_dir)
        Dir.glob(File.join(Reach::Paths.receipt_acks_dir, "*.json")).map do |path|
          begin
            data = JSON.parse(File.read(path))
            data.is_a?(Hash) ? data : nil
          rescue JSON::ParserError, SystemCallError
            nil
          end
        end.compact.sort_by { |entry| entry["ack"].to_h["acknowledged_at"].to_s }.reverse
      end

      def counts
        entries = list
        {
          "total" => entries.size,
          "linked" => entries.count { |entry| entry["state"] == "linked" },
          "pending" => entries.count { |entry| entry["state"] == "pending" },
          "mismatch" => entries.count { |entry| entry["state"] == "mismatch" },
          "refused" => entries.count { |entry| entry["state"] == "refused" }
        }
      end

      private

      def attempt(receipt_id)
        entry = load_record(receipt_id)
        return [nil, false] unless entry
        return [entry["state"], false] unless entry["state"] == "pending"

        unreachable = false
        ack = entry["ack"]
        path = format(ROUTE, receipt_id)
        begin
          response = Reach::Client.for_install(Reach::Enroll.current).post_json(path, ack, idempotency_key: ack["ack_id"])
          data = response.json || {}
          entry["state"] = "linked"
          entry["linked_at"] = data["linked_at"]
          entry["teach_ack_id"] = data["ack_id"]
          entry["last_error"] = nil
        rescue Reach::RemoteRefused => e
          if e.code == "conflict"
            entry["state"] = "mismatch"
            entry["last_error"] = e.message
          elsif e.code == "invalid_request" || permanent_refusal?(e.status)
            entry["state"] = "refused"
            entry["last_error"] = e.message
          else
            entry["last_error"] = "#{e.code}: #{e.message}"
          end
        rescue Reach::Offline, Reach::NetworkError => e
          entry["last_error"] = e.message
          unreachable = true
        end
        entry["attempted_at"] = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        save_record(receipt_id, entry)
        [entry["state"], unreachable]
      end

      def permanent_refusal?(status)
        status.is_a?(Integer) && status >= 400 && status < 500 && ![408, 429].include?(status)
      end

      def record_path(receipt_id)
        File.join(Reach::Paths.receipt_acks_dir, "#{receipt_id.to_s.gsub(/[^A-Za-z0-9_-]/, '_')}.json")
      end

      def load_record(receipt_id)
        path = record_path(receipt_id)
        return nil unless File.file?(path)

        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def save_record(receipt_id, entry)
        dir = Reach::Paths.receipt_acks_dir
        FileUtils.mkdir_p(dir)
        begin
          File.chmod(0o700, dir)
        rescue NotImplementedError, Errno::ENOENT
          nil
        end
        path = record_path(receipt_id)
        Reach::StateFile.write_atomic(path, JSON.generate(entry))
      end
    end
  end
end
