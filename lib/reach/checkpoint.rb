require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Checkpoint
    AUTOSAVE_VIAS = %w[write pre_write check provision restored].freeze
    NOTICE_FILE = "checkpoint-notice.json".freeze
    MIRROR_STATE_FILE = "checkpoint-mirror.json".freeze
    SALT_FILE = "checkpoint-salt.json".freeze
    EMPTY_DIGEST = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".freeze

    module_function

    def settings
      section = Reach::Runtime.load_config["checkpoints"]
      section = {} unless section.is_a?(Hash)
      { "autosave" => section["autosave"] != false, "mirror" => section["mirror"] != false }
    rescue StandardError
      { "autosave" => true, "mirror" => true }
    end

    def autosave?
      ENV["REACH_AUTOSAVE"] != "0" && settings["autosave"]
    end

    def relative_dir(workspace)
      meta = Reach::Workspace.metadata(workspace)
      File.join(meta["course"].to_s, meta["assignment"].to_s, File.basename(workspace))
    end

    def student_id
      install = Reach::Enroll.readable_current
      value = install.is_a?(Hash) ? install["student_id"].to_s : ""
      value.empty? ? nil : value
    end

    def salt
      local = Reach::StateFile.read(SALT_FILE)["salt"]
      kept = Reach::Sidecar.checkpoint_salt
      value = [local, kept].find { |candidate| candidate.is_a?(String) && candidate.match?(/\A[0-9a-f]{32}\z/) }
      value ||= SecureRandom.hex(16)
      Reach::StateFile.write(SALT_FILE, "salt" => value) unless local == value
      Reach::Sidecar.keep_checkpoint_salt(value) unless kept == value
      value
    end

    def student_key
      student = student_id
      return "local" unless student

      Reach::Crypto.digest_hex("#{salt}:#{student}")[0, 16]
    end

    def earlier_keys
      student = student_id
      student ? ["", "local", Reach::Crypto.digest_hex(student)[0, 16]] : []
    end

    def dir(workspace)
      key = student_key
      keyed = File.join(Reach::Paths.checkpoints_dir, key, relative_dir(workspace))
      earlier_keys.each do |earlier|
        source = File.join(Reach::Paths.checkpoints_dir, earlier, relative_dir(workspace))
        adopt(source, keyed, workspace, [keyed], Reach::Paths.checkpoints_dir, ledger_vouches: true) if File.directory?(source)
      end
      keyed
    end

    def mirror_dir(workspace)
      base = mirror_base
      return nil unless base

      keyed = File.join(base, student_key, relative_dir(workspace))
      earlier = earlier_keys
      primary = dir(workspace) unless earlier.empty?
      earlier.each do |name|
        source = File.join(base, name, relative_dir(workspace))
        adopt(source, keyed, workspace, [primary, keyed], base, ledger_vouches: false) if File.directory?(source)
      end
      keyed
    end

    def owned_store?(source, workspace, own_bases, ledger_vouches:)
      entries = entries_in(source)
      return false if entries.empty?

      mine = {}
      own_bases.each { |base| entries_in(base).each { |entry| mine[entry["n"].to_i] ||= entry } }
      matched = entries.any? do |entry|
        own = mine[entry["n"].to_i]
        own && own["at"] == entry["at"] && own["digests"] == entry["digests"]
      end
      return true if matched

      student = student_id
      records = ledger_records(workspace)
      return false if student.nil? || records.empty?
      return true if ledger_vouches && records.all? { |record| record["student_id"].to_s == student }

      tags = records.each_with_object({}) { |record, map| map[record["tag"].to_s] = record["student_id"].to_s }
      entries.any? { |entry| tags[entry["ledger_head"].to_s] == student }
    end

    def ledger_records(workspace)
      file = Reach::Ledger.path(workspace)
      Dir.glob(file.sub(/\.jsonl\z/, "*.jsonl")).sort.flat_map do |name|
        File.readlines(name).map { |line| JSON.parse(line) }.select { |record| record.is_a?(Hash) }
      end
    rescue StandardError
      []
    end

    def adopt(source, keyed, workspace, own_bases, base, ledger_vouches:)
      return nil unless owned_store?(source, workspace, own_bases, ledger_vouches: ledger_vouches)

      private_dir(File.join(keyed, "blobs"))
      taken = entries_in(keyed).map { |entry| entry["n"].to_i }
      next_n = (taken.max || 0) + 1
      Dir.children(source).sort.each do |name|
        item = File.join(source, name)
        if name == "blobs"
          Dir.children(item).each do |blob|
            target = File.join(keyed, "blobs", blob)
            FileUtils.mv(File.join(item, blob), target) unless File.file?(target)
          end
        elsif name.match?(/\A\d{3,}\z/) && File.exist?(File.join(keyed, name))
          next unless File.file?(File.join(item, "meta.json"))

          meta = JSON.parse(File.read(File.join(item, "meta.json")))
          next unless meta.is_a?(Hash)

          while taken.include?(next_n)
            next_n += 1
          end
          meta["n"] = next_n
          Reach::StateFile.write_atomic(File.join(item, "meta.json"), JSON.generate(meta), mode: 0o600)
          FileUtils.mv(item, File.join(keyed, format("%03d", next_n)))
          taken << next_n
        elsif !File.exist?(File.join(keyed, name))
          FileUtils.mv(item, File.join(keyed, name))
        end
      end
      File.chmod(0o700, keyed)
      set_aside(source, base)
    rescue StandardError
      nil
    end

    def set_aside(source, base)
      parked = private_dir(File.join(base, ".adopted"))
      label = source.sub("#{base}/", "").tr("/", "-")
      FileUtils.mv(source, File.join(parked, "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{label}"))
      parent = File.dirname(source)
      while parent != base && parent.start_with?(base) && File.directory?(parent) && Dir.empty?(parent)
        Dir.rmdir(parent)
        parent = File.dirname(parent)
      end
    end

    def private_dir(path)
      FileUtils.mkdir_p(path, mode: 0o700)
      path
    end

    def mirror_base
      return nil unless settings["mirror"]

      Reach::Paths.checkpoint_mirror_dir
    end

    def stores(workspace)
      [dir(workspace), mirror_dir(workspace)].compact
    end

    def entries_in(base)
      return [] unless File.directory?(base)

      Dir.children(base).select { |name| name.match?(/\A\d{3,}\z/) }.sort.map do |name|
        meta_path = File.join(base, name, "meta.json")
        next nil unless File.file?(meta_path)

        entry = JSON.parse(File.read(meta_path))
        entry.is_a?(Hash) && entry["n"] ? entry : nil
      end.compact
    rescue StandardError
      []
    end

    def all_entries(workspace)
      merged = {}
      stores(workspace).each do |base|
        entries_in(base).each { |entry| merged[entry["n"].to_i] ||= entry }
      end
      merged.keys.sort.map { |n| merged[n] }
    end

    def hidden?(entry)
      entry["automatic"] == true && AUTOSAVE_VIAS.include?(entry["via"].to_s)
    end

    def list(workspace, all: false)
      entries = all_entries(workspace)
      all ? entries : entries.reject { |entry| hidden?(entry) }
    end

    def hidden_count(workspace)
      all_entries(workspace).count { |entry| hidden?(entry) }
    end

    def latest(workspace)
      all_entries(workspace).last
    end

    def save(workspace, note: nil, automatic: false, via: nil, stamp: true, force: false)
      via ||= automatic ? "automatic" : "manual"
      Reach::Seal.stamp(workspace) if stamp
      digests = current_digests(workspace)
      previous = latest(workspace)
      if previous && previous["digests"] == digests && !force && (automatic || !hidden?(previous))
        return { "saved" => false, "n" => previous["n"], "message" => Reach::Messages.text("M-CHECKPOINT-SAME", n: previous["n"]) }
      end

      n = previous ? previous["n"].to_i + 1 : 1
      primary = dir(workspace)
      meta = write_entry(primary, workspace, n, digests, note, automatic, via)
      mirror_entry(workspace, primary, meta)
      unless AUTOSAVE_VIAS.include?(via)
        Reach::Ledger.append(workspace, "checkpoint", "checkpoint" => n, "note_digest" => Reach::Crypto.digest_hex(note.to_s), "automatic" => automatic)
      end
      { "saved" => true, "n" => n, "message" => Reach::Messages.text("M-CHECKPOINT-SAVED", n: n) }
    end

    def autosave(workspace, via:)
      return nil unless autosave?
      return nil unless workspace && File.directory?(workspace)
      return nil if Reach::Workspace.owned_files(workspace).empty?

      save(workspace, automatic: true, via: via, stamp: false)
    rescue StandardError
      nil
    end

    def write_entry(base, workspace, n, digests, note, automatic, via)
      blobs = private_dir(File.join(base, "blobs"))
      private_dir(File.join(base, format("%03d", n)))
      digests.each do |relative, digest|
        next if digest.nil?

        source = File.join(workspace, relative)
        blob = File.join(blobs, digest)
        next if File.file?(blob) || !File.file?(source)

        Reach::StateFile.write_atomic(blob, File.binread(source), mode: 0o600)
      end
      meta = {
        "n" => n,
        "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note" => note.to_s[0, 200],
        "automatic" => automatic,
        "via" => via,
        "store" => "blobs",
        "digests" => digests,
        "marks" => Reach::Seal.verify(workspace),
        "ledger_head" => Reach::Ledger.head(workspace)
      }
      Reach::StateFile.write_atomic(File.join(base, format("%03d", n), "meta.json"), JSON.generate(meta), mode: 0o600)
      meta
    end

    def mirror_entry(workspace, primary, meta)
      mirror = mirror_dir(workspace)
      return nil unless mirror

      private_dir(File.join(mirror, "blobs"))
      private_dir(File.join(mirror, format("%03d", meta["n"].to_i)))
      meta["digests"].each_value do |digest|
        next if digest.nil?

        source = File.join(primary, "blobs", digest)
        destination = File.join(mirror, "blobs", digest)
        next if File.file?(destination) || !File.file?(source)

        Reach::StateFile.write_atomic(destination, File.binread(source), mode: 0o600)
      end
      name = format("%03d", meta["n"].to_i)
      Reach::StateFile.write_atomic(File.join(mirror, name, "meta.json"), JSON.generate(meta), mode: 0o600)
      mirror_state!(nil)
    rescue StandardError => e
      mirror_state!(e.class.name)
      nil
    end

    def mirror_state!(failure)
      Reach::StateFile.write(MIRROR_STATE_FILE, "failed" => failure, "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
    rescue StandardError
      nil
    end

    def mirror_state
      Reach::StateFile.read(MIRROR_STATE_FILE)
    end

    def show(workspace, n)
      all_entries(workspace).find { |entry| entry["n"].to_i == n.to_i }
    end

    def entry_content(workspace, entry, relative)
      digest = entry["digests"][relative]
      return nil if digest.nil?

      name = format("%03d", entry["n"].to_i)
      stores(workspace).each do |base|
        blob = File.join(base, "blobs", digest)
        return File.binread(blob) if File.file?(blob)

        legacy = File.join(base, name, "files", relative)
        return File.binread(legacy) if File.file?(legacy)
      end
      raise Reach::Error, Reach::Messages.text("M-CHECKPOINT-UNREADABLE", n: entry["n"])
    end

    def restore(workspace, n)
      entry = show(workspace, n)
      raise Reach::Error, Reach::Messages.text("M-CHECKPOINT-UNKNOWN", n: n) unless entry

      owned = Array(Reach::Workspace.owned_files(workspace))
      contents = owned.each_with_object({}) { |relative, map| map[relative] = entry_content(workspace, entry, relative) }
      previous = latest(workspace)
      if previous.nil? || previous["digests"] != current_digests(workspace) || hidden?(previous)
        save(workspace, note: "before restore #{n}", automatic: true, via: "restore", force: true)
      end

      before = current_digests(workspace)
      owned.each do |relative|
        destination = File.join(workspace, relative)
        content = contents[relative]
        if content
          Reach::StateFile.write_atomic(destination, content, mode: 0o644)
        elsif File.file?(destination)
          Reach::StateFile.write_atomic(destination, "", mode: 0o644)
        end
      end
      Reach::Seal.stamp(workspace)
      current_digests(workspace).each do |relative, digest|
        next if before[relative] == digest

        Reach::Ledger.append(workspace, "write", "path" => relative, "before" => before[relative], "after" => digest, "via" => "restore")
      end
      Reach::Ledger.append(workspace, "restore", "checkpoint" => entry["n"])
      autosave(workspace, via: "restored")
      { "restored" => true, "n" => entry["n"], "message" => Reach::Messages.text("M-CHECKPOINT-RESTORED", n: entry["n"]) }
    end

    def current_digests(workspace)
      digests = {}
      Array(Reach::Workspace.owned_files(workspace)).each do |relative|
        full = File.join(workspace, relative)
        digests[relative] = File.file?(full) ? Reach::Crypto.digest_hex(File.binread(full)) : nil
      end
      digests
    end

    def changed_count(entry, previous)
      return entry["digests"].values.compact.length if previous.nil?

      entry["digests"].count { |path, digest| previous["digests"][path] != digest }
    end

    def content?(digest)
      !digest.nil? && digest != EMPTY_DIGEST
    end

    def deliberate?(entry)
      !hidden?(entry) || entry["via"].to_s == "restored"
    end

    def since_deliberate(workspace)
      window = []
      all_entries(workspace).reverse_each do |entry|
        window << entry
        break if deliberate?(entry)
      end
      window
    end

    def missing(workspace)
      window = since_deliberate(workspace)
      return [] if window.empty?

      Array(Reach::Workspace.owned_files(workspace)).select do |relative|
        full = File.join(workspace, relative)
        (!File.file?(full) || File.size(full).zero?) && window.any? { |entry| content?(entry["digests"][relative]) }
      end
    rescue StandardError
      []
    end

    def recover_entry(workspace)
      lost = missing(workspace)
      since_deliberate(workspace).find { |entry| lost.all? { |relative| content?(entry["digests"][relative]) } } || latest(workspace)
    end

    def orphans
      found = {}
      key = student_key
      [Reach::Paths.checkpoints_dir, mirror_base].compact.each do |base|
        next unless File.directory?(File.join(base, key))

        Dir.glob(File.join(base, key, "*", "*", "*")).each do |store|
          next unless File.directory?(store)
          next if entries_in(store).empty?

          folder = File.basename(store)
          assignment = File.basename(File.dirname(store))
          course = File.basename(File.dirname(File.dirname(store)))
          path = File.join(Reach::Paths.deliverables_root, course, assignment, folder)
          next if File.directory?(path)

          found[path] ||= { "course" => course, "assignment" => assignment, "folder" => folder, "path" => path }
        end
      end
      found.values.sort_by { |item| item["path"] }
    rescue StandardError
      []
    end

    def recover_command(folder)
      "reach checkpoint recover --slice #{folder}"
    end

    def conditions
      list = []
      Reach::Workspace.current_slices.each do |workspace|
        files = missing(workspace)
        next if files.empty?

        list << { "kind" => "missing", "folder" => File.basename(workspace), "files" => files, "path" => workspace }
      end
      orphans.each { |item| list << item.merge("kind" => "orphan") }
      list
    rescue StandardError
      []
    end

    def condition_lines(items)
      items.map do |item|
        if item["kind"] == "missing"
          Reach::Messages.text("M-WORK-MISSING", slice: item["folder"], files: item["files"].join(", "), command: recover_command(item["folder"]))
        else
          Reach::Messages.text("M-WORK-FOLDER-MISSING", slice: item["folder"], assignment: item["assignment"], command: recover_command(item["folder"]))
        end
      end
    end

    def status_notices
      condition_lines(conditions)
    end

    def notice!
      lines = []
      items = conditions
      state = Reach::StateFile.read(NOTICE_FILE)
      changed = false
      unless items.empty?
        key = Reach::Crypto.digest_hex(JSON.generate(items.map { |item| item.reject { |k, _| k == "path" } }))
        if state["key"] != key
          lines.concat(condition_lines(items))
          state["key"] = key
          changed = true
        end
      end
      if Reach::Paths.cloud_synced_folder? && state["cloud_told"] != true
        lines << Reach::Messages.text("M-CLOUD-FOLDER", name: Reach::Paths.cloud_folder_name)
        state["cloud_told"] = true
        changed = true
      end
      Reach::StateFile.write(NOTICE_FILE, state.merge("at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))) if changed
      lines.empty? ? nil : lines.join("\n\n")
    rescue StandardError
      nil
    end

    def recover(slice: nil)
      wanted = slice.to_s.strip
      items = conditions
      items = items.select { |item| item["folder"] == wanted || item["folder"].end_with?("-#{wanted}") } unless wanted.empty?
      if items.empty? && !wanted.empty?
        workspace = Reach::Workspace.current_slices.find { |path| File.basename(path) == wanted || File.basename(path).end_with?("-#{wanted}") }
        items << { "kind" => "missing", "folder" => File.basename(workspace), "path" => workspace, "files" => [] } if workspace && latest(workspace)
      end
      return { "recovered" => [], "message" => Reach::Messages.text("M-CHECKPOINT-RECOVER-NONE") } if items.empty?

      recovered = []
      messages = []
      items.each do |item|
        workspace = item["path"]
        Reach::Workspace.provision_from_package(assignment: item["assignment"]) if item["kind"] == "orphan"
        unless File.directory?(workspace) && !Reach::Workspace.owned_files(workspace).empty?
          messages << Reach::Messages.text("M-CHECKPOINT-RECOVER-FAILED", slice: item["folder"])
          next
        end

        entry = recover_entry(workspace)
        next unless entry

        restore(workspace, entry["n"])
        recovered << { "workspace" => item["folder"], "n" => entry["n"] }
        messages << Reach::Messages.text("M-CHECKPOINT-RECOVERED", slice: item["folder"], n: entry["n"])
      end
      { "recovered" => recovered, "message" => messages.join("\n") }
    end

    def status_line(workspace)
      entries = all_entries(workspace)
      return Reach::Messages.text("M-CHECKPOINT-NONE-LINE") if entries.empty?

      Reach::Messages.text("M-CHECKPOINT-SAVED-LINE", count: entries.length, time: Reach::Messages.course_time(entries.last["at"]))
    rescue StandardError
      nil
    end

    def doctor_line
      count = 0
      bytes = 0
      base = Reach::Paths.checkpoints_dir
      if File.directory?(base)
        Dir.glob(File.join(base, "**", "*")).each do |path|
          next unless File.file?(path)

          bytes += File.size(path)
          count += 1 if File.basename(path) == "meta.json"
        end
      end
      mirror = mirror_base
      copy = if mirror.nil?
               "no second copy"
             elsif mirror_state["failed"]
               "second copy at #{Reach::Paths.home_relative(mirror)} failed (#{mirror_state['failed']})"
             else
               "second copy at #{Reach::Paths.home_relative(mirror)}"
             end
      "R-DOC-COPIES: #{count} saves, #{(bytes / 1024.0).ceil} KB, #{copy}"
    rescue StandardError
      "R-DOC-COPIES: saves could not be measured"
    end
  end
end
