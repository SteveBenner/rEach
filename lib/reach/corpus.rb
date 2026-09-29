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
      corpus_port
      true
    rescue StandardError
      false
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

      if available?
        corpus_port.recall(kind: kind.to_s, limit: limit)
      else
        jsonl_read(kind).last(limit)
      end
    end

    private

    def write(kind, data)
      record = data.merge("kind" => kind, "at" => Time.now.utc.iso8601)
      if available?
        corpus_port.put(kind: kind, data: record)
      else
        jsonl_append(kind, record)
      end
      record
    end

    def corpus_port
      @ports.corpus.open("reach")
    end

    def jsonl_path(kind)
      File.join(Reach::Paths.home, "corpus-fallback", "#{kind}.jsonl")
    end

    def jsonl_append(kind, record)
      path = jsonl_path(kind)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts(JSON.generate(record)) }
    end

    def jsonl_read(kind)
      path = jsonl_path(kind)
      return [] unless File.file?(path)

      File.readlines(path).map { |line| JSON.parse(line) }
    end
  end
end
