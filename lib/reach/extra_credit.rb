require "json"
require "time"
require "securerandom"

module Reach
  module ExtraCredit
    ROUTE = "/api/v1/extra-credit".freeze
    CROCKFORD = /\A[0-9A-HJKMNP-TV-Z]{8}\z/.freeze
    ANSWER_MAX_BYTES = 4000
    REFUSALS = {
      "extra_credit_unknown" => ["unknown", "M-XC-UNKNOWN"],
      "extra_credit_expired" => ["expired", "M-XC-EXPIRED"],
      "extra_credit_used" => ["used", "M-XC-USED"]
    }.freeze

    module_function

    def normalize(text)
      chars = text.to_s.upcase.gsub(/[^A-Z0-9]/, "")
      return nil unless chars.length == 10 && chars.start_with?("XC")

      tail = chars[2..-1].tr("IL", "11").tr("O", "0")
      return nil unless CROCKFORD.match?(tail)

      "XC#{tail}"
    end

    def display(normalized)
      "XC-#{normalized[2, 4]}-#{normalized[6, 4]}"
    end

    def now_stamp
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def entries
      Reach::Profile.extra_credit
    end

    def redeem(code:, answer:)
      Reach::EnrollmentLock.check!
      install = Reach::Enroll.current
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

      normalized = normalize(code)
      raise Reach::Refused, Reach::Messages.text("M-XC-INVALID") unless normalized

      text = answer.to_s.strip
      raise Reach::Refused, Reach::Messages.text("M-XC-NO-ANSWER") if text.empty?
      raise Reach::Refused, Reach::Messages.text("M-XC-TOO-LONG", max: ANSWER_MAX_BYTES) if text.bytesize > ANSWER_MAX_BYTES

      shown = display(normalized)
      list = entries
      existing = list.find { |entry| entry["code"] == shown && %w[recorded pending].include?(entry["state"]) }
      raise Reach::Refused, Reach::Messages.text("M-XC-ALREADY") if existing

      entry = {
        "entry_id" => nil, "local_id" => SecureRandom.hex(8), "code" => shown, "label" => nil, "points" => nil,
        "answer" => text, "answered_at" => now_stamp, "recorded_at" => nil, "state" => "pending", "reason" => nil,
        "idempotency_key" => SecureRandom.uuid
      }
      list = list.reject { |item| item["code"] == shown && item["state"] == "refused" }
      list << entry
      Reach::Profile.save_extra_credit(list)
      post(install, entry, normalized)
    end

    def post(install, entry, normalized = nil)
      normalized ||= normalize(entry["code"])
      body = { "redemption" => normalized, "answer" => entry["answer"], "answered_at" => entry["answered_at"] }
      begin
        response = Reach::Client.for_install(install).post_json(ROUTE, body, idempotency_key: entry["idempotency_key"])
        taken = response.json.is_a?(Hash) ? response.json["entry"] : nil
        raise Reach::NetworkError, "extra credit answer had no entry" unless taken.is_a?(Hash)

        update(entry["local_id"]) { |item| apply_recorded(item, taken) }
        event(entry, "recorded", "recorded")
        { "state" => "recorded", "entry" => find(entry["local_id"]), "text" => Reach::Messages.text("M-XC-RECORDED", label: taken["label"].to_s) }
      rescue Reach::RemoteRefused => e
        reason, message_id = REFUSALS[e.code.to_s]
        raise unless reason

        update(entry["local_id"]) { |item| item.merge("state" => "refused", "reason" => reason) }
        event(entry, "refused", reason)
        { "state" => "refused", "reason" => reason, "entry" => find(entry["local_id"]), "text" => Reach::Messages.text(message_id) }
      rescue Reach::NetworkError
        event(entry, "pending", "network")
        { "state" => "pending", "entry" => find(entry["local_id"]), "text" => Reach::Messages.text("M-XC-PENDING") }
      end
    end

    def apply_recorded(item, taken)
      item.merge(
        "entry_id" => taken["entry_id"], "label" => taken["label"], "points" => taken["points"],
        "answer" => taken["answer"].to_s.empty? ? item["answer"] : taken["answer"],
        "answered_at" => taken["answered_at"] || item["answered_at"], "recorded_at" => taken["recorded_at"],
        "state" => "recorded", "reason" => nil
      )
    end

    def find(local_id)
      found = entries.find { |item| item["local_id"] == local_id }
      found && found.reject { |key, _| key == "idempotency_key" }
    end

    def update(local_id)
      list = entries.map { |item| item["local_id"] == local_id ? yield(item) : item }
      Reach::Profile.save_extra_credit(list)
    end

    def retry_pending!
      install = Reach::Enroll.current
      return { "sent" => 0, "pending" => 0 } unless install

      sent = 0
      entries.select { |item| item["state"] == "pending" }.each do |entry|
        break unless entry["code"] && entry["idempotency_key"]

        result = post(install, entry)
        sent += 1 unless result["state"] == "pending"
        break if result["state"] == "pending"
      end
      { "sent" => sent, "pending" => entries.count { |item| item["state"] == "pending" } }
    end

    def pull!
      install = Reach::Enroll.current
      return nil unless install

      begin
        response = Reach::Client.for_install(install).get(ROUTE)
      rescue Reach::RemoteRefused => e
        return nil if e.status == 404

        raise
      end
      body = response.json
      return nil unless body.is_a?(Hash) && body["entries"].is_a?(Array)

      remote = body["entries"].select { |row| row.is_a?(Hash) && row["entry_id"].to_s != "" }
      current = entries
      kept = current.reject { |item| item["state"] == "recorded" }
      recorded = remote.map do |row|
        local = current.find { |item| item["entry_id"] == row["entry_id"] }
        base = local || { "local_id" => SecureRandom.hex(8), "code" => nil, "reason" => nil, "idempotency_key" => nil }
        apply_recorded(base, row)
      end
      Reach::Profile.save_extra_credit(recorded + kept)
      event(nil, "synced", "pulled", count: recorded.length)
      { "entries" => recorded.length }
    end

    def event(entry, state, outcome, extra = {})
      fields = { "what" => "extra_credit", "state" => state, "outcome" => outcome }
      fields["entry_id"] = entry["entry_id"] if entry && entry["entry_id"]
      Reach::Debug.emit("submit", fields.merge(extra))
    end

    def list
      shown = entries
      rows = shown.map { |entry| row_text(entry) }
      text = if rows.empty?
               Reach::Messages.text("M-XC-LIST-EMPTY")
             else
               ([Reach::Messages.text("M-XC-LIST-HEADER")] + rows.map { |row| "  #{row}" }).join("\n")
             end
      { "state" => "listed", "entries" => shown.map { |entry| entry.reject { |key, _| key == "idempotency_key" } }, "text" => text }
    end

    def row_text(entry)
      label = entry["label"].to_s.empty? ? entry["code"].to_s : entry["label"].to_s
      points = entry["points"].nil? ? "" : " (#{Reach::Grades.number(entry["points"])} #{entry["points"].to_f == 1 ? "point" : "points"})"
      status = Reach::Messages.text("M-XC-STATE-#{entry["state"].to_s.upcase}", reason: entry["reason"].to_s)
      "#{label}#{points}: #{status}"
    end
  end
end
