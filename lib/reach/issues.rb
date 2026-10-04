require "json"
require "time"
require "fileutils"
require "digest"
require "securerandom"

module Reach
  module Issues
    DEFAULTS = { "enabled" => true, "repeat_threshold" => 3, "window_h" => 24, "max_per_day" => 3, "max_queued" => 10 }.freeze
    BLOCKING = %w[
      hook:gate- hook:hello enroll login command:enroll command:login command:hello command:sync command:qualify command:submit
      mcp:loop mcp:reach_enroll mcp:reach_enrol mcp:reach_hello mcp:reach_sync mcp:reach_qualify mcp:reach_submit
    ].freeze
    SILENT = /seal|ledger|integrity|sidecar|stamp/i.freeze
    OWN = /\Aissues:/.freeze
    TRANSPORT = %w[Reach::NetworkError Reach::Offline].freeze
    TRIGGER = "issue".freeze
    SCHEMA = "reach.issue/v1".freeze
    ROUTE = "/api/v1/hands".freeze
    MAX_SIGNATURES = 200
    KEEP_DAYS = 30
    BACKOFF_BASE_S = 60
    BACKOFF_CAP_S = 21_600
    FLUSH_WAIT_S = 30

    module_function

    def config
      section = Reach::Runtime.load_config["issues"]
      section = {} unless section.is_a?(Hash)
      merged = DEFAULTS.merge(section.select { |name, value| DEFAULTS.key?(name) && !value.nil? })
      lower(merged, policy_limits)
    rescue StandardError
      DEFAULTS.dup
    end

    def policy_limits
      limits = Reach::Policy.limits
      section = limits.is_a?(Hash) ? limits["issues"] : nil
      section.is_a?(Hash) ? section : {}
    rescue StandardError
      {}
    end

    def lower(base, policy)
      result = base.dup
      result["enabled"] = false if policy["enabled"] == false
      %w[max_per_day max_queued].each do |name|
        value = policy[name]
        result[name] = [result[name].to_i, value.to_i].min if value.is_a?(Integer) && value >= 0
      end
      value = policy["repeat_threshold"]
      result["repeat_threshold"] = [result["repeat_threshold"].to_i, value.to_i].max if value.is_a?(Integer) && value.positive?
      result
    end

    def enabled?
      ENV["REACH_ISSUES_DISABLE"].to_s != "1" && config["enabled"] != false
    rescue StandardError
      false
    end

    def state_file
      File.join(Reach::Paths.state_dir, "issues.json")
    end

    def lock_file
      File.join(Reach::Paths.state_dir, "issues.lock")
    end

    def now
      Time.now.utc
    end

    def stamp(time = now)
      time.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def parse(text)
      Time.parse(text.to_s).utc
    rescue StandardError
      nil
    end

    def signature(fields)
      frames = Array(fields["frames"]).map { |frame| signature_frame(frame) }.compact.first(3)
      parts = %w[where exception errno message_id cause].map { |name| fields[name].to_s } << frames
      Digest::SHA256.hexdigest(JSON.generate(parts))[0, 16]
    end

    def signature_frame(frame)
      text = frame.to_s.tr("\\", "/")
      return nil if text.empty? || text.start_with?("/", "<") || text.match?(/\A[A-Za-z]:\//)

      path = text[/\A(.*?):\d+(?::in |\z)/, 1] || text
      label = text[/:in [`'](.*)'\z/, 1].to_s.gsub(/[A-Z][\w:]*[#.]/, "")
      label.empty? ? path : "#{path} #{label}"
    end

    def bundle_frame(frame)
      text = frame.to_s.tr("\\", "/")
      return text unless text.start_with?("/") || text.match?(/\A[A-Za-z]:\//)

      "<outside>/#{text.split("/").last}"
    end

    def classify(fields)
      where = fields["where"].to_s
      return :ignore if OWN.match?(where)
      return :ignore if TRANSPORT.include?(fields["exception"].to_s) || !fields["cause"].to_s.empty?

      BLOCKING.any? { |prefix| where.start_with?(prefix) } ? :blocking : :repeating
    end

    def silent?(fields)
      text = [fields["where"], fields["exception"], Array(fields["frames"]).first(3)].flatten.join(" ")
      SILENT.match?(text)
    end

    def read_state
      parsed = File.file?(state_file) ? JSON.parse(File.read(state_file)) : {}
      parsed = {} unless parsed.is_a?(Hash)
      parsed["version"] = 1
      parsed["day"] = { "date" => nil, "raised" => 0, "suppressed" => 0 } unless parsed["day"].is_a?(Hash)
      parsed["issues"] = {} unless parsed["issues"].is_a?(Hash)
      parsed
    rescue StandardError
      { "version" => 1, "day" => { "date" => nil, "raised" => 0, "suppressed" => 0 }, "issues" => {} }
    end

    def write_state(state)
      FileUtils.mkdir_p(File.dirname(state_file))
      temp = "#{state_file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(prune(state))) }
      File.rename(temp, state_file)
    end

    def prune(state)
      cutoff = now - (KEEP_DAYS * 86_400)
      issues = state["issues"].reject do |_signature, entry|
        last = parse(entry["last_at"])
        last && last < cutoff && entry["pending"].nil?
      end
      if issues.size > MAX_SIGNATURES
        keep = issues.sort_by { |_signature, entry| entry["last_at"].to_s }.last(MAX_SIGNATURES)
        issues = keep.to_h
      end
      state.merge("issues" => issues)
    end

    def locked
      FileUtils.mkdir_p(File.dirname(lock_file))
      Reach::Locks.exclusive(lock_file) { yield }
    end

    def day_window(state)
      today = now.strftime("%Y-%m-%d")
      day = state["day"]
      day = { "date" => today, "raised" => 0, "suppressed" => day["suppressed"].to_i } unless day["date"] == today
      state["day"] = day
      day
    end

    def observe(fields)
      return nil unless enabled?

      kind = classify(fields)
      return nil if kind == :ignore

      settings = config
      key = signature(fields)
      due = false
      locked do
        state = read_state
        day = day_window(state)
        at = now
        entry = state["issues"][key].is_a?(Hash) ? state["issues"][key] : { "count" => 0, "first_at" => stamp(at), "window" => [] }
        horizon = at - (settings["window_h"].to_i * 3600)
        window = Array(entry["window"]).select { |seen| (time = parse(seen)) && time >= horizon }.last(settings["repeat_threshold"].to_i + 4)
        window << stamp(at)
        entry = entry.merge("count" => entry["count"].to_i + 1, "last_at" => stamp(at), "window" => window, "blocking" => kind == :blocking)
        reached = kind == :blocking || window.size >= settings["repeat_threshold"].to_i
        fresh = entry["raised_version"] != Reach::VERSION && entry["pending"].nil?
        if reached && fresh
          if day["raised"].to_i < settings["max_per_day"].to_i
            day["raised"] = day["raised"].to_i + 1
            entry["pending"] = pending_record(fields, entry, day)
            day["suppressed"] = 0
            due = true
          else
            day["suppressed"] = day["suppressed"].to_i + 1
          end
        end
        state["issues"][key] = entry
        write_state(state)
      end
      spawn_flush if due
      key
    rescue StandardError
      nil
    end

    def pending_record(fields, entry, day)
      context = begin
        Reach::Debug.envelope_context
      rescue StandardError
        {}
      end
      {
        "hand_ref" => SecureRandom.uuid, "at" => stamp, "silent" => silent?(fields), "suppressed" => day["suppressed"].to_i,
        "harness" => context["harness"], "surface" => context["surface"],
        "fault" => {
          "where" => fields["where"], "exception" => fields["exception"], "errno" => fields["errno"],
          "message_id" => fields["message_id"], "cause" => fields["cause"],
          "frames" => Array(fields["frames"]).first(12).map { |frame| bundle_frame(frame) }, "shown" => fields["shown"]
        },
        "occurrences" => entry["count"].to_i, "first_at" => entry["first_at"], "last_at" => entry["last_at"]
      }
    end

    def spawn_flush
      Reach::Storage.spawn_detached(%w[issues flush --background])
    rescue StandardError
      nil
    end

    def work?
      return false unless enabled? && File.file?(state_file)
      return true if queued_entries.any? { |_path, entry| due?(entry) }

      Reach::Debug.teach_kinds? && read_state["issues"].any? { |_key, entry| entry["pending"].is_a?(Hash) }
    rescue StandardError
      false
    end

    def flush!(quick: true, force: false)
      return { "built" => 0, "sent" => 0, "queued" => queued_entries.size } unless enabled?

      install = Reach::Enroll.current
      return { "built" => 0, "sent" => 0, "queued" => queued_entries.size } unless install

      result = serialized do
        built = Reach::Debug.teach_kinds? ? build_pending(install) : 0
        sent = send_queued(install, quick: quick, force: force)
        { "built" => built, "sent" => sent, "queued" => queued_entries.size }
      end
      result || { "built" => 0, "sent" => 0, "queued" => queued_entries.size, "busy" => true }
    rescue StandardError => e
      Reach::Debug.fault(e, "issues:flush")
      { "built" => 0, "sent" => 0, "queued" => 0 }
    end

    def flush_lock_file
      File.join(Reach::Paths.state_dir, "issues.flush.lock")
    end

    def serialized
      FileUtils.mkdir_p(File.dirname(flush_lock_file))
      File.open(flush_lock_file, File::RDWR | File::CREAT, 0o600) do |file|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FLUSH_WAIT_S
        until file.flock(File::LOCK_EX | File::LOCK_NB)
          return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep(0.1)
        end
        yield
      end
    end

    def build_pending(install)
      built = 0
      taken = []
      locked do
        state = read_state
        state["issues"].each do |key, entry|
          pending = entry["pending"]
          next unless pending.is_a?(Hash)

          taken << [key, entry, pending]
        end
      end
      taken.each do |key, entry, pending|
        enforce_cap(entry["blocking"] == true)
        write_entry(install, key, entry, pending)
        locked do
          state = read_state
          current = state["issues"][key]
          next unless current.is_a?(Hash)

          current.delete("pending")
          state["issues"][key] = current.merge(
            "raised_at" => stamp, "raised_version" => Reach::VERSION, "hand_ref" => pending["hand_ref"],
            "told" => pending["silent"] == true, "silent" => pending["silent"] == true
          )
          write_state(state)
        end
        built += 1
      end
      built
    end

    def bundle(key, entry, pending)
      {
        "schema" => SCHEMA, "hand_ref" => pending["hand_ref"], "created_at" => pending["at"], "signature" => key,
        "blocking" => entry["blocking"] == true, "occurrences" => pending["occurrences"].to_i,
        "first_at" => pending["first_at"], "last_at" => pending["last_at"], "suppressed" => pending["suppressed"].to_i,
        "fault" => pending["fault"],
        "environment" => {
          "reach_version" => Reach::VERSION, "ruby_version" => RUBY_VERSION, "platform" => RUBY_PLATFORM,
          "os" => os_name, "harness" => pending["harness"], "surface" => pending["surface"]
        },
        "capsule" => Reach::Capsule.build
      }
    end

    def os_name
      snapshot = Reach::OsInfo.snapshot
      snapshot.values_at("os_family", "os_name", "os_version", "kernel").compact.map(&:to_s).reject(&:empty?).first(3).join(" ")
    rescue StandardError
      ""
    end

    def write_entry(install, key, entry, pending)
      course = install["course"].is_a?(Hash) ? install["course"]["id"] : nil
      tar_bytes = Reach::Tarball.write("bundle.json" => JSON.generate(Reach::Utf8.clean(bundle(key, entry, pending))))
      envelope = Reach::Hands.seal_bundle(install, { "course" => course, "assignment" => nil }, tar_bytes)
      body = {
        "cutout_id" => nil, "slice" => nil, "trigger" => TRIGGER, "originator" => "reach",
        "summary" => Reach::Messages.text("M-ISSUE-SUMMARY"), "bundle" => envelope
      }
      idempotency_key = SecureRandom.uuid
      FileUtils.mkdir_p(Reach::Paths.outbox_dir)
      path = File.join(Reach::Paths.outbox_dir, "#{idempotency_key}.json")
      record = {
        "kind" => "hand", "route" => ROUTE, "idempotency_key" => idempotency_key, "body" => body, "slice" => nil,
        "hand_ref" => pending["hand_ref"], "issue" => key, "blocking" => entry["blocking"] == true,
        "attempts" => 0, "next_at" => nil, "queued_at" => stamp
      }
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(record)) }
      path
    end

    def queued_entries
      Dir.glob(File.join(Reach::Paths.outbox_dir, "*.json")).sort.map do |path|
        entry = begin
          JSON.parse(File.read(path))
        rescue StandardError
          nil
        end
        entry.is_a?(Hash) && entry["issue"] ? [path, entry] : nil
      end.compact
    end

    def enforce_cap(incoming_blocking)
      limit = config["max_queued"].to_i
      queued = queued_entries
      return if queued.size < limit

      ordered = queued.sort_by { |_path, entry| [entry["blocking"] == true ? 1 : 0, entry["queued_at"].to_s] }
      victim = ordered.first
      return if victim.nil? || (victim[1]["blocking"] == true && !incoming_blocking)

      FileUtils.rm_f(victim[0])
      locked do
        state = read_state
        day = day_window(state)
        day["suppressed"] = day["suppressed"].to_i + 1
        write_state(state)
      end
    end

    def due?(entry)
      next_at = parse(entry["next_at"])
      next_at.nil? || next_at <= now
    end

    def backoff_s(attempts, retry_after = nil)
      ceiling = [BACKOFF_CAP_S, BACKOFF_BASE_S * (2**[attempts - 1, 0].max)].min
      wait = rand * ceiling
      retry_after ? [wait, retry_after.to_f].max : wait
    end

    def defer(path, entry, retry_after = nil)
      return nil unless File.file?(path)

      attempts = entry["attempts"].to_i + 1
      updated = entry.merge("attempts" => attempts, "next_at" => stamp(now + backoff_s(attempts, retry_after)))
      temp = "#{path}.tmp.#{Process.pid}"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(updated)) }
      File.rename(temp, path)
    rescue StandardError
      nil
    end

    def send_queued(install, quick: true, force: false)
      sent = 0
      queued_entries.each do |path, entry|
        next unless force || due?(entry)

        outcome = deliver(install, path, entry, quick: quick)
        sent += 1 if outcome == :sent
        break if outcome == :offline
      end
      sent
    end

    def deliver(install, path, entry, quick: true)
      response = Reach::Client.for_install(install, quick: quick).post_json(entry["route"], entry["body"], idempotency_key: entry["idempotency_key"])
      result = response.json || {}
      FileUtils.rm_f(path)
      sent!(entry["issue"], result["hand_id"])
      Reach::Hands.track(result["hand_id"], slice: nil, hand_ref: entry["hand_ref"], originator: "reach") if result["hand_id"]
      :sent
    rescue Reach::RemoteRefused => e
      FileUtils.rm_f(path)
      Reach::Debug.fault(e, "issues:refused")
      :refused
    rescue Reach::Offline, Reach::NetworkError
      defer(path, entry)
      :offline
    end

    def sent!(key, hand_id)
      locked do
        state = read_state
        entry = state["issues"][key]
        next unless entry.is_a?(Hash)

        state["issues"][key] = entry.merge("hand_id" => hand_id, "sent_at" => stamp)
        write_state(state)
      end
    rescue StandardError
      nil
    end

    def recent_signature(within_s = 600)
      horizon = now - within_s
      newest = read_state["issues"].select { |_key, entry| (time = parse(entry["last_at"])) && time >= horizon }
      found = newest.max_by { |_key, entry| entry["last_at"].to_s }
      found ? found[0] : nil
    rescue StandardError
      nil
    end

    def notice!
      return nil unless File.file?(state_file)

      text = nil
      locked do
        state = read_state
        reported = state["issues"].select { |_key, entry| entry["hand_ref"] && entry["told"] != true }
        fixed = state["issues"].select { |_key, entry| fixed_here?(entry) && entry["told_fixed"] != true }
        next if reported.empty? && fixed.empty?

        reported.each_key { |key| state["issues"][key]["told"] = true }
        fixed.each_key { |key| state["issues"][key]["told_fixed"] = true }
        write_state(state)
        lines = []
        lines << Reach::Messages.text("M-ISSUE-REPORTED") unless reported.empty?
        lines << Reach::Messages.text("M-ISSUE-FIXED") unless fixed.reject { |_key, entry| entry["silent"] == true }.empty?
        text = lines.join("\n\n") unless lines.empty?
      end
      text
    rescue StandardError
      nil
    end

    def fixed_here?(entry)
      version = entry["fix_version"].to_s
      return false if version.empty?

      Gem::Version.new(Reach::VERSION) >= Gem::Version.new(version)
    rescue StandardError
      false
    end

    def record_status(hand_id, body)
      version = body.is_a?(Hash) ? body["fix_version"].to_s : ""
      return nil unless version.match?(/\A\d+\.\d+\.\d+\z/)

      locked do
        state = read_state
        found = state["issues"].find { |_key, entry| entry["hand_id"] == hand_id }
        next unless found

        state["issues"][found[0]] = found[1].merge("fix_version" => version, "issue_state" => body["issue_state"].to_s)
        write_state(state)
      end
    rescue StandardError
      nil
    end

    def list
      state = read_state
      queued = queued_entries.map { |_path, entry| entry["issue"] }
      state["issues"].map do |key, entry|
        {
          "signature" => key, "count" => entry["count"].to_i, "first_at" => entry["first_at"], "last_at" => entry["last_at"],
          "blocking" => entry["blocking"] == true, "reported" => !entry["sent_at"].nil?, "queued" => queued.include?(key),
          "waiting" => entry["pending"].is_a?(Hash), "fix_version" => entry["fix_version"]
        }
      end
    end

    def counts
      rows = list
      { "seen" => rows.size, "reported" => rows.count { |row| row["reported"] }, "queued" => rows.count { |row| row["queued"] || row["waiting"] } }
    rescue StandardError
      { "seen" => 0, "reported" => 0, "queued" => 0 }
    end
  end
end
