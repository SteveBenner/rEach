require "fileutils"
require "json"
require "time"

module Reach
  module Transcript
    ROUTE = "/api/v1/transcripts"
    MAX_TEXT_BYTES = 131_072
    MAX_BATCH_ENTRIES = 200
    MAX_BATCH_BYTES = 900_000
    QUICK_MAX_REQUESTS = 3
    FULL_MAX_REQUESTS = 50
    QUICK_MIN_INTERVAL_S = 60
    SESSION_ID_PATTERN = /\A[A-Za-z0-9._:-]{1,128}\z/
    HARNESSES = %w[claude-code codex unknown].freeze
    SLICES = %w[backend panel verification].freeze

    module_function

    def capture(event, harness:, gate:)
      return nil unless Reach::Enrol.current
      return nil if Reach::Enrol.revoked?

      session_id = resolve_session_id(event)
      FileUtils.mkdir_p(Reach::Paths.transcripts_dir)
      begin
        File.chmod(0o700, Reach::Paths.transcripts_dir)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end

      entries_path = File.join(Reach::Paths.transcripts_dir, "#{session_id}.jsonl")
      entry = nil
      File.open(entries_path, File::RDWR | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        state = read_state(session_id)
        seq = state["last_seq"].to_i + 1
        entry = build_entry(event, session_id: session_id, harness: harness, gate: gate, seq: seq)
        file.write(JSON.generate(entry) + "\n")
        file.flush
        write_state(session_id, state.merge("last_seq" => seq, "updated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")))
      end
      entry
    rescue StandardError => e
      log_transcript_event("capture_failed", "error" => e.class.name, "session_id" => session_id)
      nil
    end

    def flush(quick: false, final: false)
      install = begin
        Reach::Enrol.current
      rescue StandardError
        nil
      end
      return stopped_result("not_enrolled", quick) unless install
      return stopped_result("revoked", quick) if safe_revoked?
      return stopped_result("offline", quick) if ENV["REACH_OFFLINE"] == "1"

      FileUtils.mkdir_p(Reach::Paths.state_dir)
      result = nil
      File.open(Reach::Paths.flush_lock_file, File::RDWR | File::CREAT, 0o600) do |lock_file|
        unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
          result = stopped_result("busy", quick)
          next
        end

        begin
          if quick && !final && too_soon?
            result = stopped_result("too_soon", quick)
            next
          end

          write_flush_state("last_attempt_at" => Time.now.utc.to_f)
          result = run_flush(install, quick: quick)
        ensure
          lock_file.flock(File::LOCK_UN)
        end
      end
      result
    rescue StandardError => e
      log_transcript_event("flush_failed", "error" => e.class.name)
      { "sent" => 0, "requests" => 0, "stopped" => "error" }
    end

    def stopped_result(reason, quick)
      result = { "sent" => 0, "requests" => 0, "stopped" => reason }
      log_transcript_event("flush", "quick" => quick, "sent" => 0, "requests" => 0, "stopped" => reason)
      result
    end

    def counts
      dir = Reach::Paths.transcripts_dir
      return { "sent" => 0, "waiting" => 0 } unless Dir.exist?(dir)

      sent = 0
      waiting = 0
      Dir.glob(File.join(dir, "*.state.json")).each do |path|
        state = parse_json_file(path)
        next unless state

        acked = state["acked_seq"].to_i
        last = state["last_seq"].to_i
        sent += acked
        waiting += [last - acked, 0].max
      end
      { "sent" => sent, "waiting" => waiting }
    rescue StandardError
      { "sent" => 0, "waiting" => 0 }
    end

    def prompts(count)
      count.to_i == 1 ? "1 prompt" : "#{count.to_i} prompts"
    end

    def resolve_session_id(event)
      raw = event.is_a?(Hash) ? event["session_id"].to_s : ""
      cleaned = raw.gsub(/[^A-Za-z0-9._:-]/, "_")[0, 128]
      cleaned.empty? ? "unknown-#{Time.now.utc.strftime('%Y%m%d')}" : cleaned
    end

    def resolve_harness(flag)
      return flag if flag && HARNESSES.include?(flag)
      return "claude-code" if ENV["CLAUDE_PROJECT_DIR"].to_s != ""

      "unknown"
    end

    def build_entry(event, session_id:, harness:, gate:, seq:)
      prompt = event.is_a?(Hash) ? event["prompt"] : nil
      workspace = begin
        Reach::Gate.current_workspace_path
      rescue StandardError
        nil
      end
      meta = workspace ? safe_metadata(workspace) : {}
      cutout_id = meta && meta["cutout_id"]
      slice = meta && meta["slice"]
      slice = nil unless SLICES.include?(slice)

      entry = {
        "seq" => seq,
        "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "session_id" => session_id,
        "harness" => harness.to_s,
        "cutout_id" => cutout_id,
        "slice" => slice,
        "kind" => "prompt",
        "gate" => gate
      }

      if prompt.is_a?(String)
        scrubbed = prompt.dup.force_encoding("UTF-8").scrub("�")
        bytes = scrubbed.bytesize
        if bytes <= MAX_TEXT_BYTES
          entry["text"] = scrubbed
          entry["truncated"] = false
        else
          entry["text"] = truncate_to_bytes(scrubbed, MAX_TEXT_BYTES)
          entry["truncated"] = true
        end
        entry["bytes"] = bytes
        entry["digest"] = Reach::Crypto.digest_hex(scrubbed)
        entry["note"] = nil
      else
        entry["text"] = nil
        entry["bytes"] = 0
        entry["truncated"] = false
        entry["digest"] = nil
        entry["note"] = "no prompt in the hook payload"
      end

      entry
    end

    def truncate_to_bytes(text, max_bytes)
      text.byteslice(0, max_bytes).scrub("")
    end

    def safe_metadata(workspace)
      Reach::Workspace.metadata(workspace)
    rescue StandardError
      {}
    end

    def safe_revoked?
      Reach::Enrol.revoked?
    rescue StandardError
      false
    end

    def state_path(session_id)
      File.join(Reach::Paths.transcripts_dir, "#{session_id}.state.json")
    end

    def rejected_path(session_id)
      File.join(Reach::Paths.transcripts_dir, "#{session_id}.rejected.jsonl")
    end

    def entries_path(session_id)
      File.join(Reach::Paths.transcripts_dir, "#{session_id}.jsonl")
    end

    def read_state(session_id)
      path = state_path(session_id)
      parsed = File.file?(path) ? parse_json_file(path) : nil
      parsed || { "last_seq" => 0, "acked_seq" => 0, "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
    end

    def write_state(session_id, state)
      path = state_path(session_id)
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(state)) }
      File.rename(tmp, path)
    end

    def update_acked(session_id, acked_seq)
      File.open(entries_path(session_id), File::RDWR | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        state = read_state(session_id)
        acked = [[state["acked_seq"].to_i, acked_seq.to_i].max, state["last_seq"].to_i].min
        write_state(session_id, state.merge("acked_seq" => acked))
      end
    end

    def parse_json_file(path)
      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end

    def too_soon?
      state = parse_json_file(Reach::Paths.flush_state_file)
      return false unless state && state["last_attempt_at"]

      (Time.now.utc.to_f - state["last_attempt_at"].to_f) < QUICK_MIN_INTERVAL_S
    end

    def write_flush_state(fields)
      state = parse_json_file(Reach::Paths.flush_state_file) || {}
      File.write(Reach::Paths.flush_state_file, JSON.generate(state.merge(fields)))
      begin
        File.chmod(0o600, Reach::Paths.flush_state_file)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
    end

    def run_flush(install, quick:)
      sent = 0
      requests = 0
      stopped = nil
      max_requests = quick ? QUICK_MAX_REQUESTS : FULL_MAX_REQUESTS

      pending_sessions(quick).each do |session_id|
        break if stopped

        state = read_state(session_id)
        acked = state["acked_seq"].to_i
        last = state["last_seq"].to_i
        next if acked >= last

        remaining = read_entries_after(session_id, acked)
        next if remaining.empty?

        batches(session_id, remaining).each do |batch|
          if requests >= max_requests
            stopped = "request_budget"
            break
          end

          requests += 1
          outcome = send_batch(install, session_id: session_id, batch: batch, quick: quick)
          case outcome[:result]
          when :sent
            update_acked(session_id, [outcome[:last_seq].to_i, batch.last["seq"]].min)
            sent += batch.size
          when :rejected
            append_rejected(session_id, batch, outcome[:code])
            update_acked(session_id, batch.last["seq"])
          when :revoked
            Reach::Enrol.mark_revoked!
            stopped = outcome[:code]
          when :stop
            stopped = outcome[:code]
          end
          break if stopped
        end
      end

      log_transcript_event("flush", "quick" => quick, "sent" => sent, "requests" => requests, "stopped" => stopped)
      { "sent" => sent, "requests" => requests, "stopped" => stopped }
    end

    def pending_sessions(_quick)
      dir = Reach::Paths.transcripts_dir
      return [] unless Dir.exist?(dir)

      candidates = Dir.glob(File.join(dir, "*.state.json")).map do |path|
        session_id = File.basename(path, ".state.json")
        state = parse_json_file(path)
        next nil unless state && state["acked_seq"].to_i < state["last_seq"].to_i

        [session_id, state["created_at"].to_s]
      end.compact

      candidates.sort_by { |session_id, created_at| [created_at, session_id] }.map(&:first)
    end

    def read_entries_after(session_id, acked_seq)
      path = entries_path(session_id)
      return [] unless File.file?(path)

      lines = []
      File.foreach(path) do |line|
        parsed = begin
          JSON.parse(line)
        rescue StandardError
          nil
        end
        next unless parsed
        next unless parsed["seq"].to_i > acked_seq

        lines << parsed
      end
      lines.sort_by { |entry| entry["seq"].to_i }
    end

    def batches(session_id, entries)
      result = []
      current = []
      entries.each do |entry|
        candidate = current + [entry]
        if current.empty?
          current = candidate
          next
        end

        if candidate.length > MAX_BATCH_ENTRIES || batch_bytesize(session_id, candidate) > MAX_BATCH_BYTES
          result << current
          current = [entry]
        else
          current = candidate
        end
      end
      result << current unless current.empty?
      result
    end

    def batch_bytesize(session_id, entries)
      last_entry = entries.last
      harness = HARNESSES.include?(last_entry["harness"]) ? last_entry["harness"] : "unknown"
      JSON.generate(batch_body(session_id, harness, last_entry["cutout_id"], last_entry["slice"], entries)).bytesize
    end

    def send_batch(install, session_id:, batch:, quick:)
      last_entry = batch.last
      harness = HARNESSES.include?(last_entry["harness"]) ? last_entry["harness"] : "unknown"
      body = batch_body(session_id, harness, last_entry["cutout_id"], last_entry["slice"], batch)
      first_seq = batch.first["seq"]
      last_seq = batch.last["seq"]
      key = Reach::Crypto.digest_hex("#{install['install_id']}\n#{session_id}\n#{first_seq}\n#{last_seq}")

      response = Reach::Client.for_install(install, quick: quick).post_json(ROUTE, body, idempotency_key: key)
      json = response.json || {}
      { result: :sent, last_seq: json["last_seq"] }
    rescue Reach::RemoteRefused => e
      handle_remote_refused(e)
    rescue Reach::Offline
      { result: :stop, code: "offline" }
    rescue Reach::NetworkError
      { result: :stop, code: "network" }
    end

    def handle_remote_refused(error)
      if %w[invalid_request too_large].include?(error.code)
        { result: :rejected, code: error.code }
      elsif %w[revoked not_enrolled].include?(error.code)
        { result: :revoked, code: error.code }
      else
        { result: :stop, code: error.code }
      end
    end

    def append_rejected(session_id, batch, code)
      path = rejected_path(session_id)
      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        batch.each do |entry|
          record = entry.merge("rejected" => { "code" => code, "at" => now })
          file.write(JSON.generate(record) + "\n")
        end
      end
      log_transcript_event("flush_rejected", "session_id" => session_id, "code" => code)
    end

    def batch_body(session_id, harness, cutout_id, slice, entries)
      {
        "session_id" => session_id,
        "harness" => harness,
        "cutout_id" => cutout_id,
        "slice" => slice,
        "entries" => entries.map do |entry|
          {
            "seq" => entry["seq"],
            "at" => entry["at"],
            "kind" => entry["kind"],
            "text" => entry["text"],
            "bytes" => entry["bytes"],
            "truncated" => entry["truncated"],
            "digest" => entry["digest"],
            "gate" => entry["gate"],
            "note" => entry["note"]
          }
        end
      }
    end

    def log_transcript_event(event, fields = {})
      FileUtils.mkdir_p(Reach::Paths.logs_dir)
      record = { "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "event" => event }
      fields.each { |k, v| record[k.to_s] = v }
      File.open(Reach::Paths.transcript_log, File::WRONLY | File::CREAT | File::APPEND, 0o644) do |file|
        file.puts(JSON.generate(record))
      end
    rescue StandardError
      nil
    end
  end
end
