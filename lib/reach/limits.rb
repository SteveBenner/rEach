require "json"
require "fileutils"
require "zlib"
require "openssl"

module Reach
  module Limits
    DEFAULTS = {
      "corpus_max_bytes" => 52_428_800,
      "materials_max_bytes" => 209_715_200
    }.freeze

    module_function

    def enforce!
      result = {}
      result["corpus"] = guarded { enforce_corpus }
      result
    end

    def report
      lines = []
      corpus = corpus_bytes
      cap = cap_for("corpus_max_bytes")
      if corpus_port?
        lines << "R-DOC-LIMITS corpus #{megabytes(corpus)} MB, managed by the corpus port"
      else
        lines << limit_line("corpus", corpus, cap)
      end
      materials_spaces.each do |space_path|
        lines << limit_line("materials #{File.basename(space_path)}", directory_bytes(File.join(space_path, "materials")), cap_for("materials_max_bytes"))
      end
      lines
    rescue StandardError
      ["R-DOC-LIMITS the local size limits could not be checked"]
    end

    def limit_line(label, bytes, cap)
      prefix = bytes > cap ? "WARNING " : ""
      "#{prefix}R-DOC-LIMITS #{label} #{megabytes(bytes)} MB of #{megabytes(cap)} MB"
    end

    def guarded
      yield
    rescue StandardError => e
      { "error" => e.class.name }
    end

    def cap_for(key)
      values = begin
        Reach::Policy.limits
      rescue StandardError
        {}
      end
      value = values.is_a?(Hash) ? values[key].to_i : 0
      value > 0 ? value : DEFAULTS[key]
    end

    def megabytes(bytes)
      format("%.1f", bytes.to_f / 1_048_576)
    end

    def corpus_port?
      Reach::Corpus.new(Reach.ports).available?
    rescue StandardError
      false
    end

    def corpus_files
      Reach::BrainSpool.spool_files(include_admitted: false)
    end

    def corpus_bytes
      corpus_files.sum { |path| File.size(path) }
    end

    def enforce_corpus
      total = corpus_bytes
      return { "state" => "managed by the corpus port", "bytes" => total } if corpus_port?

      state = total <= cap_for("corpus_max_bytes") ? "queued for admission" : "queued for admission, over cap"
      { "state" => state, "bytes" => total }
    end

    def materials_spaces
      spaces = Reach::Workspace.current_slices.dup
      extracurricular = Reach::Paths.extracurricular_root
      spaces << extracurricular if File.directory?(extracurricular)
      spaces.select { |space| File.directory?(File.join(space, "materials")) }
    rescue StandardError
      []
    end

    def directory_bytes(dir)
      return 0 unless File.directory?(dir)

      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sum do |path|
        File.file?(path) && !File.symlink?(path) ? File.size(path) : 0
      end
    rescue StandardError
      0
    end
  end
end
