require "zlib"

module Reach
  module Zip
    LOCAL_SIG = 0x04034b50
    CENTRAL_SIG = 0x02014b50
    EOCD_SIG = 0x06054b50
    MAX_ENTRIES = 65_535
    MAX_SIZE = 0xFFFFFFFF
    EPOCH_YEAR = 1980
    FILE_MODE = 0o100644

    module_function

    def write(io, entries)
      central = []
      offset = 0
      entries.each do |name, bytes, mtime|
        raise Reach::Error, "reach: too many files for a ZIP copy" if central.length >= MAX_ENTRIES

        entry_name = name.to_s.dup.force_encoding("UTF-8").b
        data = bytes.to_s.b
        raise Reach::Error, "reach: a file is too large for a ZIP copy" if data.bytesize >= MAX_SIZE

        crc = Zlib.crc32(data)
        method, payload = compress(data)
        raise Reach::Error, "reach: the ZIP copy is too large" if payload.bytesize >= MAX_SIZE || offset >= MAX_SIZE

        dos_time, dos_date = dos_stamp(mtime)
        header = [LOCAL_SIG, 20, 0x0800, method, dos_time, dos_date, crc, payload.bytesize, data.bytesize, entry_name.bytesize, 0].pack("VvvvvvVVVvv")
        io.write(header)
        io.write(entry_name)
        io.write(payload)
        central << { name: entry_name, method: method, time: dos_time, date: dos_date, crc: crc, csize: payload.bytesize, usize: data.bytesize, offset: offset }
        offset += header.bytesize + entry_name.bytesize + payload.bytesize
      end

      start = offset
      central.each do |entry|
        record = [CENTRAL_SIG, (3 << 8) | 20, 20, 0x0800, entry[:method], entry[:time], entry[:date], entry[:crc], entry[:csize], entry[:usize], entry[:name].bytesize, 0, 0, 0, 0, FILE_MODE << 16, entry[:offset]].pack("VvvvvvvVVVvvvvvVV")
        io.write(record)
        io.write(entry[:name])
        offset += record.bytesize + entry[:name].bytesize
      end
      size = offset - start
      raise Reach::Error, "reach: the ZIP copy is too large" if offset >= MAX_SIZE

      io.write([EOCD_SIG, 0, 0, central.length, central.length, size, start, 0].pack("VvvvvVVv"))
      central.length
    end

    def compress(data)
      return [0, data] if data.empty?

      deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      packed = deflater.deflate(data, Zlib::FINISH)
      deflater.close
      packed.bytesize < data.bytesize ? [8, packed] : [0, data]
    end

    def dos_stamp(mtime)
      time = (mtime.is_a?(Time) ? mtime : Time.at(mtime.to_i)).localtime
      time = Time.local(EPOCH_YEAR, 1, 1, 0, 0, 0) if time.year < EPOCH_YEAR
      time = Time.local(2107, 12, 31, 23, 59, 58) if time.year > 2107
      dos_time = (time.hour << 11) | (time.min << 5) | (time.sec / 2)
      dos_date = ((time.year - EPOCH_YEAR) << 9) | (time.month << 5) | time.day
      [dos_time, dos_date]
    end
  end
end
