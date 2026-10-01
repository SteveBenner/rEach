require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Transfer
    ROUTE = "/api/v1/transfers".freeze
    POLL_INTERVAL_S = 60
    OFF_HOURS = 24
    NOTE_LIMIT = 2000
    PROMPT_LIMIT = 1500
    PROMPT_WINDOW_S = 1800

    module_function

    def path
      File.join(Reach::Paths.state_dir, "transfer.json")
    end

    def stored
      data = Reach::Login.read_json(path)
      data.is_a?(Hash) && data["student_id"] == Reach::Login.enrolled_id ? data : nil
    end

    def current
      data = stored
      data && data["state"] == "pending" ? data : nil
    end

    def save(data)
      Reach::Login.write_json(path, data.merge("student_id" => Reach::Login.enrolled_id))
    end

    def request!(modules:, note: nil, quick: false)
      Reach::Login.require_active!
      previous = stored
      now = Time.now.utc

      if previous && previous["off_until"] && Time.iso8601(previous["off_until"]) > now
        return { "state" => "off", "text" => Reach::Messages.text("M-TRANSFER-OFF") }
      end

      wanted = resolve(modules)
      if !wanted.empty? && wanted == Reach::Modules.module_ids.sort
        return { "state" => "same", "text" => Reach::Messages.text("M-TRANSFER-SAME") }
      end
      if previous && previous["state"] == "pending"
        return { "state" => "open", "text" => Reach::Messages.text("M-TRANSFER-OPEN", when: Reach::Messages.course_time(previous["created_at"])) }
      end
      raise Reach::Refused, Reach::Messages.text("M-MODULES-INVALID", count: expected_count, options: Reach::Modules.join_names(option_titles)) if wanted.empty?

      subject = { "modules" => wanted }
      if Reach::Consent.declined?(kind: "transfer_request", subject: subject)
        Reach::Consent.clear_declined!(kind: "transfer_request", subject: subject)
        return { "state" => "declined", "text" => Reach::Messages.text("M-CONSENT-DECLINED") }
      end

      consent = Reach::Consent.take!(kind: "transfer_request", subject: subject)
      unless consent
        question = Reach::Consent.ask!(kind: "transfer_request", subject: subject, message_id: "M-TRANSFER-ASK", fields: { modules: Reach::Modules.names(wanted) }, replay: { "note" => note })
        return { "state" => "asked", "text" => Reach::Messages.text("M-CONSENT-NEEDED", question: question) }
      end

      body = { "modules" => wanted, "consent" => consent, "client_created_at" => iso(now) }
      composed = compose_note(note)
      body["note"] = composed unless composed.empty?
      submit(body, wanted, now, quick: quick)
    end

    def submit(body, wanted, now, quick: false)
      key = SecureRandom.uuid
      record = { "transfer_id" => nil, "state" => "pending", "modules" => wanted, "created_at" => iso(now),
                 "last_polled_at" => nil, "reply" => nil, "announced" => false, "request" => body, "idempotency_key" => key }
      save(record)
      outcome = post_request(record, quick: quick)
      sent_text = Reach::Messages.text("M-TRANSFER-SENT", modules: Reach::Modules.names(wanted), current: Reach::Modules.names(Reach::Modules.module_ids))
      case outcome
      when :sent
        { "state" => "sent", "text" => sent_text }
      when :queued
        { "state" => "queued", "text" => sent_text }
      when :open
        { "state" => "open", "text" => Reach::Messages.text("M-TRANSFER-OPEN", when: Reach::Messages.course_time(iso(now))) }
      else
        { "state" => "off", "text" => Reach::Messages.text("M-TRANSFER-OFF") }
      end
    end

    def post_request(record, quick: false)
      install = Reach::Enroll.current
      response = Reach::Client.for_install(install, quick: quick).post_json(ROUTE, record["request"], idempotency_key: record["idempotency_key"])
      result = response.json || {}
      save(record.merge("transfer_id" => result["transfer_id"], "request" => nil, "idempotency_key" => nil))
      :sent
    rescue Reach::Offline, Reach::NetworkError
      :queued
    rescue Reach::RemoteRefused => e
      if e.code == "forbidden"
        save("off_until" => iso(Time.now.utc + (OFF_HOURS * 3600)), "state" => "closed")
        return :off
      end
      if e.code == "conflict"
        save(record.merge("request" => nil, "idempotency_key" => nil, "transfer_id" => nil, "state" => "pending"))
        return :open
      end
      save("state" => "closed")
      raise Reach::Refused, e.message
    end

    def flush_queued!
      data = stored
      return nil unless data && data["state"] == "pending" && data["transfer_id"].nil? && data["request"]

      outcome = post_request(data)
      outcome == :sent ? stored : nil
    end

    def poll!(quick: false)
      begin
        flush_queued!
      rescue Reach::Refused
        nil
      end
      data = current
      return nil unless data && data["transfer_id"]

      if data["last_polled_at"]
        return nil if Time.now.utc - Time.iso8601(data["last_polled_at"]) < POLL_INTERVAL_S
      end

      save(data.merge("last_polled_at" => iso(Time.now.utc)))
      response = Reach::Client.for_install(Reach::Enroll.current, quick: quick).get("#{ROUTE}/#{data['transfer_id']}")
      body = response.json || {}
      case body["state"]
      when "approved"
        record = body["module_record"]
        Reach::Modules.store!(record) if record.is_a?(Hash)
        save(data.merge("state" => "approved", "reply" => body["reply"], "announced" => false, "last_polled_at" => iso(Time.now.utc)))
        Reach::Messages.text("M-TRANSFER-APPROVED", modules: Reach::Modules.names(Reach::Modules.module_ids))
      when "denied"
        save(data.merge("state" => "denied", "reply" => body["reply"], "announced" => false, "last_polled_at" => iso(Time.now.utc)))
        denied_text(body["reply"])
      when "withdrawn"
        save(data.merge("state" => "withdrawn", "announced" => true, "last_polled_at" => iso(Time.now.utc)))
        nil
      end
    rescue Reach::Offline, Reach::NetworkError
      nil
    rescue Reach::RemoteRefused => e
      raise unless e.code == "not_found"

      nil
    end

    def denied_text(reply)
      text = reply.is_a?(Hash) ? reply["text"].to_s : reply.to_s
      Reach::Messages.text("M-TRANSFER-DENIED", modules: Reach::Modules.names(Reach::Modules.module_ids), reply: text)
    end

    def announcement!
      data = stored
      return nil unless data && !data["announced"] && %w[approved denied].include?(data["state"])

      text = if data["state"] == "approved"
               Reach::Messages.text("M-TRANSFER-APPROVED", modules: Reach::Modules.names(Reach::Modules.module_ids))
             else
               denied_text(data["reply"])
             end
      save(data.merge("announced" => true))
      text
    end

    def mark_announced!
      data = stored
      save(data.merge("announced" => true)) if data && !data["announced"] && %w[approved denied].include?(data["state"])
      nil
    end

    def status_text
      data = stored
      return nil unless data && %w[pending approved denied].include?(data["state"])

      case data["state"]
      when "pending"
        Reach::Messages.text("M-TRANSFER-OPEN", when: Reach::Messages.course_time(data["created_at"]))
      when "approved"
        Reach::Messages.text("M-TRANSFER-APPROVED", modules: Reach::Modules.names(Reach::Modules.module_ids))
      else
        denied_text(data["reply"])
      end
    end

    def resolve(modules)
      data = Reach::Modules.options_data
      options = Array(data && data["options"]).select { |option| option.is_a?(Hash) }
      Array(modules).map do |raw|
        needle = raw.to_s.strip
        match = options.find { |option| option["id"].to_s.downcase == needle.downcase } ||
                options.find { |option| option["title"].to_s.downcase == needle.downcase }
        match ? match["id"].to_s : needle
      end.reject(&:empty?).uniq.sort
    end

    def expected_count
      data = Reach::Modules.options_data
      count = data && data["count"].to_i
      count && count.positive? ? count : 2
    end

    def option_titles
      data = Reach::Modules.options_data
      data ? Reach::Modules.option_titles(data) : []
    end

    def compose_note(agent_note)
      said = latest_student_text
      parts = []
      parts << "Student said: #{said}" if said
      parts << "Agent note: #{agent_note}" unless agent_note.to_s.strip.empty?
      cut(parts.join("\n"), NOTE_LIMIT)
    end

    def latest_student_text
      dir = Reach::Paths.transcripts_dir
      return nil unless File.directory?(dir)

      cutoff = Time.now.utc - PROMPT_WINDOW_S
      enrolled = Reach::Login.enrolled_id
      best = nil
      Dir.glob(File.join(dir, "*.jsonl")).each do |file|
        next if file.end_with?(".rejected.jsonl")

        File.foreach(file) do |line|
          entry = begin
            JSON.parse(line)
          rescue JSON::ParserError
            next
          end
          next unless entry.is_a?(Hash) && entry["kind"] == "prompt" && entry["gate"] == "allowed"
          next unless entry["student_id"].nil? || entry["student_id"] == enrolled

          text = entry["text"].to_s
          next if text.strip.empty? || Reach::Login.yes?(text) || Reach::Login.no?(text)

          at = Time.iso8601(entry["at"].to_s) rescue nil
          next unless at && at >= cutoff
          best = { at: at, text: text } if best.nil? || at >= best[:at]
        end
      end
      best && cut(best[:text], PROMPT_LIMIT)
    rescue StandardError
      nil
    end

    def cut(text, limit)
      value = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      return value if value.bytesize <= limit

      value.byteslice(0, limit).scrub("")
    end

    def iso(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
