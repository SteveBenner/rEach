require "json"
require "time"
require "fileutils"
require "zlib"
require "openssl"

module Reach
  module Limits
    DEFAULTS = {
      "corpus_max_bytes" => 52_428_800,
      "transcript_spool_max_bytes" => 209_715_200,
      "materials_max_bytes" => 209_715_200
    }.freeze

    RETENTION_DEFAULTS = {
      "archive_retention_days_after_course" => 180,
      "unacked_retention_days_after_course" => 30
    }.freeze
    RETENTION_STATE_NAME = "transcripts-retention.json".freeze

    module_function

    def enforce!
      result = {}
      result["corpus"] = guarded { enforce_corpus }
      result["transcripts"] = guarded { enforce_transcripts }
      result
    end

    def report
      lines = []
      corpus = corpus_bytes
      cap = cap_for("corpus_max_bytes")
      if corpus_port?
        lines << "R-DOC-LIMITS corpus #{megabytes(corpus)} MB, managed by the corpus port"
      else
        lines << limit_line("corpus", corpus, cap)
      end
      lines << limit_line("transcripts", spool_bytes, cap_for("transcript_spool_max_bytes"))
      materials_spaces.each do |space_path|
        lines << limit_line("materials #{File.basename(space_path)}", directory_bytes(File.join(space_path, "materials")), cap_for("materials_max_bytes"))
      end
      lines
    rescue StandardError
      ["R-DOC-LIMITS the local size limits could not be checked"]
    end

    def limit_line(label, bytes, cap)
      prefix = bytes > cap ? "WARNING " : ""
      "#{prefix}R-DOC-LIMITS #{label} #{megabytes(bytes)} MB of #{megabytes(cap)} MB"
    end

    def guarded
      yield
    rescue StandardError => e
      { "error" => e.class.name }
    end

    def cap_for(key)
      values = begin
        Reach::Policy.limits
      rescue StandardError
        {}
      end
      value = values.is_a?(Hash) ? values[key].to_i : 0
      value > 0 ? value : DEFAULTS[key]
    end

    def megabytes(bytes)
      format("%.1f", bytes.to_f / 1_048_576)
    end

    def corpus_port?
      Reach::Corpus.new(Reach.ports).available?
    rescue StandardError
      false
    end

    def corpus_files
      Reach::BrainSpool.spool_files(include_admitted: false)
    end

    def corpus_bytes
      corpus_files.sum { |path| File.size(path) }
    end

    def enforce_corpus
      total = corpus_bytes
      return { "state" => "managed by the corpus port", "bytes" => total } if corpus_port?

      state = total <= cap_for("corpus_max_bytes") ? "queued for admission" : "queued for admission, over cap"
      { "state" => state, "bytes" => total }
    end

    def spool_files
      dir = Reach::Paths.transcripts_dir
      return [] unless File.directory?(dir)

      Dir.children(dir).map { |name| File.join(dir, name) }.select { |path| File.file?(path) }
    end

    def spool_bytes
      spool_files.sum { |path| File.size(path) }
    rescue StandardError
      0
    end

    def retention_days(key)
      section = Reach::Runtime.load_config["transcripts"]
      value = section.is_a?(Hash) ? section[key] : nil
      value.is_a?(Numeric) && value >= 0 ? value : RETENTION_DEFAULTS.fetch(key)
    rescue StandardError
      RETENTION_DEFAULTS.fetch(key)
    end

    def retention_state_path
      File.join(Reach::Paths.state_dir, RETENTION_STATE_NAME)
    end

    def course_end
      stamp = Reach::Stamp.current
      found = stamp.is_a?(Hash) ? parse_time(stamp["expires_at"]) : nil
      if found
        remember_course_end(found)
        return found
      end

      recorded = File.file?(retention_state_path) ? JSON.parse(File.read(retention_state_path)) : nil
      recorded.is_a?(Hash) ? parse_time(recorded["course_end"]) : nil
    rescue StandardError
      nil
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def remember_course_end(time)
      path = retention_state_path
      stamped = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      current = File.file?(path) ? JSON.parse(File.read(path)) : {}
      return if current.is_a?(Hash) && current["course_end"] == stamped

      FileUtils.mkdir_p(Reach::Paths.state_dir)
      tmp = "#{path}.tmp.#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate("course_end" => stamped)) }
      File.rename(tmp, path)
    rescue StandardError
      nil
    end

    def retention_due?(ended, days, now)
      ended && now >= ended + (days * 86_400)
    end

    def expire_file(path, deleted)
      bytes = File.size(path)
      File.delete(path)
      deleted << { "path" => path, "bytes" => bytes }
      true
    rescue SystemCallError
      false
    end

    def enforce_retention(now = Time.now.utc)
      ended = course_end
      deleted = []
      return { "state" => "course not ended", "deleted" => 0 } unless ended && now >= ended

      archive_due = retention_due?(ended, retention_days("archive_retention_days_after_course"), now)
      unacked_due = retention_due?(ended, retention_days("unacked_retention_days_after_course"), now)
      if archive_due
        Dir.glob(File.join(Reach::Paths.transcripts_archive_dir, "*.jsonl.gz")).each { |path| expire_file(path, deleted) }
      end
      remaining = {}
      spool_files.each do |path|
        name = File.basename(path)
        if name.end_with?(".rejected.jsonl")
          remaining[name.sub(/\.rejected\.jsonl\z/, "")] = true unless unacked_due && expire_file(path, deleted)
        elsif name.end_with?(".state.json")
          remaining[name.sub(/\.state\.json\z/, "")] ||= false
        elsif name.end_with?(".jsonl")
          session = File.basename(name, ".jsonl")
          due = fully_acknowledged?(session) ? archive_due : unacked_due
          remaining[session] = true unless due && expire_file(path, deleted)
        end
      end
      if unacked_due
        remaining.each do |session, kept|
          expire_file(Reach::Transcript.state_path(session), deleted) if kept == false
        end
      end
      { "state" => deleted.empty? ? "nothing expired" : "expired", "deleted" => deleted.length, "bytes" => deleted.sum { |item| item["bytes"] } }
    end

    def enforce_transcripts
      expired = guarded { enforce_retention }
      cap = cap_for("transcript_spool_max_bytes")
      total = spool_bytes
      return { "state" => "within cap", "bytes" => total, "retention" => expired } if total <= cap

      archived = []
      sessions = spool_files.select { |path| path.end_with?(".jsonl") && !path.end_with?(".rejected.jsonl") }
      sessions.sort_by { |path| File.mtime(path) }.each do |path|
        break if total <= cap

        session = File.basename(path, ".jsonl")
        next unless fully_acknowledged?(session)

        freed = archive_session(session, path)
        next unless freed

        total -= freed
        archived << session
      end
      { "state" => archived.empty? ? "nothing to archive" : "archived", "sessions" => archived, "bytes" => spool_bytes, "retention" => expired }
    end

    def fully_acknowledged?(session)
      state = Reach::Transcript.parse_json_file(Reach::Transcript.state_path(session))
      return false unless state.is_a?(Hash)

      state["last_seq"].to_i.positive? && state["acked_seq"].to_i >= state["last_seq"].to_i
    end

    def archive_session(session, path)
      FileUtils.mkdir_p(Reach::Paths.transcripts_archive_dir)
      FileUtils.chmod(0o700, Reach::Paths.transcripts_archive_dir)
      freed = nil
      Reach::Locks.exclusive(path, mode: File::RDWR) do |file|
        state = Reach::Transcript.parse_json_file(Reach::Transcript.state_path(session))
        return nil unless state.is_a?(Hash) && state["acked_seq"].to_i >= state["last_seq"].to_i

        content = file.read
        target = unique_archive(session)
        tmp = "#{target}.tmp.#{Process.pid}"
        Zlib::GzipWriter.open(tmp) { |gz| gz.write(content) }
        verified = Zlib::GzipReader.open(tmp) { |gz| gz.read }
        unless verified == content
          FileUtils.rm_f(tmp)
          return nil
        end
        File.rename(tmp, target)
        FileUtils.chmod(0o600, target)
        freed = content.bytesize
        File.delete(path)
      end
      freed
    rescue StandardError
      nil
    end

    def unique_archive(session)
      dir = Reach::Paths.transcripts_archive_dir
      target = File.join(dir, "#{session}.jsonl.gz")
      counter = 2
      while File.exist?(target)
        target = File.join(dir, "#{session}-#{counter}.jsonl.gz")
        counter += 1
      end
      target
    end

    def materials_spaces
      spaces = Reach::Workspace.current_slices.dup
      extracurricular = Reach::Paths.extracurricular_root
      spaces << extracurricular if File.directory?(extracurricular)
      spaces.select { |space| File.directory?(File.join(space, "materials")) }
    rescue StandardError
      []
    end

    def directory_bytes(dir)
      return 0 unless File.directory?(dir)

      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sum do |path|
        File.file?(path) && !File.symlink?(path) ? File.size(path) : 0
      end
    rescue StandardError
      0
    end
  end
end
