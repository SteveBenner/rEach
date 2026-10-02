require "json"
require "digest"
require "zlib"

module Reach
  module ExportImport
    module Sources
      SAMPLE_BYTES = 4_194_304
      MAX_DEPTH = 5
      SKIP_ALL = 1 << 60
      CONVERSATIONS = /\Aconversations(-\d+)?\.json\z/i.freeze
      ACTIVITY = /\Amyactivity\.json\z/i.freeze
      HTML_EXPORT = /\A(chat|conversations|myactivity)\.html\z/i.freeze

      module_function

      def open(path)
        expanded = File.expand_path(path.to_s)
        raise Reach::Refused, Reach::Messages.text("M-IMPORT-UNKNOWN") unless File.exist?(expanded)

        if File.directory?(expanded)
          Folder.new(expanded)
        elsif File.file?(expanded) && File.extname(expanded).casecmp(".zip").zero?
          Archive.new(expanded)
        else
          raise Reach::Refused, Reach::Messages.text("M-IMPORT-UNKNOWN")
        end
      end

      class Base
        attr_reader :path

        def entries
          @entries
        end

        def size_of(name)
          found = @entries.find { |entry| entry["name"] == name }
          found ? found["size"] : 0
        end

        def first_element(name)
          found = nil
          parser = Reach::JsonStream::Parser.new
          catch(:found) do
            each_chunk(name) do |chunk|
              parser.feed(chunk) do |text, _offset|
                found = text
                throw :found
              end
              throw :found if parser.finished?
            end
          end
          found ? JSON.parse(found) : nil
        rescue JSON::ParserError
          nil
        end

        def estimate_elements(name)
          total = size_of(name)
          parser = Reach::JsonStream::Parser.new(skip: SKIP_ALL)
          consumed = 0
          catch(:enough) do
            each_chunk(name) do |chunk|
              consumed += chunk.bytesize
              parser.feed(chunk) { |_text, _offset| nil }
              throw :enough if parser.finished? || consumed >= SAMPLE_BYTES
            end
          end
          return parser.elements if parser.finished? || consumed >= total
          return 0 if parser.last_end.zero?

          (parser.elements * total.to_f / parser.last_end).round
        end

        def digest
          listing = @entries.map { |entry| [entry["name"], entry["size"]] }.sort
          Digest::SHA256.hexdigest(JSON.generate([self.class.name.split("::").last, listing]))
        end
      end

      class Folder < Base
        def initialize(root)
          @path = root
          @root = root
          @entries = scan
        end

        def kind
          "folder"
        end

        def scan
          found = []
          Dir.glob("**/*", base: @root).sort.each do |relative|
            next if relative.split("/").length > MAX_DEPTH

            full = File.join(@root, relative)
            next if File.symlink?(full) || !File.file?(full)

            found << { "name" => relative, "size" => File.size(full) }
          end
          found
        end

        def each_chunk(name)
          File.open(File.join(@root, name), "rb") do |file|
            chunk = +""
            while file.read(Reach::JsonStream::CHUNK_BYTES, chunk)
              yield chunk
            end
          end
        end

        def read_range(name, offset, length)
          File.open(File.join(@root, name), "rb") do |file|
            file.seek(offset)
            file.read(length).to_s
          end
        end
      end

      class Archive < Base
        def initialize(file)
          @path = file
          @zip = {}
          File.open(file, "rb") do |io|
            Reach::Unzip.central_directory(io).each do |entry|
              next if entry[:name].end_with?("/")

              @zip[entry[:name]] = entry
            end
          end
          @entries = @zip.map { |name, entry| { "name" => name, "size" => entry[:usize] } }.sort_by { |entry| entry["name"] }
        rescue Reach::Error, SystemCallError, Zlib::Error
          raise Reach::Refused, Reach::Messages.text("M-IMPORT-UNKNOWN")
        end

        def kind
          "zip"
        end

        def each_chunk(name)
          entry = @zip.fetch(name)
          File.open(@path, "rb") do |io|
            Reach::Unzip.each_chunk(io, entry) { |piece| yield piece }
          end
        end

        def read_range(name, offset, length)
          out = +"".b
          position = 0
          wanted_end = offset + length
          catch(:done) do
            each_chunk(name) do |piece|
              piece_end = position + piece.bytesize
              if piece_end > offset
                from = [offset - position, 0].max
                to = [wanted_end - position, piece.bytesize].min
                out << piece.byteslice(from, to - from)
              end
              position = piece_end
              throw :done if position >= wanted_end
            end
          end
          out
        end
      end

      def basename(name)
        name.split("/").last.to_s
      end

      def directory(name)
        parts = name.split("/")
        parts.pop
        parts.join("/")
      end

      def detect(source)
        names = source.entries.map { |entry| entry["name"] }
        chat = names.select { |name| basename(name).match?(CONVERSATIONS) }.sort
        unless chat.empty?
          head = source.first_element(chat.first)
          vendor = if head.is_a?(Hash) && head["mapping"].is_a?(Hash) then "chatgpt"
                   elsif head.is_a?(Hash) && head.key?("chat_messages") then "claude"
                   end
          return build(source, vendor, chat, names) if vendor
        end
        activity = names.select { |name| basename(name).match?(ACTIVITY) }.sort.select do |name|
          head = source.first_element(name)
          head.is_a?(Hash) && (head["header"].to_s.match?(/gemini/i) || Array(head["products"]).any? { |product| product.to_s.match?(/gemini/i) })
        end
        return build(source, "gemini", activity, names) unless activity.empty?
        raise Reach::Refused, Reach::Messages.text("M-IMPORT-NEEDS-JSON") if names.any? { |name| basename(name).match?(HTML_EXPORT) }

        raise Reach::Refused, Reach::Messages.text("M-IMPORT-UNKNOWN")
      end

      def build(source, vendor, primary, names)
        files = primary.map { |name| { "name" => name, "size" => source.size_of(name), "kind" => vendor == "gemini" ? "activity" : "conversations" } }
        if vendor == "claude"
          folders = primary.map { |name| directory(name) }.uniq
          { "memories.json" => "memories", "projects.json" => "projects" }.each do |base, kind|
            names.select { |name| basename(name) == base && folders.include?(directory(name)) }.sort.each do |name|
              files << { "name" => name, "size" => source.size_of(name), "kind" => kind }
            end
          end
        end
        { "vendor" => vendor, "files" => files, "total_bytes" => files.inject(0) { |sum, file| sum + file["size"] } }
      end

      def estimate(source, files)
        files.inject(0) { |sum, file| sum + source.estimate_elements(file["name"]) }
      end
    end
  end
end
