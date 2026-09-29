require "json"
require "time"
require "fileutils"

module Reach
  module Checkpoint
    module_function

    def dir(workspace)
      meta = Reach::Workspace.metadata(workspace)
      File.join(Reach::Paths.checkpoints_dir, meta["course"].to_s, meta["assignment"].to_s, File.basename(workspace))
    end

    def list(workspace)
      base = dir(workspace)
      return [] unless File.directory?(base)

      Dir.children(base).select { |name| name.match?(/\A\d{3,}\z/) }.sort.map do |name|
        meta_path = File.join(base, name, "meta.json")
        File.file?(meta_path) ? JSON.parse(File.read(meta_path)) : nil
      end.compact
    end

    def latest(workspace)
      list(workspace).last
    end

    def save(workspace, note: nil, automatic: false)
      Reach::Seal.stamp(workspace)
      digests = current_digests(workspace)
      previous = latest(workspace)
      if previous && previous["digests"] == digests
        return { "saved" => false, "n" => previous["n"], "message" => Reach::Messages.text("M-CHECKPOINT-SAME", n: previous["n"]) }
      end

      n = previous ? previous["n"].to_i + 1 : 1
      target = File.join(dir(workspace), format("%03d", n))
      FileUtils.mkdir_p(File.join(target, "files"))
      digests.each_key do |relative|
        source = File.join(workspace, relative)
        next unless File.file?(source)

        destination = File.join(target, "files", relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination)
      end
      meta = {
        "n" => n,
        "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note" => note.to_s[0, 200],
        "automatic" => automatic,
        "digests" => digests,
        "marks" => Reach::Seal.verify(workspace),
        "ledger_head" => Reach::Ledger.head(workspace)
      }
      File.write(File.join(target, "meta.json"), JSON.generate(meta))
      Reach::Ledger.append(workspace, "checkpoint", "checkpoint" => n, "note_digest" => Reach::Crypto.digest_hex(note.to_s), "automatic" => automatic)
      { "saved" => true, "n" => n, "message" => Reach::Messages.text("M-CHECKPOINT-SAVED", n: n) }
    end

    def show(workspace, n)
      list(workspace).find { |entry| entry["n"].to_i == n.to_i }
    end

    def restore(workspace, n)
      entry = show(workspace, n)
      raise Reach::Error, Reach::Messages.text("M-CHECKPOINT-UNKNOWN", n: n) unless entry

      previous = latest(workspace)
      save(workspace, note: "before restore #{n}", automatic: true) if previous.nil? || previous["digests"] != current_digests(workspace)

      source_root = File.join(dir(workspace), format("%03d", entry["n"].to_i), "files")
      before = current_digests(workspace)
      Array(Reach::Workspace.owned_files(workspace)).each do |relative|
        source = File.join(source_root, relative)
        destination = File.join(workspace, relative)
        if File.file?(source)
          FileUtils.mkdir_p(File.dirname(destination))
          File.chmod(0o644, destination) if File.file?(destination)
          FileUtils.cp(source, destination)
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
  end
end
