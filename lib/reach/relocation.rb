require "json"
require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "securerandom"
require "time"

module Reach
  module Relocation
    SCHEMA = "reach.relocation/v1".freeze
    STAGING_NAME = ".reach-home.relocating".freeze
    NOTE_NAME = "rEach-has-moved.txt".freeze
    CHUNK_BYTES = 1_048_576
    VERIFY_ROUNDS = 3
    FREE_SPACE_MARGIN = 200 * 1024 * 1024
    INTENT_BATCH = 64
    FSYNC_EVERY = 64
    HEARTBEAT_S = 5
    AUTO_STATE_FILE = "relocation-auto.json".freeze
    AUTO_INTERVAL_S = 3600
    AUTO_JITTER_S = 600
    AUTO_MAX_ATTEMPTS = 5
    HOME_EXCLUDED = %w[
      state/relocation.lock state/relocation.json state/relocation.jsonl state/relocation-manifest.json
      state/relocation-auto.json RELOCATED.json
    ].freeze
    WORK_EXCLUDED = [NOTE_NAME].freeze
    UPDATE_BLOCKING_PHASES = %w[staged swapped refreshed].freeze
    REASONS = {
      "destination_occupied" => "something already in your rEach folder is in the way",
      "no_space" => "there is not enough free disk space",
      "source_busy" => "your files kept changing while they were copied",
      "update_in_progress" => "a rEach update is installing right now",
      "runtime_install_running" => "rEach's checking tools are installing right now",
      "enrollment_unreadable" => "your enrollment files could not be read",
      "enrollment_changed" => "your enrollment looked different after the copy",
      "overlap" => "the old and new folders overlap",
      "unreadable_source" => "a file could not be read",
      "copy_error" => "a file could not be copied",
      "verify_failed" => "the copy did not match the original"
    }.freeze

    class Failure < StandardError
      attr_reader :reason

      def initialize(reason, detail = nil)
        super(detail || reason)
        @reason = reason
      end
    end

    module_function

    def due?
      Reach::Paths.legacy_active?
    end

    def lock_path
      File.join(Reach::Paths.legacy_home, "state", "relocation.lock")
    end

    def lock_live?
      path = lock_path
      return false unless File.file?(path)

      File.open(path, "r") do |handle|
        if handle.flock(File::LOCK_SH | File::LOCK_NB)
          handle.flock(File::LOCK_UN)
          false
        else
          true
        end
      end
    rescue StandardError
      false
    end

    def hold!
      return unless lock_live?

      raise Reach::GateBlocked.new("M-RELOCATING", Reach::Messages.text("M-RELOCATING"))
    rescue Reach::GateBlocked
      raise
    rescue StandardError
      nil
    end

    def with_lock
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |handle|
        return :locked unless handle.flock(File::LOCK_EX | File::LOCK_NB)

        begin
          write_lock_body(handle)
          yield(handle)
        ensure
          handle.flock(File::LOCK_UN)
        end
      end
    end

    def write_lock_body(handle)
      handle.truncate(0)
      handle.rewind
      handle.write(JSON.generate("pid" => Process.pid, "heartbeat" => Time.now.utc.iso8601))
      handle.flush
    rescue StandardError
      nil
    end

    def context
      legacy_ws = Reach::Paths.workspace_root
      {
        legacy_home: Reach::Paths.legacy_home,
        legacy_ws: legacy_ws,
        root: Reach::Paths.root,
        staged: File.join(Reach::Paths.root, STAGING_NAME),
        final_home: Reach::Paths.new_home
      }
    end

    def outcome(phase, fields = {})
      { phase: phase }.merge(fields)
    end

    def run(trigger: "cli")
      return status_outcome unless due?
      return failed_outcome("destination_occupied") if quick_occupied(context)

      result = with_lock do |handle|
        perform(trigger, handle)
      end
      return outcome("in_progress", line: "rEach is already moving your files into your rEach folder. Nothing is lost; give it a moment.") if result == :locked

      result
    end

    def perform(trigger, handle)
      ctx = context
      ctx[:handle] = handle
      ctx[:heartbeat_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        deferred = deferral(ctx)
        return deferred if deferred

        mode = inspect_destination(ctx)
        return finish_switched(ctx, trigger) if mode == :switched

        relocate(ctx, trigger, mode)
      rescue Failure => e
        record_failure(ctx, e.reason, e.message)
        failed_outcome(e.reason, e.message)
      rescue SystemCallError => e
        reason = e.is_a?(Errno::ENOSPC) ? "no_space" : "copy_error"
        record_failure(ctx, reason, e.message)
        failed_outcome(reason, e.message)
      end
    end

    def deferral(ctx)
      manifest = Reach::Update.load_manifest
      if Reach::Update.installing?(manifest) || UPDATE_BLOCKING_PHASES.include?(manifest["phase"])
        return outcome("deferred", reason: "update_in_progress", line: "rEach will move your files after its update finishes. Nothing was changed.")
      end
      if Reach::RuntimeAuto.installing?
        return outcome("deferred", reason: "runtime_install_running", line: "rEach will move your files after its checking tools finish installing. Nothing was changed.")
      end
      nil
    rescue StandardError
      nil
    end

    def failed_outcome(reason, detail = nil)
      text = REASONS[reason] || reason.to_s
      outcome("failed", reason: reason, detail: detail, line: "rEach could not move your files into your rEach folder yet (#{text}). Nothing was changed or lost; your files are safe where they are.")
    end

    def record_failure(ctx, reason, detail)
      return unless File.directory?(ctx[:staged])

      update_state(ctx, "phase" => "failed", "reason" => reason, "detail" => detail.to_s, "failed_at" => now_s)
      log_event(File.join(ctx[:staged], "logs", "relocation.jsonl"), "event" => "relocation_failed", "reason" => reason, "detail" => detail.to_s)
    rescue StandardError
      nil
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def staged_state_path(ctx)
      File.join(ctx[:staged], "state", "relocation.json")
    end

    def journal_path(ctx)
      File.join(ctx[:staged], "state", "relocation.jsonl")
    end

    def manifest_path(ctx)
      File.join(ctx[:staged], "state", "relocation-manifest.json")
    end

    def read_json(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def write_json_atomic(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp-#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(data))
        file.flush
        file.fsync
      end
      File.rename(tmp, path)
    end

    def update_state(ctx, changes)
      path = staged_state_path(ctx)
      data = read_json(path) || {}
      write_json_atomic(path, data.merge(changes))
    end

    def log_event(path, record)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.puts(JSON.generate({ "at" => now_s }.merge(record)))
      end
    rescue StandardError
      nil
    end

    def heartbeat(ctx)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if now - ctx[:heartbeat_at] < HEARTBEAT_S

      ctx[:heartbeat_at] = now
      write_lock_body(ctx[:handle])
    end

    def inspect_destination(ctx)
      root = ctx[:root]
      final = ctx[:final_home]
      staged = ctx[:staged]

      legacy_real = real_or_expand(ctx[:legacy_home])
      work_real = real_or_expand(ctx[:legacy_ws])
      root_real = real_or_expand(root)
      [legacy_real, work_real].each do |tree|
        raise Failure.new("overlap", "#{root} overlaps #{tree}") if Reach::Paths.path_within?(root_real, tree) || Reach::Paths.path_within?(tree, root_real)
      end

      if File.exist?(final) || File.symlink?(final)
        state = read_json(File.join(final, "state", "relocation.json"))
        return :switched if state && state["phase"] == "switching" && state["schema"] == SCHEMA

        raise Failure.new("destination_occupied", final) unless bootstrap_only?(final)
      end

      return :fresh unless File.exist?(staged) || File.symlink?(staged)

      state = read_json(File.join(staged, "state", "relocation.json"))
      consistent = state && state["schema"] == SCHEMA && %w[copying verifying switching failed].include?(state["phase"]) &&
                   state["from_home"] == ctx[:legacy_home] && state["to_root"] == root && File.file?(File.join(staged, "state", "relocation.jsonl")) &&
                   journal_parses?(File.join(staged, "state", "relocation.jsonl"))
      return :resume if consistent

      :fresh
    end

    def bootstrap_only?(path)
      return false unless File.directory?(path) && !File.symlink?(path)

      Dir.children(path) == ["bootstrap"] && File.directory?(File.join(path, "bootstrap")) && !File.symlink?(File.join(path, "bootstrap"))
    rescue StandardError
      false
    end

    def journal_parses?(path)
      File.foreach(path) do |line|
        next if line.strip.empty?

        JSON.parse(line)
      end
      true
    rescue StandardError
      false
    end

    def real_or_expand(path)
      File.exist?(path) ? File.realpath(path) : File.expand_path(path)
    end

    def load_journal(path)
      table = {}
      return table unless File.file?(path)

      File.foreach(path) do |line|
        next if line.strip.empty?

        begin
          record = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        table[record["rel"]] = record if record.is_a?(Hash) && record["rel"]
      end
      table
    end

    class Journal
      def initialize(path, table)
        @path = path
        @table = table
        @pending = 0
        FileUtils.mkdir_p(File.dirname(path))
        @file = File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600)
      end

      attr_reader :table

      def [](key)
        @table[key]
      end

      def key?(key)
        @table.key?(key)
      end

      def add(record, sync: false)
        @table[record["rel"]] = record
        @file.write("#{JSON.generate(record)}\n")
        @pending += 1
        flush(true) if sync || @pending >= FSYNC_EVERY
      end

      def flush(sync = true)
        @file.flush
        @file.fsync if sync
        @pending = 0
      end

      def close
        flush(true)
        @file.close
      end
    end

    def relocate(ctx, trigger, mode)
      sources = walk_all(ctx)
      guard_free_space(ctx, sources)
      before = enrollment_snapshot(ctx[:legacy_home])

      staged_exists = File.exist?(ctx[:staged]) || File.symlink?(ctx[:staged])
      inherited = mode == :fresh && staged_exists ? inherited_keys(ctx) : []
      known = if mode == :resume
                load_journal(journal_path(ctx))
              else
                inherited.each_with_object({}) { |key, table| table[key] = true }
              end
      check_destination(ctx, sources, known)
      set_aside_staged(ctx) if mode == :fresh && staged_exists

      journal = nil
      begin
        if mode == :fresh
          FileUtils.mkdir_p(File.join(ctx[:staged], "state"))
          File.chmod(0o700, ctx[:staged])
          write_json_atomic(
            staged_state_path(ctx),
            "schema" => SCHEMA, "id" => SecureRandom.hex(8), "phase" => "copying", "from_home" => ctx[:legacy_home],
            "from_workspace" => ctx[:legacy_ws], "to_root" => ctx[:root], "started_at" => now_s, "trigger" => trigger,
            "enrollment" => before
          )
        end
        table = load_journal(journal_path(ctx))
        journal = Journal.new(journal_path(ctx), table)
        inherited.each { |key| journal.add({ "rel" => key, "kind" => "inherited", "status" => "copying" }) unless journal.key?(key) }

        update_state(ctx, "phase" => "copying")
        copy_entries(ctx, sources, journal)
        journal.flush

        update_state(ctx, "phase" => "verifying")
        final_sources = verify_rounds(ctx, sources, journal)

        manifest = write_manifest(ctx, final_sources, journal)

        after = enrollment_snapshot(File.join(ctx[:staged]))
        raise Failure.new("enrollment_changed", "before #{before.inspect} after #{after.inspect}") unless before == after

        rewrite_staged(ctx, final_sources)
        final_sources = recheck_before_switch(ctx, final_sources, journal)
        journal.close
        journal = nil

        update_state(ctx, "phase" => "switching", "manifest_digest" => manifest["root_digest"], "files" => manifest["files"], "bytes" => manifest["bytes"])
        switch!(ctx, manifest)
      ensure
        journal.close if journal
      end
    end

    def inherited_keys(ctx)
      inherited = []
      journal_file = journal_path(ctx)
      return inherited unless File.file?(journal_file)

      File.foreach(journal_file) do |line|
        begin
          record = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        inherited << record["rel"] if record.is_a?(Hash) && record["rel"].to_s.start_with?("work/")
      end
      inherited.uniq
    rescue StandardError
      []
    end

    def set_aside_staged(ctx)
      target = File.join(ctx[:root], ".reach-home.failed-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(2)}")
      File.rename(ctx[:staged], target)
      target
    end

    def walk_all(ctx)
      home = walk_tree(:home, ctx[:legacy_home], HOME_EXCLUDED)
      work = walk_tree(:work, ctx[:legacy_ws], WORK_EXCLUDED)
      home + work
    end

    def walk_tree(tree, base, excluded)
      return [] unless File.directory?(base)

      real = File.realpath(base)
      out = []
      walk_dir(tree, real, "", excluded, out)
      out
    end

    def walk_dir(tree, base, rel, excluded, out)
      dir = rel.empty? ? base : File.join(base, rel)
      Dir.children(dir).sort.each do |name|
        child = rel.empty? ? name : File.join(rel, name)
        next if excluded.include?(child)

        full = File.join(base, child)
        begin
          stat = File.lstat(full)
        rescue Errno::ENOENT
          next
        end
        entry = { tree: tree, rel: child, base: base, src: full, mode: stat.mode & 0o7777, mtime: stat.mtime.to_i, mtime_nsec: stat.mtime.nsec, atime: stat.atime.to_i }
        if stat.symlink?
          entry[:kind] = "symlink"
          entry[:target] = File.readlink(full)
          out << entry
        elsif stat.directory?
          entry[:kind] = "dir"
          out << entry
          walk_dir(tree, base, child, excluded, out)
        elsif stat.file?
          entry[:kind] = "file"
          entry[:size] = stat.size
          out << entry
        else
          entry[:kind] = "special"
          out << entry
        end
      end
    rescue Errno::EACCES, Errno::EPERM => e
      raise Failure.new("unreadable_source", e.message)
    end

    def key_for(entry)
      "#{entry[:tree]}/#{entry[:rel]}"
    end

    def dest_for(ctx, entry)
      if entry[:tree] == :home
        File.join(ctx[:staged], entry[:rel])
      else
        File.join(ctx[:root], entry[:rel])
      end
    end

    def guard_free_space(ctx, sources)
      bytes = sources.select { |entry| entry[:kind] == "file" }.map { |entry| entry[:size] }.sum
      free = free_bytes(nearest_existing(ctx[:root]))
      return nil if free.nil?

      needed = (2 * bytes) + FREE_SPACE_MARGIN
      raise Failure.new("no_space", "need #{needed} bytes, #{free} free") if free < needed

      nil
    end

    def nearest_existing(path)
      current = File.expand_path(path)
      current = File.dirname(current) until File.exist?(current) || current == File.dirname(current)
      current
    end

    def free_bytes(path)
      if Reach::Runtime.windows?
        letter = path[0, 1]
        out, _err, status = Open3.capture3("powershell", "-NoProfile", "-Command", "(Get-PSDrive #{letter}).Free")
        return status.success? && out.strip =~ /\A\d+\z/ ? out.strip.to_i : nil
      end

      out, _err, status = Open3.capture3("df", "-Pk", path)
      return nil unless status.success?

      line = out.lines[1].to_s.split
      line.length >= 4 && line[3] =~ /\A\d+\z/ ? line[3].to_i * 1024 : nil
    rescue StandardError
      nil
    end

    def check_destination(ctx, sources, journal)
      conflicts = []
      sources.each do |entry|
        next unless entry[:tree] == :work

        dest = dest_for(ctx, entry)
        stat = begin
          File.lstat(dest)
        rescue Errno::ENOENT
          next
        end
        next if journal.key?(key_for(entry))
        next if entry[:kind] == "dir" && stat.directory?

        conflicts << dest
      end

      known = {}
      sources.each { |entry| known[key_for(entry)] = true if entry[:tree] == :work }
      %w[deliverables extracurricular].each do |top|
        base = File.join(ctx[:root], top)
        begin
          stat = File.lstat(base)
        rescue Errno::ENOENT
          next
        end
        unless stat.directory?
          conflicts << base unless journal.key?("work/#{top}")
          next
        end
        stray_files(base, "work/#{top}").each { |key, path| conflicts << path unless journal.key?(key) }
      end
      raise Failure.new("destination_occupied", conflicts.first(5).join(", ")) unless conflicts.empty?

      nil
    end

    def stray_files(dir, key_prefix, found = [])
      Dir.children(dir).sort.each do |name|
        full = File.join(dir, name)
        key = "#{key_prefix}/#{name}"
        stat = File.lstat(full)
        if stat.directory?
          stray_files(full, key, found)
        else
          found << [key, full]
        end
      end
      found
    rescue SystemCallError
      found
    end

    def copy_entries(ctx, entries, journal)
      directories = entries.select { |entry| entry[:kind] == "dir" }
      others = entries.reject { |entry| entry[:kind] == "dir" }

      announce_intents(ctx, directories.select { |entry| entry[:tree] == :work }, journal)
      directories.each do |entry|
        heartbeat(ctx)
        make_directory(ctx, entry, journal)
      end

      others.each_slice(INTENT_BATCH) do |batch|
        announce_intents(ctx, batch.select { |entry| entry[:tree] == :work }, journal)
        batch.each do |entry|
          heartbeat(ctx)
          copy_one(ctx, entry, journal)
        end
      end

      directories.reverse_each do |entry|
        finish_directory(ctx, entry, journal)
      end
      nil
    end

    def announce_intents(ctx, batch, journal)
      pending = batch.reject { |entry| journal.key?(key_for(entry)) }
      return if pending.empty?

      pending.each do |entry|
        record = { "rel" => key_for(entry), "kind" => entry[:kind], "status" => "copying" }
        record["maybe_created"] = !(File.exist?(dest_for(ctx, entry)) || File.symlink?(dest_for(ctx, entry))) if entry[:kind] == "dir"
        record["preexisting"] = File.exist?(dest_for(ctx, entry)) || File.symlink?(dest_for(ctx, entry)) if entry[:kind] == "file"
        journal.add(record)
      end
      journal.flush(true)
    end

    def make_directory(ctx, entry, journal)
      dest = dest_for(ctx, entry)
      key = key_for(entry)
      record = journal[key]
      existed = File.directory?(dest) && !File.symlink?(dest)
      if existed
        created = record && (record["created"] || record["maybe_created"])
        created = true if entry[:tree] == :home
        journal.add({ "rel" => key, "kind" => "dir", "status" => "copying", "created" => created ? true : false })
        make_owner_writable(dest) if created
        return
      end

      raise Failure.new("destination_occupied", dest) if File.exist?(dest) || File.symlink?(dest)

      Dir.mkdir(dest, 0o700)
      journal.add({ "rel" => key, "kind" => "dir", "status" => "copying", "created" => true })
    end

    def make_owner_writable(path)
      File.chmod(0o700, path)
    rescue StandardError
      nil
    end

    def finish_directory(ctx, entry, journal)
      key = key_for(entry)
      record = journal[key]
      return unless record

      unless record["created"]
        journal.add({ "rel" => key, "kind" => "dir", "status" => "existing", "created" => false })
        return
      end

      dest = dest_for(ctx, entry)
      File.chmod(entry[:mode], dest)
      apply_times(dest, entry)
      journal.add({ "rel" => key, "kind" => "dir", "status" => "copied", "mode" => entry[:mode], "mtime" => entry[:mtime], "mtime_nsec" => entry[:mtime_nsec], "created" => true })
    rescue Errno::ENOENT
      nil
    end

    def apply_times(dest, entry)
      mtime = Time.at(entry[:mtime], Rational(entry[:mtime_nsec], 1000))
      atime = Time.at(entry[:atime] || entry[:mtime])
      File.utime(atime, mtime, dest)
    rescue StandardError
      nil
    end

    def copy_one(ctx, entry, journal)
      key = key_for(entry)
      dest = dest_for(ctx, entry)
      case entry[:kind]
      when "file"
        record = journal[key]
        return if file_already_copied?(entry, record, dest)
        raise Failure.new("destination_occupied", dest) if record && record["preexisting"]

        digest, bytes = copy_file(entry[:src], dest, entry)
        journal.add({
          "rel" => key, "kind" => "file", "bytes" => bytes, "sha256" => digest, "mode" => entry[:mode],
          "mtime" => entry[:mtime], "mtime_nsec" => entry[:mtime_nsec], "src_size" => entry[:size], "status" => "copied"
        })
      when "symlink"
        copy_symlink(entry, dest, journal, key)
      else
        journal.add({ "rel" => key, "kind" => "special", "mode" => entry[:mode], "mtime" => entry[:mtime], "status" => "skipped_special" })
      end
    end

    def file_already_copied?(entry, record, dest)
      return false unless record && record["status"] == "copied" && record["kind"] == "file"
      return false unless record["src_size"] == entry[:size] && record["mtime"] == entry[:mtime] && record["mtime_nsec"] == entry[:mtime_nsec]

      stat = File.lstat(dest)
      stat.file? && stat.size == entry[:size]
    rescue SystemCallError
      false
    end

    def copy_file(src, dest, entry)
      if File.exist?(dest) || File.symlink?(dest)
        raise Failure.new("destination_occupied", dest) if File.directory?(dest) || File.symlink?(dest)

        File.chmod(0o600, dest)
      end
      digest = Digest::SHA256.new
      bytes = 0
      buffer = +""
      File.open(src, "rb") do |input|
        File.open(dest, File::WRONLY | File::CREAT | File::TRUNC | File::BINARY, 0o600) do |output|
          while input.read(CHUNK_BYTES, buffer)
            digest << buffer
            output.write(buffer)
            bytes += buffer.bytesize
          end
          output.flush
          output.fsync
        end
      end
      File.chmod(entry[:mode], dest)
      apply_times(dest, entry)
      [digest.hexdigest, bytes]
    rescue Errno::EACCES, Errno::EPERM => e
      raise Failure.new("unreadable_source", e.message)
    end

    def copy_symlink(entry, dest, journal, key)
      if File.symlink?(dest)
        if File.readlink(dest) == entry[:target]
          journal.add({ "rel" => key, "kind" => "symlink", "target" => entry[:target], "status" => "copied" })
          return
        end
        raise Failure.new("destination_occupied", dest)
      end
      raise Failure.new("destination_occupied", dest) if File.exist?(dest)

      begin
        File.symlink(entry[:target], dest)
        journal.add({ "rel" => key, "kind" => "symlink", "target" => entry[:target], "status" => "copied" })
      rescue NotImplementedError, Errno::EPERM, Errno::EACCES
        journal.add({ "rel" => key, "kind" => "symlink", "target" => entry[:target], "status" => "skipped_symlink" })
      end
    end

    def file_digest(path)
      digest = Digest::SHA256.new
      buffer = +""
      File.open(path, "rb") do |file|
        digest << buffer while file.read(CHUNK_BYTES, buffer)
      end
      digest.hexdigest
    end

    def source_changed?(entry, record)
      return true unless record
      return true if record["status"] == "copying" || record["status"] == "inherited"

      case entry[:kind]
      when "file"
        !(record["kind"] == "file" && record["src_size"] == entry[:size] && record["mtime"] == entry[:mtime] && record["mtime_nsec"] == entry[:mtime_nsec])
      when "symlink"
        record["target"] != entry[:target]
      when "dir"
        false
      else
        false
      end
    end

    def dest_matches?(ctx, entry, record)
      dest = dest_for(ctx, entry)
      stat = File.lstat(dest)
      case entry[:kind]
      when "dir"
        stat.directory?
      when "symlink"
        return true if record && record["status"] == "skipped_symlink"

        stat.symlink? && File.readlink(dest) == entry[:target]
      when "file"
        stat.file? && stat.size == entry[:size] && file_digest(dest) == record["sha256"]
      else
        true
      end
    rescue SystemCallError
      false
    end

    def verify_rounds(ctx, first_sources, journal)
      sources = first_sources
      rounds = 0
      loop do
        heartbeat(ctx)
        changed = sources.select do |entry|
          record = journal[key_for(entry)]
          source_changed?(entry, record) || !dest_matches?(ctx, entry, record)
        end
        return sources if changed.empty?

        rounds += 1
        raise Failure.new("source_busy", changed.first(5).map { |entry| entry[:src] }.join(", ")) if rounds > VERIFY_ROUNDS

        copy_entries(ctx, changed, journal)
        journal.flush
        sources = walk_all(ctx)
      end
    end

    def recheck_before_switch(ctx, sources, journal)
      rounds = 0
      current = walk_all(ctx)
      loop do
        changed = current.select { |entry| source_changed?(entry, journal[key_for(entry)]) }
        return current if changed.empty?

        rounds += 1
        raise Failure.new("source_busy", changed.first(5).map { |entry| entry[:src] }.join(", ")) if rounds > VERIFY_ROUNDS

        copy_entries(ctx, changed, journal)
        journal.flush
        rewrite_staged(ctx, current)
        current = walk_all(ctx)
      end
    end

    def write_manifest(ctx, sources, journal)
      files = 0
      dirs = 0
      links = 0
      bytes = 0
      lines = []
      sources.each do |entry|
        record = journal[key_for(entry)]
        next unless record

        lines << JSON.generate(record)
        case entry[:kind]
        when "file"
          files += 1
          bytes += record["bytes"].to_i
          raise Failure.new("verify_failed", entry[:src]) unless record["bytes"].to_i == entry[:size]
        when "dir"
          dirs += 1
        when "symlink"
          links += 1
        end
      end
      digest = Digest::SHA256.hexdigest(lines.sort.join("\n"))
      manifest = { "files" => files, "dirs" => dirs, "symlinks" => links, "bytes" => bytes, "root_digest" => digest }
      write_json_atomic(manifest_path(ctx), manifest)
      manifest
    end

    def enrollment_snapshot(home)
      install = File.join(home, "install.yml")
      return { "enrolled" => false } unless File.file?(install)

      paths = {
        "key" => File.join(home, "keys", "install.pem"),
        "fingerprint" => File.join(home, "fingerprint.json"),
        "stamp" => File.join(home, "stamp.json")
      }
      present = {}
      paths.each do |name, path|
        present[name] = File.file?(path)
        next unless present[name]

        begin
          File.open(path, "rb") { |file| file.read(1) }
        rescue SystemCallError
          raise Failure.new("enrollment_unreadable", path)
        end
      end

      snapshot = { "enrolled" => true, "present" => present }
      return snapshot unless present.values.all?

      begin
        salt = JSON.parse(File.read(paths["fingerprint"]))["salt"]
        stamp = JSON.parse(File.read(paths["stamp"]))
        key = Reach::Crypto.load_private_key(File.read(paths["key"])).public_key
        binding_hashes = Reach::Fingerprint.binding_for(salt, key)
        hostname_hash = Reach::Fingerprint.component(salt, "hostname", Reach::Fingerprint.hostname)
        digests = Reach::Fingerprint.digests_for(binding_hashes, hostname_hash)
        snapshot["loose_match"] = digests[0] == stamp["fingerprint_digest"]
        snapshot["strict_match"] = digests[1] == stamp["fingerprint_strict_digest"]
      rescue StandardError => e
        snapshot["error"] = e.class.name
      end
      snapshot
    end

    def rewrite_staged(ctx, sources)
      final_home = ctx[:final_home]
      root = ctx[:root]
      rekey_pairs = space_pairs(ctx, sources)

      Reach::Paths.with_override(home: final_home, root: root) do
        targets = [root]
        extracurricular = File.join(root, "extracurricular")
        targets << extracurricular if File.directory?(extracurricular)
        rekey_pairs.each { |pair| targets << pair[:new] if pair[:slice] && File.directory?(pair[:new]) }
        targets.uniq.each do |target|
          begin
            Reach::Harness.configure_all(target)
          rescue StandardError
            nil
          end
        end
      end

      rewrite_shim_root(ctx)
      rewrite_update_manifest(ctx)
      rekey_transcript_digests(ctx, rekey_pairs)
      rewrite_last_install(ctx)
    end

    def space_pairs(ctx, sources)
      pairs = []
      sources.each do |entry|
        next unless entry[:tree] == :work

        if entry[:kind] == "file" && File.basename(entry[:rel]) == "slice.json" && File.basename(File.dirname(entry[:rel])) == ".reach"
          relative = File.dirname(File.dirname(entry[:rel]))
          pairs << { slice: true, old: File.join(ctx[:legacy_ws], relative), new: File.join(ctx[:root], relative) }
        elsif entry[:kind] == "dir" && entry[:rel] == "extracurricular"
          pairs << { slice: false, old: File.join(ctx[:legacy_ws], "extracurricular"), new: File.join(ctx[:root], "extracurricular") }
        end
      end
      pairs
    end

    def rewrite_shim_root(ctx)
      plugin = File.join(ctx[:staged], "plugin")
      return unless File.file?(File.join(plugin, "exe", "reach"))

      root_file = File.join(ctx[:staged], "bin", "root")
      return unless File.file?(root_file)

      File.write(root_file, "#{File.join(ctx[:final_home], 'plugin')}\n")
    end

    def rewrite_update_manifest(ctx)
      path = File.join(ctx[:staged], "state", "update.json")
      data = read_json(path)
      return unless data && data["phase"] == "completed"

      rewritten = rewrite_strings(data, ctx[:legacy_home], ctx[:final_home])
      return if rewritten == data

      File.write(path, JSON.generate(rewritten))
    end

    def rewrite_strings(value, from, to)
      case value
      when String
        value == from || value.start_with?("#{from}#{File::SEPARATOR}") ? "#{to}#{value[from.length..-1]}" : value
      when Array
        value.map { |item| rewrite_strings(item, from, to) }
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key] = rewrite_strings(item, from, to) }
      else
        value
      end
    end

    def rekey_transcript_digests(ctx, pairs)
      dir = File.join(ctx[:staged], "transcripts", "spaces")
      return unless File.directory?(dir)

      pairs.each do |pair|
        old_name = File.join(dir, "#{Reach::Crypto.digest_hex(File.expand_path(pair[:old]))}.json")
        new_name = File.join(dir, "#{Reach::Crypto.digest_hex(File.expand_path(pair[:new]))}.json")
        next unless File.file?(old_name)
        next if File.exist?(new_name)

        File.rename(old_name, new_name)
      end
    end

    def rewrite_last_install(ctx)
      note = File.join(ctx[:staged], "bootstrap", "last-install.txt")
      return unless File.file?(note)

      legacy_plugin = File.join(ctx[:legacy_home], "plugin")
      return unless File.read(note).strip == legacy_plugin

      File.write(note, "#{File.join(ctx[:final_home], 'plugin')}\n")
    end

    def switch!(ctx, manifest)
      final = ctx[:final_home]
      aside = nil
      if File.exist?(final) || File.symlink?(final)
        raise Failure.new("destination_occupied", final) unless bootstrap_only?(final)

        merge_bootstrap(ctx, final)
        aside = "#{final}.pre-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(2)}"
        File.rename(final, aside)
      end
      File.rename(ctx[:staged], final)
      finish_switch(ctx, manifest, aside)
    end

    def merge_bootstrap(ctx, existing)
      source = File.join(existing, "bootstrap")
      target = File.join(ctx[:staged], "bootstrap")
      FileUtils.mkdir_p(target)
      Dir.children(source).sort.each do |name|
        from = File.join(source, name)
        next unless File.file?(from) && !File.symlink?(from)

        to = File.join(target, name)
        File.chmod(0o600, to) if File.file?(to)
        FileUtils.cp(from, to)
      end
      rewrite_last_install(ctx)
    end

    def finish_switch(ctx, manifest, aside)
      final = ctx[:final_home]
      state_path = File.join(final, "state", "relocation.json")
      state = read_json(state_path) || {}
      completed_at = now_s
      write_json_atomic(state_path, state.merge("phase" => "completed", "completed_at" => completed_at, "manifest_digest" => manifest["root_digest"], "bootstrap_aside" => aside))
      Reach::Paths.forget_resolution!

      pointer = File.join(ctx[:legacy_home], "RELOCATED.json")
      write_json_atomic(pointer, "to_home" => final, "to_root" => ctx[:root], "completed_at" => completed_at, "manifest_digest" => manifest["root_digest"])

      log_event(File.join(final, "logs", "relocation.jsonl"), "event" => "relocated", "from" => ctx[:legacy_home], "to" => final, "files" => manifest["files"], "bytes" => manifest["bytes"])
      leave_note(ctx, state["started_at"])
      refresh_harnesses(ctx)
      refresh_root_space

      outcome(
        "completed",
        files: manifest["files"], bytes: manifest["bytes"], completed_at: completed_at,
        line: "rEach moved everything into your rEach folder (#{ctx[:root]}): #{manifest['files']} files, #{format_bytes(manifest['bytes'])}. The old folders were left exactly as they were."
      )
    end

    def finish_switched(ctx, _trigger)
      final = ctx[:final_home]
      manifest = read_json(File.join(final, "state", "relocation-manifest.json"))
      raise Failure.new("verify_failed", "manifest missing") unless manifest

      journal = load_journal(File.join(final, "state", "relocation.jsonl"))
      journal.each do |key, record|
        next unless record["kind"] == "file" && record["status"] == "copied" && key.start_with?("home/")

        path = File.join(final, key.sub(%r{\Ahome/}, ""))
        raise Failure.new("verify_failed", path) unless File.file?(path)
      end
      finish_switch(ctx, manifest, nil)
    end

    def leave_note(ctx, started_at)
      return unless File.directory?(ctx[:legacy_ws])

      started = begin
        Time.iso8601(started_at.to_s)
      rescue ArgumentError
        nil
      end
      return unless started

      newest = walk_tree(:work, ctx[:legacy_ws], WORK_EXCLUDED).map { |entry| Time.at(entry[:mtime]) }.max
      return if newest && newest > started

      path = File.join(ctx[:legacy_ws], NOTE_NAME)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        file.write("rEach moved everything it keeps into the rEach folder in your home folder (#{ctx[:root]}). Work there. This folder was left as it was and is no longer used.\n")
      end
    rescue StandardError
      nil
    end

    def refresh_root_space
      Reach::Workspace.provision_extracurricular!
    rescue StandardError
      nil
    end

    def refresh_harnesses(ctx)
      plugin = File.join(ctx[:final_home], "plugin")
      legacy_plugin = File.join(ctx[:legacy_home], "plugin")
      return unless File.directory?(plugin)

      links = [File.expand_path("~/.gemini/config/plugins/reach"), File.expand_path("~/.gemini/antigravity-cli/plugins/reach")]
      links.each { |link| repoint(link, plugin, legacy_plugin) }

      config_path = Reach::Harness.hermes_config_path
      if config_path
        skills = File.join(File.dirname(config_path), "skills")
        %w[reach-assistant reach-course].each do |name|
          repoint(File.join(skills, name), File.join(plugin, "skills", name), File.join(legacy_plugin, "skills", name))
        end
        Reach::Harness.configure("hermes", nil)
      end

      refresh_harness_sources(ctx, plugin)
    rescue StandardError
      nil
    end

    def refresh_harness_sources(ctx, plugin)
      return unless File.file?(File.join(plugin, "exe", "reach"))

      results = Reach::HarnessSource.repoint(plugin)
      if results["claude-code"] == "ok"
        _out, _err, updated = Reach::HarnessSource.capture(%w[claude plugin marketplace update reach])
        _out, _err, updated = Reach::HarnessSource.capture(%w[claude plugin update reach@reach --scope user]) if updated
        results["claude-code"] = "failed: refresh did not complete" unless updated
      end
      if results["codex"] == "ok"
        _out, err, added = Reach::HarnessSource.capture(%w[codex plugin add reach@reach])
        results["codex"] = "failed: #{Reach::HarnessSource.first_line(err)}" unless added
      end
      state_path = File.join(ctx[:final_home], "state", "relocation.json")
      state = read_json(state_path) || {}
      write_json_atomic(state_path, state.merge("harness_sources" => results))
    rescue StandardError
      nil
    end

    def repoint(link, new_target, old_target)
      return unless File.symlink?(link)

      current = File.readlink(link)
      return unless current == old_target || current.start_with?("#{old_target}#{File::SEPARATOR}")

      temp = "#{link}.reach-new-#{Process.pid}"
      File.symlink(new_target, temp)
      File.rename(temp, link)
    rescue StandardError
      nil
    end

    def format_bytes(bytes)
      value = bytes.to_f
      return "#{value.to_i} bytes" if value < 1024

      units = %w[KB MB GB TB]
      unit = "KB"
      value /= 1024
      units.each do |name|
        unit = name
        break if value < 1024

        value /= 1024
      end
      format("%.1f %s", value, unit)
    end

    def status
      ctx = context
      if Reach::Paths.relocation_completed?
        state = read_json(Reach::Paths.relocation_pointer_file) || {}
        return { state: "completed", date: state["completed_at"] }
      end
      return { state: "none-needed" } unless due?
      return { state: "in-progress" } if lock_live?

      staged = read_json(staged_state_path(ctx))
      return { state: "failed", reason: staged["reason"] } if staged && staged["phase"] == "failed"

      occupied = quick_occupied(ctx)
      return { state: "failed", reason: "destination_occupied" } if occupied

      { state: "pending" }
    rescue StandardError
      { state: "pending" }
    end

    def quick_occupied(ctx)
      final = ctx[:final_home]
      if File.exist?(final) || File.symlink?(final)
        state = read_json(File.join(final, "state", "relocation.json"))
        return false if state && state["phase"] == "switching"
        return true unless bootstrap_only?(final)
      end

      journal = load_journal(journal_path(ctx))
      %w[deliverables extracurricular].each do |top|
        base = File.join(ctx[:root], top)
        next unless File.lstat(base).directory?

        return true if stray_files(base, "work/#{top}").any? { |key, _path| !journal.key?(key) }
      end
      false
    rescue Errno::ENOENT
      false
    rescue StandardError
      false
    end

    def status_outcome
      state = status
      line = case state[:state]
             when "completed" then "rEach has already moved your files into your rEach folder (#{state[:date]})."
             when "none-needed" then "Nothing to move: rEach already keeps everything in your rEach folder."
             when "in-progress" then "rEach is moving your files into your rEach folder right now."
             when "failed" then "rEach could not move your files into your rEach folder yet (#{REASONS[state[:reason]] || state[:reason]}). Nothing was changed or lost."
             else "rEach will move your files into your rEach folder the next time a session starts."
             end
      outcome(state[:state], reason: state[:reason], line: line)
    end

    def doctor_line
      state = status
      case state[:state]
      when "completed" then "R-DOC-RELOCATION: completed #{state[:date]}"
      when "failed" then "R-DOC-RELOCATION: failed #{state[:reason]}"
      else "R-DOC-RELOCATION: #{state[:state]}"
      end
    end

    def folder_line
      "rEach folder: #{Reach::Paths.root}"
    end

    def auto_state_path
      File.join(Reach::Paths.legacy_home, "state", AUTO_STATE_FILE)
    end

    def load_auto_state
      data = JSON.parse(File.read(auto_state_path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def start(now = Time.now)
      return nil unless due?
      return nil if lock_live?

      state = load_auto_state
      return nil if state["attempts"].to_i >= AUTO_MAX_ATTEMPTS

      next_at = begin
        Time.parse(state["next_at"].to_s)
      rescue ArgumentError
        nil
      end
      return nil if next_at && now < next_at

      state["attempts"] = state["attempts"].to_i + 1
      state["started_at"] = now.utc.iso8601
      state["next_at"] = (now + AUTO_INTERVAL_S + rand(AUTO_JITTER_S + 1)).utc.iso8601
      write_json_atomic(auto_state_path, state)
      spawn_detached
    rescue StandardError
      nil
    end

    def spawn_detached
      exe = File.join(Reach::Runtime.root, "exe", "reach")
      options = { in: File::NULL, out: File::NULL, err: File::NULL }
      if Reach::Runtime.windows?
        options[:new_pgroup] = true
      else
        options[:pgroup] = true
      end
      pid = Process.spawn(RbConfig.ruby, exe, "relocate", options)
      Process.detach(pid)
      pid
    end
  end
end
