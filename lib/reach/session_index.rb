# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"

module Reach
  module SessionIndex
    PASSAGE_BYTES = 360
    EPISODE_PASSAGES = 60
    EPISODE_HEAD = 10
    SAME_SLICE_BOOST = 1.5
    K1 = 1.2
    B = 0.75
    ELLIPSIS = "…"
    CODE_REF = /\[code[^\]\n]*(?:\]|\z)/.freeze

    module_function

    def fault(error, where)
      Reach::Debug.fault(error, "session_index:#{where}")
      nil
    end

    def path
      File.join(Reach::SessionRecall.dir, "episodes.json")
    end

    def lock_path
      File.join(Reach::SessionRecall.dir, "index.lock")
    end

    def clip_bytes(text, limit)
      return text if text.bytesize <= limit

      keep = limit - ELLIPSIS.bytesize
      "#{text.byteslice(0, keep).scrub('')}#{ELLIPSIS}"
    end

    def clean(text)
      return "" unless text.is_a?(String)

      flat = text.scrub("").gsub(CODE_REF, " ").gsub(/\s+/, " ").strip
      clip_bytes(flat, PASSAGE_BYTES)
    end

    def empty(student)
      { "version" => 1, "student_id" => student, "files" => {}, "episodes" => [] }
    end

    def validated?(data, student)
      data.is_a?(Hash) && data["version"] == 1 && !student.empty? && data["student_id"] == student &&
        data["files"].is_a?(Hash) && data["episodes"].is_a?(Array)
    end

    def load
      student = Reach::SessionRecall.student_id
      data = Reach::SessionRecall.read_json(path)
      validated?(data, student) ? data : empty(student)
    rescue StandardError => e
      fault(e, "load")
      empty(nil)
    end

    def keep_entry(entry, student, matcher)
      return nil unless %w[prompt reply].include?(entry["kind"].to_s)
      return nil unless entry["student_id"].to_s == student

      space = entry["space"].to_s
      return nil unless %w[slice root].include?(space)
      return nil if entry["note"].to_s.include?("subagent")

      text = clean(entry["text"])
      return nil if text.empty? || matcher.call(text)

      at = Reach::SessionRecall.parse_time(entry["at"])
      return nil unless at

      cutout = entry["cutout_id"].to_s
      slice = entry["slice"].to_s
      if space == "slice"
        return nil if cutout.empty? || slice.empty?

        key = "#{cutout}.#{slice}"
      else
        cutout = nil
        slice = nil
        key = "root"
      end
      { kind: entry["kind"].to_s, text: text, at: at, session: entry["session_id"].to_s, key: key, cutout: cutout, slice: slice, seq: entry["seq"].to_i }
    end

    def open_episode(src, kept)
      {
        "id" => "ep-#{Digest::SHA256.hexdigest("#{src}\n#{kept[:session]}\n#{kept[:seq]}")[0, 16]}",
        "src" => src, "session" => kept[:session], "slice_key" => kept[:key], "cutout_id" => kept[:cutout], "slice" => kept[:slice],
        "started_at" => Reach::SessionRecall.iso(kept[:at]), "ended_at" => Reach::SessionRecall.iso(kept[:at]), "turns" => 0, "passages" => []
      }
    end

    def add_passage(episode, kept)
      stamp = Reach::SessionRecall.iso(kept[:at])
      episode["ended_at"] = stamp
      episode["turns"] += 1 if kept[:kind] == "prompt"
      episode["passages"] << { "at" => stamp, "k" => kept[:kind] == "prompt" ? "p" : "r", "x" => kept[:text] }
      episode["passages"].delete_at(EPISODE_HEAD) if episode["passages"].length > EPISODE_PASSAGES
    end

    def each_from(file_path, offset, gz, &block)
      if gz
        Reach::TranscriptExport.each_line(file_path, &block)
      else
        File.open(file_path, "r:UTF-8") do |file|
          file.seek(offset)
          file.each_line(&block)
        end
      end
    end

    def scan(file_path, offset, tail, gz, deadline, student, matcher, config)
      gap = config["episode_gap_minutes"] * 60
      src = File.basename(file_path)
      current = tail
      last_at = tail ? Reach::SessionRecall.parse_time(tail["ended_at"]) : nil
      fresh = []
      consumed = gz ? 0 : offset
      done = true
      each_from(file_path, gz ? 0 : offset, gz) do |line|
        if Reach::SessionRecall.clock >= deadline
          done = false
          break
        end
        break unless gz || line.end_with?("\n")

        consumed += line.bytesize
        entry = Reach::TranscriptExport.parse_line(line)
        kept = entry && keep_entry(entry, student, matcher)
        next unless kept

        continues = current && last_at && current["session"] == kept[:session] && current["slice_key"] == kept[:key] && (kept[:at] - last_at) <= gap
        unless continues
          current = open_episode(src, kept)
          fresh << current
        end
        add_passage(current, kept)
        last_at = kept[:at]
      end
      { fresh: fresh, offset: consumed, done: done }
    end

    def drop_source(index, name)
      index["episodes"].reject! { |episode| episode["src"] == name }
      index["files"].delete(name)
    end

    def ascending(episodes)
      episodes.each_index.sort_by { |position| [episodes[position]["ended_at"].to_s, position] }
    end

    def without(episodes, doomed)
      episodes.each_index.reject { |position| doomed.include?(position) }.map { |position| episodes[position] }
    end

    def trim(index, config)
      extra = index["episodes"].length - config["max_episodes"]
      index["episodes"] = without(index["episodes"], ascending(index["episodes"]).first(extra)) if extra.positive?
      bytes = JSON.generate(index).bytesize
      return index if bytes <= config["max_index_bytes"]

      episodes = index["episodes"]
      excess = bytes - config["max_index_bytes"]
      doomed = []
      freed = 0
      ascending(episodes).each do |position|
        break if freed >= excess

        doomed << position
        freed += JSON.generate(episodes[position]).bytesize + 1
      end
      index["episodes"] = without(episodes, doomed)
      index
    end

    def scan_source(index, name, file_path, deadline, student, matcher, config)
      files = index["files"]
      stat = File.stat(file_path)
      recorded = files[name].is_a?(Hash) ? files[name] : nil
      if name.end_with?(".gz")
        return true if recorded && recorded["gz"] == true && recorded["size"] == stat.size && recorded["mtime"] == stat.mtime.to_i

        result = scan(file_path, 0, nil, true, deadline, student, matcher, config)
        return false unless result[:done]

        drop_source(index, name)
        index["episodes"].concat(result[:fresh])
        files[name] = { "ino" => stat.ino, "size" => stat.size, "mtime" => stat.mtime.to_i, "offset" => stat.size, "gz" => true }
        return true
      end

      continuing = recorded && recorded["gz"] != true && recorded["ino"] == stat.ino && stat.size >= recorded["offset"].to_i
      if continuing
        return true if recorded["size"] == stat.size && recorded["mtime"] == stat.mtime.to_i && recorded["offset"].to_i == stat.size

        tail = index["episodes"].select { |episode| episode["src"] == name }.last
        result = scan(file_path, recorded["offset"].to_i, tail, false, deadline, student, matcher, config)
      else
        drop_source(index, name)
        result = scan(file_path, 0, nil, false, deadline, student, matcher, config)
      end
      index["episodes"].concat(result[:fresh])
      files[name] = { "ino" => stat.ino, "size" => stat.size, "mtime" => stat.mtime.to_i, "offset" => result[:offset], "gz" => false }
      result[:done]
    end

    def build(budget_s)
      deadline = Reach::SessionRecall.clock + budget_s
      config = Reach::SessionRecall.settings
      student = Reach::SessionRecall.student_id
      data = Reach::SessionRecall.read_json(path)
      reused = validated?(data, student)
      index = reused ? data : empty(student)
      before = reused ? JSON.generate(index["files"]) : nil
      present = Reach::TranscriptExport.source_files.each_with_object({}) { |file_path, memo| memo[File.basename(file_path)] = file_path }
      (index["files"].keys - present.keys).each { |name| drop_source(index, name) }
      matcher = Reach::Brain.secret_matcher
      stopped = false
      present.each do |name, file_path|
        if Reach::SessionRecall.clock >= deadline
          stopped = true
          break
        end
        stopped = true unless scan_source(index, name, file_path, deadline, student, matcher, config)
      end
      index["files"].keys.each { |name| drop_source(index, name) unless present[name] && File.exist?(present[name]) }
      written = before.nil? || JSON.generate(index["files"]) != before
      if written
        index = trim(index, config)
        Reach::Brain.write_json(path, index)
      end
      Reach::SessionRecall.log("recall.refreshed", "episodes" => index["episodes"].length, "files" => index["files"].length, "written" => written, "stopped" => stopped)
      { "episodes" => index["episodes"].length, "files" => index["files"].length }
    end

    def refresh!(budget_s)
      Reach::SessionRecall.ensure_dir!
      outcome = Reach::Locks.exclusive(lock_path, wait_s: 0) { build(budget_s.to_f) }
      outcome == :busy ? nil : outcome
    rescue StandardError => e
      fault(e, "refresh")
    end

    def prune_missing!
      return nil unless File.file?(path)

      outcome = Reach::Locks.exclusive(lock_path, wait_s: nil) do
        data = Reach::SessionRecall.read_json(path)
        next nil unless data.is_a?(Hash) && data["files"].is_a?(Hash) && data["episodes"].is_a?(Array)

        present = Reach::TranscriptExport.source_files.map { |file_path| File.basename(file_path) }
        gone = data["files"].keys - present
        next 0 if gone.empty?

        gone.each { |name| drop_source(data, name) }
        Reach::Brain.write_json(path, data)
        Reach::SessionRecall.log("recall.pruned", "files" => gone.length, "episodes" => data["episodes"].length)
        gone.length
      end
      outcome == :busy ? nil : outcome
    rescue StandardError => e
      fault(e, "prune_missing")
    end

    def forget_paths
      File.file?(path) ? [path] : []
    rescue StandardError => e
      fault(e, "forget_paths")
      []
    end

    def search(query, episodes, k:, boost_slice: nil)
      terms = Reach::BrainIndex.tokens(query).uniq
      return [] if terms.empty?

      pool = []
      Array(episodes).each do |episode|
        Array(episode["passages"]).each do |passage|
          counted = Reach::BrainIndex.tokens(passage["x"])
          pool << [episode, passage, Reach::BrainIndex.term_counts(counted), counted.length]
        end
      end
      return [] if pool.empty?

      total = pool.length
      average = pool.inject(0) { |sum, entry| sum + entry[3] }.to_f / total
      average = 1.0 if average.zero?
      idf = {}
      terms.each do |term|
        df = pool.count { |entry| entry[2].key?(term) }
        idf[term] = df.zero? ? nil : Math.log(1.0 + ((total - df + 0.5) / (df + 0.5)))
      end
      ideal = idf.values.compact.inject(0.0) { |sum, weight| sum + weight }
      scored = []
      pool.each do |episode, passage, counts, length|
        score = 0.0
        terms.each do |term|
          weight = idf[term]
          next unless weight

          tf = counts[term]
          next unless tf.positive?

          score += weight * (tf * (K1 + 1)) / (tf + (K1 * (1 - B + (B * length / average))))
        end
        next unless score.positive?

        share = ideal.positive? ? score / ideal : 0.0
        score *= SAME_SLICE_BOOST if boost_slice && episode["slice_key"] == boost_slice
        scored << { "episode" => episode, "passage" => passage, "score" => score, "share" => share }
      end
      scored.sort do |left, right|
        order = right["score"] <=> left["score"]
        order.zero? ? right["passage"]["at"].to_s <=> left["passage"]["at"].to_s : order
      end.first(k)
    rescue StandardError => e
      fault(e, "search")
      []
    end
  end
end
