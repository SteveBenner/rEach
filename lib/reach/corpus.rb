require "json"
require "time"
require "fileutils"

module Reach
  class Corpus
    KINDS = %w[note tip attempt receipt qualification source finding].freeze

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
      corpus = owned_corpus
      return :unavailable unless corpus && defined?(Rcorpus::Spool)

      settings = Reach::Brain.settings
      now = Time.now.to_i
      state = Reach::Brain.read_state
      return :throttled unless force || now >= state["admit_next_at"].to_i

      report = Reach::BrainSpool.admit(corpus)
      if report.nil?
        wait = [(state["admit_wait_s"].to_i.positive? ? state["admit_wait_s"].to_i * 2 : settings["admit_interval_s"]), settings["admit_max_backoff_s"]].min
        Reach::Brain.update_state { |fresh| fresh.merge("admit_wait_s" => wait, "admit_next_at" => now + wait) }
        Reach::Brain.log("brain.admit_failed", "wait_s" => wait)
        return :failed
      end

      Reach::Brain.update_state { |fresh| fresh.merge("admit_wait_s" => 0, "admit_next_at" => now + settings["admit_interval_s"]) }
      consolidate(corpus)
      :admitted
    rescue StandardError => e
      Reach::Brain.log("brain.admit_failed", "error" => e.class.name)
      :failed
    end

    def erase(ids)
      corpus = owned_corpus
      return :unavailable unless corpus && defined?(Rcorpus::Erase)

      report = Rcorpus::Erase.new(corpus).run(ids: Array(ids), reason: "forgotten")
      Reach::Brain.log("brain.erased", "erased" => Array(report["erased"]).length, "missing" => Array(report["missing"]).length, "lines" => report["lines_removed"].to_i)
      :erased
    rescue StandardError => e
      Reach::Brain.log("brain.erase_failed", "error" => e.class.name)
      :failed
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
