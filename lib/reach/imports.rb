require "json"
require "time"
require "fileutils"
require "openssl"
require "uri"

module Reach
  module Imports
    ALLOWED_EXTENSIONS = %w[txt md csv tsv json yml yaml pdf png jpg jpeg gif webp xlsx docx pptx].freeze
    DEFAULT_MAX_BYTES = 20_971_520
    DEFAULT_MAX_PER_PROMPT = 5
    DEFAULT_MATERIALS_MAX_BYTES = 209_715_200
    MATERIALS_DIR = "materials".freeze
    FILE_URI = %r{file://(/[^\s"'<>]+)}
    QUOTED = /"([^"\n]+)"|'([^'\n]+)'/
    ESCAPED = %r{(?:\A|(?<=[\s(\[,;:]))((?:~/|/)(?:\\.|[^\s\\"'])+)}
    WINDOWS_PATH = /(?:\A|(?<=[\s(\[,;:"']))([A-Za-z]:\\[^"'\r\n<>|*?]*)/

    module_function

    def observe(text:, space_path:, session_id:, harness:)
      return [] unless text.is_a?(String) && space_path

      paths = candidate_paths(text)
      return [] if paths.empty?

      limits = limit_values
      lines = []
      paths.each_with_index do |path, index|
        if index >= limits[:per_prompt]
          extra = paths.length - limits[:per_prompt]
          lines << Reach::Messages.text("M-IMPORT-REFUSED", source_name: "#{extra} more #{extra == 1 ? 'file' : 'files'}", reason: Reach::Messages.text("M-IMPORT-TOO-MANY", max: limits[:per_prompt]))
          break
        end

        result = import!(path, space_path: space_path)
        if result["ok"]
          lines << Reach::Messages.text("M-IMPORT-OK", name: result["name"])
          record_action(result, space_path: space_path, session_id: session_id, harness: harness)
        else
          lines << Reach::Messages.text("M-IMPORT-REFUSED", source_name: result["source_name"], reason: result["reason"])
        end
      end
      lines
    rescue StandardError
      []
    end

    def import!(path, space_path:)
      source = File.expand_path(path.to_s)
      source_name = File.basename(source)
      limits = limit_values

      extension = File.extname(source_name).delete(".").downcase
      return refused(source_name, Reach::Messages.text("M-IMPORT-TYPE")) unless ALLOWED_EXTENSIONS.include?(extension)
      return refused(source_name, Reach::Messages.text("M-IMPORT-TYPE")) unless File.file?(source) && !File.symlink?(source)

      size = File.size(source)
      return refused(source_name, Reach::Messages.text("M-IMPORT-TOO-LARGE", max: megabytes(limits[:max_bytes]))) if size > limits[:max_bytes]

      materials = File.join(space_path, MATERIALS_DIR)
      return refused(source_name, Reach::Messages.text("M-IMPORT-FULL")) if directory_bytes(materials) + size > limits[:materials_max_bytes]

      FileUtils.mkdir_p(materials)
      safe_chmod(0o700, materials)
      name, destination = reserve(materials, source_name)
      File.open(source, "rb") do |input|
        File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
          IO.copy_stream(input, output)
        end
      end
      digest = OpenSSL::Digest::SHA256.file(destination).hexdigest
      bytes = File.size(destination)
      record = {
        "source_name" => source_name, "name" => name, "space" => File.basename(space_path), "bytes" => bytes,
        "digest" => digest, "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "student_id" => student_id
      }
      append_record(record)
      witness(space_path, record)
      { "ok" => true, "name" => name, "source_name" => source_name, "bytes" => bytes, "digest" => digest }
    rescue StandardError
      refused(File.basename(path.to_s), Reach::Messages.text("M-IMPORT-TYPE"))
    end

    def candidate_paths(text)
      raw = []
      text.scan(FILE_URI) { |match| raw << URI.decode_www_form_component(match[0].gsub("+", "%2B")) }
      text.scan(QUOTED) do |double, single|
        candidate = (double || single).to_s
        raw << candidate if path_start?(candidate)
      end
      text.scan(ESCAPED) { |match| raw << match[0].gsub(/\\(.)/, '\1') }
      if Reach::Runtime.windows?
        text.scan(WINDOWS_PATH) { |match| raw << match[0].strip }
      end

      seen = {}
      raw.each_with_object([]) do |candidate, list|
        expanded = expand(candidate)
        next unless expanded
        next if seen[expanded]

        seen[expanded] = true
        next unless File.file?(expanded) && !File.symlink?(expanded)
        next if inside?(expanded, Reach::Paths.workspace_root)
        next if inside?(expanded, Reach::Paths.home)
        next if inside?(expanded, Reach::Paths.root)

        list << expanded
      end
    end

    def path_start?(candidate)
      candidate.start_with?("/", "~/") || (Reach::Runtime.windows? && candidate =~ /\A[A-Za-z]:\\/)
    end

    def expand(candidate)
      text = candidate.to_s.strip
      return nil if text.empty?

      full = File.expand_path(text)
      return full if File.exist?(full)

      trimmed = text.sub(/[.,;:!?)\]]+\z/, "")
      trimmed.empty? ? nil : File.expand_path(trimmed)
    rescue StandardError
      nil
    end

    def inside?(path, root)
      return false unless root

      base = File.exist?(root) ? File.realpath(root) : File.expand_path(root)
      real = File.exist?(path) ? File.realpath(path) : File.expand_path(path)
      real == base || real.start_with?("#{base}#{File::SEPARATOR}")
    rescue StandardError
      false
    end

    def reserve(materials, source_name)
      cleaned = source_name.gsub(/\s+/, "-").gsub(/[^A-Za-z0-9._-]/, "")
      cleaned = "file" if cleaned.empty? || cleaned == "." || cleaned == ".."
      extension = File.extname(cleaned)
      stem = extension.empty? ? cleaned : cleaned[0...-extension.length]
      stem = "file" if stem.empty?
      counter = 1
      loop do
        name = counter == 1 ? "#{stem}#{extension}" : "#{stem}-#{counter}#{extension}"
        destination = File.join(materials, name)
        return [name, destination] unless File.exist?(destination) || File.symlink?(destination)

        counter += 1
      end
    end

    def directory_bytes(dir)
      return 0 unless File.directory?(dir)

      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sum do |path|
        File.file?(path) && !File.symlink?(path) ? File.size(path) : 0
      end
    rescue StandardError
      0
    end

    def limit_values
      values = begin
        Reach::Policy.limits
      rescue StandardError
        {}
      end
      values = {} unless values.is_a?(Hash)
      {
        max_bytes: positive(values["import_max_bytes"], DEFAULT_MAX_BYTES),
        per_prompt: positive(values["import_max_per_prompt"], DEFAULT_MAX_PER_PROMPT),
        materials_max_bytes: positive(values["materials_max_bytes"], DEFAULT_MATERIALS_MAX_BYTES)
      }
    end

    def positive(value, default)
      number = value.to_i
      number > 0 ? number : default
    end

    def megabytes(bytes)
      value = bytes.to_f / 1_048_576
      value == value.to_i ? value.to_i.to_s : format("%.1f", value)
    end

    def refused(source_name, reason)
      { "ok" => false, "source_name" => source_name, "reason" => reason }
    end

    def student_id
      install = Reach::Enroll.current
      install && install["student_id"]
    rescue StandardError
      nil
    end

    def append_record(record)
      FileUtils.mkdir_p(File.dirname(Reach::Paths.imports_file))
      Reach::Locks.exclusive(Reach::Paths.imports_file, mode: File::WRONLY | File::CREAT | File::APPEND) do |file|
        file.puts(JSON.generate(record))
      end
    end

    def witness(space_path, record)
      Reach::Ledger.append(space_path, "import", "name" => record["name"], "bytes" => record["bytes"], "digest" => record["digest"])
    rescue StandardError
      nil
    end

    def record_action(result, space_path:, session_id:, harness:)
      space = Reach::Workspace.space_for(space_path)
      kind = space && space["kind"]
      meta = kind == "slice" ? Reach::Workspace.metadata(space_path) : {}
      slice = meta["slice"]
      slice = nil unless Reach::Transcript::SLICES.include?(slice)
      summary = "imported #{result['name']}, #{result['bytes']} bytes, sha256 #{result['digest'].to_s[0, 12]}"
      Reach::Transcript.record(
        session_id, kind: "action", harness: Reach::Transcript.resolve_harness(harness),
        cutout_id: meta["cutout_id"], slice: slice, space: kind,
        fields: { "tool" => "reach import", "summary" => summary, "note" => nil }
      )
    rescue StandardError
      nil
    end

    def safe_chmod(mode, path)
      File.chmod(mode, path)
    rescue NotImplementedError, Errno::ENOENT, Errno::EPERM
      nil
    end
  end
end
