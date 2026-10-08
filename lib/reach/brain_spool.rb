require "json"
require "time"
require "securerandom"
require "digest"
require "fileutils"

module Reach
  module BrainSpool
    SCHEMA = "rcorpus.spool/v1"
    CORPUS_ID = "reach"
    ID_LIMIT = 128
    STAMPED = %w[revision recorded_at actor operation_id].freeze
    DAY_FILE = /\A\d{4}-\d{2}-\d{2}\.jsonl\z/.freeze

    module_function

    def state_home
      if Reach::Paths.persona_id
        File.join(Reach::Paths.home, "brain-store")
      elsif defined?(Rplugin::Paths) && Rplugin::Paths.respond_to?(:state_home)
        Rplugin::Paths.state_home
      else
        value = ENV["XDG_STATE_HOME"].to_s
        File.expand_path(File.join(value.empty? ? File.join(Reach::Paths.user_home, ".local", "state") : value, "rplugin"))
      end
    end

    def dir
      File.join(state_home, "reach", "brain-spool")
    end

    def writer
      "reach #{Reach::VERSION}"
    end

    def sanitize_id(value)
      text = value.to_s.downcase.gsub(/[^a-z0-9_.:-]/, "-")
      text = "x#{text}" unless text.match?(/\A[a-z0-9]/)
      text[0, ID_LIMIT]
    end

    def build_id(kind, record, fallback_uuid)
      key = case kind
            when "receipt" then record["receipt_id"] || record["submission_id"]
            when "qualification" then record["qualification_id"]
            end
      key = fallback_uuid if key.to_s.empty? && kind != "qualification"
      key = [record["slice"], record["attempt"], record["files_digest"].to_s[0, 16]].join("-") if key.to_s.empty?
      sanitize_id("#{kind}:#{key}")
    end

    def clean_record(kind, data)
      body = {}
      data.each { |key, value| body[key.to_s] = value }
      body["receipt_kind"] = body.delete("kind") if kind == "receipt" && body.key?("kind")
      body.delete("kind")
      body.delete("id") unless kind == "receipt"
      STAMPED.each { |field| body.delete(field) }
      body
    end

    def append(kind, data, operation_id: nil, written_at: nil, id: nil)
      record = clean_record(kind, data)
      line = {
        "spool" => SCHEMA,
        "operation_id" => operation_id || SecureRandom.uuid,
        "corpus" => CORPUS_ID,
        "op" => "put",
        "kind" => kind.to_s,
        "id" => id || build_id(kind.to_s, record, SecureRandom.uuid),
        "tier" => "private",
        "record" => record,
        "written_at" => written_at || Time.now.utc.iso8601(3),
        "writer" => writer
      }
      write_line(line)
      line
    end

    def append_op(op:, kind:, id:, record:, operation_id: nil)
      line = {
        "spool" => SCHEMA,
        "operation_id" => operation_id || SecureRandom.uuid,
        "corpus" => CORPUS_ID,
        "op" => op.to_s,
        "kind" => kind.to_s,
        "id" => id.to_s,
        "tier" => "private",
        "record" => record,
        "written_at" => Time.now.utc.iso8601(3),
        "writer" => writer
      }
      write_line(line)
      line
    end

    def write_line(line)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{Time.now.utc.strftime('%Y-%m-%d')}.jsonl")
      done = false
      3.times do
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
          raise Reach::Locks::Busy, "brain spool is busy" unless Reach::Locks.acquire(file, path)

          current = File.stat(path) rescue nil
          next unless current && current.ino == file.stat.ino

          file.write("#{JSON.generate(line)}\n")
          file.flush
          done = true
        end
        break if done
      end
      unless done
        log("spool_write_dropped", "id" => line["id"], "operation_id" => line["operation_id"], "kind" => line["kind"])
        return nil
      end
      path
    end

    def scrub!(ids, keep_tombstones: true)
      wanted = Array(ids).map(&:to_s).reject(&:empty?)
      return 0 if wanted.empty?

      removed = 0
      spool_files(include_admitted: true).each do |path|
        removed += scrub_file(path, wanted, keep_tombstones)
      end
      removed
    end

    def scrub_file(path, wanted, keep_tombstones)
      return 0 unless File.file?(path)

      count = 0
      File.open(path, File::RDWR) do |file|
        file.flock(File::LOCK_EX)
        raw = file.read
        return 0 unless wanted.any? { |id| raw.include?(id) }

        kept = []
        raw.each_line do |text|
          parsed = begin
            JSON.parse(text)
          rescue JSON::ParserError
            nil
          end
          if parsed.is_a?(Hash) && wanted.include?(parsed["id"].to_s) && !(keep_tombstones && parsed["op"] == "tombstone")
            count += 1
          else
            kept << text
          end
        end
        return 0 if count.zero?

        tmp = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |out|
          kept.each { |text| out.write(text) }
          out.flush
          out.fsync
        end
        File.rename(tmp, path)
      end
      count
    end

    def spool_files(include_admitted: true)
      return [] unless File.directory?(dir)

      paths = Dir.children(dir).select { |name| name.match?(DAY_FILE) }.sort.map { |name| File.join(dir, name) }
      if include_admitted
        admitted = File.join(dir, "admitted")
        if File.directory?(admitted)
          paths = Dir.children(admitted).select { |name| name.start_with?(/\d{4}-\d{2}-\d{2}\.jsonl/) }.sort.map { |name| File.join(admitted, name) } + paths
        end
      end
      paths
    end

    def read_lines(paths)
      paths.flat_map do |path|
        File.readlines(path).map do |raw|
          begin
            parsed = JSON.parse(raw)
            parsed.is_a?(Hash) ? parsed : nil
          rescue JSON::ParserError
            nil
          end
        end.compact
      end
    end

    def lines_for(kind, include_admitted: true)
      seen = {}
      read_lines(spool_files(include_admitted: include_admitted)).each_with_index.select do |line, _|
        line["spool"] == SCHEMA && line["corpus"] == CORPUS_ID && line["op"] == "put" && line["kind"] == kind.to_s &&
          line["record"].is_a?(Hash)
      end.select do |line, _|
        !seen.key?(line["operation_id"]) && (seen[line["operation_id"]] = true)
      end.map(&:first)
    end

    def sort_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      Time.at(0)
    end

    def body_for(line)
      line["record"].merge("id" => line["id"], "kind" => line["kind"], "recorded_at" => line["written_at"], "operation_id" => line["operation_id"])
    end

    def latest_per_id(rows, time_key)
      latest = {}
      rows.each_with_index do |row, index|
        key = row["id"]
        current = latest[key]
        stamp = [sort_time(row[time_key]), index]
        latest[key] = [stamp, row] if current.nil? || (stamp <=> current[0]) >= 0
      end
      latest.values.sort_by(&:first).map(&:last)
    end

    def recent_from_spool(kind, limit, include_admitted: true)
      rows = lines_for(kind, include_admitted: include_admitted).map { |line| body_for(line) }
      latest_per_id(rows, "recorded_at").last(limit)
    end

    def pending_rows(kind)
      lines_for(kind, include_admitted: false).map { |line| body_for(line) }
    end

    def admit(corpus)
      return nil unless defined?(Rcorpus::Spool)

      report = Rcorpus::Spool.new(corpus, dir).admit
      unless report["refused"].to_a.empty?
        log("spool_refused", "refused" => report["refused"])
      end
      report
    rescue StandardError => e
      log("spool_admit_failed", "error" => e.class.name, "message" => e.message)
      nil
    end

    def derived_uuid(text)
      hex = Digest::SHA256.hexdigest(text)[0, 32].dup
      hex[12] = "4"
      hex[16] = %w[8 9 a b][hex[16].to_i(16) % 4]
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    def migrate_legacy
      legacy = Reach::Paths.corpus_fallback_dir
      return 0 unless File.directory?(legacy)

      files = Dir.glob(File.join(legacy, "*.jsonl")).sort
      return 0 if files.empty?

      known = existing_operation_ids
      count = 0
      files.each do |path|
        File.readlines(path).each do |raw|
          text = raw.strip
          next if text.empty?

          data = begin
            JSON.parse(text)
          rescue JSON::ParserError
            nil
          end
          next unless data.is_a?(Hash)

          kind = File.basename(path, ".jsonl")
          kind = data["kind"].to_s if kind.empty?
          next unless Reach::Corpus::KINDS.include?(kind)

          operation_id = derived_uuid(Digest::SHA256.hexdigest(text))
          next if known[operation_id]

          written_at = begin
            Time.iso8601(data["at"].to_s).utc.iso8601(3)
          rescue ArgumentError
            File.mtime(path).utc.iso8601(3)
          end
          id = %w[receipt qualification].include?(kind) ? nil : "#{kind}:#{operation_id}"
          append(kind, data, operation_id: operation_id, written_at: written_at, id: id)
          known[operation_id] = true
          count += 1
        end
        FileUtils.mv(path, "#{path}.migrated")
      end
      count
    end

    def existing_operation_ids
      ids = {}
      read_lines(spool_files).each { |line| ids[line["operation_id"]] = true }
      ids
    end

    def log(event, fields = {})
      record = { "at" => Time.now.utc.iso8601, "event" => event }.merge(fields)
      begin
        Reach::Debug.append_log(File.join(Reach::Paths.logs_dir, "brain.jsonl"), record)
      rescue StandardError
        nil
      end
      $stderr.puts("reach brain: #{JSON.generate(record)}") unless ENV["REACH_DEBUG"].to_s.empty?
      nil
    rescue StandardError
      nil
    end
  end
end
