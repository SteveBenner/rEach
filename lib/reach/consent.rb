require "json"
require "time"
require "fileutils"
require "rbconfig"

module Reach
  module Consent
    SCHEMA = "reach.consent/v1".freeze
    KINDS = %w[module_lock transfer_request submission compaction export_import live_session live_action live_send codex_setup].freeze
    WINDOW_S = 1800
    WIRE_KEYS = %w[kind subject_digest message_id answer session_id seq digest asked_at answered_at].freeze

    module_function

    def dir
      File.join(Reach::Paths.state_dir, "consent")
    end

    def pending_path
      File.join(dir, "pending.json")
    end

    def answered_path
      File.join(dir, "answered.jsonl")
    end

    def digest(subject)
      Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(subject))
    end

    def yes?(text)
      Reach::Login.yes?(text)
    end

    def no?(text)
      Reach::Login.no?(text)
    end

    def ask!(kind:, subject:, message_id:, fields: {}, replay: {})
      question = Reach::Messages.text(message_id, **fields.each_with_object({}) { |(key, value), memo| memo[key.to_sym] = value }).strip
      Reach::Login.write_json(
        pending_path,
        "schema" => SCHEMA, "kind" => kind.to_s, "subject" => subject, "subject_digest" => digest(subject),
        "message_id" => message_id.to_s, "question" => question, "asked_at" => iso(Time.now.utc),
        "student_id" => Reach::Login.enrolled_id, "replay" => replay
      )
      question
    end

    def observe(entry)
      return nil unless entry.is_a?(Hash) && entry["gate"] == "allowed"
      return nil unless Reach::Login.session_confirmed?(entry["session_id"])

      capture(entry)
    rescue StandardError
      nil
    end

    def observe_blocked(entry, kinds:)
      return nil unless entry.is_a?(Hash) && entry["gate"] == "blocked"

      capture(entry, kinds: kinds)
    rescue StandardError
      nil
    end

    def capture(entry, kinds: nil)
      pending = Reach::Login.read_json(pending_path)
      return nil unless pending.is_a?(Hash) && pending["student_id"] == Reach::Login.enrolled_id
      return nil if kinds && !kinds.include?(pending["kind"])

      now = Time.now.utc
      return nil if now - Time.iso8601(pending["asked_at"]) > WINDOW_S

      text = entry["text"]
      answer = if yes?(text)
                 "yes"
               elsif no?(text)
                 "no"
               end
      return nil unless answer

      record = {
        "kind" => pending["kind"], "subject_digest" => pending["subject_digest"], "message_id" => pending["message_id"],
        "answer" => answer, "session_id" => entry["session_id"], "seq" => entry["seq"], "digest" => entry["digest"],
        "asked_at" => pending["asked_at"], "answered_at" => iso(now), "used_at" => nil,
        "student_id" => Reach::Login.enrolled_id
      }
      record["gate"] = "blocked" if entry["gate"] == "blocked"
      FileUtils.mkdir_p(dir)
      File.open(answered_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |file| file.puts(JSON.generate(record)) }
      FileUtils.rm_f(pending_path)
      record.merge("subject" => pending["subject"], "replay" => pending["replay"] || {})
    end

    def follow_up!(observed)
      subject = observed["subject"] || {}
      replay = observed["replay"] || {}
      return Reach::Live.follow_up!(observed) if Reach::Live::KINDS.include?(observed["kind"])

      if observed["kind"] == "submission"
        return observed["answer"] == "yes" ? Reach::Messages.text("M-SUBMIT-YES-AGENT", slice_id: replay["slice_id"]) : Reach::Messages.text("M-CONSENT-DECLINED")
      end

      if observed["kind"] == "compaction"
        return observed["answer"] == "yes" ? Reach::Messages.text("M-STORAGE-COMPACT-YES-AGENT") : Reach::Messages.text("M-STORAGE-COMPACT-DECLINED")
      end

      return Reach::CodexSetup.follow_up!(observed) if observed["kind"] == Reach::CodexSetup::KIND

      if observed["kind"] == "export_import"
        return observed["answer"] == "yes" ? Reach::Messages.text("M-IMPORT-YES-AGENT", path_hint: replay["path"], mode: replay["mode"]) : Reach::Messages.text("M-IMPORT-DECLINED")
      end

      result = case observed["kind"]
               when "transfer_request"
                 Reach::Transfer.request!(modules: subject["modules"], note: replay["note"], quick: true)
               when "module_lock"
                 Reach::Modules.choose!(subject["modules"], quick: true)
               end
      spawn_flush(observed["kind"]) if result.is_a?(Hash) && result["state"] == "queued"
      result.is_a?(Hash) ? result["text"] : nil
    rescue Reach::Refused => e
      e.message
    rescue StandardError
      nil
    end

    def agent_context(observed, done)
      return done if %w[submission compaction export_import].include?(observed["kind"]) && observed["answer"] == "yes"
      return Reach::Live.agent_context(observed, done) if Reach::Live::KINDS.include?(observed["kind"])

      Reach::Messages.text("M-CONSENT-DONE", answer: observed["answer"], text: done)
    end

    def take!(kind:, subject:)
      target = digest(subject)
      records = read_all
      now = Time.now.utc
      index = nil
      records.each_with_index do |record, position|
        next unless matches?(record, kind, target, now)
        next unless record["answer"] == "yes" && record["used_at"].nil?

        index = position
      end
      return nil unless index

      chosen = records[index]
      chosen["used_at"] = iso(now)
      write_all(records)
      WIRE_KEYS.each_with_object({}) { |key, memo| memo[key] = chosen[key] }
    rescue StandardError
      nil
    end

    def spawn_flush(kind)
      command = kind == "module_lock" ? %w[modules --flush] : %w[transfer --flush]
      exe = File.expand_path("../../exe/reach", __dir__)
      pid = Process.spawn(RbConfig.ruby, exe, *command, in: File::NULL, out: File::NULL, err: File::NULL, **Reach::Runtime.detach_group)
      Process.detach(pid)
    rescue StandardError
      nil
    end

    def declined?(kind:, subject:)
      target = digest(subject)
      now = Time.now.utc
      latest = read_all.select { |record| matches?(record, kind, target, now) }.last
      !latest.nil? && latest["answer"] == "no" && latest["used_at"].nil?
    rescue StandardError
      false
    end

    def clear_declined!(kind:, subject:)
      target = digest(subject)
      now = Time.now.utc
      records = read_all
      records.each do |record|
        record["used_at"] = iso(now) if matches?(record, kind, target, now) && record["answer"] == "no" && record["used_at"].nil?
      end
      write_all(records)
      nil
    rescue StandardError
      nil
    end

    def matches?(record, kind, target, now)
      return false unless record["kind"] == kind.to_s && record["subject_digest"] == target
      return false unless record["student_id"] == Reach::Login.enrolled_id

      now - Time.iso8601(record["answered_at"]) <= WINDOW_S
    rescue ArgumentError, TypeError
      false
    end

    def read_all
      return [] unless File.file?(answered_path)

      File.readlines(answered_path).map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end.compact
    end

    def write_all(records)
      FileUtils.mkdir_p(dir)
      tmp = "#{answered_path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        records.each { |record| file.puts(JSON.generate(record)) }
      end
      File.rename(tmp, answered_path)
    end

    def iso(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
