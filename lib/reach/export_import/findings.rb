require "json"
require "zlib"

module Reach
  module ExportImport
    module Findings
      SNIPPET_BYTES = 300
      MAX_HITS = 10
      VERBATIM_KEEP = 40
      K1 = 1.2
      B = 0.75
      SKIP_CHUNK = 1_048_576

      module_function

      def clip(text, limit)
        flat = text.to_s.gsub(/\s+/, " ").strip
        return flat if flat.bytesize <= limit

        cut = limit
        cut -= 1 while cut.positive? && (flat.getbyte(cut) & 0xC0) == 0x80
        flat.byteslice(0, cut).to_s.scrub("")
      end

      def state_for(id)
        data = ExportImport.read_json(ExportImport.findings_file(id)) || {}
        { "done" => data["done"].is_a?(Hash) ? data["done"] : {}, "parts" => data["parts"].is_a?(Hash) ? data["parts"] : {}, "totals" => data["totals"].is_a?(Hash) ? data["totals"] : {} }
      end

      def save_state(id, state)
        ExportImport.write_json(ExportImport.findings_file(id), state)
      end

      def done_count(id)
        state_for(id)["done"].length
      end

      def target_job(job_id)
        if job_id.to_s.empty?
          job = ExportImport.jobs.reverse.find { |item| item["state"] == "finished" && item["queued"] }
          raise Reach::Refused, "reach: no import has finished reading yet" unless job

          return job
        end
        job = ExportImport.find_job(job_id)
        raise Reach::Refused, "reach: import #{job['id']} has not finished reading yet (#{job['state']})" unless job["state"] == "finished"

        job
      end

      def open_entry(job, id)
        File.foreach(ExportImport.queue_file(job["id"])) do |raw|
          next unless raw.include?(JSON.generate("conversation_id" => id)[1..-2])

          entry = JSON.parse(raw)
          return entry if entry["conversation_id"] == id
        end
        nil
      rescue Errno::ENOENT
        nil
      end

      def first_open(job, state)
        File.foreach(ExportImport.queue_file(job["id"])) do |raw|
          entry = JSON.parse(raw)
          return entry unless state["done"][entry["conversation_id"]]
        end
        nil
      rescue Errno::ENOENT
        nil
      end

      def spool_candidates(name)
        base = Reach::Paths.import_spool_dir
        list = [File.join(base, name), File.join(base, "#{name}.gz")]
        admitted = File.join(base, "admitted")
        if File.directory?(admitted)
          Dir.children(admitted).sort.each do |child|
            list << File.join(admitted, child) if child == name || child.start_with?("#{name}.")
          end
        end
        list.select { |path| File.file?(path) }
      end

      def read_range(path, offset, length)
        if path.end_with?(".gz")
          Zlib::GzipReader.open(path) do |reader|
            remaining = offset
            while remaining.positive?
              piece = reader.read([remaining, SKIP_CHUNK].min)
              return nil unless piece

              remaining -= piece.bytesize
            end
            reader.read(length)
          end
        else
          File.open(path, "rb") do |file|
            file.seek(offset)
            file.read(length)
          end
        end
      rescue Zlib::Error, SystemCallError
        nil
      end

      def copy_text(entry, vendor)
        name, offset, length = entry["sp"]
        exact = %r{\A#{Regexp.escape("import/#{vendor}/#{entry['conversation_id']}")}(\.part\d+)?\.md\z}
        spool_candidates(name).each do |path|
          raw = read_range(path, offset.to_i, length.to_i)
          next if raw.nil? || raw.empty?

          parts = []
          raw.force_encoding(Encoding::UTF_8).each_line do |line|
            record = JSON.parse(line)["record"]
            parts << record["text"] if record.is_a?(Hash) && record["path"].to_s.match?(exact)
          rescue JSON::ParserError
            next
          end
          return parts.join unless parts.empty?
        end
        raise Reach::Refused, "reach: the saved copy of this conversation could not be found"
      end

      def export_text(job, entry)
        unless File.exist?(job["source"])
          raise Reach::Refused, "reach: the export is no longer where it was and this import kept no full copy, so the full text of this conversation is gone"
        end

        source = Sources.open(job["source"])
        Sources.verify_original!(source, job, entry["src"])
        stamp = source.stamp(entry["src"])
        raw = source.read_range(entry["src"], entry["off"].to_i, entry["len"].to_i)
        Sources.unchanged_since!(source, entry["src"], stamp)
        file = job["files"].find { |item| item["name"] == entry["src"] } || {}
        conversation = Vendors.normalize(file["kind"], job["vendor"], JSON.parse(raw.force_encoding(Encoding::UTF_8)), 0)
        raise Reach::Refused, "reach: this conversation could not be read from the export again" unless conversation

        Render.markdown(conversation)
      rescue JSON::ParserError
        raise Reach::Refused, "reach: this conversation could not be read from the export again"
      end

      def conversation_text(job, entry)
        entry["sp"] ? copy_text(entry, job["vendor"]) : export_text(job, entry)
      end

      def origin_for(job, entry)
        "import:#{job['id']}/#{entry['conversation_id']}"
      end

      def next_item(job_id)
        job = target_job(job_id)
        state = state_for(job["id"])
        entry = first_open(job, state)
        return { "state" => "empty", "job" => job["id"], "text" => "nothing is left in the queue of import #{job['id']}" } unless entry

        parts = Render.split(conversation_text(job, entry), ExportImport.config["next_max_bytes"])
        parts = [""] if parts.empty?
        id = entry["conversation_id"]
        part = [state["parts"][id].to_i + 1, parts.length].min
        state["totals"][id] = parts.length
        save_state(job["id"], state)
        remaining = job["queued"].to_i - state["done"].length - 1
        origin = origin_for(job, entry)
        done_hint = parts.length > 1 ? "reach import done #{id} --part #{part}" : "reach import done #{id}"
        lines = [
          "import: #{job['id']}", "conversation: #{id}", "title: #{entry['title']}",
          "dates: #{entry['created_at']} to #{entry['updated_at']}", "origin: #{origin}"
        ]
        lines << "part: #{part} of #{parts.length}" if parts.length > 1
        lines << "after this one: #{[remaining, 0].max} more conversations queued"
        lines << "---"
        lines << parts[part - 1].to_s.rstrip
        lines << "---"
        lines << "Record each durable thing with reach remember --origin #{origin}; when you have read this #{parts.length > 1 ? 'part' : 'conversation'}, run #{done_hint}"
        {
          "state" => "item", "job" => job["id"], "conversation_id" => id, "title" => entry["title"], "created_at" => entry["created_at"],
          "updated_at" => entry["updated_at"], "origin" => origin, "part" => part, "parts" => parts.length, "remaining" => [remaining, 0].max,
          "body" => parts[part - 1].to_s, "text" => lines.join("\n")
        }
      end

      def done(conversation_id, part: nil, job: nil)
        id = conversation_id.to_s
        raise Reach::Refused, "reach: give the conversation id to mark done" if id.empty?

        target = target_job(job)
        entry = open_entry(target, id)
        raise Reach::Refused, "reach: #{id} is not in the queue of import #{target['id']}" unless entry

        state = state_for(target["id"])
        finished = true
        unless part.to_s.empty?
          number = Integer(part.to_s, 10)
          raise Reach::Refused, "reach: --part must be 1 or more" if number < 1

          total = state["totals"][id]
          unless total
            total = [Render.split(conversation_text(target, entry), ExportImport.config["next_max_bytes"]).length, 1].max
            state["totals"][id] = total
          end
          if number < total
            state["parts"][id] = number
            finished = false
          end
        end
        if finished
          state["done"][id] = true
          state["parts"].delete(id)
        end
        save_state(target["id"], state)
        remaining = [target["queued"].to_i - state["done"].length, 0].max
        text = finished ? "done: #{id}; #{remaining} conversations left in the queue" : "part #{state['parts'][id]} of #{id} recorded; run reach import next for the following part"
        { "state" => finished ? "done" : "partial", "job" => target["id"], "conversation_id" => id, "remaining" => remaining, "text" => text }
      rescue ArgumentError
        raise Reach::Refused, "reach: --part must be a number"
      end

      def catalog_scan(jobs)
        jobs.each do |job|
          path = ExportImport.catalog_file(job["id"])
          next unless File.file?(path)

          File.foreach(path) do |raw|
            entry = JSON.parse(raw)
            yield job, entry
          rescue JSON::ParserError
            next
          end
        end
      end

      def bm25_hits(jobs, terms)
        documents = 0
        total_length = 0
        frequency = Hash.new(0)
        matches = []
        catalog_scan(jobs) do |job, entry|
          tokens = Reach::BrainIndex.tokens("#{entry['title']} #{Array(entry['tokens']).join(' ')} #{entry['excerpt']}")
          documents += 1
          total_length += tokens.length
          counts = Hash.new(0)
          tokens.each { |token| counts[token] += 1 if terms.include?(token) }
          next if counts.empty?

          counts.each_key { |token| frequency[token] += 1 }
          matches << [job, entry, counts, tokens.length]
        end
        return [] if matches.empty?

        average = [total_length.to_f / documents, 1.0].max
        scored = matches.map do |job, entry, counts, length|
          score = counts.inject(0.0) do |sum, (token, count)|
            idf = Math.log(1 + (documents - frequency[token] + 0.5) / (frequency[token] + 0.5))
            sum + idf * (count * (K1 + 1)) / (count + K1 * (1 - B + B * length / average))
          end
          { "job" => job["id"], "entry" => entry, "score" => score }
        end
        scored.sort_by { |hit| [-hit["score"], hit["entry"]["conversation_id"].to_s] }.first(MAX_HITS * 2)
      end

      def spool_files
        base = Reach::Paths.import_spool_dir
        return [] unless File.directory?(base)

        list = Dir.children(base).select { |name| name.match?(/\A\d{4}-\d{2}-\d{2}\.jsonl(\..+)?\z/) }.sort.map { |name| File.join(base, name) }
        admitted = File.join(base, "admitted")
        list += Dir.children(admitted).select { |name| name.match?(/\A\d{4}-\d{2}-\d{2}\.jsonl/) }.sort.map { |name| File.join(admitted, name) } if File.directory?(admitted)
        list.select { |path| File.file?(path) }
      end

      def each_line_of(path, &block)
        if path.end_with?(".gz")
          Zlib::GzipReader.open(path) { |reader| reader.each_line(&block) }
        else
          File.foreach(path, &block)
        end
      rescue Zlib::Error, SystemCallError
        nil
      end

      def conversation_key(path)
        match = path.to_s.match(%r{\Aimport/[^/]+/(.+?)(?:\.part\d+)?\.md\z})
        match ? match[1] : nil
      end

      def snippet_around(text, term)
        index = text.downcase.index(term)
        return clip(text, SNIPPET_BYTES) unless index

        from = [index - 100, 0].max
        if from.positive?
          boundary = text.index(/\s/, from)
          from = boundary + 1 if boundary && boundary < index
        end
        clip(text[from, SNIPPET_BYTES], SNIPPET_BYTES)
      end

      def excerpt_snippet(excerpt, terms)
        lowered = excerpt.downcase
        term = terms.find { |item| lowered.include?(item) }
        term ? snippet_around(excerpt, term) : clip(excerpt, SNIPPET_BYTES)
      end

      def verbatim_hits(terms)
        kept = []
        spool_files.each do |path|
          each_line_of(path) do |raw|
            lowered = raw.downcase
            next unless terms.any? { |term| lowered.include?(term) }

            record = begin
              JSON.parse(raw)["record"]
            rescue JSON::ParserError
              nil
            end
            next unless record.is_a?(Hash) && record["path"].to_s.start_with?("import/")

            text = record["text"].to_s
            body = text.downcase
            score = 0.0
            first = nil
            terms.each do |term|
              count = body.scan(term).length
              next if count.zero?

              score += Math.log(1 + count)
              first ||= term
            end
            next if first.nil?

            kept << { "key" => conversation_key(record["path"]), "title" => record["title"], "score" => score, "snippet" => snippet_around(text, first) }
            kept = kept.sort_by { |hit| -hit["score"] }.first(VERBATIM_KEEP) if kept.length > VERBATIM_KEEP * 2
          end
        end
        kept.sort_by { |hit| -hit["score"] }.first(VERBATIM_KEEP)
      end

      def search(query, job: nil)
        terms = Reach::BrainIndex.tokens(query).uniq
        raise Reach::Refused, "reach: give something to search for" if terms.empty?

        selected = job.to_s.empty? ? ExportImport.jobs : [ExportImport.find_job(job)]
        raise Reach::Refused, "reach: no import has been started" if selected.empty?

        combined = {}
        catalog = bm25_hits(selected, terms)
        top = catalog.map { |hit| hit["score"] }.max.to_f
        catalog.each do |hit|
          key = hit["entry"]["conversation_id"]
          combined[key] = {
            "conversation_id" => key, "job" => hit["job"], "title" => hit["entry"]["title"], "created_at" => hit["entry"]["created_at"],
            "score" => top.positive? ? hit["score"] / top : 0.0, "snippet" => excerpt_snippet(hit["entry"]["excerpt"].to_s, terms), "where" => ["catalog"]
          }
        end
        if selected.any? { |item| item["mode"] == "copy" }
          verbatim = verbatim_hits(terms)
          best = verbatim.map { |hit| hit["score"] }.max.to_f
          verbatim.each do |hit|
            next unless hit["key"]

            share = best.positive? ? hit["score"] / best : 0.0
            existing = combined[hit["key"]]
            if existing
              next if existing["where"].include?("copy")

              existing["score"] += share
              existing["snippet"] = hit["snippet"]
              existing["where"] << "copy"
            else
              combined[hit["key"]] = {
                "conversation_id" => hit["key"], "job" => nil, "title" => hit["title"], "created_at" => nil,
                "score" => share, "snippet" => hit["snippet"], "where" => ["copy"]
              }
            end
          end
        end
        hits = combined.values.sort_by { |hit| [-hit["score"], hit["conversation_id"].to_s] }.first(MAX_HITS)
        hits.each { |hit| hit["score"] = hit["score"].round(3) }
        text = if hits.empty?
                 "no match for #{query.to_s.inspect} in the imported conversations"
               else
                 hits.each_with_index.map do |hit, index|
                   "#{index + 1}. #{hit['conversation_id']}  #{hit['title']}#{hit['created_at'] ? "  (#{hit['created_at']})" : ''}  [#{hit['where'].join('+')}]\n   #{hit['snippet']}"
                 end.join("\n")
               end
        { "hits" => hits, "text" => text }
      end

      def find_entry(id, job)
        selected = job.to_s.empty? ? ExportImport.jobs.reverse : [ExportImport.find_job(job)]
        needle = JSON.generate("conversation_id" => id)[1..-2]
        selected.each do |item|
          path = ExportImport.catalog_file(item["id"])
          next unless File.file?(path)

          File.foreach(path) do |raw|
            next unless raw.include?(needle)

            entry = JSON.parse(raw)
            return [item, entry] if entry["conversation_id"] == id
          end
        end
        nil
      end

      def show(conversation_id, part: nil, job: nil)
        id = conversation_id.to_s
        raise Reach::Refused, "reach: give the conversation id to show" if id.empty?

        found = find_entry(id, job)
        raise Reach::Refused, "reach: no conversation #{id} in the imports" unless found

        item, entry = found
        raise Reach::Refused, Reach::Messages.text("M-IMPORT-NO-COPY") unless item["mode"] == "copy" && entry["sp"]

        parts = Render.split(copy_text(entry, item["vendor"]), ExportImport.config["next_max_bytes"])
        parts = [""] if parts.empty?
        number = part.to_s.empty? ? 1 : Integer(part.to_s, 10)
        raise Reach::Refused, "reach: this conversation has #{parts.length} parts; --part must be between 1 and #{parts.length}" if number < 1 || number > parts.length

        head = ["import: #{item['id']}", "conversation: #{id}", "title: #{entry['title']}"]
        head << "part: #{number} of #{parts.length}" if parts.length > 1
        {
          "job" => item["id"], "conversation_id" => id, "part" => number, "parts" => parts.length, "body" => parts[number - 1].to_s,
          "text" => "#{head.join("\n")}\n---\n#{parts[number - 1].to_s.rstrip}"
        }
      rescue ArgumentError
        raise Reach::Refused, "reach: --part must be a number"
      end
    end
  end
end
