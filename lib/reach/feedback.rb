require "json"
require "time"
require "securerandom"

module Reach
  module Feedback
    ROUTE = "/api/v1/feedback".freeze
    CATEGORIES = %w[general praise suggestion request question complaint problem pace].freeze
    MESSAGE_MAX_BYTES = 4000
    CONSENT_KIND = "feedback_send".freeze
    LIST_LIMIT = 100
    STORE = "feedback.json".freeze
    PULL_INTERVAL_S = 3600
    ROW_PREVIEW = 60
    STATES = %w[pending refused new seen acted closed].freeze
    RETRY_STATUSES = [404, 429].freeze

    module_function

    def now_stamp
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def label(category)
      Reach::Messages.text(["M-FEEDBACK-CATEGORY", category.to_s.upcase].join("-"))
    rescue StandardError
      category.to_s
    end

    def read_store
      data = Reach::StateFile.read(STORE)
      items = data["items"].is_a?(Array) ? data["items"].select { |item| item.is_a?(Hash) } : []
      data.merge("items" => items)
    end

    def entries
      read_store["items"]
    end

    def mutate
      Reach::StateFile.update(STORE) do |state|
        state["items"] = state["items"].is_a?(Array) ? state["items"].select { |item| item.is_a?(Hash) } : []
        yield(state)
      end
    end

    def find(local_id)
      found = entries.find { |item| item["local_id"] == local_id }
      found && found.reject { |key, _| key == "idempotency_key" }
    end

    def update(local_id)
      mutate do |state|
        state["items"] = state["items"].map { |item| item["local_id"] == local_id ? yield(item) : item }
      end
    end

    def clean_category(value)
      value.to_s.strip.downcase
    end

    def validated(category:, message:)
      chosen = clean_category(category)
      unless CATEGORIES.include?(chosen)
        raise Reach::Refused, Reach::Messages.text("M-FEEDBACK-CATEGORY-UNKNOWN", categories: CATEGORIES.join(", "))
      end

      text = message.to_s.strip
      raise Reach::Refused, Reach::Messages.text("M-FEEDBACK-EMPTY") if text.empty?
      raise Reach::Refused, Reach::Messages.text("M-FEEDBACK-TOO-LONG", max: MESSAGE_MAX_BYTES) if text.bytesize > MESSAGE_MAX_BYTES

      [chosen, text]
    end

    def ask(category:, message:, anonymous: false)
      Reach::EnrollmentLock.check!
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless Reach::Enroll.current

      chosen, text = validated(category: category, message: message)
      hidden = anonymous == true
      question = Reach::Consent.ask!(
        kind: CONSENT_KIND,
        subject: { "category" => chosen, "message" => text, "anonymous" => hidden },
        message_id: hidden ? "M-FEEDBACK-ASK-ANON" : "M-FEEDBACK-ASK",
        fields: { category: label(chosen), message: text }
      )
      { "state" => "asked", "text" => question }
    end

    def send!(subject, quick: false)
      Reach::EnrollmentLock.check!
      install = Reach::Enroll.current
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

      subject = {} unless subject.is_a?(Hash)
      chosen, text = validated(category: subject["category"], message: subject["message"])
      canonical = { "category" => chosen, "message" => text, "anonymous" => subject["anonymous"] == true }
      raise Reach::Refused, Reach::Messages.text("M-FEEDBACK-DECLINED") unless Reach::Consent.take!(kind: CONSENT_KIND, subject: canonical)

      entry = {
        "local_id" => SecureRandom.hex(8), "feedback_id" => nil, "category" => chosen, "message" => text,
        "anonymous" => subject["anonymous"] == true, "written_at" => now_stamp, "received_at" => nil,
        "state" => "pending", "reply" => nil, "reply_seen" => false, "acted_seen" => false, "reason" => nil,
        "idempotency_key" => SecureRandom.uuid
      }
      mutate { |state| state["items"] = state["items"] + [entry] }
      post(install, entry, quick: quick)
    end

    def post(install, entry, quick: false)
      body = {
        "category" => entry["category"], "message" => entry["message"], "anonymous" => entry["anonymous"] == true,
        "written_at" => entry["written_at"]
      }
      begin
        response = Reach::Client.for_install(install, quick: quick).post_json(ROUTE, body, idempotency_key: entry["idempotency_key"])
        taken = response.json
        raise Reach::NetworkError, "feedback answer had no id" unless taken.is_a?(Hash) && taken["feedback_id"].to_s != ""

        update(entry["local_id"]) do |item|
          item.merge("feedback_id" => taken["feedback_id"], "received_at" => taken["received_at"], "state" => "new", "reason" => nil)
        end
        event(entry, "new", "sent", feedback_id: taken["feedback_id"])
        { "state" => "new", "item" => find(entry["local_id"]), "text" => Reach::Messages.text(entry["anonymous"] ? "M-FEEDBACK-SENT-ANON" : "M-FEEDBACK-SENT") }
      rescue Reach::RemoteRefused => e
        status = e.status.to_i
        return pending_result(entry, "status_#{status}", quick: quick) if RETRY_STATUSES.include?(status) || status >= 500

        reason = e.code.to_s.empty? ? "refused" : e.code.to_s
        update(entry["local_id"]) { |item| item.merge("state" => "refused", "reason" => reason) }
        event(entry, "refused", reason)
        { "state" => "refused", "reason" => reason, "item" => find(entry["local_id"]), "text" => Reach::Messages.text("M-FEEDBACK-REFUSED") }
      rescue Reach::NetworkError
        pending_result(entry, "network", quick: quick)
      end
    end

    def pending_result(entry, outcome, quick: false)
      event(entry, "pending", outcome)
      Reach::Consent.spawn_flush(CONSENT_KIND) if quick
      { "state" => "pending", "item" => find(entry["local_id"]), "text" => Reach::Messages.text("M-FEEDBACK-PENDING") }
    end

    def retry_pending!
      install = Reach::Enroll.current
      return { "sent" => 0, "pending" => 0 } unless install

      sent = 0
      entries.select { |item| item["state"] == "pending" }.each do |entry|
        next unless entry["idempotency_key"].to_s != "" && entry["message"].to_s != ""

        result = post(install, entry)
        break if result["state"] == "pending"

        sent += 1
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

      remote = {}
      body["entries"].each do |row|
        remote[row["feedback_id"].to_s] = row if row.is_a?(Hash) && row["feedback_id"].to_s != ""
      end
      changed = 0
      mutate do |state|
        state["pulled_at"] = now_stamp
        state["items"] = state["items"].map do |item|
          row = remote[item["feedback_id"].to_s]
          next item unless row && !item["anonymous"] && !%w[pending refused].include?(item["state"])

          merged = apply_remote(item, row)
          changed += 1 unless merged == item
          merged
        end
      end
      event(nil, "synced", "pulled", count: changed)
      { "items" => changed }
    end

    def apply_remote(item, row)
      state = STATES.include?(row["state"].to_s) && !%w[pending refused].include?(row["state"].to_s) ? row["state"].to_s : item["state"]
      reply = row["reply"].is_a?(Hash) && row["reply"]["message"].to_s != "" ? { "message" => row["reply"]["message"].to_s, "answered_at" => row["reply"]["answered_at"] } : nil
      merged = item.merge("state" => state, "reply" => reply)
      merged["reply_seen"] = false if reply && reply != item["reply"]
      merged["reply_seen"] = item["reply_seen"] == true if reply.nil?
      merged["acted_seen"] = false if state == "acted" && item["state"] != "acted"
      merged
    end

    def pull_if_due!
      return nil unless Reach::Enroll.current

      last = begin
        Time.iso8601(read_store["pulled_at"].to_s)
      rescue ArgumentError
        nil
      end
      return nil if last && Time.now.utc - last < PULL_INTERVAL_S

      mutate { |state| state["pulled_at"] = now_stamp }
      pull!
    rescue StandardError
      nil
    end

    def news_lines
      lines = []
      mutate do |state|
        state["items"] = state["items"].map do |item|
          next item if %w[pending refused].include?(item["state"]) || item["anonymous"]

          shown = item
          reply = item["reply"]
          if reply.is_a?(Hash) && reply["message"].to_s != "" && item["reply_seen"] != true
            lines << Reach::Messages.text("M-FEEDBACK-REPLY-LINE", category: label(item["category"]), reply: reply["message"])
            shown = shown.merge("reply_seen" => true)
          end
          if item["state"] == "acted" && item["acted_seen"] != true
            lines << Reach::Messages.text("M-FEEDBACK-ACTED-LINE", category: label(item["category"]))
            shown = shown.merge("acted_seen" => true)
          end
          shown
        end
      end
      lines
    rescue StandardError
      []
    end

    def reach_out_due?
      read_store["reach_out"] != true
    rescue StandardError
      false
    end

    def reach_out_shown!
      mutate { |state| state["reach_out"] = true }
      nil
    rescue StandardError
      nil
    end

    def event(entry, state, outcome, extra = {})
      return nil if entry && entry["anonymous"] == true

      fields = { "what" => "feedback", "state" => state, "outcome" => outcome }
      fields["category"] = entry["category"] if entry
      fields["feedback_id"] = entry["feedback_id"] if entry && entry["feedback_id"]
      Reach::Debug.emit("submit", fields.merge(extra))
    end

    def list
      shown = entries.map { |entry| entry.reject { |key, _| key == "idempotency_key" } }
      rows = shown.map { |entry| row_text(entry) }
      text = if rows.empty?
               Reach::Messages.text("M-FEEDBACK-LIST-EMPTY")
             else
               ([Reach::Messages.text("M-FEEDBACK-LIST-HEADER")] + rows.map { |row| "  #{row}" }).join("\n")
             end
      { "state" => "listed", "entries" => shown, "text" => text }
    end

    def row_text(entry)
      words = entry["message"].to_s.gsub(/\s+/, " ").strip
      preview = words.length > ROW_PREVIEW ? "#{words[0, ROW_PREVIEW]}..." : words
      status = Reach::Messages.text(["M-FEEDBACK-STATE", entry["state"].to_s.upcase].join("-"))
      "#{label(entry["category"])}: \"#{preview}\" (#{status})"
    end
  end
end
