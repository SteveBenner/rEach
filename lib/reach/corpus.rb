require "json"
require "time"
require "fileutils"

module Reach
  class Corpus
    KINDS = %w[note tip attempt receipt qualification].freeze

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
      corpus = owned_corpus
      Reach::BrainSpool.admit(corpus) if corpus
      nil
    rescue StandardError => e
      Reach::BrainSpool.log("admit_failed", "error" => e.class.name, "message" => e.message)
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
