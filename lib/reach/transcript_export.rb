require "json"
require "time"
require "zlib"
require "fileutils"

module Reach
  module TranscriptExport
    STATE_NAME = "transcripts-export.json".freeze
    SPAWN_GAP_S = 120
    SESSION_NAME_LENGTH = 8
    RESERVED_DIRS = %w[extracurricular unsorted raw README.md].freeze
    HEADINGS = {
      "prompt" => "M-TX-HEAD-PROMPT", "reply" => "M-TX-HEAD-REPLY", "reasoning" => "M-TX-HEAD-REASONING",
      "action" => "M-TX-HEAD-ACTION", "output" => "M-TX-HEAD-OUTPUT", "code" => "M-TX-HEAD-CODE"
    }.freeze
    TEXT_KINDS = %w[prompt reply reasoning].freeze

    class NothingToExport < StandardError
    end

    module_function

    def auto_enabled?
      section = Reach::Runtime.load_config["transcripts"]
      !(section.is_a?(Hash) && section["auto_export"] == false)
    rescue StandardError
      true
    end

    def course_id
      stamp = Reach::Stamp.current
      found = stamp.is_a?(Hash) ? stamp["course_id"].to_s : ""
      if found.empty?
        install = Reach::Enroll.current
        found = install && install["course"].is_a?(Hash) ? install["course"]["id"].to_s : ""
      end
      if found.empty?
        section = Reach::Runtime.load_config["course"]
        found = section.is_a?(Hash) ? section["id"].to_s : ""
      end
      found.empty? ? "course" : found
    rescue StandardError
      "course"
    end

    def student_id
      install = Reach::Enroll.current
      install && install["student_id"].to_s
    rescue StandardError
      nil
    end

    def source_files
      live = Dir.glob(File.join(Reach::Paths.transcripts_dir, "*.jsonl")).reject { |path| path.end_with?(".rejected.jsonl") }
      archived = Dir.glob(File.join(Reach::Paths.transcripts_archive_dir, "*.jsonl.gz"))
      (live + archived).sort
    end

    def each_line(path)
      if path.end_with?(".gz")
        Zlib::GzipReader.open(path) do |gz|
          gz.each_line { |line| yield(line) }
        end
      else
        File.foreach(path) { |line| yield(line) }
      end
    rescue Zlib::Error, SystemCallError
      nil
    end

    def parse_line(line)
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def session_of(path)
      found = nil
      each_line(path) do |line|
        entry = parse_line(line)
        next unless entry && !entry["session_id"].to_s.empty?

        found = entry["session_id"].to_s
        break
      end
      found
    end

    def plan
      grouped = {}
      source_files.each do |path|
        session = session_of(path)
        next unless session

        (grouped[session] ||= []) << path
      end
      grouped.sort_by { |session, _| session }
    end

    def mine?(entry, student)
      owner = entry["student_id"].to_s
      owner.empty? || owner == student.to_s
    end

    def load_session(paths, student)
      seen = {}
      kept = []
      paths.each do |path|
        each_line(path) do |line|
          entry = parse_line(line)
          next unless entry && mine?(entry, student)

          seq = entry["seq"].to_i
          next if seq.positive? && seen[seq]

          seen[seq] = true if seq.positive?
          kept << { entry: entry, raw: "#{line.chomp}\n" }
        end
      end
      kept.each_with_index.sort_by { |item, position| [item[:entry]["seq"].to_i, position] }.map(&:first)
    end

    def assignment_index
      index = {}
      Reach::Workspace.current_slices.each do |path|
        meta = Reach::Workspace.metadata(path)
        key = [meta["cutout_id"], meta["slice"]]
        index[key] ||= meta["assignment"] unless meta["assignment"].to_s.empty?
      end
      Reach::Receipts.list.each do |receipt|
        key = [receipt["cutout_id"], receipt["slice"]]
        index[key] ||= receipt["assignment"] unless receipt["assignment"].to_s.empty?
      end
      index
    rescue StandardError
      index || {}
    end

    def group_for(entries, index)
      entries.each do |entry|
        scope = entry["scope"].is_a?(Hash) ? entry["scope"] : {}
        assignment = scope["assignment"].to_s
        slice = entry["slice"].to_s
        slice = scope["slice"].to_s if slice.empty?
        if assignment.empty?
          assignment = index[[entry["cutout_id"], entry["slice"]]].to_s
        end
        return [:assignment, assignment, slice] unless assignment.empty?
      end
      return [:extracurricular] if entries.any? { |entry| entry["space"] == "extracurricular" }

      [:unsorted]
    end

    def folder_name(value)
      cleaned = Reach::Archive.clean(value)
      cleaned = "unnamed" if cleaned.empty?
      RESERVED_DIRS.include?(cleaned) ? "assignment-#{cleaned}" : cleaned
    end

    def group_dir(group)
      case group.first
      when :assignment
        slice = group[2].to_s.empty? ? "slice" : folder_name(group[2])
        "#{folder_name(group[1])}/#{slice}"
      when :extracurricular
        "extracurricular"
      else
        "unsorted"
      end
    end

    def group_label(group)
      case group.first
      when :assignment
        Reach::Messages.text("M-TX-README-GROUP-ASSIGNMENT", assignment: group[1], slice: group[2])
      when :extracurricular
        Reach::Messages.text("M-TX-README-GROUP-EXTRA")
      else
        Reach::Messages.text("M-TX-README-GROUP-UNSORTED")
      end
    end

    def entry_time(entry)
      Time.parse(entry["at"].to_s)
    rescue ArgumentError
      nil
    end

    def session_short(session)
      short = session.to_s.gsub(/[^A-Za-z0-9]/, "")[0, SESSION_NAME_LENGTH]
      short.empty? ? "session" : short
    end

    def unique(used, name)
      return name unless used[name]

      extension = File.extname(name)
      stem = name[0, name.length - extension.length]
      counter = 2
      counter += 1 while used["#{stem}-#{counter}#{extension}"]
      "#{stem}-#{counter}#{extension}"
    end

    def fence_for(text)
      longest = text.to_s.scan(/`+/).map(&:length).max.to_i
      "`" * [3, longest + 1].max
    end

    def language_for(path)
      extension = File.extname(path.to_s).delete(".")
      extension.match?(/\A[A-Za-z0-9]{1,8}\z/) ? extension : ""
    end

    def render_entry(entry)
      kind = entry["kind"].to_s
      heading_id = HEADINGS[kind] || "M-TX-HEAD-OTHER"
      time = Reach::CourseTime.format(entry["at"])
      lines = ["## #{Reach::Messages.text(heading_id)}#{time.empty? ? '' : ", #{time}"}", ""]
      case kind
      when "action"
        lines << Reach::Messages.text("M-TX-ENTRY-TOOL", tool: entry["tool"]) unless entry["tool"].to_s.empty?
        lines.concat(["", entry["summary"].to_s]) unless entry["summary"].to_s.empty?
        lines.concat(["", entry["note"].to_s]) unless entry["note"].to_s.empty?
      when "output"
        lines << Reach::Messages.text("M-TX-ENTRY-TOOL", tool: entry["tool"]) unless entry["tool"].to_s.empty?
        lines.concat(["", entry["note"].to_s]) unless entry["note"].to_s.empty?
        if entry["text"].is_a?(String) && !entry["text"].empty?
          fence = fence_for(entry["text"])
          lines.concat(["", fence, entry["text"].chomp, fence])
        else
          lines.concat(["", Reach::Messages.text("M-TX-ENTRY-NO-TEXT")])
        end
      when "code"
        lines << Reach::Messages.text("M-TX-ENTRY-FILE", path: entry["path"])
        if entry["deleted"]
          lines.concat(["", Reach::Messages.text("M-TX-ENTRY-DELETED")])
        elsif entry["binary"]
          lines.concat(["", Reach::Messages.text("M-TX-ENTRY-BINARY")])
        elsif entry["text"].is_a?(String)
          fence = fence_for(entry["text"])
          body = entry["text"].end_with?("\n") ? entry["text"] : "#{entry["text"]}\n"
          lines.concat(["", "#{fence}#{language_for(entry["path"])}", body.chomp, fence])
          lines.concat(["", Reach::Messages.text("M-TX-ENTRY-CUT")]) if entry["truncated"]
        else
          lines.concat(["", Reach::Messages.text("M-TX-ENTRY-NO-TEXT")])
        end
      else
        if entry["text"].is_a?(String) && !entry["text"].empty?
          lines << entry["text"].chomp
          lines.concat(["", Reach::Messages.text("M-TX-ENTRY-CUT")]) if entry["truncated"]
        else
          lines << Reach::Messages.text("M-TX-ENTRY-NO-TEXT")
          lines.concat(["", entry["note"].to_s]) unless entry["note"].to_s.empty?
        end
      end
      lines.join("\n")
    end

    def counts_for(entries)
      kinds = entries.map { |entry| entry["kind"].to_s }
      {
        "prompts" => kinds.count("prompt"), "replies" => kinds.count("reply"), "reasoning" => kinds.count("reasoning"),
        "actions" => kinds.count("action"), "outputs" => kinds.count("output"), "code" => kinds.count("code")
      }
    end

    def counts_text(counts)
      Reach::Messages.text(
        "M-TX-README-COUNTS",
        prompts: counts["prompts"], replies: counts["replies"], reasoning: counts["reasoning"], actions: counts["actions"],
        outputs: counts["outputs"], code: counts["code"]
      )
    end

    def markdown(session, group, entries)
      first = entries.first
      harness = first["harness"].to_s
      started = Reach::CourseTime.format(first["at"])
      lines = ["# #{Reach::Messages.text('M-TX-SESSION-TITLE', session: session_short(session))}", ""]
      lines << Reach::Messages.text("M-TX-SESSION-WHERE", where: group_label(group))
      lines << Reach::Messages.text("M-TX-SESSION-HARNESS", harness: harness) unless harness.empty?
      lines << Reach::Messages.text("M-TX-SESSION-STARTED", when: started) unless started.empty?
      entries.each do |entry|
        lines << ""
        lines << render_entry(entry)
      end
      "#{lines.join("\n")}\n"
    end

    def readme(course, summaries)
      lines = ["# #{Reach::Messages.text('M-TX-README-TITLE', course: course)}", ""]
      lines << Reach::Messages.text("M-TX-README-INTRO", saved: Reach::CourseTime.format(Time.now.utc))
      summaries.group_by { |item| item[:label] }.sort_by { |label, items| [items.first[:order], label] }.each do |label, items|
        lines.concat(["", "## #{label}", ""])
        items.sort_by { |item| item[:sort] }.each do |item|
          lines << "- #{Reach::Messages.text('M-TX-README-SESSION', file: item[:file], when: item[:when], counts: counts_text(item[:counts]))}"
        end
      end
      "#{lines.join("\n")}\n"
    end

    def order_for(group)
      { assignment: 0, extracurricular: 1, unsorted: 2 }.fetch(group.first)
    end

    def build_entries(root, student, index, summaries)
      Enumerator.new do |yielder|
        summaries.clear
        used = {}
        raw_used = {}
        plan.each do |session, paths|
          kept = load_session(paths, student)
          next if kept.empty?

          entries = kept.map { |item| item[:entry] }
          group = group_for(entries, index)
          dir = group_dir(group)
          moment = entry_time(entries.first)
          prefix = moment ? Reach::CourseTime.stamp(moment)[0, 15] : "undated"
          file = unique(used, "#{dir}/#{prefix}-#{session_short(session)}.md")
          used[file] = true
          raw = unique(raw_used, "#{Reach::Archive.clean(session)}.jsonl")
          raw_used[raw] = true
          stamp_time = moment || Time.now
          yielder << ["#{root}/#{file}", markdown(session, group, entries), stamp_time]
          yielder << ["#{root}/raw/#{raw}", kept.map { |item| item[:raw] }.join, stamp_time]
          summaries << {
            label: group_label(group), order: order_for(group), file: file, when: Reach::CourseTime.format(entries.first["at"]),
            sort: [moment ? moment.to_i : 0, file], counts: counts_for(entries), entries: entries.length
          }
        end
        raise NothingToExport if summaries.empty?

        yielder << ["#{root}/README.md", readme(course_id, summaries), Time.now]
      end
    end

    def size_text(bytes)
      bytes = bytes.to_i
      return "#{[(bytes / 1024.0).ceil, 1].max} KB" if bytes < 1_048_576

      format("%.1f MB", bytes / 1_048_576.0)
    end

    def write!(auto: false)
      return perform(false) unless auto

      FileUtils.mkdir_p(Reach::Paths.state_dir)
      File.open("#{state_path}.run", File::RDWR | File::CREAT, 0o600) do |lock|
        return { "state" => "busy" } unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        recorded = state_read["auto"]
        return { "state" => "skipped", "reason" => "already_exported" } if recorded.is_a?(Hash) && recorded[course_id]

        perform(true)
      end
    end

    def perform(auto)
      destination = Reach::Archive.downloads_dir
      FileUtils.mkdir_p(destination)
      base = "#{Reach::Archive.clean(course_id)}-transcripts-#{Reach::CourseTime.stamp(Time.now)}"
      student = student_id
      index = assignment_index
      summaries = []
      final = Reach::Archive.claim_zip(destination, base) { |stem| build_entries(stem, student, index, summaries) }
      result = {
        "state" => "saved", "path" => final, "name" => File.basename(final), "bytes" => File.size(final),
        "sessions" => summaries.length, "entries" => summaries.sum { |item| item[:entries] }
      }
      record_auto(result) if auto
      result
    rescue NothingToExport
      record_auto("state" => "none") if auto
      { "state" => "none" }
    rescue StandardError => e
      begin
        Reach::BrainSpool.log("transcript_export_failed", "error" => e.class.name)
      rescue StandardError
        nil
      end
      { "state" => "failed" }
    end

    def result_text(result)
      case result["state"]
      when "saved"
        Reach::Messages.text(
          "M-TRANSCRIPTS-EXPORTED", name: result["name"], sessions: result["sessions"], entries: result["entries"], size: size_text(result["bytes"])
        )
      when "none"
        Reach::Messages.text("M-TRANSCRIPTS-NONE")
      else
        Reach::Messages.text("M-TRANSCRIPTS-FAILED")
      end
    end

    def state_path
      File.join(Reach::Paths.state_dir, STATE_NAME)
    end

    def state_read
      return {} unless File.file?(state_path)

      data = JSON.parse(File.read(state_path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def with_state
      FileUtils.mkdir_p(Reach::Paths.state_dir)
      Reach::Locks.exclusive("#{state_path}.lock") do |_lock|
        state = state_read
        before = JSON.generate(state)
        result = yield(state)
        unless JSON.generate(state) == before
          tmp = "#{state_path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
          File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
            file.write(JSON.generate(state))
            file.flush
            file.fsync
          end
          File.rename(tmp, state_path)
        end
        result
      end
    end

    def record_auto(result)
      course = course_id
      with_state do |state|
        auto = state["auto"].is_a?(Hash) ? state["auto"] : {}
        auto[course] = {
          "course" => course, "path" => result["path"], "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "state" => result["state"]
        }
        state["auto"] = auto
      end
    rescue StandardError
      nil
    end

    def recent?(value)
      stamp = Time.iso8601(value.to_s)
      Time.now.utc - stamp < SPAWN_GAP_S
    rescue ArgumentError
      false
    end

    def student_course?
      return false if Reach::Persona.active? || Reach::Instructor.mode?

      !Reach::Enroll.current.nil?
    rescue StandardError
      false
    end

    def course_over?
      stamp = Reach::Stamp.current
      stamp.is_a?(Hash) && Reach::Stamp.expired?(stamp)
    rescue StandardError
      false
    end

    def spawn_auto_if_due
      return false unless auto_enabled? && student_course? && course_over?

      course = course_id
      with_state do |state|
        auto = state["auto"].is_a?(Hash) ? state["auto"] : {}
        next false if auto[course]
        next false if recent?(state["auto_spawned_at"])

        state["auto_spawned_at"] = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        !Reach::Storage.spawn_detached(%w[transcripts export --auto]).nil?
      end
    rescue StandardError
      false
    end

    def pending_notice!
      return nil unless File.file?(state_path)

      course = course_id
      path = nil
      with_state do |state|
        auto = state["auto"].is_a?(Hash) ? state["auto"] : {}
        record = auto[course]
        next unless record.is_a?(Hash) && record["state"] == "saved" && !record["path"].to_s.empty? && record["announced_at"].nil?

        record["announced_at"] = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        path = record["path"]
      end
      path ? Reach::Messages.text("M-TRANSCRIPTS-AUTO", path: path) : nil
    rescue StandardError
      nil
    end

    def session_start
      spawn_auto_if_due
      pending_notice!
    rescue StandardError
      nil
    end

    def agent_notice(text)
      text ? Reach::Messages.text("M-TRANSCRIPTS-AUTO-AGENT", text: text) : nil
    end
  end
end
