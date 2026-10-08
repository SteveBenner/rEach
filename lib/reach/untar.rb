require "zlib"
require "rbconfig"
require "fileutils"
require "rubygems/package"

module Reach
  module Untar
    CHUNK_BYTES = 1_048_576

    module_function

    def extract(gz_path, into:, strip: "runtime/")
      root = File.expand_path(into)
      FileUtils.mkdir_p(root)
      count = 0
      File.open(gz_path, "rb") do |io|
        gz = Zlib::GzipReader.new(io)
        Gem::Package::TarReader.new(gz) do |tar|
          long_name = nil
          long_link = nil
          pax = {}
          tar.each do |entry|
            typeflag = entry.header.typeflag.to_s
            case typeflag
            when "L"
              long_name = read_all(entry).sub(/\0.*\z/m, "")
              next
            when "K"
              long_link = read_all(entry).sub(/\0.*\z/m, "")
              next
            when "x"
              pax = parse_pax(read_all(entry))
              next
            when "g"
              read_all(entry)
              next
            end
            raw_name = long_name || pax["path"] || entry.full_name.to_s
            raw_link = long_link || pax["linkpath"] || entry.header.linkname.to_s
            long_name = nil
            long_link = nil
            pax = {}
            name = raw_name.sub(%r{\A\./}, "")
            next if name.empty? || name == "."

            relative = relative_name(name, strip)
            next if relative.nil?

            target = safe_path(root, relative)
            if entry.directory?
              FileUtils.mkdir_p(target)
            elsif typeflag == "1"
              raise Reach::Error, "reach: the bundle holds a hard link (#{name}); it was not used"
            elsif entry.symlink?
              raise Reach::Error, "reach: symlinks cannot be extracted on this platform" if windows?

              link = raw_link
              check_link(root, target, link, name)
              FileUtils.mkdir_p(File.dirname(target))
              FileUtils.rm_f(target)
              File.symlink(link, target)
            elsif entry.file?
              FileUtils.mkdir_p(File.dirname(target))
              write_entry(entry, target)
              count += 1
            end
          end
        end
      end
      count
    end

    def read_all(entry)
      buffer = +""
      while (chunk = entry.read(CHUNK_BYTES))
        buffer << chunk
      end
      buffer.force_encoding("UTF-8")
    end

    def parse_pax(text)
      records = {}
      data = text.dup.force_encoding("BINARY")
      until data.empty?
        space = data.index(" ")
        break unless space

        length = data[0, space].to_i
        break if length <= space + 1 || length > data.bytesize

        record = data[space + 1, length - space - 2].to_s.force_encoding("UTF-8")
        key, value = record.split("=", 2)
        records[key] = value if key && value
        data = data[length..-1].to_s
      end
      records
    end

    def relative_name(name, strip)
      raise Reach::Error, "reach: the bundle holds an unsafe path (#{name}); it was not used" if unsafe?(name)
      return name if strip.to_s.empty?

      stripped = strip.to_s.chomp("/")
      return nil if name == stripped || name == "#{stripped}/"
      raise Reach::Error, "reach: the bundle holds a path outside #{strip} (#{name}); it was not used" unless name.start_with?(strip)

      remainder = name[strip.length..-1]
      remainder.empty? ? nil : remainder
    end

    def unsafe?(name)
      name.start_with?("/") || name =~ /\A[A-Za-z]:/ || name.include?("\\") || name.split("/").include?("..") || name.include?("\0")
    end

    def safe_path(root, relative)
      raise Reach::Error, "reach: the bundle holds an unsafe path (#{relative}); it was not used" if unsafe?(relative)

      target = File.expand_path(relative, root)
      raise Reach::Error, "reach: the bundle holds a path outside its folder (#{relative}); it was not used" unless within?(root, target)
      unless target == root || within?(physical(root), physical(File.dirname(target)))
        raise Reach::Error, "reach: the bundle holds a path outside its folder (#{relative}); it was not used"
      end

      target
    end

    def physical(path)
      full = File.expand_path(path)
      prefix = full[%r{\A(?:[A-Za-z]:)?/}]
      pending = full[prefix.length..-1].split("/").reject(&:empty?)
      current = prefix
      hops = 0
      until pending.empty?
        part = pending.shift
        next if part == "."

        if part == ".."
          current = File.dirname(current)
          next
        end

        candidate = File.join(current, part)
        if File.symlink?(candidate)
          hops += 1
          raise Reach::Error, "reach: the bundle holds too many nested links; it was not used" if hops > 40

          link = File.readlink(candidate)
          link_prefix = link[%r{\A(?:[A-Za-z]:)?/}]
          if link_prefix
            current = link_prefix
            link = link[link_prefix.length..-1]
          end
          pending = link.split("/").reject(&:empty?) + pending
        else
          current = candidate
        end
      end
      current
    end

    def within?(root, target)
      target == root || target.start_with?(root.end_with?("/") ? root : "#{root}/")
    end

    def check_link(root, target, link, name)
      raise Reach::Error, "reach: the bundle holds an empty link (#{name}); it was not used" if link.empty?

      directory = physical(File.dirname(target))
      resolved = physical(File.expand_path(link, directory))
      raise Reach::Error, "reach: the bundle holds a link that points outside its folder (#{name}); it was not used" unless within?(physical(root), resolved)
    end

    def write_entry(entry, target)
      mode = entry.header.mode.to_i
      FileUtils.rm_f(target)
      File.open(target, "wb") do |file|
        while (chunk = entry.read(CHUNK_BYTES))
          file.write(chunk)
        end
      end
      File.chmod((mode & 0o111).zero? ? 0o644 : 0o755, target)
    end

    def windows?
      RbConfig::CONFIG["host_os"].to_s =~ /mswin|mingw|cygwin/ ? true : false
    end
  end
end
