# frozen_string_literal: true

require "json"
require "time"
require "yaml"
require "digest"
require "fileutils"
require "securerandom"

module Reach
  module Reclaim
    LEDGER_FILE = "reclaimed.jsonl"
    OFFER_FILE = "reclaim-offer.json"
    KIND = "reclaim"
    ONLY = %w[brain work from].freeze
    ASIDE_PATTERNS = %w[.reach-home.set-aside-* .reach-home.failed-* .reach-home.pre-*].freeze
    SKIP_BRAIN = %w[index.json owner.json MOVED.json].freeze
    SETTLED = %i[copied same merged dropped].freeze
    SKIP_COPY_NAMES = %w[AGENTS.md CLAUDE.md GEMINI.md .mcp.json .reach-space.json].freeze
    SKIP_COPY_DIRS = %w[.reach .claude .codex].freeze
    OWNER_SCAN_LIMIT = 50
    OFFER_RECHECK_S = 86_400
    FAILURES = [SystemCallError, IOError, Reach::Error].freeze

    module_function

    def enrolled?
      !Reach::Checkpoint.student_id.nil? && !Reach::EnrollmentLock.locked?
    rescue *FAILURES
      false
    end

    def available?
      Reach::Paths.persona_id.nil?
    end

    def tilde(path)
      Reach::Paths.home_relative(path)
    end

    def real(path)
      Reach::Paths.realish(path)
    end

    def work_bases
      bases = [Reach::Paths.workspace_base]
      Reach::Paths.stray_bases.each { |base| bases << File.join(base, "reach-work") }
      parent = File.dirname(Reach::Paths.workspace_base)
      Dir.glob(File.join(parent, "reach-work*")).sort.each { |path| bases << path if File.directory?(path) }
      bases.map { |path| File.expand_path(path) }.uniq.select { |path| File.directory?(path) }
    end

    def home_like_dirs
      dirs = [Reach::Paths.legacy_home]
      Reach::Paths.stray_bases.each { |base| dirs << File.join(base, ".reach") }
      work_bases.each do |base|
        dirs << File.join(base, Reach::Paths::NEW_HOME_NAME)
        ASIDE_PATTERNS.each { |pattern| dirs.concat(Dir.glob(File.join(base, pattern))) }
      end
      dirs.select { |path| File.directory?(path) }
    end

    def brain_dirs
      found = home_like_dirs.map { |home| File.join(home, "brain") }
      roots = work_bases.map { |base| File.join(base, Reach::Paths::BRAIN_ROOT_NAME) } + [Reach::Paths.brain_root]
      roots.uniq.each { |root| found.concat(Dir.glob(File.join(root, "*"))) }
      active = real(Reach::Brain.dir)
      seen = {}
      found.select { |path| File.directory?(path) && !File.symlink?(path) }.each_with_object([]) do |path, memo|
        resolved = real(path)
        next if resolved == active || seen[resolved]

        seen[resolved] = true
        memo << path
      end
    end

    def skipped_brain_file?(rel)
      base = File.basename(rel)
      return true if base.end_with?(".lock") || base.include?(".tmp-")
      return true if (base.start_with?("context-") && base.end_with?(".query")) || (base.start_with?("erase-") && base.end_with?(".ids"))

      !rel.include?(File::SEPARATOR) && SKIP_BRAIN.include?(base)
    end

    def brain_files(dir)
      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sort.each_with_object([]) do |path, memo|
        next unless File.file?(path) && !File.symlink?(path)

        rel = path.sub("#{dir}#{File::SEPARATOR}", "")
        memo << [rel, path] unless skipped_brain_file?(rel)
      end
    end

    def fingerprint(entries)
      Digest::SHA256.hexdigest(entries.map { |rel, path| "#{rel}:#{File.size(path)}" }.sort.join("\n"))[0, 24]
    end

    def student_of(data)
      data.is_a?(Hash) && data["student_id"].is_a?(String) && !data["student_id"].empty? ? [data["student_id"]] : []
    end

    def json_ids(path)
      student_of(JSON.parse(File.read(path)))
    rescue JSON::ParserError, SystemCallError
      []
    end

    def install_id(dir)
      path = File.join(File.dirname(dir), "install.yml")
      return [] unless File.basename(dir) == "brain" && File.file?(path)

      student_of(YAML.safe_load(File.read(path)))
    rescue Psych::Exception, SystemCallError
      []
    end

    def recorded_ids(dir)
      ids = json_ids(File.join(dir, Reach::Brain::OWNER_FILE)) + install_id(dir)
      ids += Dir.glob(File.join(dir, "sessions", "*.json")).first(OWNER_SCAN_LIMIT).flat_map { |path| json_ids(path) }
      ids += Dir.glob(File.join(dir, "imports", "*", "job.json")).first(OWNER_SCAN_LIMIT).flat_map { |path| json_ids(path) }
      ids.uniq
    end

    def in_brain_root?(dir)
      File.basename(File.dirname(dir)) == Reach::Paths::BRAIN_ROOT_NAME
    end

    def owner_of(dir)
      mine = Reach::Checkpoint.student_id
      ids = recorded_ids(dir)
      ids += [mine] if mine && in_brain_root?(dir) && File.basename(dir) == Reach::Checkpoint.student_key
      ids = ids.uniq
      return(in_brain_root?(dir) && File.basename(dir) == "local" ? "local" : "unknown") if ids.empty?
      return "ours" if mine && ids == [mine]

      ids.include?(mine) ? "unknown" : "other"
    end

    def ledger_path
      File.join(Reach::Brain.dir, LEDGER_FILE)
    end

    def ledger
      return [] unless File.file?(ledger_path)

      File.readlines(ledger_path).filter_map do |line|
        record = JSON.parse(line)
        record.is_a?(Hash) ? record : nil
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end

    def done?(kind, source, print)
      ledger.any? { |record| record["kind"] == kind && record["source"] == source && record["fingerprint"] == print }
    end

    def record!(kind, source, print, fields = {})
      Reach::Brain.ensure_dir!
      File.open(ledger_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.puts(JSON.generate({ "kind" => kind, "source" => source, "fingerprint" => print, "at" => Time.now.utc.iso8601 }.merge(fields)))
      end
      nil
    rescue SystemCallError
      nil
    end

    def brain_candidates
      return [] unless enrolled?

      brain_dirs.filter_map do |dir|
        entries = brain_files(dir)
        next if entries.empty?

        print = fingerprint(entries)
        source = real(dir)
        next if done?("brain", source, print)

        { "kind" => "brain", "path" => dir, "source" => source, "owner" => owner_of(dir), "files" => entries.length, "fingerprint" => print }
      end
    end

    def rules_missing?(path)
      Reach::Workspace::GENERATED_FILES.first(3).any? { |name| !File.file?(File.join(path, name)) }
    end

    def work_candidates
      empty = { "slices" => [], "extracurricular" => false, "recoverable" => [] }
      return empty unless enrolled?

      slices = Reach::Workspace.current_slices.select { |path| rules_missing?(path) }
      extra = Reach::Paths.extracurricular_root
      marker = !File.file?(File.join(extra, ".reach-space.json")) || rules_missing?(extra)
      { "slices" => slices, "extracurricular" => marker, "recoverable" => Reach::Checkpoint.conditions }
    rescue *FAILURES
      empty
    end

    def copy_roots(folder)
      base = File.expand_path(folder.to_s)
      nested = File.join(base, "reach-work")
      plain = File.directory?(File.join(base, "deliverables")) || File.directory?(File.join(base, "extracurricular"))
      base = nested if !plain && File.directory?(nested)
      [["deliverables", Reach::Paths.deliverables_root], ["extracurricular", Reach::Paths.extracurricular_root]].filter_map do |name, destination|
        source = File.join(base, name)
        File.directory?(source) && !File.symlink?(source) ? [name, source, destination] : nil
      end
    end

    def copy_state(path, target)
      return "copy" if !File.exist?(target) && !File.symlink?(target)
      return "same" if File.file?(target) && !File.symlink?(target) && File.size(target) == File.size(path) && file_sha(target) == file_sha(path)

      "differs"
    end

    def copy_plan(folder)
      roots = copy_roots(folder)
      return nil if roots.empty?

      roots.each_with_object({ "files" => [] }) do |(_name, source, destination), memo|
        next if Reach::Paths.path_within?(real(source), real(destination))

        Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          next unless File.file?(path) && !File.symlink?(path)

          rel = path.sub("#{source}#{File::SEPARATOR}", "")
          parts = rel.split(File::SEPARATOR)
          next if SKIP_COPY_NAMES.include?(parts.last) || (parts[0..-2] & SKIP_COPY_DIRS).any?

          target = File.join(destination, rel)
          memo["files"] << { "from" => path, "to" => target, "rel" => rel, "state" => copy_state(path, target) }
        end
      end
    end

    def file_sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def from_candidate(folder)
      plan = copy_plan(folder)
      return { "kind" => "from", "path" => File.expand_path(folder.to_s), "error" => true } unless plan

      print = Digest::SHA256.hexdigest(plan["files"].map { |item| "#{item['rel']}:#{File.size(item['from'])}" }.sort.join("\n"))[0, 24]
      source = real(folder)
      counts = plan["files"].group_by { |item| item["state"] }
      {
        "kind" => "from", "path" => File.expand_path(folder.to_s), "source" => source, "fingerprint" => print, "plan" => plan,
        "copy" => counts.fetch("copy", []).length, "same" => counts.fetch("same", []).length,
        "differs" => counts.fetch("differs", []).map { |item| item["rel"] }, "done" => done?("from", source, print)
      }
    end

    def scan(from: nil)
      return { "brain" => [], "work" => nil, "from" => nil } unless available?

      result = { "brain" => brain_candidates, "work" => work_candidates, "from" => nil }
      result["from"] = from_candidate(from) if from.to_s.strip != ""
      result
    end

    def takable_brain(scan, only)
      explicit = only&.include?("brain")
      scan["brain"].select { |item| item["owner"] == "ours" || (explicit && item["owner"] == "local") }
    end

    def work_pending?(work)
      work && (!work["slices"].empty? || work["extracurricular"])
    end

    def from_pending?(from)
      from && !from["error"] && !from["done"] && from["copy"].to_i.positive?
    end

    def actionable?(scan, only = nil)
      wanted = only || ONLY
      return true if wanted.include?("brain") && !takable_brain(scan, only).empty?
      return true if wanted.include?("work") && work_pending?(scan["work"])

      wanted.include?("from") && from_pending?(scan["from"]) ? true : false
    end

    def brain_line_id(owner, named)
      case owner
      when "ours" then "M-RECLAIM-ITEM-BRAIN"
      when "local" then named ? "M-RECLAIM-ITEM-BRAIN-LOCAL-NAMED" : "M-RECLAIM-ITEM-BRAIN-LOCAL"
      when "other" then "M-RECLAIM-ITEM-OTHER"
      else "M-RECLAIM-ITEM-UNKNOWN"
      end
    end

    def work_item_lines(work)
      out = work["slices"].map { |path| Reach::Messages.text("M-RECLAIM-ITEM-WORK", folder: File.basename(path)) }
      out << Reach::Messages.text("M-RECLAIM-ITEM-EXTRA") if work["extracurricular"]
      out << Reach::Checkpoint.condition_lines(work["recoverable"]).join("\n") unless work["recoverable"].empty?
      out
    end

    def from_item_lines(from)
      return [Reach::Messages.text("M-RECLAIM-FROM-BAD", path: tilde(from["path"]))] if from["error"]
      return [Reach::Messages.text("M-RECLAIM-ITEM-FROM-DONE", path: tilde(from["path"]))] if from["done"]

      head = Reach::Messages.text("M-RECLAIM-ITEM-FROM", path: tilde(from["path"]), copy: from["copy"], same: from["same"], differ: from["differs"].length)
      [head] + from["differs"].first(20).map { |rel| Reach::Messages.text("M-RECLAIM-ITEM-DIFFERS", file: rel) }
    end

    def lines(scan, only = nil)
      wanted = only || ONLY
      out = []
      if wanted.include?("brain")
        scan["brain"].each { |item| out << Reach::Messages.text(brain_line_id(item["owner"], only&.include?("brain")), path: tilde(item["path"]), files: item["files"]) }
      end
      out.concat(work_item_lines(scan["work"])) if wanted.include?("work") && scan["work"]
      out.concat(from_item_lines(scan["from"])) if wanted.include?("from") && scan["from"]
      out
    end

    def subject_for(scan, only)
      wanted = only || ONLY
      work = scan["work"]
      folders = wanted.include?("work") && work ? work["slices"].map { |path| File.basename(path) }.sort + (work["extracurricular"] ? ["extracurricular"] : []) : []
      from = scan["from"]
      {
        "only" => wanted.sort,
        "brain" => wanted.include?("brain") ? takable_brain(scan, only).map { |item| item["source"] }.sort : [],
        "work" => folders,
        "from" => wanted.include?("from") && from && !from["error"] ? from["source"] : nil
      }
    end

    def parse_only(value)
      list = Array(value).flat_map { |item| item.to_s.split(",") }.map { |item| item.strip.downcase }.reject(&:empty?).uniq
      bad = list - ONLY
      raise Reach::Refused, Reach::Messages.text("M-RECLAIM-ONLY", values: ONLY.join(", ")) unless bad.empty?

      list.empty? ? nil : list
    end

    def verbatim(state, message)
      { "state" => state, "message" => message, "text" => message, "relay_verbatim" => true }
    end

    def via_consent!(only: nil, from: nil)
      wanted = parse_only(only)
      return verbatim("none", Reach::Messages.text("M-RECLAIM-PERSONA")) unless available?
      return verbatim("needs_enrollment", Reach::Messages.text("M-RECLAIM-NEEDS-ENROLL")) unless enrolled?

      found = scan(from: from)
      return verbatim("bad_folder", Reach::Messages.text("M-RECLAIM-FROM-BAD", path: tilde(found["from"]["path"]))) if found["from"] && found["from"]["error"]

      shown = lines(found, wanted)
      return verbatim("none", Reach::Messages.text("M-RECLAIM-NONE")) if shown.empty?
      return verbatim("nothing_to_take", Reach::Messages.text("M-RECLAIM-LEFT", items: shown.join("\n"))) unless actionable?(found, wanted)

      subject = subject_for(found, wanted)
      return perform(only: wanted, from: from, scan: found).merge("relay_verbatim" => true) if Reach::Consent.take!(kind: KIND, subject: subject)

      question = Reach::Consent.ask!(kind: KIND, subject: subject, message_id: "M-RECLAIM-ASK", fields: { items: shown.join("\n") })
      { "state" => "needs_confirmation", "relay_verbatim" => true, "message" => question, "text" => question, "subject" => subject }
    end

    def perform(only: nil, from: nil, scan: nil)
      wanted = only || ONLY
      return { "state" => "needs_enrollment", "message" => Reach::Messages.text("M-RECLAIM-NEEDS-ENROLL") } unless available? && enrolled?

      found = scan || self.scan(from: from)
      report = []
      brain = wanted.include?("brain") ? perform_brain(takable_brain(found, only)) : nil
      report << brain_report(brain) if brain && brain["sources"].positive?
      report << Reach::Messages.text("M-RECLAIM-BRAIN-BUSY", count: brain["busy"]) if brain && brain["busy"].positive?
      work = wanted.include?("work") && work_pending?(found["work"]) ? perform_work(found["work"]) : nil
      report.concat(work_report(work)) if work
      candidate = found["from"]
      copied = wanted.include?("from") && from_pending?(candidate) ? perform_from(candidate) : nil
      report.concat(from_report(copied, candidate)) if copied
      report << Reach::Messages.text("M-RECLAIM-NONE") if report.empty?
      { "state" => "done", "brain" => brain, "work" => work, "from" => copied, "message" => report.join("\n") }
    end

    def brain_report(result)
      Reach::Messages.text("M-RECLAIM-DONE-BRAIN", sources: result["sources"], copied: result["copied"], merged: result["merged"], kept: result["kept"])
    end

    def work_report(result)
      out = []
      out << Reach::Messages.text("M-RECLAIM-DONE-WORK", count: result["adopted"].length) unless result["adopted"].empty?
      out << Reach::Messages.text("M-RECLAIM-DONE-EXTRA") if result["extracurricular"]
      out << Reach::Messages.text("M-RECLAIM-WORK-FAILED", folders: result["failed"].join(", ")) unless result["failed"].empty?
      out << Reach::Checkpoint.condition_lines(result["recoverable"]).join("\n") unless result["recoverable"].empty?
      out
    end

    def from_report(result, candidate)
      head = Reach::Messages.text("M-RECLAIM-DONE-FROM", path: tilde(candidate["path"]), copied: result["copied"], same: result["same"], differ: result["differs"].length, failed: result["failed"])
      [head] + result["differs"].first(20).map { |rel| Reach::Messages.text("M-RECLAIM-ITEM-DIFFERS", file: rel) }
    end

    def perform_brain(candidates)
      total = { "sources" => 0, "copied" => 0, "merged" => 0, "kept" => 0, "busy" => 0 }
      return total if candidates.empty? || Reach::Brain.owner_mismatch?

      candidates.each do |item|
        counts = merge_brain(item["path"])
        if counts.nil?
          total["busy"] += 1
          next
        end
        total["sources"] += 1
        total["copied"] += counts[:copied]
        total["merged"] += counts[:merged] + counts[:same] + counts[:dropped]
        total["kept"] += counts[:kept]
        record!("brain", item["source"], fingerprint(brain_files(item["path"])), "files" => counts.values.sum, "owner" => item["owner"])
      end
      total
    end

    def merge_brain(source)
      Reach::Brain.ensure_dir!
      target = Reach::Brain.dir
      counts = Hash.new(0)
      outcome = Reach::Brain.with_lock(wait_s: 5) do
        brain_files(source).each do |rel, from|
          result = merge_file(rel, from, File.join(target, rel))
          counts[result] += 1
          File.delete(from) if SETTLED.include?(result)
        end
        true
      end
      return nil if outcome == :busy

      FileUtils.rm_f(File.join(target, "index.json"))
      FileUtils.rm_f(File.join(source, "index.json"))
      Reach::Brain.prune_empty(source)
      Dir.rmdir(source) if Dir.empty?(source)
      Reach::Brain.load_index
      counts
    rescue SystemCallError, IOError => error
      Reach::Brain.log("brain.reclaim_failed", "error" => error.class.name)
      nil
    end

    def merge_file(rel, from, to)
      return merge_existing(rel, from, to) if File.exist?(to) || File.symlink?(to)

      FileUtils.mkdir_p(File.dirname(to))
      tmp = format("%s.tmp-%d-%s", to, Process.pid, SecureRandom.hex(3))
      FileUtils.cp(from, tmp, preserve: true)
      unless File.size(tmp) == File.size(from) && file_sha(tmp) == file_sha(from)
        FileUtils.rm_f(tmp)
        return :kept
      end
      File.chmod(0o600, tmp)
      File.rename(tmp, to)
      :copied
    end

    def merge_existing(rel, from, to)
      return :kept unless File.file?(to) && !File.symlink?(to)
      return :same if File.size(to) == File.size(from) && file_sha(to) == file_sha(from)

      case rel
      when "state.json" then merge_state(from, to)
      when "pending-erase.jsonl" then merge_lines(from, to)
      when "course-ingest.json" then :dropped
      else :kept
      end
    rescue SystemCallError, IOError
      :kept
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def later(left, right)
      a = parse_time(left)
      b = parse_time(right)
      return left || right unless a && b

      a >= b ? left : right
    end

    def merge_state(from, to)
      mine = Reach::Brain.read_json(to)
      theirs = Reach::Brain.read_json(from)
      table = mine["reinforcements"].is_a?(Hash) ? mine["reinforcements"].dup : {}
      extra = theirs["reinforcements"].is_a?(Hash) ? theirs["reinforcements"] : {}
      extra.each do |id, entry|
        next unless entry.is_a?(Hash)

        current = table[id].is_a?(Hash) ? table[id] : nil
        table[id] = current ? { "count" => [current["count"].to_i, entry["count"].to_i].max, "last" => later(current["last"], entry["last"]) } : entry
      end
      merged = theirs.merge(mine).merge("reinforcements" => table)
      Reach::Brain.write_json(to, merged) unless merged == mine
      :merged
    end

    def merge_lines(from, to)
      have = File.readlines(to, chomp: true)
      extra = File.readlines(from, chomp: true).reject { |line| line.strip.empty? || have.include?(line) }.uniq
      return :merged if extra.empty?

      tmp = format("%s.tmp-%d-%s", to, Process.pid, SecureRandom.hex(3))
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write((have + extra).map { |line| "#{line}\n" }.join) }
      File.rename(tmp, to)
      :merged
    end

    def perform_work(work)
      adopted = []
      failed = []
      work["slices"].each do |path|
        adopt_slice(path)
        adopted << File.basename(path)
      rescue *FAILURES
        failed << File.basename(path)
      end
      extra = false
      if work["extracurricular"]
        begin
          Reach::Workspace.provision_extracurricular!
          extra = true
        rescue *FAILURES
          failed << "extracurricular"
        end
      end
      { "adopted" => adopted, "extracurricular" => extra, "failed" => failed, "recoverable" => Reach::Checkpoint.conditions }
    end

    def adopt_slice(path)
      Reach::Checkpoint.autosave(path, via: "reclaim")
      Reach::Workspace.write_rules_files(path)
      digests = Reach::Workspace.read_delivered_digests(path)
      delivered = (digests.fetch("readonly", {}).keys + Reach::Workspace::GENERATED_FILES.select { |name| File.file?(File.join(path, name)) }).uniq
      Reach::Workspace.lock_down(path, Reach::Workspace.owned_files(path), delivered)
      Reach::Workspace.configure_harness(path)
      nil
    end

    def perform_from(candidate)
      tally = { "copied" => 0, "same" => 0, "failed" => 0, "differs" => [] }
      candidate["plan"]["files"].each do |item|
        case item["state"]
        when "same" then tally["same"] += 1
        when "differs" then tally["differs"] << item["rel"]
        else tally[copy_new(item["from"], item["to"]) ? "copied" : "failed"] += 1
        end
      end
      record!("from", candidate["source"], candidate["fingerprint"], "copied" => tally["copied"])
      tally
    end

    def copy_new(from, to)
      return false if File.exist?(to) || File.symlink?(to)

      FileUtils.mkdir_p(File.dirname(to))
      tmp = File.join(File.dirname(to), format(".%s.reclaim-%d-%s", File.basename(to), Process.pid, SecureRandom.hex(3)))
      File.binwrite(tmp, File.binread(from))
      unless File.size(tmp) == File.size(from) && file_sha(tmp) == file_sha(from)
        FileUtils.rm_f(tmp)
        return false
      end
      File.chmod(0o644, tmp)
      File.rename(tmp, to)
      true
    rescue SystemCallError
      FileUtils.rm_f(tmp) if tmp
      false
    end

    def offer_due?
      return false unless available? && enrolled?
      record = Reach::StateFile.read(OFFER_FILE)
      return false if record["offered"] == true
      return false if checked_recently?(record["checked_at"])

      found = scan
      due = found["brain"].any? { |item| item["owner"] == "ours" } || !(found["work"] && found["work"]["slices"]).to_a.empty?
      Reach::StateFile.write(OFFER_FILE, "offered" => false, "checked_at" => Time.now.utc.iso8601) unless due
      due
    rescue *FAILURES
      false
    end

    def checked_recently?(stamp)
      return false unless stamp.is_a?(String)

      Time.now.utc - Time.iso8601(stamp) < OFFER_RECHECK_S
    rescue ArgumentError
      false
    end

    def offer_shown!
      Reach::StateFile.write(OFFER_FILE, "offered" => true, "at" => Time.now.utc.iso8601)
      nil
    rescue SystemCallError
      nil
    end
  end
end
