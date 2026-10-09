module Reach
  module SafeFiles
    class Unsafe < StandardError
      attr_reader :relative

      def initialize(relative, reason)
        @relative = relative.to_s
        super("#{reason}: #{@relative}")
      end
    end

    NOFOLLOW = defined?(File::NOFOLLOW) ? File::NOFOLLOW : 0
    READ_CHUNK = 65_536

    module_function

    def read(root, relative, max_bytes: nil)
      full = resolve(root, relative)
      return nil if full.nil?

      before = File.lstat(full)
      raise Unsafe.new(relative, "not a regular file") unless before.file? && !before.symlink?

      File.open(full, File::RDONLY | NOFOLLOW) do |handle|
        stat = handle.stat
        raise Unsafe.new(relative, "file changed while reading") unless same_file?(before, stat) && stat.file?
        raise Unsafe.new(relative, "file too large") if max_bytes && stat.size > max_bytes

        handle.binmode
        data = +""
        while (chunk = handle.read(READ_CHUNK))
          data << chunk
          raise Unsafe.new(relative, "file too large") if max_bytes && data.bytesize > max_bytes
        end
        raise Unsafe.new(relative, "file changed while reading") unless same_file?(before, File.lstat(full))

        data
      end
    rescue Errno::ELOOP, Errno::EMLINK
      raise Unsafe.new(relative, "symbolic link")
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def read_or_skip(root, relative, max_bytes: nil)
      [read(root, relative, max_bytes: max_bytes), nil]
    rescue Unsafe => e
      [nil, e.message.split(":").first]
    rescue SystemCallError
      [nil, "unreadable"]
    end

    def collect(root, relatives, max_bytes: nil)
      files = {}
      skipped = []
      Array(relatives).each do |relative|
        data, reason = read_or_skip(root, relative, max_bytes: max_bytes)
        files[relative] = data
        skipped << { "path" => relative.to_s, "reason" => "unsafe path" } if reason
      end
      [files, skipped]
    end

    def safe?(root, relative)
      read_or_skip(root, relative).last.nil?
    end

    def safe_dir?(root, relative)
      full = resolve(root, relative)
      !full.nil? && File.lstat(full).directory?
    rescue Unsafe, SystemCallError
      false
    end

    def resolve(root, relative)
      name = relative.to_s
      raise Unsafe.new(name, "empty path") if name.empty?
      raise Unsafe.new(name, "unsafe path") if name.include?("\0")
      raise Unsafe.new(name, "absolute path") if name.start_with?("/", "\\") || name.match?(/\A[A-Za-z]:/)

      segments = name.split(%r{[/\\]}).reject(&:empty?)
      raise Unsafe.new(name, "empty path") if segments.empty?
      raise Unsafe.new(name, "path traversal") if segments.include?("..")

      segments = segments.reject { |segment| segment == "." }
      raise Unsafe.new(name, "empty path") if segments.empty?

      base = File.realpath(root.to_s)
      current = base
      segments.each_with_index do |segment, index|
        current = File.join(current, segment)
        begin
          stat = File.lstat(current)
        rescue Errno::ENOENT, Errno::ENOTDIR
          return nil
        end
        raise Unsafe.new(name, "symbolic link") if stat.symlink?
        raise Unsafe.new(name, "not a directory") if index < segments.length - 1 && !stat.directory?
      end
      real = File.realpath(current)
      raise Unsafe.new(name, "outside the workspace") unless within?(base, real)

      current
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def within?(base, path)
      prefix = base.end_with?(File::SEPARATOR) ? base : base + File::SEPARATOR
      path.start_with?(prefix)
    end

    def same_file?(first, second)
      return first.dev == second.dev && first.ino == second.ino if first.ino.to_i != 0 || second.ino.to_i != 0

      first.size == second.size && first.mtime == second.mtime
    end
  end
end
