require "json"
require "time"
require "fileutils"

module Reach
  module LateWork
    DEFAULT_NOTICE_EVERY = 10
    SPAWN_GAP_S = 120
    SENDING_STALE_S = 600
    MAX_ATTEMPTS = 5
    SESSIONS_KEPT = 50
    WORK = "late_work".freeze
    SUBMISSION = "late_submission".freeze
    GIVE_UP_CODES = %w[hands_disabled].freeze
    GIVE_UP_STATUSES = [400].freeze

    module_function

    def settings
      section = Reach::Runtime.load_config["late_work"]
      section.is_a?(Hash) ? section : {}
    rescue StandardError
      {}
    end

    def allow?
      settings["allow"] != false
    end

    def notice_every
      value = settings["notice_every"]
      value.is_a?(Integer) && value.positive? ? value : DEFAULT_NOTICE_EVERY
    end

    def parse_time(value)
      return nil if value.to_s.strip.empty?

      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def due_for_meta(meta)
      meta = {} unless meta.is_a?(Hash)
      current = Reach::Pace.current_assignment
      if current && current["id"].to_s == meta["assignment"].to_s
        return parse_time(current["due"])
      end

      parse_time(meta["due"])
    end

    def due_for(workspace)
      due_for_meta(Reach::Workspace.metadata(workspace))
    rescue StandardError
      nil
    end

    def late?(workspace)
      return false if workspace.nil?

      due = due_for(workspace)
      !due.nil? && Reach::Pace.server_now >= due
    rescue StandardError
      false
    end

    def active?(workspace)
      allow? && late?(workspace)
    end

    def ingest_receipts(meta)
      Reach::Receipts.list.select do |receipt|
        receipt["kind"] == "ingest" && receipt["cutout_id"] == meta["cutout_id"] && receipt["slice"] == meta["slice"] && receipt["assignment"] == meta["assignment"]
      end
    rescue StandardError
      []
    end

    def info(workspace)
      meta = Reach::Workspace.metadata(workspace)
      due = due_for_meta(meta)
      late = !due.nil? && Reach::Pace.server_now >= due
      receipts = ingest_receipts(meta)
      on_record = !receipts.empty?
      {
        "late" => late,
        "assignment" => meta["assignment"],
        "slice" => meta["slice"],
        "due" => due && due.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "late_by_s" => late ? (Reach::Pace.server_now - due).to_i : 0,
        "how_late" => late ? how_late(Reach::Pace.server_now - due) : nil,
        "submitted_before_due" => receipts.any? { |receipt| receipt["late"] == false },
        "on_record" => on_record,
        "can_submit" => !on_record || !late
      }
    end

    def how_late(seconds)
      seconds = seconds.to_i
      if seconds < 60
        Reach::Messages.text("M-LATE-HOW-LESS")
      elsif seconds < 3600
        minutes = seconds / 60
        Reach::Messages.text(minutes == 1 ? "M-LATE-HOW-MINUTE" : "M-LATE-HOW-MINUTES", count: minutes)
      elsif seconds < 86_400
        hours = seconds / 3600
        Reach::Messages.text(hours == 1 ? "M-LATE-HOW-HOUR" : "M-LATE-HOW-HOURS", count: hours)
      else
        days = seconds / 86_400
        Reach::Messages.text(days == 1 ? "M-LATE-HOW-DAY" : "M-LATE-HOW-DAYS", count: days)
      end
    end

    def submit_sentence(details)
      if details["can_submit"]
        Reach::Messages.text("M-LATE-CAN-SUBMIT")
      elsif details["submitted_before_due"]
        Reach::Messages.text("M-LATE-CANNOT-SUBMIT-ONTIME")
      else
        Reach::Messages.text("M-LATE-CANNOT-SUBMIT")
      end
    end

    def notice_text(workspace)
      details = info(workspace)
      return nil unless allow? && details["late"]

      Reach::Messages.text(
        "M-LATE-NOTICE",
        slice: details["slice"], assignment: details["assignment"], due: Reach::Messages.course_time(details["due"]),
        how_late: details["how_late"], submit: submit_sentence(details)
      )
    rescue StandardError
      nil
    end

    def hello_line(workspace)
      text = notice_text(workspace)
      text ? "- #{text}" : nil
    end

    def status_text(workspace)
      details = info(workspace)
      return nil unless details["late"]

      Reach::Messages.text(
        "M-LATE-STATUS",
        how_late: details["how_late"], due: Reach::Messages.course_time(details["due"]), submit: submit_sentence(details)
      )
    rescue StandardError
      nil
    end

    def prompt_notice(session_id)
      workspace = Reach::Gate.current_workspace_path
      return nil unless workspace && active?(workspace)

      count = bump_prompt_count("#{session_id}|#{File.basename(workspace)}")
      return nil unless count == 1 || ((count - 1) % notice_every).zero?

      notice_text(workspace)
    rescue StandardError
      nil
    end

    def state_file(name)
      File.join(Reach::Paths.state_dir, name)
    end

    def read_json(path)
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(data))
        file.flush
        file.fsync
      end
      File.rename(tmp, path)
    end

    def with_state(name)
      path = state_file(name)
      FileUtils.mkdir_p(File.dirname(path))
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        state = read_json(path)
        before = JSON.generate(state)
        result = yield(state)
        write_json(path, state) unless JSON.generate(state) == before
        result
      end
    end

    def bump_prompt_count(key)
      with_state("late-prompts.json") do |state|
        counts = state["counts"].is_a?(Hash) ? state["counts"] : {}
        order = state["order"].is_a?(Array) ? state["order"] : []
        counts[key] = counts[key].to_i + 1
        order.delete(key)
        order << key
        while order.length > SESSIONS_KEPT
          counts.delete(order.shift)
        end
        state["counts"] = counts
        state["order"] = order
        counts[key]
      end
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def recent?(value, seconds)
      stamp = parse_time(value)
      !stamp.nil? && Time.now.utc - stamp < seconds
    end

    def spawn_args(assignment, key)
      args = ["hand", "late", "--assignment", assignment.to_s]
      args.concat(["--type", SUBMISSION]) if key == SUBMISSION
      args
    end

    def due_to_spawn?(entry)
      return false unless entry.is_a?(Hash) && entry["state"] == "pending"
      return false if recent?(entry["spawned_at"], SPAWN_GAP_S)
      return false if entry["sending_since"] && recent?(entry["sending_since"], SENDING_STALE_S)

      true
    end

    def spawn_for(assignment, key, entry)
      entry["spawned_at"] = now_s
      Reach::Storage.spawn_detached(spawn_args(assignment, key))
    end

    def note_write(workspace)
      return nil unless allow? && late?(workspace)

      meta = Reach::Workspace.metadata(workspace)
      assignment = meta["assignment"].to_s
      return nil if assignment.empty?

      created = false
      with_state("late-hands.json") do |state|
        entry_set = state[assignment].is_a?(Hash) ? state[assignment] : {}
        entry = entry_set[WORK]
        if entry.nil?
          entry = { "state" => "pending", "workspace" => workspace, "slice" => meta["slice"], "recorded_at" => now_s, "attempts" => 0 }
          entry_set[WORK] = entry
          created = true
        end
        spawn_for(assignment, WORK, entry) if due_to_spawn?(entry)
        state[assignment] = entry_set
      end
      Reach::Debug.emit("gate", "check" => "late_write", "outcome" => "allow") if created
      nil
    rescue StandardError
      nil
    end

    def note_receipt(receipt)
      return nil unless receipt.is_a?(Hash) && receipt["kind"] == "ingest" && receipt["late"] == true

      assignment = receipt["assignment"].to_s
      return nil if assignment.empty?

      workspace = Reach::Workspace.find(cutout_id: receipt["cutout_id"], slice: receipt["slice"])
      with_state("late-hands.json") do |state|
        entry_set = state[assignment].is_a?(Hash) ? state[assignment] : {}
        next if entry_set[SUBMISSION]

        entry = { "state" => workspace ? "pending" : "given_up", "workspace" => workspace, "slice" => receipt["slice"], "recorded_at" => now_s, "attempts" => 0 }
        entry["reason"] = "no_workspace" unless workspace
        entry_set[SUBMISSION] = entry
        spawn_for(assignment, SUBMISSION, entry) if due_to_spawn?(entry)
        state[assignment] = entry_set
      end
      nil
    rescue StandardError
      nil
    end

    def session_start
      spawned = false
      with_state("late-hands.json") do |state|
        state.each do |assignment, entry_set|
          next unless entry_set.is_a?(Hash)

          [WORK, SUBMISSION].each do |key|
            entry = entry_set[key]
            next if spawned || !due_to_spawn?(entry)

            spawn_for(assignment, key, entry)
            spawned = true
          end
        end
      end
      nil
    rescue StandardError
      nil
    end

    def send_hand(assignment:, type: WORK)
      key = type.to_s == SUBMISSION ? SUBMISSION : WORK
      claimed = nil
      with_state("late-hands.json") do |state|
        entry = state.dig(assignment, key)
        next unless entry.is_a?(Hash) && entry["state"] == "pending"
        next if entry["sending_since"] && recent?(entry["sending_since"], SENDING_STALE_S)

        entry["sending_since"] = now_s
        claimed = entry.dup
      end
      return { "state" => "skipped" } unless claimed

      outcome = deliver(assignment, key, claimed)
      with_state("late-hands.json") do |state|
        entry = state.dig(assignment, key)
        next unless entry.is_a?(Hash)

        entry.delete("sending_since")
        entry["attempts"] = entry["attempts"].to_i + 1
        entry.merge!(outcome)
        entry["state"] = "given_up" if entry["state"] == "pending" && entry["attempts"] >= MAX_ATTEMPTS
      end
      outcome
    end

    def deliver(assignment, key, entry)
      workspace = entry["workspace"].to_s
      return { "state" => "given_up", "reason" => "no_workspace" } unless File.directory?(File.join(workspace, ".reach"))

      meta = Reach::Workspace.metadata(workspace)
      due = Reach::Messages.course_time(due_for_meta(meta))
      id = key == SUBMISSION ? "M-LATE-HAND-SUBMISSION" : "M-LATE-HAND-WORK"
      record = Reach::Hands.raise_record(
        trigger: key, summary: Reach::Messages.text(id, assignment: assignment, due: due), slice: workspace, originator: "agent"
      )
      refused = record["refused"]
      if refused
        give_up = GIVE_UP_CODES.include?(refused["code"].to_s) || GIVE_UP_STATUSES.include?(refused["status"].to_i)
        return give_up ? { "state" => "given_up", "reason" => refused["code"].to_s } : { "state" => "pending", "last_refusal" => refused["code"].to_s }
      end

      outcome = { "state" => "sent", "sent_at" => now_s }
      outcome["hand_id"] = record["hand_id"] if record["hand_id"]
      outcome["queued"] = true if record["queued"]
      outcome
    rescue Reach::Refused => e
      { "state" => "pending", "last_refusal" => e.class.name.split("::").last }
    rescue Reach::NetworkError
      { "state" => "pending", "last_refusal" => "offline" }
    rescue StandardError => e
      { "state" => "pending", "last_refusal" => e.class.name.split("::").last }
    end
  end
end
