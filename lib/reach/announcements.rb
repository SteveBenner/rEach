require "json"
require "digest"
require "time"

module Reach
  module Announcements
    ROUTE = "/api/v1/announcements".freeze
    RECEIPTS_ROUTE = "/api/v1/announcements/receipts".freeze
    FILE = "announcements.json".freeze
    UNSUPPORTED_WAIT_S = 21_600
    PER_PROMPT = 3
    RECEIPTS_PER_POST = 50

    module_function

    def show?
      section = Reach::Runtime.load_config["announcements"]
      !(section.is_a?(Hash) && section["show"] == false)
    end

    def items(state = Reach::StateFile.read(FILE))
      state["items"].is_a?(Array) ? state["items"].select { |item| item.is_a?(Hash) && item["id"].is_a?(String) } : []
    end

    def list
      items.sort_by { |item| item["sent_at"].to_s }.reverse.map { |item| item.slice("id", "audience", "title", "body", "sent_at", "received_at", "shown_at") }
    end

    def parked?(state)
      state["unsupported_until"].to_i > Time.now.to_i
    end

    def fetch!
      install = Reach::Enroll.current
      return nil unless install
      return { "skipped" => "unsupported" } if parked?(Reach::StateFile.read(FILE))

      response = Reach::Client.for_install(install).get(ROUTE)
      rows = (response.json || {})["announcements"]
      raise Reach::Error, "reach: the course server's announcements answer was unreadable" unless rows.is_a?(Array)

      fresh = store(rows)
      flush_receipts!
      { "new" => fresh, "held" => rows.size }
    rescue Reach::RemoteRefused => e
      raise unless e.status == 404 || e.code == "unavailable"

      park! if e.status == 404
      { "skipped" => e.status == 404 ? "unsupported" : "switched_off" }
    end

    def park!
      Reach::StateFile.update(FILE) { |state| state["unsupported_until"] = Time.now.to_i + UNSUPPORTED_WAIT_S }
    end

    def store(rows)
      at = Reach::StateFile.now_s
      Reach::StateFile.update(FILE) do |state|
        known = items(state).to_h { |item| [item["id"], item] }
        fresh = 0
        state["items"] = rows.select { |row| row.is_a?(Hash) && row["id"].is_a?(String) }.map do |row|
          prior = known[row["id"]]
          fresh += 1 if prior.nil?
          kept = prior ? prior.slice("received_at", "shown_at", "reported_received", "reported_shown") : { "received_at" => at }
          row.slice("id", "audience", "title", "body", "sent_at").merge(kept)
        end
        state["fetched_at"] = at
        state.delete("unsupported_until")
        fresh
      end
    end

    def pending_receipts(state)
      items(state).select do |item|
        !item["reported_received"] || (item["shown_at"] && !item["reported_shown"])
      end.first(RECEIPTS_PER_POST)
    end

    def flush_receipts!
      install = Reach::Enroll.current
      return 0 unless install

      state = Reach::StateFile.read(FILE)
      return 0 if parked?(state)

      pending = pending_receipts(state)
      return 0 if pending.empty?

      receipts = pending.map { |item| { "id" => item["id"], "received_at" => item["received_at"], "shown_at" => item["shown_at"] }.compact }
      body = { "receipts" => receipts }
      response = Reach::Client.for_install(install, quiet: true).post_json(
        RECEIPTS_ROUTE, body, idempotency_key: Digest::SHA256.hexdigest(JSON.generate(body))
      )
      answered = response.json || {}
      settled = Array(answered["recorded"]) + Array(answered["unknown"])
      sent = receipts.to_h { |receipt| [receipt["id"], receipt] }
      Reach::StateFile.update(FILE) do |fresh|
        items(fresh).each do |item|
          next unless settled.include?(item["id"])

          item["reported_received"] = true
          item["reported_shown"] = true if sent.dig(item["id"], "shown_at")
        end
      end
      settled.size
    rescue Reach::RemoteRefused => e
      raise unless e.status == 404 || e.code == "unavailable"

      park! if e.status == 404
      0
    end

    def notice_text(item)
      Reach::Messages.text(
        "M-ANNOUNCE-NOTICE", sent: Reach::Messages.course_time(item["sent_at"]), title: item["title"].to_s, body: item["body"].to_s
      )
    end

    def prompt_notices
      return [] unless show?

      shown = Reach::StateFile.update(FILE) do |state|
        due = items(state).reject { |item| item["shown_at"] }.sort_by { |item| item["sent_at"].to_s }.first(PER_PROMPT)
        due.each { |item| item["shown_at"] = Reach::StateFile.now_s }
        due.map(&:dup)
      end
      return [] unless shown.is_a?(Array) && !shown.empty?

      Reach::Storage.spawn_detached(%w[announcements flush])
      shown.map { |item| notice_text(item) }
    end

    def render(rows)
      return Reach::Messages.text("M-ANNOUNCE-NONE") if rows.empty?

      rows.map do |item|
        Reach::Messages.text("M-ANNOUNCE-LINE", sent: Reach::Messages.course_time(item["sent_at"]), title: item["title"].to_s, body: item["body"].to_s)
      end.join("\n\n")
    end
  end
end
