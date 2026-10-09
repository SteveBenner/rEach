require "zlib"
require "fileutils"

module Reach
  module Unzip
    CHUNK_BYTES = 1_048_576
    MAX_ENTRY_BYTES = 2 * 1024 * 1_048_576
    MAX_EXTRACT_BYTES = 4 * 1024 * 1_048_576
    MAX_ENTRIES = 100_000
    EXTRACT_DEADLINE_S = 900
    EOCD_SIG = 0x06054b50
    EOCD64_SIG = 0x06064b50
    LOCATOR64_SIG = 0x07064b50
    CENTRAL_SIG = 0x02014b50
    LOCAL_SIG = 0x04034b50
    MAX_COMMENT = 65_557
    S_IFMT = 0o170000
    S_IFLNK = 0o120000
    S_IFDIR = 0o040000

    module_function

    def extract(zip_path, into:, max_total_bytes: MAX_EXTRACT_BYTES, deadline_s: EXTRACT_DEADLINE_S)
      root = File.expand_path(into)
      fresh = !File.exist?(root)
      FileUtils.mkdir_p(root)
      count = 0
      written = []
      budget = { used: 0, max: max_total_bytes, deadline: Time.now + deadline_s }
      begin
        File.open(zip_path, "rb") do |io|
          entries = central_directory(io)
          raise Reach::Error, "reach: the archive holds too many entries" if entries.length > MAX_ENTRIES
          declared = entries.inject(0) { |sum, entry| sum + entry[:usize].to_i }
          raise Reach::Error, "reach: the archive would expand past the allowed size" if declared > max_total_bytes

          entries.each do |entry|
            name = entry[:name]
            relative = name.sub(%r{\A\./}, "")
            next if relative.empty?

            target = Reach::Untar.safe_path(root, relative)
            mode = entry[:mode]
            if name.end_with?("/") || (mode && (mode & S_IFMT) == S_IFDIR)
              FileUtils.mkdir_p(target)
            elsif mode && (mode & S_IFMT) == S_IFLNK
              raise Reach::Error, "reach: symlinks cannot be extracted on this platform" if Reach::Untar.windows?

              link = read_small(io, entry)
              Reach::Untar.check_link(root, target, link, name)
              FileUtils.mkdir_p(File.dirname(target))
              FileUtils.rm_f(target)
              File.symlink(link, target)
              written << target
            else
              FileUtils.mkdir_p(File.dirname(target))
              written << target
              write_entry(io, entry, target, budget)
              count += 1
            end
          end
        end
      rescue StandardError
        if fresh
          FileUtils.rm_rf(root)
        else
          written.each { |path| FileUtils.rm_f(path) }
        end
        raise
      end
      count
    end

    def central_directory(io)
      size = io.size
      tail_len = [size, MAX_COMMENT].min
      io.seek(size - tail_len)
      tail = io.read(tail_len)
      index = tail.rindex([EOCD_SIG].pack("V"))
      raise Reach::Error, "reach: the archive has no end record" unless index

      eocd = tail[index, 22]
      raise Reach::Error, "reach: the archive end record is cut short" unless eocd && eocd.bytesize == 22

      total = eocd[10, 2].unpack("v").first
      cd_size = eocd[12, 4].unpack("V").first
      cd_offset = eocd[16, 4].unpack("V").first
      if total == 0xFFFF || cd_size == 0xFFFFFFFF || cd_offset == 0xFFFFFFFF
        locator_at = size - tail_len + index - 20
        raise Reach::Error, "reach: the archive's Zip64 locator is missing" if locator_at < 0

        io.seek(locator_at)
        locator = io.read(20)
        raise Reach::Error, "reach: the archive's Zip64 locator is missing" unless locator && locator[0, 4] == [LOCATOR64_SIG].pack("V")

        record_at = locator[8, 8].unpack("Q<").first
        io.seek(record_at)
        record = io.read(56)
        raise Reach::Error, "reach: the archive's Zip64 end record is missing" unless record && record[0, 4] == [EOCD64_SIG].pack("V")

        total = record[32, 8].unpack("Q<").first
        cd_size = record[40, 8].unpack("Q<").first
        cd_offset = record[48, 8].unpack("Q<").first
      end

      io.seek(cd_offset)
      data = io.read(cd_size)
      raise Reach::Error, "reach: the archive's directory is cut short" unless data && data.bytesize == cd_size

      entries = []
      position = 0
      total.times do
        raise Reach::Error, "reach: the archive's directory is damaged" unless data[position, 4] == [CENTRAL_SIG].pack("V")

        fixed = data[position + 4, 42].unpack("vvvvvvVVVvvvvvVV")
        made_by, _needed, flags, method, _time, _date, crc, csize, usize, nlen, elen, clen, _disk, _int, ext, offset = fixed
        name = data[position + 46, nlen].dup.force_encoding("UTF-8")
        extra = data[position + 46 + nlen, elen]
        usize, csize, offset = zip64_fields(extra, usize, csize, offset)
        mode = (made_by >> 8) == 3 ? (ext >> 16) : nil
        entries << { name: name, method: method, crc: crc, csize: csize, usize: usize, offset: offset, mode: mode, flags: flags }
        position += 46 + nlen + elen + clen
      end
      entries
    end

    def zip64_fields(extra, usize, csize, offset)
      cursor = 0
      while cursor + 4 <= extra.bytesize
        id, len = extra[cursor, 4].unpack("vv")
        if id == 0x0001
          body = extra[cursor + 4, len]
          at = 0
          if usize == 0xFFFFFFFF
            usize = body[at, 8].unpack("Q<").first
            at += 8
          end
          if csize == 0xFFFFFFFF
            csize = body[at, 8].unpack("Q<").first
            at += 8
          end
          offset = body[at, 8].unpack("Q<").first if offset == 0xFFFFFFFF
          break
        end
        cursor += 4 + len
      end
      [usize, csize, offset]
    end

    def data_start(io, entry)
      io.seek(entry[:offset])
      header = io.read(30)
      raise Reach::Error, "reach: an archive entry is damaged (#{entry[:name]})" unless header && header[0, 4] == [LOCAL_SIG].pack("V")

      nlen, elen = header[26, 4].unpack("vv")
      entry[:offset] + 30 + nlen + elen
    end

    def each_chunk(io, entry, max_bytes: MAX_ENTRY_BYTES, deadline: nil, budget: nil)
      raise Reach::Error, "reach: an archive entry is encrypted (#{entry[:name]})" if entry[:flags] & 1 == 1

      declared = entry[:usize].to_i
      raise Reach::Error, "reach: an archive entry is larger than allowed (#{entry[:name]})" if declared > max_bytes

      io.seek(data_start(io, entry))
      remaining = entry[:csize]
      inflater = entry[:method] == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS) : nil
      raise Reach::Error, "reach: an archive entry uses an unsupported method (#{entry[:name]})" unless inflater || entry[:method] == 0

      crc = 0
      produced = 0
      begin
        while remaining > 0
          raw = io.read([remaining, CHUNK_BYTES].min)
          raise Reach::Error, "reach: an archive entry is cut short (#{entry[:name]})" if raw.nil? || raw.empty?

          remaining -= raw.bytesize
          if inflater
            inflater.inflate(raw) do |piece|
              produced = account!(entry, produced, piece.bytesize, declared, deadline, budget)
              crc = Zlib.crc32(piece, crc)
              yield piece
            end
          else
            produced = account!(entry, produced, raw.bytesize, declared, deadline, budget)
            crc = Zlib.crc32(raw, crc)
            yield raw
          end
        end
        inflater.finish if inflater
      ensure
        inflater.close if inflater && !inflater.closed?
      end
      raise Reach::Error, "reach: an archive entry failed its checksum (#{entry[:name]})" unless crc == entry[:crc] && produced == declared
    end

    def account!(entry, produced, added, declared, deadline, budget)
      produced += added
      raise Reach::Error, "reach: an archive entry expands past its declared size (#{entry[:name]})" if produced > declared
      raise Reach::Error, "reach: unpacking the archive took longer than allowed" if deadline && Time.now > deadline
      if budget
        budget[:used] += added
        raise Reach::Error, "reach: the archive expands past the allowed size" if budget[:used] > budget[:max]
        raise Reach::Error, "reach: unpacking the archive took longer than allowed" if budget[:deadline] && Time.now > budget[:deadline]
      end
      produced
    end

    def write_entry(io, entry, target, budget = nil)
      FileUtils.rm_f(target)
      begin
        File.open(target, "wb") do |file|
          each_chunk(io, entry, budget: budget) { |piece| file.write(piece) }
        end
      rescue StandardError
        FileUtils.rm_f(target)
        raise
      end
      mode = entry[:mode]
      executable = mode ? (mode & 0o111) != 0 : target =~ /\.(exe|dll|bat|cmd|com)\z/i ? true : false
      File.chmod(executable ? 0o755 : 0o644, target)
    end

    def read_small(io, entry)
      raise Reach::Error, "reach: an archive link is too large (#{entry[:name]})" if entry[:usize] > 4096

      buffer = +""
      each_chunk(io, entry, max_bytes: 4096) { |piece| buffer << piece }
      buffer
    end
  end
end
