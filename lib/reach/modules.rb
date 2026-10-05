require "json"
require "time"
require "base64"
require "fileutils"
require "securerandom"

module Reach
  module Modules
    SCHEMA = "teach.module-assignment/v1".freeze
    PENDING_SCHEMA = "reach.module-selection/v1".freeze
    OPTIONS_SCHEMA = "reach.module-options/v1".freeze
    ROUTE = "/api/v1/modules".freeze
    SELECT_ROUTE = "/api/v1/modules/selection".freeze

    module_function

    def dir
      File.join(Reach::Paths.state_dir, "modules")
    end

    def current_path
      File.join(dir, "current.json")
    end

    def history_dir
      File.join(dir, "history")
    end

    def pending_path
      File.join(dir, "pending.json")
    end

    def options_path
      File.join(dir, "options.json")
    end

    def current
      record = Reach::Login.read_json(current_path)
      return nil unless record.is_a?(Hash)

      verify!(record, refresh: false)
      record
    rescue StandardError
      nil
    end

    def module_ids
      record = current
      record ? Array(record["modules"]).map(&:to_s) : []
    end

    def allows?(cutout_id)
      record = current
      return true unless record

      module_ids.include?(cutout_id.to_s.split(".").first.to_s)
    end

    def verify!(record, refresh: true)
      raise Reach::VerificationFailed, "reach: module record is malformed" unless record.is_a?(Hash)
      raise Reach::VerificationFailed, "reach: module record carries no signature" unless record["signature"]
      raise Reach::VerificationFailed, "reach: module record has the wrong schema" unless record["schema"] == SCHEMA

      install = Reach::Enroll.current
      raise Reach::VerificationFailed, "reach: module record is for a different student" unless install && record["student_id"] == install["student_id"]

      unsigned = record.reject { |key, _| key == "signature" }
      signable = Reach::Crypto.canonical_json(unsigned)
      public_key = signer_public_key_for(record["signing_key_id"], refresh)
      valid = begin
        public_key && Reach::Crypto.verify_pss(public_key, Base64.strict_decode64(record["signature"]), signable)
      rescue ArgumentError
        false
      end
      raise Reach::VerificationFailed, "reach: module record signature does not verify" unless valid

      record
    end

    def store!(record)
      verify!(record)
      FileUtils.mkdir_p(history_dir)
      Reach::Login.write_json(File.join(history_dir, "#{record['record_id']}.json"), record)
      stored = Reach::Login.read_json(current_path)
      if !stored.is_a?(Hash) || record["version"].to_i > stored["version"].to_i
        Reach::Login.write_json(current_path, record)
      end
      record
    end

    def refresh!(quick: false)
      install = Reach::Enroll.current
      return nil unless install

      response = Reach::Client.for_install(install, quick: quick).get(ROUTE)
      body = response.json
      return nil unless body.is_a?(Hash)

      records = Array(body["history"]).select { |item| item.is_a?(Hash) }
      records << body["current"] if body["current"].is_a?(Hash) && records.none? { |item| item["record_id"] == body["current"]["record_id"] }
      records.sort_by { |item| item["version"].to_i }.each { |item| store!(item) }
      write_options(body)
      begin
        flush_pending!
      rescue Reach::Refused, Reach::VerificationFailed
        nil
      end
      body
    rescue Reach::RemoteRefused => e
      return nil if e.code == "not_found"

      raise
    end

    def write_options(body)
      Reach::Login.write_json(
        options_path,
        "schema" => OPTIONS_SCHEMA, "student_id" => Reach::Login.enrolled_id, "mode" => body["mode"],
        "count" => body["count"], "options" => Array(body["options"]), "window" => body["window"],
        "open" => body["open"] == true, "full" => Array(body["full"]),
        "fetched_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      )
    end

    def options_data
      data = Reach::Login.read_json(options_path)
      data.is_a?(Hash) && data["student_id"] == Reach::Login.enrolled_id ? data : nil
    end

    def names(ids)
      titles = {}
      data = options_data
      Array(data && data["options"]).each do |option|
        titles[option["id"].to_s] = option["title"].to_s if option.is_a?(Hash) && !option["title"].to_s.empty?
      end
      join_names(Array(ids).map { |id| titles[id.to_s] || id.to_s })
    end

    def join_names(list)
      list = Array(list).map(&:to_s)
      return list.first.to_s if list.length <= 1

      "#{list[0..-2].join(', ')} and #{list.last}"
    end

    def summary_text
      text = base_summary_text
      open = Reach::Consent.open_notice
      open ? "#{text}\n\n#{open['text']}" : text
    end

    def open_question
      Reach::Consent.open_notice
    end

    def base_summary_text
      begin
        refresh!(quick: true)
      rescue Reach::NetworkError, Reach::RemoteRefused
        nil
      end
      record = current
      data = options_data
      return Reach::Messages.text("M-MODULES-CURRENT", modules: names(record["modules"])) if record

      if data && data["mode"] == "student_choice"
        return Reach::Messages.text("M-MODULES-CLOSED") unless data["open"]

        closes = data["window"].is_a?(Hash) ? Reach::Messages.course_time(data["window"]["closes_at"]) : ""
        if closes.to_s.empty?
          return Reach::Messages.text("M-MODULES-OPTIONS-OPEN", count: data["count"], options: join_names(option_titles(data)))
        end

        return Reach::Messages.text(
          "M-MODULES-OPTIONS", count: data["count"], closes: closes, options: join_names(option_titles(data))
        )
      end

      Reach::Messages.text("M-MODULES-NONE")
    end

    def option_titles(data, skip: [])
      Array(data["options"]).select { |option| option.is_a?(Hash) && !skip.include?(option["id"].to_s) }.map do |option|
        option["title"].to_s.empty? ? option["id"].to_s : option["title"].to_s
      end
    end

    def choose!(modules, quick: false, session_id: nil)
      session_id = Reach::Login.current_session_id if session_id.to_s.empty?
      Reach::Login.require_active!(session_id: session_id)
      data = nil
      begin
        refresh!(quick: quick)
        data = options_data
      rescue Reach::NetworkError
        data = options_data
      end

      if current
        return { "state" => "refused", "text" => Reach::Messages.text("M-MODULES-ALREADY", modules: names(module_ids)) }
      end
      unless data && data["mode"] == "student_choice" && data["open"]
        return { "state" => "closed", "text" => Reach::Messages.text("M-MODULES-CLOSED") }
      end

      count = data["count"].to_i.positive? ? data["count"].to_i : 2
      chosen = resolve_choice(modules, data)
      if chosen.nil? || chosen.length != count
        return { "state" => "invalid", "text" => Reach::Messages.text("M-MODULES-INVALID", count: count, options: join_names(option_titles(data))) }
      end

      full = chosen & Array(data["full"]).map(&:to_s)
      unless full.empty?
        return {
          "state" => "full",
          "text" => Reach::Messages.text("M-MODULES-FULL", module: names([full.first]), options: join_names(option_titles(data, skip: Array(data["full"]).map(&:to_s))))
        }
      end

      subject = { "modules" => chosen }
      if Reach::Consent.declined?(kind: "module_lock", subject: subject)
        Reach::Consent.clear_declined!(kind: "module_lock", subject: subject)
        return { "state" => "declined", "text" => Reach::Messages.text("M-CONSENT-DECLINED") }
      end

      consent = Reach::Consent.take!(kind: "module_lock", subject: subject)
      unless consent
        question = Reach::Consent.ask!(kind: "module_lock", subject: subject, message_id: "M-MODULES-LOCK-ASK", fields: { modules: names(chosen) }, replay: {}, session_id: session_id)
        return { "state" => "asked", "text" => Reach::Messages.text("M-CONSENT-NEEDED", question: question) }
      end

      write_pending(chosen, consent)
      outcome = send_pending(quick: quick)
      case outcome[:state]
      when :locked
        spawn_sync
        { "state" => "locked", "text" => Reach::Messages.text("M-MODULES-LOCKED", modules: names(outcome[:record]["modules"])) }
      when :already
        { "state" => "refused", "text" => Reach::Messages.text("M-MODULES-ALREADY", modules: names(module_ids)) }
      else
        { "state" => "queued", "text" => Reach::Messages.text("M-MODULES-PENDING") }
      end
    end

    def spawn_sync
      pid = Process.spawn(RbConfig.ruby, Reach::Runtime.exe_path, "sync", in: File::NULL, out: File::NULL, err: File::NULL, **Reach::Runtime.detach_group)
      Process.detach(pid)
    rescue StandardError
      nil
    end

    def resolve_choice(modules, data)
      options = Array(data["options"]).select { |option| option.is_a?(Hash) }
      resolved = Array(modules).map do |raw|
        needle = raw.to_s.strip.downcase
        match = options.find { |option| option["id"].to_s.downcase == needle } ||
                options.find { |option| option["title"].to_s.downcase == needle }
        match && match["id"].to_s
      end
      return nil if resolved.any?(&:nil?)

      resolved.uniq.sort
    end

    def write_pending(chosen, consent)
      body = {
        "schema" => PENDING_SCHEMA, "modules" => chosen, "consent" => consent,
        "idempotency_key" => SecureRandom.uuid, "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "student_id" => Reach::Login.enrolled_id
      }
      Reach::Login.write_json(pending_path, body.merge("signature" => sign_pending(body)))
    end

    def sign_pending(body)
      key = Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
      Base64.strict_encode64(Reach::Crypto.sign_pss(key, Reach::Crypto.canonical_json(body)))
    end

    def pending_valid?(pending)
      return false unless pending.is_a?(Hash) && pending["signature"] && pending["student_id"] == Reach::Login.enrolled_id

      body = pending.reject { |key, _| key == "signature" }
      key = Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
      Reach::Crypto.verify_pss(key.public_key, Base64.strict_decode64(pending["signature"]), Reach::Crypto.canonical_json(body))
    rescue StandardError
      false
    end

    def flush_pending!
      pending = Reach::Login.read_json(pending_path)
      return nil unless pending.is_a?(Hash)

      outcome = send_pending
      outcome[:record]
    end

    def send_pending(quick: false)
      pending = Reach::Login.read_json(pending_path)
      return { state: :queued, record: nil } unless pending_valid?(pending)

      install = Reach::Enroll.current
      body = { "modules" => pending["modules"], "consent" => pending["consent"], "client_created_at" => pending["created_at"] }
      begin
        response = Reach::Client.for_install(install, quick: quick).post_json(SELECT_ROUTE, body, idempotency_key: pending["idempotency_key"])
      rescue Reach::Offline, Reach::NetworkError
        return { state: :queued, record: nil }
      rescue Reach::RemoteRefused => e
        FileUtils.rm_f(pending_path) unless e.code == "rate_limited"
        if e.code == "conflict"
          begin
            refresh!(quick: quick)
          rescue Reach::NetworkError
            nil
          end
          return { state: :already, record: current } if current
        end
        raise Reach::Refused, e.message
      end

      record = response.json
      store!(record)
      FileUtils.rm_f(pending_path) if Array(record["modules"]).map(&:to_s).sort == Array(pending["modules"]).map(&:to_s).sort
      { state: :locked, record: record }
    end

    def signer_public_key_for(key_id, refresh)
      key = lookup_key(key_id)
      return Reach::Crypto.load_public_key(key["pem"]) if key
      return nil unless refresh

      Reach::Sync.refresh_status(quick: false)
      key = lookup_key(key_id)
      key ? Reach::Crypto.load_public_key(key["pem"]) : nil
    rescue StandardError
      nil
    end

    def lookup_key(key_id)
      install = Reach::Enroll.current
      return nil unless install

      Array(install["signing_public_keys"]).find { |item| item.is_a?(Hash) && item["key_id"] == key_id }
    end
  end
end
