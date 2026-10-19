require "json"
require "time"
require "fileutils"

module Reach
  module Checkpoint
    AUTOSAVE_VIAS = %w[write pre_write check provision restored].freeze
    NOTICE_FILE = "checkpoint-notice.json".freeze
    MIRROR_STATE_FILE = "checkpoint-mirror.json".freeze
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

    def dir(workspace)
      File.join(Reach::Paths.checkpoints_dir, relative_dir(workspace))
    end

    def mirror_dir(workspace)
      base = mirror_base
      base && File.join(base, relative_dir(workspace))
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
      blobs = File.join(base, "blobs")
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
          FileUtils.mkdir_p(File.dirname(destination))
          File.chmod(0o644, destination) if File.file?(destination)
          File.open(destination, "wb") { |f| f.write(content) }
        elsif File.file?(destination)
          File.open(destination, "wb") { |f| f.write("") }
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

    def missing(workspace)
      entry = latest(workspace)
      return [] unless entry

      Array(Reach::Workspace.owned_files(workspace)).select do |relative|
        digest = entry["digests"][relative]
        full = File.join(workspace, relative)
        digest && digest != EMPTY_DIGEST && (!File.file?(full) || File.size(full).zero?)
      end
    rescue StandardError
      []
    end

    def orphans
      found = {}
      [Reach::Paths.checkpoints_dir, mirror_base].compact.each do |base|
        next unless File.directory?(base)

        Dir.glob(File.join(base, "*", "*", "*")).each do |store|
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

        entry = latest(workspace)
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
