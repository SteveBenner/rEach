require "json"
require "time"
require "rbconfig"
require "fileutils"

module Reach
  module EnrollOutbox
    SCHEMA = "reach.enroll_outbox/v1".freeze
    OPEN_ROUTE = "/api/v1/enroll/attempts".freeze
    STEPS = %w[username student_id confirmed password_chosen].freeze
    KEEP_STATUSES = [401, 403, 408, 425, 429].freeze
    CONNECT_TIMEOUT_S = 3
    READ_TIMEOUT_S = 8
    LOCK_WAIT_S = 2.0
    Attempt = Struct.new(:id, :key)

    module_function

    def file
      File.join(Reach::Paths.enroll_state_dir, "outbox.json")
    end

    def key_file
      "#{Reach::Paths.install_key_file}.attempt"
    end

    def drain_lock
      "#{file}.lock"
    end

    def edit_lock
      "#{file}.edit.lock"
    end

    def iso(time = Time.now.utc)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def read
      data = Reach::Login.read_json(file)
      data.is_a?(Hash) && data["schema"] == SCHEMA && data["entries"].is_a?(Array) ? data : nil
    end

    def write(data)
      Reach::Login.write_json(file, data.merge("schema" => SCHEMA))
    end

    def editing(&block)
      FileUtils.mkdir_p(Reach::Paths.enroll_state_dir)
      outcome = Reach::Locks.exclusive(edit_lock, wait_s: LOCK_WAIT_S, &block)
      outcome == :busy ? block.call : outcome
    end

    def key
      return nil unless File.file?(key_file)

      Reach::Crypto.load_private_key(File.read(key_file))
    rescue StandardError
      nil
    end

    def attempt_id
      data = read
      id = data && data["attempt_id"].to_s
      id.nil? || id.empty? ? nil : id
    end

    def attempt
      provisional = key
      provisional ? Attempt.new(attempt_id, provisional) : nil
    end

    def pending
      data = read
      data ? data["entries"] : []
    end

    def begin!(course_code:, teach_url:, harness:)
      provisional = Reach::Crypto.generate_install_key
      Reach::StateFile.write_atomic(key_file, provisional.to_pem)
      editing do
        write(
          "teach_url" => teach_url, "attempt_id" => nil, "errors" => [],
          "entries" => [{ "kind" => "open", "step" => "code", "course_code" => course_code, "harness" => harness.to_s, "at" => iso }]
        )
      end
      spawn_drain
      provisional
    rescue StandardError
      nil
    end

    def push_step!(step, username: nil, student_id: nil)
      return nil unless File.file?(key_file)

      entry = { "kind" => "step", "step" => step, "at" => iso }
      entry["username"] = username if username
      entry["student_id"] = student_id if student_id
      appended = editing do
        data = read
        next nil unless data

        write(data.merge("entries" => data["entries"] + [entry]))
        true
      end
      spawn_drain if appended
      appended
    rescue StandardError
      nil
    end

    def clear!
      editing do
        FileUtils.rm_f(file)
        FileUtils.rm_f(key_file)
      end
      nil
    rescue StandardError
      nil
    end

    def spawn_drain
      script = 'begin; require "reach/ca_roots"; Reach::CaRoots.apply!; rescue ScriptError, StandardError; nil; end; require "reach"; Reach::EnrollOutbox.drain!'
      lib = File.expand_path("..", __dir__)
      pid = Process.spawn(RbConfig.ruby, "-I", lib, "-e", script, in: File::NULL, out: File::NULL, err: File::NULL, **Reach::Runtime.detach_group)
      Process.detach(pid)
      pid
    rescue StandardError
      nil
    end

    def drain!
      2.times do
        outcome = Reach::Locks.exclusive(drain_lock, wait_s: 0.0) { drain_locked }
        return nil unless outcome == :empty && !pending.empty?
      end
      nil
    rescue StandardError
      nil
    end

    def drain_locked
      loop do
        data = read
        return :empty unless data && !data["entries"].empty?

        head = data["entries"].first
        provisional = key
        return :stalled unless provisional

        if head["kind"] == "open"
          step = deliver_open(data, head, provisional)
        elsif data["attempt_id"].to_s.empty?
          editing { FileUtils.rm_f(file) }
          return :stalled
        else
          step = deliver_step(data, head, provisional)
        end
        return :stalled if step == :stop
      end
    rescue Reach::Error
      :stalled
    end

    def client(data)
      Reach::Client.anonymous(data["teach_url"], connect_timeout: CONNECT_TIMEOUT_S, read_timeout: READ_TIMEOUT_S, max_retries: 0, link: false)
    end

    def attempt_client(data, provisional)
      Reach::Client.for_attempt(data["teach_url"], data["attempt_id"], provisional, connect_timeout: CONNECT_TIMEOUT_S, read_timeout: READ_TIMEOUT_S)
    end

    def deliver_open(data, head, provisional)
      body = {
        "course_code" => head["course_code"], "public_key" => provisional.public_key.to_pem, "reach_version" => Reach::VERSION,
        "harness" => head["harness"].to_s.empty? ? "unknown" : head["harness"], "platform" => Reach::Enroll.platform
      }
      reply = client(data).post_json(OPEN_ROUTE, body).json
      id = reply.is_a?(Hash) ? reply["attempt_id"].to_s : ""
      return :stop if id.empty?

      advance(head) { |held| held.merge("attempt_id" => id) }
      :next
    rescue Reach::RemoteRefused => e
      refused(e, head, wipe: true)
    rescue Reach::Error
      :stop
    end

    def deliver_step(data, head, provisional)
      body = { "step" => head["step"], "at" => head["at"] }
      body["username"] = head["username"] if head["username"]
      body["student_id"] = head["student_id"] if head["student_id"]
      attempt_client(data, provisional).post_json("#{OPEN_ROUTE}/#{data["attempt_id"]}/steps", body)
      advance(head) { |held| held }
      :next
    rescue Reach::RemoteRefused => e
      refused(e, head, wipe: false)
    rescue Reach::Error
      :stop
    end

    def advance(head)
      editing do
        held = read
        next nil unless held

        rest = held["entries"]
        rest = rest.drop(1) if rest.first && rest.first["at"] == head["at"] && rest.first["step"] == head["step"]
        write(yield(held).merge("entries" => rest))
      end
    end

    def refused(error, head, wipe:)
      return :stop if KEEP_STATUSES.include?(error.status) || error.status.to_i >= 500

      record = { "step" => head["step"], "code" => error.code, "status" => error.status, "at" => iso }
      if error.code == "attempt_completed"
        editing { FileUtils.rm_f(file) }
        return :stop
      end

      editing do
        held = read
        next nil unless held

        rest = held["entries"]
        rest = wipe ? [] : rest.drop(1)
        write(held.merge("entries" => rest, "errors" => (Array(held["errors"]) + [record]).last(20)))
      end
      :next
    end
  end
end
