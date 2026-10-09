require "zlib"
require "stringio"
require "rubygems/package"

module Reach
  module Tarball
    MAX_TOTAL_BYTES = 200 * 1024 * 1024
    MAX_ENTRIES = 20_000
    MAX_MEMBER_BYTES = MAX_TOTAL_BYTES
    READ_CHUNK_BYTES = 1_048_576
    READ_DEADLINE_S = 120
    GZIP_MAGIC = "\x1F\x8B".b.freeze

    module_function

    def write(entries)
      tar_io = StringIO.new
      Gem::Package::TarWriter.new(tar_io) do |tar|
        entries.each do |name, contents|
          bytes = contents.to_s.dup.force_encoding(Encoding::ASCII_8BIT)
          tar.add_file(name, 0o644) { |entry| entry.write(bytes) }
        end
      end

      gz_io = StringIO.new
      gz = Zlib::GzipWriter.new(gz_io)
      gz.write(tar_io.string)
      gz.close
      gz_io.string
    end

    def read(bytes)
      source = bytes.to_s.dup.force_encoding(Encoding::ASCII_8BIT)
      io = if source.byteslice(0, 2) == GZIP_MAGIC
             Zlib::GzipReader.new(StringIO.new(source))
           else
             StringIO.new(source)
           end

      result = {}
      total_bytes = 0
      entry_count = 0
      deadline = Time.now + READ_DEADLINE_S

      Gem::Package::TarReader.new(io) do |tar|
        tar.each do |entry|
          raise Reach::VerificationFailed, "reach: package archive rejected (took too long to read)" if Time.now > deadline

          next if entry.directory?

          unless entry.file?
            raise Reach::VerificationFailed, "reach: package archive rejected (unsupported entry type at #{entry.full_name})"
          end

          name = entry.full_name
          validate_name!(name)

          entry_count += 1
          raise Reach::VerificationFailed, "reach: package archive rejected (too many entries)" if entry_count > MAX_ENTRIES

          declared = entry.header.size.to_i
          raise Reach::VerificationFailed, "reach: package archive rejected (entry too large)" if declared > MAX_MEMBER_BYTES
          raise Reach::VerificationFailed, "reach: package archive rejected (archive too large)" if total_bytes + declared > MAX_TOTAL_BYTES

          data = read_member(entry, declared, deadline)
          total_bytes += data.bytesize

          result[name] = data
        end
      end

      result
    rescue Reach::VerificationFailed
      raise
    rescue StandardError => e
      raise Reach::VerificationFailed, "reach: package archive rejected (#{e.message})"
    end

    def read_member(entry, declared, deadline)
      data = String.new.force_encoding(Encoding::ASCII_8BIT)
      while data.bytesize < declared
        raise Reach::VerificationFailed, "reach: package archive rejected (took too long to read)" if Time.now > deadline

        piece = entry.read([READ_CHUNK_BYTES, declared - data.bytesize].min)
        break if piece.nil? || piece.empty?

        data << piece.force_encoding(Encoding::ASCII_8BIT)
      end
      data
    end

    def validate_name!(name)
      raise Reach::VerificationFailed, "reach: package archive rejected (bad entry name #{name.inspect})" if name.nil?
      raise Reach::VerificationFailed, "reach: package archive rejected (entry name too long)" if name.bytesize > 255
      if name.start_with?("/")
        raise Reach::VerificationFailed, "reach: package archive rejected (absolute entry name #{name.inspect})"
      end
      if name.include?("\\")
        raise Reach::VerificationFailed, "reach: package archive rejected (backslash in entry name #{name.inspect})"
      end
      raise Reach::VerificationFailed, "reach: package archive rejected (NUL in entry name)" if name.include?("\0")

      name.split("/").each do |segment|
        if segment == "." || segment == ".."
          raise Reach::VerificationFailed, "reach: package archive rejected (path segment #{segment.inspect} in #{name.inspect})"
        end
      end
    end
  end
end
