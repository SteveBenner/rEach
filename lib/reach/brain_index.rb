require "json"
require "time"
require "fileutils"

module Reach
  class BrainIndex
    CACHE_VERSION = 4
    K1 = 1.2
    B = 0.75
    FLOOR = 0.05
    HALF_LIFE_DAYS = 30.0
    REINFORCE_STEP = 0.1
    STOPWORDS = %w[the and for are was were with that this from into onto its it's not but you your our their them they then than
                   have has had been being will would can could should may might must shall of to in on at by as an be or is if
                   so no do does did per via].each_with_object({}) { |word, memo| memo[word] = true }.freeze
    SOURCE_ID = /"id":"(source-[0-9a-f]+)"/.freeze
    SOURCE_PATH = /"path":"([^"\\]*)"/.freeze
    PASSAGE_BYTES = 600
    COURSE_PREFIX = "course/".freeze
    WRITTEN_AT = /"written_at":"([^"]+)","writer"/.freeze

    class << self
      def tokens(text)
        text.to_s.downcase.scan(/[a-z0-9]+/).reject { |token| token.size < 2 || STOPWORDS.key?(token) }
      end

      def term_counts(tokens)
        counts = Hash.new(0)
        tokens.each { |token| counts[token] += 1 }
        counts
      end

      def load(reinforcements: {}, now: Time.now)
        new(reinforcements: reinforcements, now: now).tap(&:build)
      end

      def passages(title, text)
        pieces = []
        current = nil
        text.to_s.split(/\n[ \t]*\n/).each do |block|
          block = block.strip
          next if block.empty?

          cut_passage(block).each do |piece|
            if current && current.bytesize + 2 + piece.bytesize <= PASSAGE_BYTES
              current = "#{current}\n\n#{piece}"
            else
              pieces << current if current
              current = piece
            end
          end
        end
        pieces << current if current
        pieces.map do |piece|
          counted = tokens("#{title} #{piece}")
          { "x" => piece, "tf" => term_counts(counted), "n" => counted.length }
        end
      end

      def cut_passage(block)
        return [block] if block.bytesize <= PASSAGE_BYTES

        pieces = []
        rest = block
        while rest.bytesize > PASSAGE_BYTES
          cut = PASSAGE_BYTES
          cut -= 1 while cut.positive? && (rest.getbyte(cut) & 0xC0) == 0x80
          head = rest.byteslice(0, cut)
          space = head.rindex(/\s/)
          if space && space > cut / 2
            head = head[0, space]
            cut = head.bytesize
          end
          pieces << head.strip
          rest = rest.byteslice(cut, rest.bytesize - cut).to_s.strip
        end
        pieces << rest unless rest.empty?
        pieces.reject(&:empty?)
      end

      def cache_path
        File.join(Reach::Paths.home, "brain", "index.json")
      end
    end

    attr_reader :findings, :sources, :course_sources

    def initialize(reinforcements: {}, now: Time.now)
      @reinforcements = reinforcements.is_a?(Hash) ? reinforcements : {}
      @now = now
      @findings = []
      @sources = []
      @course_sources = []
      @by_id = {}
      @history = {}
    end

    def build
      cache = read_cache
      files = cache["files"].is_a?(Hash) ? cache["files"] : {}
      fresh = {}
      dirty = false
      root = Reach::BrainSpool.dir
      Reach::BrainSpool.spool_files(include_admitted: true).each do |path|
        key = path.sub("#{root}#{File::SEPARATOR}", "")
        stat = File.stat(path)
        entry = files[key]
        if entry.is_a?(Hash) && entry["ino"] == stat.ino && entry["size"] == stat.size && entry["mtime"] == stat.mtime.to_i
          fresh[key] = entry
          next
        end

        dirty = true
        if entry.is_a?(Hash) && entry["ino"] == stat.ino && stat.size > entry["size"].to_i && entry["offset"].to_i <= stat.size
          rows, offset = parse_file(path, entry["offset"].to_i)
          fresh[key] = { "ino" => stat.ino, "size" => stat.size, "mtime" => stat.mtime.to_i, "offset" => offset, "rows" => entry["rows"] + rows }
        else
          rows, offset = parse_file(path, 0)
          fresh[key] = { "ino" => stat.ino, "size" => stat.size, "mtime" => stat.mtime.to_i, "offset" => offset, "rows" => rows }
        end
      end
      dirty = true if fresh.keys.sort != files.keys.sort
      write_cache("version" => CACHE_VERSION, "files" => fresh) if dirty
      assemble(fresh)
      self
    end

    def finding(id)
      row = @by_id[id.to_s]
      row && row["k"] == "finding" ? row : nil
    end

    def find_finding(prefix)
      exact = finding(prefix)
      return exact if exact

      matches = @findings.select { |row| row["id"].start_with?(prefix.to_s) }
      matches.length == 1 ? matches.first : nil
    end

    def lineage(row)
      found = []
      current = row
      while current && current["u"].to_s != "" && !found.include?(current["u"])
        found << current["u"]
        current = @history[current["u"]]
      end
      found
    end

    def history_row(id)
      @history[id.to_s]
    end

    def source_for(id)
      row = @by_id[id.to_s]
      row && row["k"] == "source" ? row : nil
    end

    def reinforcement(id)
      entry = @reinforcements[id.to_s]
      entry.is_a?(Hash) ? entry : { "count" => 0, "last" => nil }
    end

    def effective_salience(row)
      base = (row["sal"] || 0.5).to_f
      info = reinforcement(row["id"])
      anchor = [parse_time(row["a"] || row["w"]), parse_time(info["last"])].compact.max
      age_days = anchor ? [(@now - anchor) / 86_400.0, 0.0].max : 0.0
      decayed = [base * (0.5**(age_days / HALF_LIFE_DAYS)), FLOOR].max
      [decayed + (REINFORCE_STEP * info["count"].to_i), 1.0].min
    end

    def search(query, k:, categories: nil)
      terms = self.class.tokens(query).uniq
      return [] if terms.empty?

      pool = categories ? @findings.select { |row| categories.include?(row["c"]) } : @findings
      return [] if pool.empty?

      total = pool.length
      average = pool.inject(0) { |sum, row| sum + row["n"].to_i }.to_f / total
      average = 1.0 if average.zero?
      idf = {}
      terms.each do |term|
        df = pool.count { |row| row["tf"].key?(term) }
        idf[term] = df.zero? ? nil : Math.log(1.0 + ((total - df + 0.5) / (df + 0.5)))
      end
      scored = []
      pool.each do |row|
        score = 0.0
        length = row["n"].to_i
        terms.each do |term|
          weight = idf[term]
          next unless weight

          tf = row["tf"][term]
          next unless tf

          score += weight * (tf * (K1 + 1)) / (tf + (K1 * (1 - B + (B * length / average))))
        end
        scored << [score, row] if score.positive?
      end
      ideal = idf.values.compact.inject(0.0) { |sum, weight| sum + weight }
      scored.sort_by { |score, row| [-score, -effective_salience(row), row["id"]] }.first(k).map do |score, row|
        row.merge("score" => score, "share" => ideal.positive? ? score / ideal : 0.0)
      end
    end

    def search_course(query, k:)
      terms = self.class.tokens(query).uniq
      return [] if terms.empty?

      pool = []
      @course_sources.each do |row|
        row["ps"].each_with_index { |passage, index| pool << [row, index, passage] }
      end
      return [] if pool.empty?

      total = pool.length
      average = pool.inject(0) { |sum, entry| sum + entry[2]["n"].to_i }.to_f / total
      average = 1.0 if average.zero?
      idf = {}
      terms.each do |term|
        df = pool.count { |entry| entry[2]["tf"].key?(term) }
        idf[term] = df.zero? ? nil : Math.log(1.0 + ((total - df + 0.5) / (df + 0.5)))
      end
      scored = []
      pool.each do |row, index, passage|
        score = 0.0
        length = passage["n"].to_i
        terms.each do |term|
          weight = idf[term]
          next unless weight

          tf = passage["tf"][term]
          next unless tf

          score += weight * (tf * (K1 + 1)) / (tf + (K1 * (1 - B + (B * length / average))))
        end
        scored << [score, "#{row['id']}##{index}", row, passage] if score.positive?
      end
      ideal = idf.values.compact.inject(0.0) { |sum, weight| sum + weight }
      scored.sort_by { |score, id, _, _| [-score, id] }.first(k).map do |score, id, row, passage|
        {
          "id" => id, "source_id" => row["id"], "path" => row["p"], "title" => row["t"], "text" => passage["x"],
          "score" => score, "share" => ideal.positive? ? score / ideal : 0.0
        }
      end
    end

    def similar(text, category:, exclude: [])
      query = self.class.term_counts(self.class.tokens(text))
      return nil if query.empty?

      norm = Math.sqrt(query.values.inject(0) { |sum, value| sum + (value * value) })
      best = nil
      @findings.each do |row|
        next unless row["c"] == category
        next if exclude.include?(row["id"])

        counts = self.class.term_counts(self.class.tokens("#{row["m"]}\n#{row["e"]}"))
        next if counts.empty?

        dot = 0.0
        query.each { |term, value| dot += value * counts[term] if counts.key?(term) }
        next if dot.zero?

        other = Math.sqrt(counts.values.inject(0) { |sum, value| sum + (value * value) })
        similarity = dot / (norm * other)
        best = [similarity, row] if best.nil? || similarity > best[0]
      end
      best && { "similarity" => best[0], "finding" => best[1] }
    end

    private

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_file(path, offset)
      rows = []
      consumed = offset
      File.open(path, "rb") do |file|
        file.seek(offset)
        file.each_line do |raw|
          break unless raw.end_with?("\n")

          consumed += raw.bytesize
          row = parse_line(raw)
          rows << row if row
        end
      end
      [rows, consumed]
    end

    def parse_line(raw)
      if raw.include?('"kind":"source"')
        id = raw[SOURCE_ID, 1]
        return nil unless id

        path = raw[SOURCE_PATH, 1]
        written = raw[WRITTEN_AT, 1]
        return { "o" => "tombstone", "k" => "source", "id" => id, "w" => written.to_s } if raw.include?('"op":"tombstone"')
        return nil unless raw.include?('"op":"source"') || raw.include?('"op":"put"')
        return course_row(raw, id, written) if path.to_s.start_with?(COURSE_PREFIX)

        return { "o" => "put", "k" => "source", "id" => id, "w" => written.to_s, "p" => path.to_s, "b" => raw.bytesize }
      end
      return nil unless raw.include?('"kind":"finding"')

      parsed = JSON.parse(raw)
      return nil unless parsed.is_a?(Hash) && parsed["corpus"] == Reach::BrainSpool::CORPUS_ID && parsed["kind"] == "finding"

      id = parsed["id"].to_s
      return nil if id.empty?

      if parsed["op"] == "tombstone"
        return { "o" => "tombstone", "k" => "finding", "id" => id, "w" => parsed["written_at"].to_s }
      end
      return nil unless %w[finding put].include?(parsed["op"]) && parsed["record"].is_a?(Hash)

      record = parsed["record"]
      claim = record["claim"].to_s
      return nil if claim.empty?

      tokens = self.class.tokens("#{record['category']} #{claim} #{record['evidence']}")
      {
        "o" => "put", "k" => "finding", "id" => id, "w" => parsed["written_at"].to_s,
        "c" => record["category"].to_s, "m" => claim, "e" => record["evidence"].to_s,
        "s" => record["source_id"].to_s, "sal" => record["salience"], "a" => record["at"].to_s,
        "u" => record["supersedes"], "tf" => self.class.term_counts(tokens), "n" => tokens.length
      }
    rescue JSON::ParserError
      nil
    end

    def course_row(raw, id, written)
      parsed = JSON.parse(raw)
      record = parsed["record"]
      return nil unless record.is_a?(Hash)

      title = record["title"].to_s
      {
        "o" => "put", "k" => "source", "id" => id, "w" => written.to_s, "p" => record["path"].to_s, "b" => raw.bytesize,
        "t" => title, "ps" => self.class.passages(title, record["text"])
      }
    rescue JSON::ParserError
      nil
    end

    def assemble(files)
      ordered = []
      files.keys.sort.each_with_index do |key, file_index|
        files[key]["rows"].each_with_index { |row, line_index| ordered << [row["w"].to_s, file_index, line_index, row] }
      end
      ordered.sort_by! { |written, file_index, line_index, _| [written, file_index, line_index] }
      latest = {}
      ordered.each do |_, _, _, row|
        latest[row["id"]] = row
        @history[row["id"]] = row if row["o"] == "put" && row["k"] == "finding"
      end
      latest.each_value do |row|
        next unless row["o"] == "put"

        @by_id[row["id"]] = row
        if row["k"] == "finding"
          @findings << row
        else
          @sources << row
          @course_sources << row if row["ps"]
        end
      end
    end

    def read_cache
      path = self.class.cache_path
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) && data["version"] == CACHE_VERSION ? data : {}
    rescue StandardError
      {}
    end

    def write_cache(data)
      path = self.class.cache_path
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      tmp = "#{path}.tmp-#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      File.rename(tmp, path)
    rescue StandardError
      nil
    end
  end
end
