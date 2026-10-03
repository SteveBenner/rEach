require "json"
require "time"
require "digest"

module Reach
  module CourseCorpus
    PATH_PREFIX = "course/".freeze
    MAX_PART_BYTES = 1_000_000
    TEXT_EXTS = %w[.md .markdown .txt].freeze
    REASON = "course material replaced".freeze

    module_function

    def state_path
      File.join(Reach::Brain.dir, "course-ingest.json")
    end

    def fingerprint
      blobs = Reach::Reference.blob_paths.map { |path| [File.basename(path), Digest::SHA256.file(path).hexdigest] }.sort
      held, _courses = Reach::Reference.keys
      Digest::SHA256.hexdigest(JSON.generate("blobs" => blobs, "keys" => held.keys.sort))
    end

    def ingest(force: false, admit: true)
      return { "state" => "disabled", "courses" => 0, "files" => 0, "sources" => 0, "tombstoned" => 0 } unless Reach::Brain.enabled?

      report = nil
      held = Reach::Brain.with_lock do
        report = ingest_locked(force)
      end
      return { "state" => "busy", "courses" => 0, "files" => 0, "sources" => 0, "tombstoned" => 0 } if held == :busy

      if report["state"] == "ingested"
        Reach::Corpus.new(Reach.ports).admit_if_due(force: true) if admit
        Reach::Brain.log("brain.course_ingested", "courses" => report["courses"], "files" => report["files"], "sources" => report["sources"], "tombstoned" => report["tombstoned"], "state" => report["state"])
      end
      report
    rescue StandardError => e
      Reach::Brain.log("brain.course_ingest_failed", "error" => e.class.name)
      { "state" => "failed", "courses" => 0, "files" => 0, "sources" => 0, "tombstoned" => 0 }
    end

    def ingest_if_changed(admit: true)
      ingest(force: false, admit: admit)
    rescue StandardError
      nil
    end

    def ingest_locked(force)
      stored = Reach::Brain.read_json(state_path)
      print = fingerprint
      if !force && stored["fingerprint"] == print
        return { "state" => "unchanged", "courses" => stored["courses"].to_i, "files" => stored["files"].to_i, "sources" => 0, "tombstoned" => 0 }
      end

      begin
        documents = Reach::Reference.documents
      rescue Reach::Refused
        return { "state" => "none", "courses" => 0, "files" => 0, "sources" => 0, "tombstoned" => 0 }
      end

      previous = stored["sources"].is_a?(Hash) ? stored["sources"] : {}
      current = {}
      written = 0
      files = 0
      now = Time.now.utc.iso8601
      documents.each do |document|
        document["files"].each do |file|
          files += 1
          each_part(document["course"], file) do |path, part|
            digest = Digest::SHA256.hexdigest(part)
            id = Reach::Brain.source_id(path, digest)
            current[path] = id
            next if previous[path] == id

            record = { "text" => part, "path" => path, "source_digest" => digest, "title" => file["title"], "category" => "course", "at" => now }
            Reach::BrainSpool.append_op(op: "source", kind: "source", id: id, record: record)
            written += 1
          end
        end
      end

      tombstoned = 0
      previous.each do |path, old_id|
        next if current[path] == old_id

        Reach::BrainSpool.append_op(op: "tombstone", kind: "source", id: old_id, record: { "reason" => REASON })
        tombstoned += 1
      end

      Reach::Brain.write_json(state_path, "fingerprint" => print, "sources" => current, "courses" => documents.length, "files" => files, "at" => now)
      { "state" => "ingested", "courses" => documents.length, "files" => files, "sources" => written, "tombstoned" => tombstoned }
    end

    def each_part(course, file)
      text = file["text"].to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
      return if text.strip.empty?

      relative = file["path"].to_s.sub(%r{\A/+}, "")
      return if relative.empty? || relative.split("/").include?("..")

      base = "#{PATH_PREFIX}#{course}/#{relative}"
      base = "#{base}.md" unless TEXT_EXTS.include?(File.extname(base))
      parts = split_text(text)
      if parts.length == 1
        yield base, parts.first
      else
        ext = File.extname(base)
        stem = base[0, base.length - ext.length]
        parts.each_with_index { |part, index| yield "#{stem}.part#{index + 1}#{ext}", part }
      end
    end

    def split_text(text)
      parts = []
      current = +""
      text.each_line do |line|
        if current.bytesize + line.bytesize > MAX_PART_BYTES && !current.empty?
          parts << current
          current = +""
        end
        while line.bytesize > MAX_PART_BYTES
          cut = MAX_PART_BYTES
          cut -= 1 while cut.positive? && (line.getbyte(cut) & 0xC0) == 0x80
          unless current.empty?
            parts << current
            current = +""
          end
          parts << line.byteslice(0, cut)
          line = line.byteslice(cut, line.bytesize - cut)
        end
        current << line
      end
      parts << current unless current.empty?
      parts
    end
  end
end
