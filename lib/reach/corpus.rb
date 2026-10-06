require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  class Corpus
    KINDS = %w[note tip attempt receipt qualification source finding].freeze
    ADMIT_LOCK_WAIT_S = 25

    def initialize(ports)
      @ports = ports
    end

    def available?
      !owned_corpus.nil?
    end

    def note(text, slice: nil)
      write("note", { "text" => text, "slice" => slice })
    end

    def tip(text, slice: nil, source: nil)
      write("tip", { "text" => text, "slice" => slice, "source" => source })
    end

    def attempt(finding_id:, slice:, resolved:)
      write("attempt", { "finding_id" => finding_id, "slice" => slice, "resolved" => resolved })
    end

    def receipt(receipt)
      write("receipt", receipt)
    end

    def qualification(record)
      write("qualification", record)
    end

    def admit_if_due(force: false)
      return admit_inline if Reach::BrainPlanes.child?
      return :unavailable unless Reach::BrainPlanes.available?

      settings = Reach::Brain.settings
      now = Time.now.to_i
      state = Reach::Brain.read_state
      return :throttled unless force || now >= state["admit_next_at"].to_i

      Reach::Brain.update_state { |fresh| fresh.merge("admit_next_at" => now + settings["admit_interval_s"]) }
      Reach::BrainPlanes.spawn(%w[brain admit]).nil? ? :failed : :spawned
    rescue StandardError => e
      Reach::Brain.log("brain.admit_failed", "error" => e.class.name)
      :failed
    end

    def admit_inline
      corpus = owned_corpus
      return :unavailable unless corpus && defined?(Rcorpus::Spool)

      settings = Reach::Brain.settings
      now = Time.now.to_i
      run_pending_erases(corpus)
      report = Reach::BrainSpool.admit(corpus)
      if report.nil?
        state = Reach::Brain.read_state
        wait = [(state["admit_wait_s"].to_i.positive? ? state["admit_wait_s"].to_i * 2 : settings["admit_interval_s"]), settings["admit_max_backoff_s"]].min
        Reach::Brain.update_state { |fresh| fresh.merge("admit_wait_s" => wait, "admit_next_at" => now + wait) }
        Reach::Brain.log("brain.admit_failed", "wait_s" => wait)
        return :failed
      end

      Reach::Brain.update_state { |fresh| fresh.merge("admit_wait_s" => 0, "admit_next_at" => now + settings["admit_interval_s"]) }
      counts = {}
      report.each { |key, value| counts[key.to_s] = value if value.is_a?(Integer) } if report.is_a?(Hash)
      Reach::Brain.log("brain.admitted", counts)
      consolidate(corpus)
      :admitted
    rescue StandardError => e
      Reach::Brain.log("brain.admit_failed", "error" => e.class.name)
      :failed
    end

    def erase(ids)
      list = Array(ids).map(&:to_s).reject(&:empty?)
      if Reach::BrainPlanes.child?
        return erase_inline(list)
      elsif Reach.ports
        result = erase_inline(list)
        return result unless result == :failed
      elsif Reach::BrainPlanes.available?
        return :erased if erase_via_child(list)
      elsif !File.directory?(Reach::BrainPlanes.planes_dir)
        return :unavailable
      end

      queue_erase(list)
      :queued
    rescue StandardError => e
      Reach::Brain.log("brain.erase_failed", "error" => e.class.name)
      :failed
    end

    def erase_inline(ids)
      corpus = owned_corpus
      return :unavailable unless corpus && defined?(Rcorpus::Erase)

      outcome = with_admit_lock(ADMIT_LOCK_WAIT_S) do
        Reach::BrainSpool.admit(corpus)
        report = Rcorpus::Erase.new(corpus).run(ids: Array(ids), reason: "forgotten")
        Reach::Brain.log("brain.erased", "erased" => Array(report["erased"]).length, "missing" => Array(report["missing"]).length, "lines" => report["lines_removed"].to_i)
        :erased
      end
      outcome == :busy ? :failed : outcome
    rescue StandardError => e
      Reach::Brain.log("brain.erase_failed", "error" => e.class.name)
      :failed
    end

    def with_admit_lock(wait_s)
      Reach::Brain.ensure_dir!
      File.open(File.join(Reach::Brain.dir, "brain-admit.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        deadline = Time.now + wait_s
        until lock.flock(File::LOCK_EX | File::LOCK_NB)
          return :busy if Time.now >= deadline

          sleep 0.2
        end
        yield
      end
    end

    def run_pending_erases(corpus)
      return nil unless defined?(Rcorpus::Erase)

      rows = pending_rows
      return nil if rows.empty?

      ids = rows.map { |row| row["id"] }.uniq
      report = Rcorpus::Erase.new(corpus).run(ids: ids, reason: "forgotten")
      done = (Array(report["erased"]) + Array(report["missing"])).map(&:to_s)
      drop_pending(done)
      Reach::Brain.log("brain.erased", "erased" => Array(report["erased"]).length, "missing" => Array(report["missing"]).length, "lines" => report["lines_removed"].to_i, "pending" => true)
      nil
    rescue StandardError => e
      Reach::Brain.log("brain.erase_failed", "error" => e.class.name, "pending" => true)
      nil
    end

    def erase_via_child(ids)
      return true if ids.empty?

      Reach::Brain.ensure_dir!
      path = File.join(Reach::Brain.dir, "erase-#{Process.pid}-#{SecureRandom.hex(4)}.ids")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(ids.join("\n")) }
      result = Reach::BrainPlanes.run(["brain", "erase", "--ids-file", path], timeout: 30)
      !result.nil? && result[1].success?
    ensure
      FileUtils.rm_f(path) if path
    end

    def queue_erase(ids)
      Reach::Brain.ensure_dir!
      with_pending_lock do
        File.open(Reach::BrainPlanes.pending_path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
          ids.each { |id| file.write("#{JSON.generate('id' => id, 'at' => Time.now.utc.iso8601)}\n") }
        end
      end
      Reach::Brain.log("brain.erase_queued", "count" => ids.length)
      nil
    end

    def pending_rows
      path = Reach::BrainPlanes.pending_path
      return [] unless File.file?(path)

      with_pending_lock do
        File.readlines(path).map do |line|
          row = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          row.is_a?(Hash) && row["id"].to_s != "" ? row : nil
        end.compact
      end
    end

    def drop_pending(done)
      path = Reach::BrainPlanes.pending_path
      with_pending_lock do
        kept = File.file?(path) ? File.readlines(path).reject { |line| (row = (JSON.parse(line) rescue nil)).is_a?(Hash) && done.include?(row["id"].to_s) } : []
        if kept.empty?
          FileUtils.rm_f(path)
        else
          tmp = "#{path}.tmp-#{Process.pid}"
          File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| kept.each { |line| file.write(line) } }
          File.rename(tmp, path)
        end
      end
    end

    def with_pending_lock
      File.open(Reach::BrainPlanes.pending_lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def recent(kind, limit: 20)
      raise ArgumentError, "reach: unknown corpus kind #{kind.inspect}" unless KINDS.include?(kind.to_s)

      migrate
      corpus = owned_corpus
      return Reach::BrainSpool.recent_from_spool(kind.to_s, limit) unless corpus

      stored = begin
        corpus.kv.list(kind: kind.to_s)
      rescue StandardError => e
        Reach::BrainSpool.log("corpus_list_failed", "kind" => kind.to_s, "error" => e.class.name, "message" => e.message)
        return Reach::BrainSpool.recent_from_spool(kind.to_s, limit)
      end
      known = {}
      stored.each { |row| known[row["operation_id"]] = true }
      pending = Reach::BrainSpool.pending_rows(kind.to_s).reject { |row| known[row["operation_id"]] }
      Reach::BrainSpool.latest_per_id(stored + pending, "recorded_at").last(limit)
    end

    private

    def write(kind, data)
      migrate
      record = data.merge("at" => Time.now.utc.iso8601, "student_id" => enrolled_student_id)
      Reach::BrainSpool.append(kind, record)
      admit
      record.merge("kind" => kind)
    end

    def migrate
      moved = Reach::BrainSpool.migrate_legacy
      admit if moved.positive?
      moved
    rescue StandardError => e
      Reach::BrainSpool.log("migrate_failed", "error" => e.class.name, "message" => e.message)
      nil
    end

    def admit
      admit_if_due
      nil
    end

    def consolidate(corpus)
      return nil unless defined?(Rcorpus::Consolidate)

      today = Time.now.utc.strftime("%Y-%m-%d")
      return nil if Reach::Brain.read_state["consolidated_on"] == today

      report = Rcorpus::Consolidate.new(corpus).run
      Reach::Brain.update_state { |fresh| fresh.merge("consolidated_on" => today) }
      counts = {}
      report.each { |key, value| counts[key.to_s] = value if value.is_a?(Integer) } if report.is_a?(Hash)
      Reach::Brain.log("brain.consolidated", counts)
      nil
    rescue StandardError => e
      Reach::Brain.log("brain.consolidate_failed", "error" => e.class.name)
      nil
    end

    def enrolled_student_id
      install = Reach::Enroll.current
      install && install["student_id"]
    rescue StandardError
      nil
    end

    def owned_corpus
      return @owned if defined?(@owned) && @owned
      return nil unless @ports

      @owned = @ports.corpus.open("reach")
    rescue StandardError => e
      Reach::BrainSpool.log("corpus_unavailable", "error" => e.class.name, "message" => e.message)
      nil
    end
  end
end
