require "json"
require "time"
require "digest"
require "fileutils"

module Reach
  module ExportImport
    class Worker
      EXCERPT_BYTES = 400
      TOKEN_COUNT = 12
      TOKEN_CANDIDATES = 40
      TOKEN_MAX_CHARS = 24
      PART_BYTES = 1_000_000
      SPOOL_SCHEMA = "rcorpus.spool/v1".freeze
      RUN_DEADLINE_S = 12 * 3600
      RANK_WEIGHTS = { recency: 0.6, length: 0.2, overlap: 0.2 }.freeze

      def self.debug_fields(job)
        { "vendor" => job["vendor"], "mode" => job["mode"], "conversations" => job["seen"].to_i, "done" => job["done"].to_i, "bytes" => job["bytes"].to_i }
      end

      def initialize(id)
        @id = id
        @job = ExportImport.read_job(id)
        @catalog = nil
        @spool = nil
        @cancelled = false
        @deadline = Time.now + RUN_DEADLINE_S
      end

      def run
        @job = @job.merge("state" => "running", "phase" => "reading", "error" => nil)
        @job["started_at"] ||= ExportImport.now_s
        @job["spool_file"] ||= "#{Time.now.utc.strftime('%Y-%m-%d')}.jsonl" if copy?
        save
        begin
          unless @job["reading_done"]
            @source = approved_snapshot
            unless @source
              fail_with("source_changed")
              return result
            end

            prepare_outputs
            unless @job["started_logged"]
              @job["started_logged"] = true
              save
              Reach::Debug.import("started", self.class.debug_fields(@job))
            end
            stream_files
            return finish_cancelled if @cancelled

            @job["reading_done"] = true
            save
          end
          close_outputs
          finish
        rescue Reach::JsonStream::LimitExceeded => e
          close_outputs
          Reach::BrainSpool.log("import.failed", "error" => e.class.name)
          fail_with("element_limit")
        rescue Sources::TimeLimit => e
          close_outputs
          Reach::BrainSpool.log("import.failed", "error" => e.class.name)
          fail_with("time_limit")
        rescue Sources::SourceChanged => e
          close_outputs
          Reach::BrainSpool.log("import.failed", "error" => e.class.name)
          fail_with("source_changed")
        rescue StandardError => e
          close_outputs
          Reach::BrainSpool.log("import.failed", "error" => e.class.name)
          fail_with(e.class.name)
        ensure
          discard_snapshot
        end
        result
      end

      private

      def snapshot_dir
        File.join(ExportImport.job_dir(@id), "snapshot")
      end

      def discard_snapshot
        FileUtils.rm_rf(snapshot_dir) if File.exist?(snapshot_dir)
      rescue SystemCallError
        nil
      end

      def approved_snapshot
        approved = @job["source_digest"].to_s
        names = @job["files"].map { |file| file["name"] }
        dir = snapshot_dir
        if File.directory?(dir)
          held = Sources::Folder.new(dir)
          if held.content_digest(names) == approved
            record_file_digests(held, names)
            return held
          end

          discard_snapshot
        end
        original = Sources.open(@job["source"])
        ExportImport.ensure_dir!(ExportImport.job_dir(@id))
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
        original.copy_into(dir, names)
        copy = Sources::Folder.new(dir)
        if copy.content_digest(names) == approved
          record_file_digests(copy, names)
          return copy
        end

        discard_snapshot
        nil
      end

      def record_file_digests(snapshot, names)
        return if @job["file_digests"].is_a?(Hash) && names.all? { |name| @job["file_digests"][name] }

        digests = {}
        names.each do |name|
          digests[name] = snapshot.file_digest(name) || raise(Sources::SourceChanged)
        end
        @job["file_digests"] = digests
        save
      end

      def copy?
        @job["mode"] == "copy"
      end

      def result
        { "state" => @job["state"], "job" => @id, "done" => @job["done"].to_i, "seen" => @job["seen"].to_i }
      end

      def now
        ExportImport.now_s
      end

      def save
        @job["updated_at"] = now
        ExportImport.write_job(@id, @job)
      end

      def fail_with(error)
        @job = @job.merge("state" => "failed", "phase" => "failed", "error" => error, "finished_at" => now, "announced" => false)
        save
        Reach::Debug.import("failed", self.class.debug_fields(@job))
        true
      end

      def finish_cancelled
        close_outputs
        @job = @job.merge("state" => "cancelled", "phase" => "cancelled", "finished_at" => now, "announced" => true)
        save
        FileUtils.rm_f(ExportImport.cancel_file(@id))
        Reach::Debug.import("cancelled", self.class.debug_fields(@job))
        result
      end

      def truncate_to(path, expected, label)
        actual = File.exist?(path) ? File.size(path) : 0
        raise Reach::Error, "reach: #{label} is shorter than recorded" if actual < expected

        File.truncate(path, expected) if actual > expected
      end

      def prepare_outputs
        ExportImport.ensure_dir!(ExportImport.job_dir(@id))
        catalog = ExportImport.catalog_file(@id)
        truncate_to(catalog, @job["catalog_bytes"].to_i, "the catalog")
        @catalog = File.open(catalog, "ab", 0o600)
        return unless copy?

        folder = Reach::Paths.import_spool_dir
        ExportImport.ensure_dir!(folder)
        path = File.join(folder, @job["spool_file"])
        if @job["spool_bytes"].nil?
          @job["spool_bytes"] = File.exist?(path) ? File.size(path) : 0
        else
          truncate_to(path, @job["spool_bytes"].to_i, "the verbatim copy")
        end
        @spool = File.open(path, "ab", 0o600)
      end

      def close_outputs
        [@catalog, @spool].compact.each do |handle|
          handle.close unless handle.closed?
        end
        @catalog = nil
        @spool = nil
      end

      def guard
        @guard ||= Reach::Brain.secret_matcher
      end

      def cancelled?
        File.exist?(ExportImport.cancel_file(@id))
      end

      def stream_files
        files = @job["files"]
        every = ExportImport.config["progress_every"]
        index = @job["file_index"].to_i
        while index < files.length
          file = files[index]
          skip = index == @job["file_index"].to_i ? @job["file_elements"].to_i : 0
          base = files[0...index].inject(0) { |sum, item| sum + item["size"].to_i }
          parser = Reach::JsonStream::Parser.new(skip: skip)
          catch(:stop) do
            @source.each_chunk(file["name"]) do |chunk|
              parser.feed(chunk) do |text, offset|
                raise Sources::TimeLimit if Time.now > @deadline

                handle(file, text, offset, base)
                progress!(every)
                if cancelled?
                  @cancelled = true
                  throw :stop
                end
              end
              throw :stop if parser.finished?
            end
          end
          return if @cancelled

          index += 1
          @job["file_index"] = index
          @job["file_elements"] = 0
          @job["bytes"] = base + file["size"].to_i
          save
        end
      end

      def progress!(every)
        done = @job["done"].to_i
        return unless done.positive? && (done % every).zero? && @progress_at != done

        @progress_at = done
        Reach::Debug.import("progress", self.class.debug_fields(@job))
      end

      def handle(file, text, offset, base)
        @job["resumes"] = 0
        @job["seen"] = @job["seen"].to_i + 1
        @job["file_elements"] = @job["file_elements"].to_i + 1
        length = text.bytesize
        @job["bytes"] = base + offset + length
        conversation = begin
          Vendors.normalize(file["kind"], @job["vendor"], JSON.parse(text), @job["seen"])
        rescue JSON::ParserError, EncodingError
          nil
        end
        if conversation
          emit(file, conversation, offset, length)
        else
          @job["skipped"] = @job["skipped"].to_i + 1
        end
        save
      end

      def top_tokens(conversation)
        counts = Hash.new(0)
        conversation["turns"].each do |item|
          Reach::BrainIndex.tokens(item["text"]).each { |token| counts[token] += 1 }
        end
        ranked = counts.sort_by { |token, count| [-count, token] }.first(TOKEN_CANDIDATES)
        ranked.map(&:first).reject { |token| token.length > TOKEN_MAX_CHARS || guard.call(token) }.first(TOKEN_COUNT)
      end

      def excerpt_for(conversation)
        first = conversation["turns"].find { |item| item["role"] == "user" } || conversation["turns"].first
        flat = first["text"].gsub(/\s+/, " ").strip
        return flat if flat.bytesize <= EXCERPT_BYTES

        cut = EXCERPT_BYTES
        cut -= 1 while cut.positive? && (flat.getbyte(cut) & 0xC0) == 0x80
        flat.byteslice(0, cut)
      end

      def spool_lines(conversation)
        markdown = Render.markdown(conversation)
        parts = Render.split(markdown, PART_BYTES)
        stamp = Time.now.utc.iso8601(3)
        parts.each_with_index.map do |part, index|
          path = Render.part_path(conversation["vendor"], conversation["conversation_id"], index, parts.length)
          digest = Digest::SHA256.hexdigest(part)
          record = { "text" => part, "path" => path, "source_digest" => digest, "title" => conversation["title"].to_s, "category" => "import" }
          record["at"] = conversation["created_at"] if conversation["created_at"]
          JSON.generate(
            "spool" => SPOOL_SCHEMA, "operation_id" => Reach::BrainSpool.derived_uuid("import:#{@id}:#{path}"), "corpus" => Reach::BrainSpool::CORPUS_ID,
            "op" => "source", "kind" => "source", "id" => Reach::Brain.source_id(path, digest), "tier" => "private", "record" => record,
            "written_at" => stamp, "writer" => Reach::BrainSpool.writer
          ) + "\n"
        end
      end

      def emit(file, conversation, offset, length)
        title = conversation["title"].to_s
        title = "" if guard.call(title)
        excerpt = excerpt_for(conversation)
        excerpt = "" if guard.call(excerpt)
        line = {
          "conversation_id" => conversation["conversation_id"], "title" => title, "created_at" => conversation["created_at"],
          "updated_at" => conversation["updated_at"], "turns" => conversation["turns"].length,
          "bytes" => conversation["turns"].inject(0) { |sum, item| sum + item["text"].bytesize },
          "tokens" => top_tokens(conversation), "excerpt" => excerpt, "src" => file["name"], "off" => offset, "len" => length
        }
        if copy?
          lines = spool_lines(conversation)
          written = lines.inject(0) { |sum, text| sum + text.bytesize }
          lines.each { |text| @spool.write(text) }
          @spool.flush
          line["sp"] = [@job["spool_file"], @job["spool_bytes"].to_i, written]
          line["parts"] = lines.length
          @job["spool_bytes"] = @job["spool_bytes"].to_i + written
        end
        encoded = "#{JSON.generate(line)}\n"
        @catalog.write(encoded)
        @catalog.flush
        @job["catalog_bytes"] = @job["catalog_bytes"].to_i + encoded.bytesize
        @job["done"] = @job["done"].to_i + 1
      end

      def course_tokens
        set = {}
        Reach::Reference.documents.each do |document|
          Reach::BrainIndex.tokens(document["course"]).each { |token| set[token] = true }
          Array(document["files"]).each do |file|
            Reach::BrainIndex.tokens(file["title"]).each { |token| set[token] = true }
          end
        end
        set
      rescue StandardError
        {}
      end

      def stamp_value(entry)
        Time.iso8601((entry["updated_at"] || entry["created_at"]).to_s).to_f
      rescue ArgumentError
        0.0
      end

      def rank
        catalog = ExportImport.catalog_file(@id)
        vocabulary = course_tokens
        rows = []
        if File.file?(catalog)
          File.foreach(catalog) do |raw|
            entry = JSON.parse(raw)
            overlap = Array(entry["tokens"]).count { |token| vocabulary.key?(token) }
            keep = entry.reject { |key, _| %w[tokens excerpt].include?(key) }
            rows << { "entry" => keep, "at" => stamp_value(entry), "bytes" => entry["bytes"].to_i, "overlap" => overlap }
          rescue JSON::ParserError
            next
          end
        end
        newest = rows.map { |row| row["at"] }.max.to_f
        oldest = rows.map { |row| row["at"] }.min.to_f
        longest = rows.map { |row| row["bytes"] }.max.to_i
        span = newest - oldest
        scored = rows.map do |row|
          recency = span.positive? ? (row["at"] - oldest) / span : 1.0
          length = longest.positive? ? Math.log(1 + row["bytes"]) / Math.log(1 + longest) : 0.0
          overlap = row["overlap"].to_f / TOKEN_COUNT
          score = RANK_WEIGHTS[:recency] * recency + RANK_WEIGHTS[:length] * length + RANK_WEIGHTS[:overlap] * overlap
          [score, row["entry"]]
        end
        ordered = scored.each_with_index.sort_by { |(score, entry), index| [-score, entry["conversation_id"].to_s, index] }.map(&:first)
        target = ExportImport.queue_file(@id)
        tmp = "#{target}.tmp.#{Process.pid}"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          ordered.each_with_index do |(score, entry), index|
            file.write("#{JSON.generate({ 'rank' => index + 1, 'score' => score.round(4) }.merge(entry))}\n")
          end
        end
        File.rename(tmp, target)
        ordered.length
      end

      def admit
        corpus = Reach::Storage.open_corpus
        return unless corpus && defined?(Rcorpus::Spool)

        report = Rcorpus::Spool.new(corpus, Reach::Paths.import_spool_dir).admit
        @job["admitted"] = report["admitted"].to_i
        unless report["refused"].to_a.empty?
          @job["admit_refused"] = report["refused"].length
          Reach::BrainSpool.log("import.admit_refused", "refused" => report["refused"].length)
        end
      rescue StandardError => e
        @job["admit_error"] = e.class.name
        Reach::BrainSpool.log("import.admit_failed", "error" => e.class.name)
      end

      def finish
        @job["phase"] = "ranking"
        save
        queued = rank
        @job["queued"] = queued
        if copy?
          @job["phase"] = "admitting"
          save
          admit
        end
        begin
          Reach::Storage.measure!
        rescue StandardError
          nil
        end
        @job = @job.merge("state" => "finished", "phase" => "done", "finished_at" => now, "bytes" => @job["total_bytes"].to_i, "announced" => false)
        save
        Reach::Debug.import("finished", self.class.debug_fields(@job).merge("findings_queued" => queued))
      end
    end
  end
end
