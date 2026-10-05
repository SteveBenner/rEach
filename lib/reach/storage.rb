require "json"
require "time"
require "find"
require "zlib"
require "digest"
require "fileutils"
require "rbconfig"

module Reach
  module Storage
    SCHEMA = "reach.storage/v1".freeze
    MB = 1_048_576
    DEFAULTS = { "warn_mb" => [512, 1024, 2048].freeze, "demand_mb" => 4096, "check_interval_s" => 3600 }.freeze
    SESSIONS_KEPT = 50
    SPAWN_GAP_S = 120
    START_GRACE_S = 120
    COPY_CHUNK = 1_048_576
    SPOOL_ADMITTED = "admitted".freeze

    module_function

    def config
      section = Reach::Runtime.load_config["storage"]
      section = {} unless section.is_a?(Hash)
      steps = Array(section["warn_mb"]).select { |value| value.is_a?(Integer) && value.positive? }.uniq.sort
      steps = DEFAULTS["warn_mb"].dup if steps.empty?
      demand = section["demand_mb"]
      demand = DEFAULTS["demand_mb"] unless demand.is_a?(Integer) && demand.positive?
      interval = section["check_interval_s"]
      interval = DEFAULTS["check_interval_s"] unless interval.is_a?(Integer) && interval.positive?
      { "warn_mb" => steps, "demand_mb" => demand, "check_interval_s" => interval }
    rescue StandardError
      DEFAULTS.merge("warn_mb" => DEFAULTS["warn_mb"].dup)
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def recent?(value, seconds)
      stamp = parse_time(value)
      !stamp.nil? && Time.now - stamp <= seconds
    end

    def mb_value(bytes)
      (bytes.to_f / MB).round(1)
    end

    def mb_text(bytes)
      value = mb_value(bytes)
      value == value.round ? value.round.to_s : value.to_s
    end

    def mb_whole(bytes)
      (bytes.to_f / MB).round
    end

    def read_state
      path = Reach::Paths.storage_state_file
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write_state(state)
      path = Reach::Paths.storage_state_file
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(state))
        file.flush
        file.fsync
      end
      File.rename(tmp, path)
      state
    end

    def with_flock(path, nonblock: false)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        locked = nonblock ? file.flock(File::LOCK_EX | File::LOCK_NB) : Reach::Locks.acquire(file, path)
        return :busy unless locked

        yield
      end
    end

    def lock_held?(path)
      return false unless File.exist?(path)

      File.open(path, File::RDWR) do |file|
        return true unless file.flock(File::LOCK_EX | File::LOCK_NB)

        file.flock(File::LOCK_UN)
      end
      false
    rescue StandardError
      false
    end

    def update_state
      with_flock(Reach::Paths.storage_lock_file("state")) do
        original = read_state
        updated = yield(JSON.parse(JSON.generate(original)))
        write_state(updated) unless updated == original
        updated
      end
    end

    def open_corpus
      ports = Reach.ports
      return nil unless ports

      ports.corpus.open("reach")
    rescue StandardError
      nil
    end

    def corpus_root
      corpus = open_corpus
      corpus ? corpus.root.to_s : nil
    rescue StandardError
      nil
    end

    def brain_roots
      [Reach::Brain.dir, Reach::BrainSpool.dir, Reach::Paths.import_spool_dir, Reach::Paths.imports_dir]
    end

    def distinct_roots(paths)
      expanded = paths.compact.map { |path| File.expand_path(path) }.uniq
      expanded.reject { |path| expanded.any? { |other| other != path && path.start_with?(other + File::SEPARATOR) } }
    end

    def tree_bytes(root)
      return 0 unless File.exist?(root)

      total = 0
      Find.find(File.realpath(root)) do |path|
        stat = begin
          File.lstat(path)
        rescue SystemCallError
          nil
        end
        next unless stat
        next if stat.symlink?

        total += stat.size if stat.file?
      end
      total
    rescue SystemCallError
      0
    end

    def measure
      root = corpus_root
      corpus = root ? tree_bytes(root) : 0
      brain = distinct_roots(brain_roots).inject(0) { |sum, path| sum + tree_bytes(path) }
      { "corpus" => corpus, "brain" => brain, "total" => corpus + brain, "measured_at" => now_s }
    end

    def tier_for(total_bytes, settings = config)
      megabytes = total_bytes.to_f / MB
      settings["warn_mb"].select { |step| megabytes >= step }.max.to_i
    end

    def debug_fields(result, settings = config)
      {
        "corpus_mb" => mb_value(result["corpus"]), "brain_mb" => mb_value(result["brain"]),
        "total_mb" => mb_value(result["total"]), "tier" => tier_for(result["total"], settings)
      }
    end

    def record_measure(result)
      settings = config
      update_state do |state|
        state["schema"] = SCHEMA
        state["measure"] = result
        tier = tier_for(result["total"], settings)
        state["warned_mb"] = tier if tier < state["warned_mb"].to_i
        state
      end
    end

    def measure!
      outcome = with_flock(Reach::Paths.storage_lock_file("measure"), nonblock: true) do
        result = measure
        record_measure(result)
        Reach::Debug.storage("measured", debug_fields(result))
        result
      end
      outcome
    end

    def last_measure
      value = read_state["measure"]
      value.is_a?(Hash) && value["total"].is_a?(Integer) ? value : nil
    end

    def demanded?
      latest = last_measure
      !latest.nil? && latest["total"] >= config["demand_mb"] * MB
    rescue StandardError
      false
    end

    def measure_due?
      latest = last_measure
      return true unless latest

      stamp = parse_time(latest["measured_at"])
      stamp.nil? || Time.now - stamp >= config["check_interval_s"]
    end

    def spawn_detached(args)
      exe = File.expand_path("../../exe/reach", __dir__)
      pid = Process.spawn(RbConfig.ruby, exe, *args, in: File::NULL, out: File::NULL, err: File::NULL, **Reach::Runtime.detach_group)
      Process.detach(pid)
      pid
    rescue StandardError
      nil
    end

    def spawn_measure_if_due
      return false unless measure_due?
      return false if recent?(read_state["measure_spawned_at"], SPAWN_GAP_S)
      return false if lock_held?(Reach::Paths.storage_lock_file("measure"))

      update_state { |state| state.merge("measure_spawned_at" => now_s) }
      !spawn_detached(%w[storage measure]).nil?
    rescue StandardError
      false
    end

    def demand_text
      latest = last_measure
      settings = config
      return nil unless latest && latest["total"] >= settings["demand_mb"] * MB

      Reach::Messages.text("M-STORAGE-DEMAND", total_mb: mb_text(latest["total"]), limit_mb: settings["demand_mb"])
    end

    def session_start
      spawn_measure_if_due
      demand_text
    rescue StandardError
      nil
    end

    def compaction_notice(job)
      case job["state"]
      when "failed"
        Reach::Messages.text("M-STORAGE-COMPACT-FAILED")
      else
        id = job["reclaim"] == "unsupported" ? "M-STORAGE-COMPACT-OLD-LIBRARY" : "M-STORAGE-COMPACTED"
        Reach::Messages.text(id, before_mb: mb_text(job["before"]), after_mb: mb_text(job["after"]))
      end
    end

    def interrupted?(job)
      return false unless job.is_a?(Hash)
      return false if lock_held?(Reach::Paths.storage_lock_file("compact"))

      case job["state"]
      when "running" then true
      when "starting" then !recent?(job["requested_at"], START_GRACE_S)
      else false
      end
    end

    def notices_for(state, session, events, greeted)
      settings = config
      list = []
      job = state["compaction"]
      if job.is_a?(Hash)
        if interrupted?(job)
          job.merge!("state" => "failed", "finished_at" => now_s, "error" => "interrupted")
          events << ["compact_failed", {}]
        end
        if %w[done failed].include?(job["state"]) && !job["announced"]
          list << compaction_notice(job)
          job["announced"] = true
        end
      end
      latest = state["measure"]
      return list unless latest.is_a?(Hash) && latest["total"].is_a?(Integer)

      tier = tier_for(latest["total"], settings)
      warned = state["warned_mb"].to_i
      if latest["total"] >= settings["demand_mb"] * MB
        seen = Array(state["demand_announced_sessions"])
        unless seen.include?(session)
          list << Reach::Messages.text("M-STORAGE-DEMAND", total_mb: mb_text(latest["total"]), limit_mb: settings["demand_mb"]) unless greeted
          state["demand_announced_sessions"] = (seen + [session]).last(SESSIONS_KEPT)
          events << ["demanded", debug_fields(latest, settings).merge("tier" => settings["demand_mb"])]
        end
        state["warned_mb"] = tier if tier != warned
      elsif tier > warned
        list << Reach::Messages.text("M-STORAGE-WARN", total_mb: mb_text(latest["total"]), corpus_mb: mb_text(latest["corpus"]), brain_mb: mb_text(latest["brain"]))
        state["warned_mb"] = tier
        events << ["warned", debug_fields(latest, settings)]
      elsif tier < warned
        state["warned_mb"] = tier
      end
      list
    end

    def prompt_notices(session_id, greeted: false)
      return [] unless File.file?(Reach::Paths.storage_state_file)

      list = []
      events = []
      update_state do |state|
        list = notices_for(state, session_id.to_s, events, greeted)
        state
      end
      events.each { |outcome, fields| Reach::Debug.storage(outcome, fields) }
      list
    rescue StandardError
      []
    end

    def approval_mode
      return "terminal" if $stdin.tty? && $stdout.tty?
      return "agent" if ENV["REACH_HARNESS"] == "antigravity"

      "hook"
    end

    def compaction_subject(root, total)
      { "corpus_root" => Reach::Crypto.digest_hex(root.to_s), "total" => mb_whole(total) }
    end

    def approve!(subject)
      fields = { total_mb: subject["total"] }
      case approval_mode
      when "agent"
        nil
      when "terminal"
        puts Reach::Messages.text("M-STORAGE-COMPACT-ASK", **fields).strip
        print "> "
        $stdout.flush
        answer = $stdin.gets
        Reach::Consent.yes?(answer.to_s) ? nil : { "state" => "declined", "text" => Reach::Messages.text("M-STORAGE-COMPACT-DECLINED") }
      else
        if Reach::Consent.declined?(kind: "compaction", subject: subject)
          Reach::Consent.clear_declined!(kind: "compaction", subject: subject)
          return { "state" => "declined", "text" => Reach::Messages.text("M-STORAGE-COMPACT-DECLINED") }
        end
        return nil if Reach::Consent.take!(kind: "compaction", subject: subject)

        question = Reach::Consent.ask!(kind: "compaction", subject: subject, message_id: "M-STORAGE-COMPACT-ASK", fields: fields, replay: {})
        { "state" => "asked", "text" => Reach::Messages.text("M-CONSENT-NEEDED", question: question) }
      end
    end

    def compaction_running?
      return true if lock_held?(Reach::Paths.storage_lock_file("compact"))

      job = read_state["compaction"]
      job.is_a?(Hash) && job["state"] == "starting" && recent?(job["requested_at"], START_GRACE_S)
    end

    def compact
      root = corpus_root
      return { "state" => "no_corpus", "text" => Reach::Messages.text("M-STORAGE-NO-CORPUS") } unless root
      return { "state" => "running", "text" => Reach::Messages.text("M-STORAGE-COMPACT-RUNNING") } if compaction_running?

      latest = last_measure
      unless latest
        measured = measure!
        latest = measured == :busy ? nil : measured
      end
      total = latest ? latest["total"] : tree_bytes(root)
      subject = compaction_subject(root, total)
      pending = approve!(subject)
      return pending if pending

      start_worker
    end

    def start_worker
      update_state { |state| state.merge("compaction" => { "state" => "starting", "requested_at" => now_s, "announced" => true }) }
      if spawn_detached(%w[storage compact --run]).nil?
        update_state { |state| state.merge("compaction" => { "state" => "failed", "finished_at" => now_s, "error" => "spawn", "announced" => true }) }
        return { "state" => "failed", "text" => Reach::Messages.text("M-STORAGE-COMPACT-FAILED") }
      end

      { "state" => "started", "text" => Reach::Messages.text("M-STORAGE-COMPACT-STARTED") }
    end

    def run_compact
      job = read_state["compaction"]
      unless job.is_a?(Hash) && job["state"] == "starting" && recent?(job["requested_at"], START_GRACE_S)
        raise Reach::Refused, "reach: compaction starts only after the student says yes; run reach storage compact"
      end

      outcome = with_flock(Reach::Paths.storage_lock_file("compact"), nonblock: true) { perform_compact }
      outcome == :busy ? { "state" => "running" } : outcome
    end

    def perform_compact
      before = measure
      record_measure(before)
      update_state do |state|
        state.merge("compaction" => { "state" => "running", "started_at" => now_s, "pid" => Process.pid, "before" => before["total"], "announced" => false })
      end
      Reach::Debug.storage("compact_started", debug_fields(before))
      begin
        reclaim = compact_corpus
        gzipped = gzip_import_spool
        after = measure
        record_measure(after)
        update_state do |state|
          state.merge("compaction" => {
                        "state" => "done", "started_at" => state.dig("compaction", "started_at"), "finished_at" => now_s,
                        "before" => before["total"], "after" => after["total"], "reclaim" => reclaim, "gzipped" => gzipped, "announced" => false
                      })
        end
        Reach::Debug.storage("compacted", debug_fields(after).merge("before_mb" => mb_value(before["total"]), "after_mb" => mb_value(after["total"])))
        { "state" => "done", "reclaim" => reclaim, "before" => before["total"], "after" => after["total"] }
      rescue StandardError => e
        Reach::BrainSpool.log("storage.compact_failed", "error" => e.class.name)
        update_state do |state|
          state.merge("compaction" => { "state" => "failed", "finished_at" => now_s, "before" => before["total"], "error" => e.class.name, "announced" => false })
        end
        Reach::Debug.storage("compact_failed", debug_fields(before))
        { "state" => "failed", "error" => e.class.name }
      end
    end

    def compress_supported?(compactor)
      compactor.method(:run).parameters.any? { |kind, name| name == :compress && %i[key keyreq].include?(kind) }
    end

    def compact_corpus
      corpus = open_corpus
      raise Reach::Error, "reach: the corpus could not be opened" unless corpus && defined?(Rcorpus::Compact)

      compactor = Rcorpus::Compact.new(corpus)
      if compress_supported?(compactor)
        compactor.run(compress: true)
        "compressed"
      else
        compactor.run
        "unsupported"
      end
    end

    def file_sha256(path)
      Digest::SHA256.file(path).hexdigest
    end

    def gunzip_sha256(path)
      digest = Digest::SHA256.new
      Zlib::GzipReader.open(path) do |reader|
        while (chunk = reader.read(COPY_CHUNK))
          digest.update(chunk)
        end
      end
      digest.hexdigest
    end

    def gzip_file(path)
      target = "#{path}.gz"
      plain = file_sha256(path)
      unless File.file?(target)
        tmp = "#{target}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        begin
          File.open(path, "rb") do |input|
            File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::BINARY, 0o600) do |output|
              writer = Zlib::GzipWriter.new(output)
              while (chunk = input.read(COPY_CHUNK))
                writer.write(chunk)
              end
              writer.finish
              output.flush
              output.fsync
            end
          end
          File.rename(tmp, target)
        ensure
          FileUtils.rm_f(tmp)
        end
      end
      return true if gunzip_sha256(target) == plain && File.unlink(path) == 1

      FileUtils.rm_f(target)
      false
    end

    def gzip_import_spool
      dir = File.join(Reach::Paths.import_spool_dir, SPOOL_ADMITTED)
      return 0 unless File.directory?(dir)

      Dir.children(dir).sort.inject(0) do |count, name|
        next count if name.end_with?(".gz") || name.include?(".tmp.")

        path = File.join(dir, name)
        next count unless File.file?(path) && !File.symlink?(path)

        gzip_file(path) ? count + 1 : count
      end
    end

    def status(refresh: true)
      latest = last_measure
      if latest.nil? && refresh
        measured = measure!
        latest = measured == :busy ? nil : measured
      end
      state = read_state
      settings = config
      total = latest ? latest["total"] : nil
      job = state["compaction"].is_a?(Hash) ? state["compaction"] : {}
      job = job.merge("state" => "failed", "error" => "interrupted") if interrupted?(job)
      {
        "measure" => latest,
        "total_mb" => total ? mb_value(total) : nil,
        "warn_mb" => settings["warn_mb"],
        "demand_mb" => settings["demand_mb"],
        "tier" => total ? tier_for(total, settings) : 0,
        "demanded" => total ? total >= settings["demand_mb"] * MB : false,
        "warned_mb" => state["warned_mb"].to_i,
        "corpus_available" => !corpus_root.nil?,
        "compaction" => job.empty? ? { "state" => "idle" } : job
      }
    end

    def status_text(info)
      latest = info["measure"]
      lines = []
      if latest
        lines << "memory: #{mb_text(latest['total'])} MB (course memory #{mb_text(latest['corpus'])} MB, learned #{mb_text(latest['brain'])} MB), measured #{latest['measured_at']}"
      else
        lines << "memory: not measured yet"
      end
      lines << "warns at #{info['warn_mb'].join(', ')} MB; compaction required at #{info['demand_mb']} MB"
      level = if info["demanded"] then "at the limit: compaction required, imports refused"
              elsif info["tier"].positive? then "above the #{info['tier']} MB warning"
              else "below every warning"
              end
      lines << "level: #{level}"
      job = info["compaction"]
      detail = job["state"].to_s
      detail += " (#{job['reclaim']}, #{mb_text(job['before'])} MB to #{mb_text(job['after'])} MB)" if job["state"] == "done"
      lines << "compaction: #{detail}"
      lines << "corpus: #{info['corpus_available'] ? 'present' : 'none on this computer'}"
      lines.join("\n")
    end
  end
end
