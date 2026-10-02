require "json"
require "time"
require "digest"
require "fileutils"
require "shellwords"
require "securerandom"

require_relative "export_import/sources"
require_relative "export_import/vendors"
require_relative "export_import/worker"
require_relative "export_import/findings"

module Reach
  module ExportImport
    SCHEMA = "reach.import/v1".freeze
    MODES = %w[brain copy].freeze
    ACTIONS = %w[pick export run status cancel list next done search show].freeze
    DEFAULTS = { "next_max_bytes" => 12_000, "progress_every" => 500 }.freeze
    JOB_ID = /\Aimp-\d{14}-[0-9a-f]{6}\z/.freeze
    START_GRACE_S = 120
    SPAWN_GAP_S = 120
    RESUME_LIMIT = 5
    MB = 1_048_576
    CATALOG_BYTES_PER_CONVERSATION = 1500
    LIVE_STATES = %w[starting running].freeze
    RUNNABLE_STATES = %w[starting running failed].freeze

    module_function

    def config
      section = Reach::Runtime.load_config["import"]
      section = {} unless section.is_a?(Hash)
      DEFAULTS.each_with_object({}) do |(key, default), memo|
        given = section[key]
        memo[key] = given.is_a?(Integer) && given.positive? ? given : default
      end
    rescue StandardError
      DEFAULTS.dup
    end

    def dir
      Reach::Paths.imports_dir
    end

    def valid_id?(id)
      id.to_s.match?(JOB_ID)
    end

    def job_dir(id)
      raise Reach::Refused, "reach: #{id.to_s.inspect} is not an import id" unless valid_id?(id)

      File.join(dir, id)
    end

    def job_file(id)
      File.join(job_dir(id), "job.json")
    end

    def catalog_file(id)
      File.join(job_dir(id), "catalog.jsonl")
    end

    def queue_file(id)
      File.join(job_dir(id), "queue.jsonl")
    end

    def findings_file(id)
      File.join(job_dir(id), "findings.json")
    end

    def cancel_file(id)
      File.join(job_dir(id), "cancel")
    end

    def run_lock
      File.join(dir, "run.lock")
    end

    def now_s
      Reach::Storage.now_s
    end

    def ensure_dir!(path = dir)
      FileUtils.mkdir_p(path, mode: 0o700)
      File.chmod(0o700, path)
    rescue NotImplementedError, SystemCallError
      nil
    end

    def read_json(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def write_json(path, data)
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(data))
        file.flush
      end
      File.rename(tmp, path)
      data
    end

    def read_job(id)
      read_json(job_file(id))
    end

    def write_job(id, job)
      folder = job_dir(id)
      ensure_dir!(folder) unless File.directory?(folder)
      write_json(job_file(id), job)
    end

    def jobs
      return [] unless File.directory?(dir)

      Dir.children(dir).select { |name| valid_id?(name) }.sort.map { |name| read_job(name) }.compact
    end

    def find_job(id)
      if id.to_s.empty?
        latest = jobs.last
        raise Reach::Refused, "reach: no import has been started" unless latest

        return latest
      end
      read_job(id.to_s) || raise(Reach::Refused, "reach: no import named #{id}")
    end

    def active_job
      jobs.reverse.find { |job| LIVE_STATES.include?(job["state"]) }
    end

    def worker_alive?
      Reach::Storage.lock_held?(run_lock)
    end

    def interrupted?(job)
      return false unless job.is_a?(Hash) && LIVE_STATES.include?(job["state"])
      return false if worker_alive?

      job["state"] == "running" || !Reach::Storage.recent?(job["requested_at"], START_GRACE_S)
    end

    def new_id
      "imp-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}"
    end

    def format_elapsed(seconds)
      seconds = seconds.to_i
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      rest = seconds % 60
      return "#{hours}h #{format('%02d', minutes)}m #{format('%02d', rest)}s" if hours.positive?
      return "#{minutes}m #{format('%02d', rest)}s" if minutes.positive?

      "#{rest}s"
    end

    def elapsed(job)
      started = Reach::Storage.parse_time(job["started_at"] || job["requested_at"])
      return 0 unless started

      stopped = Reach::Storage.parse_time(job["finished_at"]) if %w[finished failed cancelled].include?(job["state"])
      ((stopped || Time.now) - started).to_i
    end

    def percent(job)
      return 100 if job["state"] == "finished"

      total = job["total_bytes"].to_i
      return 0 unless total.positive?

      [(job["bytes"].to_i * 100 / total), 99].min
    end

    def measured_total
      latest = Reach::Storage.last_measure
      unless latest
        measured = Reach::Storage.measure!
        latest = measured == :busy ? nil : measured
      end
      latest ? latest["total"] : 0
    end

    def round_estimate(count)
      count >= 100 ? (count / 10.0).round * 10 : count
    end

    def crossing_note(total, added)
      settings = Reach::Storage.config
      before = Reach::Storage.tier_for(total, settings)
      after_total = total + added
      return "" unless Reach::Storage.tier_for(after_total, settings) > before || (after_total >= settings["demand_mb"] * MB && total < settings["demand_mb"] * MB)

      limit = settings["warn_mb"].select { |step| after_total.to_f / MB >= step }.max || settings["demand_mb"]
      " #{Reach::Messages.text('M-IMPORT-WARN-NOTE', after_mb: Reach::Storage.mb_whole(after_total), limit_mb: limit)}"
    end

    def approve!(subject, replay, message_id, fields)
      case Reach::Storage.approval_mode
      when "agent"
        nil
      when "terminal"
        puts Reach::Messages.text(message_id, **fields).strip
        print "> "
        $stdout.flush
        answer = $stdin.gets
        Reach::Consent.yes?(answer.to_s) ? nil : { "state" => "declined", "text" => Reach::Messages.text("M-IMPORT-DECLINED") }
      else
        if Reach::Consent.declined?(kind: "export_import", subject: subject)
          Reach::Consent.clear_declined!(kind: "export_import", subject: subject)
          return { "state" => "declined", "text" => Reach::Messages.text("M-IMPORT-DECLINED") }
        end
        return nil if Reach::Consent.take!(kind: "export_import", subject: subject)

        question = Reach::Consent.ask!(kind: "export_import", subject: subject, message_id: message_id, fields: fields, replay: replay)
        { "state" => "asked", "text" => Reach::Messages.text("M-CONSENT-NEEDED", question: question) }
      end
    end

    def export(path, mode)
      mode = mode.to_s
      raise Reach::Refused, "reach: --mode must be brain or copy" unless MODES.include?(mode)
      raise Reach::Refused, "reach: give the path of the export folder or ZIP" if path.to_s.strip.empty?
      raise Reach::Refused, Reach::Messages.text("M-BRAIN-DISABLED") unless Reach::Brain.settings["enabled"]
      raise Reach::Refused, Reach::Messages.text("M-IMPORT-STORAGE-FULL") if Reach::Storage.demanded?

      active = active_job
      if active
        resume(active) if interrupted?(active)
        raise Reach::Refused, Reach::Messages.text("M-IMPORT-RUNNING")
      end

      source = Sources.open(path)
      detected = Sources.detect(source)
      conversations = Sources.estimate(source, detected["files"])
      total = measured_total
      limit = Reach::Storage.config["demand_mb"] * MB
      raise Reach::Refused, Reach::Messages.text("M-IMPORT-COPY-TOO-LARGE") if mode == "copy" && total + detected["total_bytes"] >= limit

      added = mode == "copy" ? detected["total_bytes"] : conversations * CATALOG_BYTES_PER_CONVERSATION
      subject = { "path" => Reach::Crypto.digest_hex(source.path), "mode" => mode, "size" => detected["total_bytes"] }
      fields = {
        vendor: Render.vendor_name(detected["vendor"]), size_mb: Reach::Storage.mb_text(detected["total_bytes"]),
        conversations: round_estimate(conversations), note: crossing_note(total, added)
      }
      message_id = mode == "copy" ? "M-IMPORT-ASK-COPY" : "M-IMPORT-ASK-BRAIN"
      replay = { "path" => Shellwords.escape(source.path), "mode" => mode }
      pending = approve!(subject, replay, message_id, fields)
      return pending if pending

      start_job(source, detected, mode, conversations)
    end

    def start_job(source, detected, mode, conversations)
      ensure_dir!
      id = new_id
      stamp = now_s
      job = {
        "schema" => SCHEMA, "id" => id, "vendor" => detected["vendor"], "mode" => mode, "source" => source.path,
        "source_kind" => source.kind, "source_digest" => source.digest, "files" => detected["files"],
        "total_bytes" => detected["total_bytes"], "estimate" => conversations, "state" => "starting", "phase" => "queued",
        "seen" => 0, "done" => 0, "skipped" => 0, "bytes" => 0, "file_index" => 0, "file_elements" => 0,
        "catalog_bytes" => 0, "requested_at" => stamp, "updated_at" => stamp, "resumes" => 0, "announced" => false, "error" => nil
      }
      write_job(id, job)
      if Reach::Storage.spawn_detached(["import", "run", "--job", id]).nil?
        write_job(id, job.merge("state" => "failed", "phase" => "failed", "error" => "spawn", "finished_at" => now_s, "announced" => true))
        return { "state" => "failed", "job" => id, "text" => Reach::Messages.text("M-IMPORT-FAILED") }
      end

      { "state" => "started", "job" => id, "text" => Reach::Messages.text("M-IMPORT-STARTED") }
    end

    def run_worker(id)
      job = read_job(id)
      raise Reach::Refused, "reach: no import named #{id}" unless job
      raise Reach::Refused, "reach: this import is not waiting to run (#{job['state']})" unless RUNNABLE_STATES.include?(job["state"])

      ensure_dir!
      outcome = Reach::Storage.with_flock(run_lock, nonblock: true) { Worker.new(id).run }
      outcome == :busy ? { "state" => "running", "job" => id } : outcome
    end

    def resume(job)
      id = job["id"]
      return false if Reach::Storage.recent?(job["resume_spawned_at"], SPAWN_GAP_S)

      fresh = read_job(id) || job
      if fresh["resumes"].to_i >= RESUME_LIMIT
        write_job(id, fresh.merge("state" => "failed", "phase" => "failed", "error" => "stalled", "finished_at" => now_s, "updated_at" => now_s))
        return false
      end
      write_job(id, fresh.merge("resume_spawned_at" => now_s, "resumes" => fresh["resumes"].to_i + 1, "updated_at" => now_s))
      !Reach::Storage.spawn_detached(["import", "run", "--job", id]).nil?
    rescue StandardError
      false
    end

    def cancel(id)
      job = find_job(id)
      unless LIVE_STATES.include?(job["state"])
        return { "state" => job["state"], "job" => job["id"], "text" => "import #{job['id']} is #{job['state']}; nothing to cancel" }
      end

      if worker_alive?
        FileUtils.touch(cancel_file(job["id"]))
      else
        write_job(job["id"], job.merge("state" => "cancelled", "phase" => "cancelled", "finished_at" => now_s, "updated_at" => now_s, "announced" => true))
        Reach::Debug.import("cancelled", Worker.debug_fields(job))
      end
      { "state" => "cancelling", "job" => job["id"], "text" => "import #{job['id']} is being cancelled; what it already wrote stays" }
    end

    def status(id)
      job = find_job(id)
      info = {
        "job" => job["id"], "vendor" => job["vendor"], "mode" => job["mode"], "state" => job["state"], "phase" => job["phase"],
        "conversations_seen" => job["seen"].to_i, "conversations_done" => job["done"].to_i, "skipped" => job["skipped"].to_i,
        "estimate" => job["estimate"].to_i, "bytes" => job["bytes"].to_i, "total_bytes" => job["total_bytes"].to_i,
        "percent" => percent(job), "elapsed_s" => elapsed(job), "interrupted" => interrupted?(job), "error" => job["error"],
        "queued" => job["queued"], "started_at" => job["started_at"], "updated_at" => job["updated_at"]
      }
      info["findings_done"] = Findings.done_count(job["id"]) if job["queued"]
      info
    end

    def status_text(info)
      lines = ["import #{info['job']}: #{info['state']} (#{info['phase']})#{info['interrupted'] ? ', interrupted and will resume' : ''}"]
      lines << "source: #{info['vendor']} export, #{info['mode']} mode"
      lines << "progress: #{info['percent']}% (#{Reach::Storage.mb_text(info['bytes'])} of #{Reach::Storage.mb_text(info['total_bytes'])} MB)"
      lines << "conversations: #{info['conversations_seen']} read, #{info['conversations_done']} indexed#{info['skipped'].positive? ? ", #{info['skipped']} skipped" : ''} (about #{info['estimate']} expected)"
      lines << "elapsed: #{format_elapsed(info['elapsed_s'])}"
      lines << "findings: #{info['findings_done']} of #{info['queued']} queued conversations worked" if info["queued"]
      lines << "last error: #{info['error']}" if info["error"]
      lines.join("\n")
    end

    def list
      jobs.map do |job|
        {
          "job" => job["id"], "vendor" => job["vendor"], "mode" => job["mode"], "state" => job["state"],
          "conversations_done" => job["done"].to_i, "conversations_seen" => job["seen"].to_i,
          "total_bytes" => job["total_bytes"].to_i, "requested_at" => job["requested_at"]
        }
      end
    end

    def list_text(rows)
      return "no imports yet" if rows.empty?

      rows.map do |row|
        "#{row['job']}  #{row['vendor']}  #{row['mode']}  #{row['state']}  #{row['conversations_done']}/#{row['conversations_seen']} conversations  #{Reach::Storage.mb_text(row['total_bytes'])} MB"
      end.join("\n")
    end

    def finished_text(job)
      Reach::Messages.text("M-IMPORT-FINISHED", vendor: Render.vendor_name(job["vendor"]), conversations: job["done"].to_i, size_mb: Reach::Storage.mb_text(job["total_bytes"]))
    end

    def prompt_notices(_session_id = nil)
      return [] unless File.directory?(dir)

      notices = []
      jobs.each do |job|
        if %w[finished failed].include?(job["state"]) && !job["announced"]
          fresh = read_job(job["id"])
          next unless fresh && !fresh["announced"]

          write_job(job["id"], fresh.merge("announced" => true))
          notices << (fresh["state"] == "finished" ? finished_text(fresh) : Reach::Messages.text("M-IMPORT-FAILED"))
        elsif interrupted?(job)
          resume(job)
        end
      end
      notices
    rescue StandardError
      []
    end

    def forget_all!
      jobs.each do |job|
        next unless LIVE_STATES.include?(job["state"])

        FileUtils.touch(cancel_file(job["id"])) if File.directory?(job_dir(job["id"]))
      end
      ids = []
      Findings.spool_files.each do |path|
        Findings.each_line_of(path) do |raw|
          line = begin
            JSON.parse(raw)
          rescue JSON::ParserError
            nil
          end
          next unless line.is_a?(Hash) && line["record"].is_a?(Hash) && line["record"]["path"].to_s.start_with?("import/")

          ids << line["id"].to_s unless line["id"].to_s.empty?
        end
      end
      ids = ids.uniq
      Reach::Corpus.new(Reach.ports).erase(ids) unless ids.empty?
      [Reach::Paths.import_spool_dir, dir].each { |path| FileUtils.rm_rf(path) if File.directory?(path) }
      ids.length
    rescue StandardError => e
      Reach::BrainSpool.log("import.forget_failed", "error" => e.class.name)
      0
    end

    def session_start
      return unless File.directory?(dir)

      jobs.each { |job| resume(job) if interrupted?(job) }
    rescue StandardError
      nil
    end

    def pick(folder: false)
      outcome = Reach::Picker.pick(folder: folder)
      case outcome["status"]
      when "ok"
        { "state" => "ok", "path" => outcome["path"], "text" => outcome["path"] }
      when "unavailable"
        { "state" => "unavailable", "text" => Reach::Messages.text("M-IMPORT-PICKER-UNAVAILABLE") }
      else
        { "state" => outcome["status"], "text" => "reach: the student closed the picker without choosing anything; ask them to drop the export into the chat or type its path" }
      end
    end

    def perform(action, params)
      case action.to_s
      when "pick" then pick(folder: params["folder"] == true)
      when "export" then export(params["path"], params["mode"])
      when "run" then run_worker(params["job"].to_s)
      when "status"
        info = status(params["job"])
        info.merge("text" => status_text(info))
      when "cancel" then cancel(params["job"])
      when "list"
        rows = list
        { "jobs" => rows, "text" => list_text(rows) }
      when "next" then Findings.next_item(params["job"])
      when "done" then Findings.done(params["conversation_id"], part: params["part"], job: params["job"])
      when "search" then Findings.search(params["query"], job: params["job"])
      when "show" then Findings.show(params["conversation_id"], part: params["part"], job: params["job"])
      else
        raise Reach::Refused, "reach: unknown import action #{action.to_s.inspect}"
      end
    end
  end
end
