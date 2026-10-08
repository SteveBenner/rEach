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
    LOCK_NAME = ".reach-home.relocation.lock".freeze
    AUTO_STATE_NAME = ".reach-home.relocation-auto.json".freeze
    POINTER_NAME = "RELOCATED.json".freeze
    CHUNK_BYTES = 1_048_576
    VERIFY_ROUNDS = 3
    FREE_SPACE_MARGIN = 200 * 1024 * 1024
    FSYNC_EVERY = 64
    HEARTBEAT_S = 5
    AUTO_INTERVAL_S = 3600
    AUTO_JITTER_S = 600
    AUTO_MAX_ATTEMPTS = 5
    HOME_EXCLUDED = [POINTER_NAME].freeze
    STRAY_EXCLUDED = [POINTER_NAME, "state/relocation.json", "state/relocation.jsonl", "state/relocation-manifest.json"].freeze
    MOVING_SUFFIX = ".reach-moving".freeze
    SCAN_MAX_BYTES = 5 * 1024 * 1024
    REASONS = {
      "destination_occupied" => "something already in your reach-work folder is in the way",
      "no_space" => "there is not enough free disk space",
      "source_busy" => "rEach's files kept changing while they were copied",
      "update_in_progress" => "a rEach update is installing right now",
      "runtime_install_running" => "rEach's checking tools are installing right now",
      "enrollment_unreadable" => "your enrollment files could not be read",
      "enrollment_changed" => "your enrollment looked different after the copy",
      "overlap" => "the old and new folders overlap",
      "unreadable_source" => "a file could not be read",
      "copy_error" => "a file could not be copied",
      "verify_failed" => "the copy did not match the original",
      "rollback_incomplete" => "a folder could not be put back after the move stopped"
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
      Reach::Paths.legacy_active? || Reach::Paths.stray_active?
    end

    def lock_path
      File.join(Reach::Paths.workspace_base, LOCK_NAME)
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
      Reach::Paths.require_home!
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
      base = Reach::Paths.workspace_base
      stray = Reach::Paths.stray_active?
      {
        legacy_home: stray ? Reach::Paths.root : Reach::Paths.legacy_home,
        stray_base: stray ? Reach::Paths.stray_base : nil,
        base: base,
        staged: File.join(base, STAGING_NAME),
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
      return outcome("in_progress", line: "rEach is already moving its files into your reach-work folder. Nothing is lost; give it a moment.") if result == :locked

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

    def deferral(_ctx)
      manifest = Reach::Update.load_manifest
      if Reach::Update.blocks_relocation?(manifest)
        return outcome("deferred", reason: "update_in_progress", line: "rEach will move its files after its update finishes. Nothing was changed.")
      end
      if Reach::RuntimeAuto.installing?
        return outcome("deferred", reason: "runtime_install_running", line: "rEach will move its files after its checking tools finish installing. Nothing was changed.")
      end
      nil
    rescue StandardError
      nil
    end

    def failure_tail(reason)
      return "Nothing was deleted or lost, but part of rEach's folder is still in your reach-work folder under a hidden name that starts with .reach-home and contains set-aside or pre; tell your instructor." if reason == "rollback_incomplete"

      "Nothing was changed or lost; your files are safe where they are."
    end

    def failed_outcome(reason, detail = nil)
      text = REASONS[reason] || reason.to_s
      outcome("failed", reason: reason, detail: detail, line: "rEach could not move its files into your reach-work folder yet (#{text}). #{failure_tail(reason)}")
    end

    def record_failure(ctx, reason, detail)
      return unless File.directory?(ctx[:staged])
      return unless read_json(staged_state_path(ctx))

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

    def present?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def inspect_destination(ctx)
      final = ctx[:final_home]
      staged = ctx[:staged]

      legacy_real = real_or_expand(ctx[:legacy_home])
      base_real = real_or_expand(ctx[:base])
      if Reach::Paths.path_within?(base_real, legacy_real) || Reach::Paths.path_within?(legacy_real, base_real)
        raise Failure.new("overlap", "#{ctx[:base]} overlaps #{ctx[:legacy_home]}")
      end

      if present?(final)
        state = read_json(File.join(final, "state", "relocation.json"))
        return :switched if state && state["phase"] == "switching" && state["schema"] == SCHEMA

        if displaceable?(ctx, final)
          ctx[:displace] = true
        elsif !bootstrap_only?(final)
          raise Failure.new("destination_occupied", final)
        end
      end

      return :fresh unless present?(staged)

      state = read_json(File.join(staged, "state", "relocation.json"))
      raise Failure.new("destination_occupied", staged) unless state && state["schema"] == SCHEMA

      journal_file = File.join(staged, "state", "relocation.jsonl")
      consistent = %w[copying verifying switching failed].include?(state["phase"]) &&
                   state["from_home"] == ctx[:legacy_home] && state["to_home"] == final &&
                   File.file?(journal_file) && journal_parses?(journal_file)
      return :resume if consistent

      :set_aside
    end

    def displaceable?(ctx, final)
      ctx[:stray_base] && !bootstrap_only?(final) && !Reach::Paths.enrolled_home?(final)
    end

    def set_aside_final(ctx, final)
      aside = "#{ctx[:base]}/#{Reach::Paths::NEW_HOME_NAME}.set-aside-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
      aside = "#{aside}-#{SecureRandom.hex(2)}" if present?(aside)
      File.rename(final, aside)
      ctx[:set_aside] = File.basename(aside)
      log_event(File.join(ctx[:staged], "logs", "relocation.jsonl"), "event" => "set_aside", "to" => ctx[:set_aside])
      aside
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
      sources = walk_home(ctx)
      guard_free_space(ctx, sources)
      before = enrollment_state(ctx[:legacy_home])

      set_aside_staged(ctx) if mode == :set_aside

      journal = nil
      begin
        if mode != :resume
          FileUtils.mkdir_p(File.join(ctx[:staged], "state"))
          File.chmod(0o700, ctx[:staged])
          write_json_atomic(
            staged_state_path(ctx),
            "schema" => SCHEMA, "id" => SecureRandom.hex(8), "phase" => "copying", "from_home" => ctx[:legacy_home],
            "to_home" => ctx[:final_home], "workspace" => ctx[:base], "started_at" => now_s, "trigger" => trigger,
            "enrollment" => before
          )
        end
        table = load_journal(journal_path(ctx))
        journal = Journal.new(journal_path(ctx), table)

        update_state(ctx, "phase" => "copying")
        copy_entries(ctx, sources, journal)
        journal.flush

        update_state(ctx, "phase" => "verifying")
        final_sources = verify_rounds(ctx, sources, journal)

        manifest = write_manifest(ctx, final_sources, journal)

        after = enrollment_state(ctx[:staged])
        raise Failure.new("enrollment_changed", "before #{before.inspect} after #{after.inspect}") unless before == after

        rewrite_staged(ctx)
        final_sources = recheck_before_switch(ctx, final_sources, journal)
        journal.close
        journal = nil

        update_state(ctx, "phase" => "switching", "manifest_digest" => manifest["root_digest"], "files" => manifest["files"], "bytes" => manifest["bytes"])
        switch!(ctx, manifest)
      ensure
        journal.close if journal
      end
    end

    def set_aside_staged(ctx)
      target = File.join(ctx[:base], ".reach-home.failed-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(2)}")
      File.rename(ctx[:staged], target)
      target
    end

    def walk_home(ctx)
      walk_tree(ctx[:legacy_home], ctx[:stray_base] ? STRAY_EXCLUDED : HOME_EXCLUDED)
    end

    def walk_tree(base, excluded)
      return [] unless File.directory?(base)

      real = File.realpath(base)
      out = []
      walk_dir(real, "", excluded, out)
      out
    end

    def walk_dir(base, rel, excluded, out)
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
        entry = { rel: child, base: base, src: full, mode: stat.mode & 0o7777, mtime: stat.mtime.to_i, mtime_nsec: stat.mtime.nsec, atime: stat.atime.to_i }
        if stat.symlink?
          entry[:kind] = "symlink"
          entry[:target] = File.readlink(full)
          out << entry
        elsif stat.directory?
          entry[:kind] = "dir"
          out << entry
          walk_dir(base, child, excluded, out)
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
      "home/#{entry[:rel]}"
    end

    def dest_for(ctx, entry)
      File.join(ctx[:staged], entry[:rel])
    end

    def guard_free_space(ctx, sources)
      bytes = sources.select { |entry| entry[:kind] == "file" }.map { |entry| entry[:size] }.sum
      free = free_bytes(nearest_existing(ctx[:base]))
      return nil if free.nil?

      needed = bytes + FREE_SPACE_MARGIN
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

    def copy_entries(ctx, entries, journal)
      directories = entries.select { |entry| entry[:kind] == "dir" }
      others = entries.reject { |entry| entry[:kind] == "dir" }

      directories.each do |entry|
        heartbeat(ctx)
        make_directory(ctx, entry, journal)
      end

      others.each do |entry|
        heartbeat(ctx)
        copy_one(ctx, entry, journal)
      end

      directories.reverse_each do |entry|
        finish_directory(ctx, entry, journal)
      end
      nil
    end

    def make_directory(ctx, entry, journal)
      dest = dest_for(ctx, entry)
      key = key_for(entry)
      if File.directory?(dest) && !File.symlink?(dest)
        make_owner_writable(dest)
        journal.add({ "rel" => key, "kind" => "dir", "status" => "copying" })
        return
      end

      raise Failure.new("destination_occupied", dest) if present?(dest)

      Dir.mkdir(dest, 0o700)
      journal.add({ "rel" => key, "kind" => "dir", "status" => "copying" })
    end

    def make_owner_writable(path)
      File.chmod(0o700, path)
    rescue StandardError
      nil
    end

    def finish_directory(ctx, entry, journal)
      dest = dest_for(ctx, entry)
      File.chmod(entry[:mode], dest)
      apply_times(dest, entry)
      journal.add({ "rel" => key_for(entry), "kind" => "dir", "status" => "copied", "mode" => entry[:mode], "mtime" => entry[:mtime], "mtime_nsec" => entry[:mtime_nsec] })
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
      if present?(dest)
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
      return true if record["status"] == "copying"

      case entry[:kind]
      when "file"
        !(record["kind"] == "file" && record["src_size"] == entry[:size] && record["mtime"] == entry[:mtime] && record["mtime_nsec"] == entry[:mtime_nsec])
      when "symlink"
        record["target"] != entry[:target]
      else
        false
      end
    end

    def dest_matches?(ctx, entry, record)
      return true if entry[:kind] == "special"

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
        sources = walk_home(ctx)
      end
    end

    def recheck_before_switch(ctx, _sources, journal)
      rounds = 0
      current = walk_home(ctx)
      loop do
        changed = current.select { |entry| source_changed?(entry, journal[key_for(entry)]) }
        return current if changed.empty?

        rounds += 1
        raise Failure.new("source_busy", changed.first(5).map { |entry| entry[:src] }.join(", ")) if rounds > VERIFY_ROUNDS

        copy_entries(ctx, changed, journal)
        journal.flush
        rewrite_staged(ctx)
        current = walk_home(ctx)
      end
    end

    def write_manifest(ctx, sources, journal)
      files = 0
      dirs = 0
      links = 0
      skipped = 0
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
        when "special"
          skipped += 1
        end
      end
      digest = Digest::SHA256.hexdigest(lines.sort.join("\n"))
      manifest = { "files" => files, "dirs" => dirs, "symlinks" => links, "skipped" => skipped, "bytes" => bytes, "root_digest" => digest }
      write_json_atomic(manifest_path(ctx), manifest)
      manifest
    end

    def persona_dirs(home)
      dir = File.join(home, "personas")
      return {} unless File.directory?(dir)

      Dir.children(dir).sort.each_with_object({}) do |name, table|
        full = File.join(dir, name)
        table[name] = full if name.match?(Reach::Paths::PERSONA_ID) && File.directory?(full)
      end
    end

    def enrollment_state(home)
      state = { "root" => enrollment_snapshot(home) }
      personas = persona_dirs(home).each_with_object({}) { |(id, dir), table| table[id] = enrollment_snapshot(dir) }
      state["personas"] = personas unless personas.empty?
      state
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

    def rewrite_staged(ctx)
      rewrite_shim_root(ctx)
      rewrite_update_manifest(ctx)
      rewrite_last_install(ctx)
      record_legacy_hits(ctx)
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

    def rewrite_last_install(ctx)
      note = File.join(ctx[:staged], "bootstrap", "last-install.txt")
      return unless File.file?(note)

      legacy_plugin = File.join(ctx[:legacy_home], "plugin")
      return unless File.read(note).strip == legacy_plugin

      File.write(note, "#{File.join(ctx[:final_home], 'plugin')}\n")
    end

    def scan_targets(staged)
      files = []
      Dir.children(staged).sort.each do |name|
        full = File.join(staged, name)
        stat = File.lstat(full)
        if stat.file?
          files << full
        elsif stat.directory? && %w[state bin].include?(name)
          collect_files(full, files)
        elsif stat.directory? && name == "personas"
          Dir.children(full).sort.each do |id|
            collect_files(File.join(full, id, "state"), files)
            Dir[File.join(full, id, "*")].sort.each { |path| files << path if File.file?(path) && !File.symlink?(path) }
          end
        end
      end
      files
    rescue SystemCallError
      files
    end

    def collect_files(dir, out)
      return unless File.directory?(dir) && !File.symlink?(dir)

      Dir.children(dir).sort.each do |name|
        full = File.join(dir, name)
        stat = File.lstat(full)
        if stat.directory?
          collect_files(full, out)
        elsif stat.file?
          out << full
        end
      end
    rescue SystemCallError
      nil
    end

    def legacy_hits(ctx)
      staged = ctx[:staged]
      needle = ctx[:legacy_home].dup.force_encoding(Encoding::BINARY)
      hits = []
      skipped = %w[state/relocation.json state/relocation.jsonl state/relocation-manifest.json]
      scan_targets(staged).each do |path|
        relative = path[(staged.length + 1)..-1]
        next if skipped.include?(relative)
        next if File.size(path) > SCAN_MAX_BYTES

        count = File.binread(path).scan(needle).length
        hits << { "path" => relative, "count" => count } if count.positive?
      rescue SystemCallError
        next
      end
      hits
    end

    def record_legacy_hits(ctx)
      hits = legacy_hits(ctx)
      update_state(ctx, "legacy_path_hits" => hits)
      hits
    rescue StandardError
      nil
    end

    def switch!(ctx, manifest)
      final = ctx[:final_home]
      aside = nil
      displaced = nil
      if present?(final)
        if ctx[:displace] && displaceable?(ctx, final)
          displaced = set_aside_final(ctx, final)
        else
          raise Failure.new("destination_occupied", final) unless bootstrap_only?(final)

          merge_bootstrap(ctx, final)
          aside = "#{final}.pre-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(2)}"
          File.rename(final, aside)
        end
      end
      begin
        File.rename(ctx[:staged], final)
      rescue StandardError, ScriptError => e
        restore = displaced || aside
        if restore
          begin
            raise Errno::EEXIST, final if present?(final)

            File.rename(restore, final)
          rescue StandardError
            raise Failure.new("rollback_incomplete", "#{e.class}: #{File.basename(restore)} kept under its set-aside name")
          end
        end
        raise
      end
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

      pointer = File.join(ctx[:legacy_home], POINTER_NAME)
      pointer_body = { "to_home" => final, "workspace" => ctx[:base], "completed_at" => completed_at, "manifest_digest" => manifest["root_digest"] }
      log_path = File.join(final, "logs", "relocation.jsonl")
      if ctx[:stray_base]
        begin
          write_json_atomic(pointer, pointer_body)
        rescue StandardError => e
          log_event(log_path, "event" => "stray_pointer_failed", "error" => e.class.name)
        end
      else
        write_json_atomic(pointer, pointer_body)
      end

      log_event(log_path, "event" => "relocated", "from" => ctx[:legacy_home], "to" => final, "files" => manifest["files"], "bytes" => manifest["bytes"])
      copy_stray_workspace(ctx, log_path) if ctx[:stray_base]
      Reach::Paths.with_persona(nil) do
        configure_spaces(ctx)
        refresh_harnesses(ctx)
        refresh_subscription
      end

      outcome(
        "completed",
        files: manifest["files"], bytes: manifest["bytes"], completed_at: completed_at,
        line: "rEach moved its files into your reach-work folder (#{final}): #{manifest['files']} files, #{format_bytes(manifest['bytes'])}. The old folder was left exactly as it was."
      )
    end

    def copy_stray_workspace(ctx, log_path)
      source = File.join(ctx[:stray_base], "reach-work")
      return nil unless File.directory?(source)

      Dir.children(source).sort.each do |name|
        next if Reach::Paths.home_name?(name) || name.end_with?(MOVING_SUFFIX)

        begin
          result = copy_workspace_entry(File.join(source, name), File.join(ctx[:base], name), File.join(ctx[:base], ".#{name}#{MOVING_SUFFIX}"))
          log_event(log_path, "event" => "workspace_entry_#{result}", "name" => name)
        rescue StandardError => e
          log_event(log_path, "event" => "workspace_entry_failed", "name" => name, "error" => e.class.name, "reason" => e.respond_to?(:reason) ? e.reason : nil)
        end
      end
      nil
    rescue StandardError
      nil
    end

    def copy_workspace_entry(src, dest, tmp)
      return "skipped" if present?(dest)

      stat = File.lstat(src)
      entry = { mode: stat.mode & 0o7777, mtime: stat.mtime.to_i, mtime_nsec: stat.mtime.nsec, atime: stat.atime.to_i }
      if stat.symlink?
        File.symlink(File.readlink(src), dest)
      elsif stat.file?
        copy_file(src, tmp, entry)
        raise Failure.new("verify_failed", src) unless file_digest(src) == file_digest(tmp)

        File.rename(tmp, dest)
      elsif stat.directory?
        copy_workspace_tree(src, tmp, entry)
        File.rename(tmp, dest)
      else
        return "skipped_special"
      end
      "copied"
    rescue NotImplementedError, Errno::EPERM, Errno::EACCES => e
      raise Failure.new("copy_error", e.class.name)
    end

    def copy_workspace_tree(src, tmp, entry)
      entries = walk_tree(src, [])
      if present?(tmp)
        raise Failure.new("destination_occupied", tmp) unless File.directory?(tmp) && !File.symlink?(tmp)
      else
        Dir.mkdir(tmp, 0o700)
      end
      directories = entries.select { |item| item[:kind] == "dir" }
      directories.each do |item|
        target = File.join(tmp, item[:rel])
        next if File.directory?(target) && !File.symlink?(target)

        raise Failure.new("destination_occupied", target) if present?(target)

        Dir.mkdir(target, 0o700)
      end
      entries.each do |item|
        target = File.join(tmp, item[:rel])
        case item[:kind]
        when "file"
          copy_file(item[:src], target, item)
          raise Failure.new("verify_failed", item[:rel]) unless File.size(target) == item[:size] && file_digest(item[:src]) == file_digest(target)
        when "symlink"
          next if File.symlink?(target) && File.readlink(target) == item[:target]
          raise Failure.new("destination_occupied", target) if present?(target)

          begin
            File.symlink(item[:target], target)
          rescue NotImplementedError, Errno::EPERM, Errno::EACCES
            nil
          end
        end
      end
      directories.reverse_each do |item|
        target = File.join(tmp, item[:rel])
        File.chmod(item[:mode], target)
        apply_times(target, item)
      end
      File.chmod(entry[:mode], tmp)
      apply_times(tmp, entry)
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

    def space_targets
      targets = []
      workspace = Reach::Paths.workspace_root
      targets << workspace if File.directory?(workspace)
      extracurricular = Reach::Paths.extracurricular_root
      targets << extracurricular if File.directory?(extracurricular)
      Reach::Workspace.current_slices.each { |slice| targets << slice if File.directory?(slice) }
      targets.uniq
    rescue StandardError
      targets
    end

    def configure_spaces(ctx)
      ids = persona_dirs(ctx[:final_home]).keys
      groups = [[nil, Reach::Paths.with_persona(nil) { space_targets }]]
      ids.each do |id|
        groups << [id, Reach::Paths.with_persona(id) { space_targets }]
      end
      configured = []
      groups.each do |id, targets|
        Reach::Paths.with_persona(id) do
          targets.each do |target|
            begin
              Reach::Harness.configure_all(target)
              configured << target
            rescue StandardError
              nil
            end
          end
        end
      end
      record_final(ctx, "configured_spaces" => configured)
    rescue StandardError
      nil
    end

    def repair_ruby_paths!
      root = Reach::Paths.root
      return 0 unless File.directory?(root)

      groups = [[nil, Reach::Paths.with_persona(nil) { space_targets }]]
      persona_dirs(root).each_key { |id| groups << [id, Reach::Paths.with_persona(id) { space_targets }] }
      repaired = 0
      groups.each do |id, targets|
        Reach::Paths.with_persona(id) do
          targets.each do |target|
            begin
              next unless stale_ruby_target?(target)

              Reach::Harness.configure_all(target)
              repaired += 1
            rescue StandardError
              nil
            end
          end
        end
      end
      repaired
    rescue StandardError
      0
    end

    def unparseable_config?(target)
      [File.join(target, ".codex", "hooks.json"), File.join(target, ".claude", "settings.json")].any? do |path|
        next false unless File.file?(path)

        begin
          !JSON.parse(File.read(path)).is_a?(Hash)
        rescue JSON::ParserError
          true
        rescue StandardError
          false
        end
      end
    end

    def stale_ruby_target?(target)
      return true if unparseable_config?(target)

      pairs = written_command_pairs(target)
      return false if pairs.empty?

      ruby = Reach::Runtime.ruby_path
      shim = Reach::Runtime.shim_path
      pairs.any? { |pair_ruby, pair_shim| pair_ruby != ruby || pair_shim != shim }
    end

    def written_command_pairs(target)
      pairs = []
      [File.join(target, ".codex", "hooks.json"), File.join(target, ".claude", "settings.json")].each do |path|
        next unless File.file?(path)

        data = JSON.parse(File.read(path))
        hooks = data.is_a?(Hash) && data["hooks"].is_a?(Hash) ? data["hooks"] : {}
        hooks.each_value do |entries|
          Array(entries).each do |entry|
            Array(entry.is_a?(Hash) ? entry["hooks"] : nil).each do |hook|
              pair = command_pair(hook["command"]) if hook.is_a?(Hash)
              pairs << pair if pair
            end
          end
        end
      end
      mcp = File.join(target, ".mcp.json")
      if File.file?(mcp)
        data = JSON.parse(File.read(mcp))
        server = data.is_a?(Hash) && data["mcpServers"].is_a?(Hash) ? data["mcpServers"]["reach"] : nil
        if server.is_a?(Hash) && server["command"].is_a?(String) && server["args"].is_a?(Array) && server["args"].first.is_a?(String)
          pairs << [server["command"], server["args"].first]
        end
      end
      pairs.concat(toml_command_pairs(File.join(target, ".codex", "config.toml")))
      pairs
    rescue StandardError
      []
    end

    def command_pair(command)
      return nil unless command.is_a?(String)

      tokens = command.start_with?("\"") ? command.scan(/"([^"]*)"/).flatten : Shellwords.shellsplit(command)
      return nil if tokens.length < 3

      shim = tokens[1].tr("\\", "/")
      return nil unless File.basename(shim) == "reach" && File.basename(File.dirname(shim)) == "bin"

      [tokens[0], tokens[1]]
    rescue StandardError
      nil
    end

    def toml_command_pairs(path)
      return [] unless File.file?(path)

      lines = File.read(path).lines.map(&:strip)
      start = lines.index("[mcp_servers.reach]")
      return [] unless start

      section = lines[(start + 1)..].take_while { |line| !line.start_with?("[") }
      command = section.map { |line| line.match(/\Acommand\s*=\s*"((?:[^"\\]|\\.)*)"\z/) }.compact.first
      args = section.map { |line| line.match(/\Aargs\s*=\s*\["((?:[^"\\]|\\.)*)"/) }.compact.first
      return [] unless command && args

      [[command[1], args[1]].map { |value| value.gsub(/\\(["\\])/) { Regexp.last_match(1) } }]
    rescue StandardError
      []
    end

    def record_final(ctx, fields)
      state_path = File.join(ctx[:final_home], "state", "relocation.json")
      state = read_json(state_path) || {}
      write_json_atomic(state_path, state.merge(fields))
    rescue StandardError
      nil
    end

    def refresh_subscription
      Reach::Subscribe.ensure!
    rescue StandardError
      nil
    end

    def refresh_harnesses(ctx)
      plugin = File.join(ctx[:final_home], "plugin")
      legacy_plugin = File.join(ctx[:legacy_home], "plugin")
      return unless File.directory?(plugin)

      links = [File.join(Reach::Paths.gemini_dir, "config", "plugins", "reach"), File.join(Reach::Paths.gemini_dir, "antigravity-cli", "plugins", "reach")]
      links.each { |link| repoint(link, plugin, legacy_plugin) }

      config_path = Reach::Harness.hermes_config_path
      if config_path
        skills = File.join(File.dirname(config_path), "skills")
        %w[reach-assistant reach-course].each do |name|
          repoint(File.join(skills, name), File.join(plugin, "skills", name), File.join(legacy_plugin, "skills", name))
        end
        Reach::Harness.configure("hermes", nil)
      end
      Reach::Setup.refresh_copies(plugin)

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
      record_final(ctx, "harness_sources" => results)
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
      return { state: "failed", reason: "destination_occupied" } if quick_occupied(ctx)

      { state: "pending" }
    rescue StandardError
      { state: "pending" }
    end

    def quick_occupied(ctx)
      final = ctx[:final_home]
      if present?(final)
        state = read_json(File.join(final, "state", "relocation.json"))
        return false if state && state["phase"] == "switching"
        return true unless bootstrap_only?(final) || displaceable?(ctx, final)
      end

      staged = ctx[:staged]
      if present?(staged)
        state = read_json(File.join(staged, "state", "relocation.json"))
        return true unless state && state["schema"] == SCHEMA
      end
      false
    rescue StandardError
      false
    end

    def status_outcome
      state = status
      line = case state[:state]
             when "completed" then "rEach has already moved its files into your reach-work folder (#{state[:date]})."
             when "none-needed" then "Nothing to move: rEach already keeps its files in your reach-work folder."
             when "in-progress" then "rEach is moving its files into your reach-work folder right now."
             when "failed" then "rEach could not move its files into your reach-work folder yet (#{REASONS[state[:reason]] || state[:reason]}). #{failure_tail(state[:reason])}"
             else "rEach will move its files into your reach-work folder the next time a session starts."
             end
      outcome(state[:state], reason: state[:reason], line: line)
    end

    def doctor_line
      state = status
      case state[:state]
      when "completed" then "R-DOC-RELOCATION completed #{state[:date]}"
      when "failed" then "R-DOC-RELOCATION failed #{state[:reason]}"
      else "R-DOC-RELOCATION #{state[:state]}"
      end
    end

    def folder_line
      home = Reach::Paths.root
      base = Reach::Paths.workspace_base
      return "Your reach-work folder: #{base} (rEach keeps its own files in #{home})" unless due?

      state = status
      if state[:state] == "failed"
        reason = REASONS[state[:reason]] || state[:reason]
        return "Your reach-work folder: #{base} (rEach's own files are still in #{home}; rEach could not move them into #{Reach::Paths.new_home} yet: #{reason}. #{failure_tail(state[:reason])})"
      end

      "Your reach-work folder: #{base} (rEach's own files are still in #{home}; rEach will move them into #{Reach::Paths.new_home} soon)"
    rescue StandardError
      "Your reach-work folder: unknown"
    end

    def auto_state_path
      File.join(Reach::Paths.workspace_base, AUTO_STATE_NAME)
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
      return nil if deferral(nil)

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
