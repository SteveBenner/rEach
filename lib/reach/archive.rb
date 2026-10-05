require "fileutils"
require "rbconfig"

module Reach
  module Archive
    DEFAULT_MAX_MB = 256
    SKIPPED_TOP_FILES = %w[AGENTS.md CLAUDE.md GEMINI.md].freeze
    MAX_NAME_TRIES = 200

    module_function

    def write!(workspace, meta)
      folder = assignment_folder(workspace)
      return { "state" => "failed" } unless folder

      files = collect(folder, workspace)
      return { "state" => "skipped", "reason" => "too_large" } if too_large?(files)

      extras = extras_for(meta)
      return { "state" => "skipped", "reason" => "too_large" } if too_large?(files, extras.sum { |_, data, _| data.bytesize })

      destination = downloads_dir
      FileUtils.mkdir_p(destination)
      base = base_name(meta)
      final = claim(destination, base, files, extras)
      { "state" => "saved", "path" => final, "name" => File.basename(final), "bytes" => File.size(final), "entries" => files.length + extras.length }
    rescue StandardError => e
      begin
        Reach::BrainSpool.log("archive_failed", "error" => e.class.name)
      rescue StandardError
        nil
      end
      { "state" => "failed" }
    end

    def assignment_folder(workspace)
      folder = File.realpath(File.dirname(workspace))
      root = File.realpath(Reach::Paths.deliverables_root)
      folder.start_with?(root + File::SEPARATOR) ? folder : nil
    rescue SystemCallError
      nil
    end

    def collect(folder, current)
      current_real = File.realpath(current)
      workspaces = Dir.children(folder).sort.map { |name| File.join(folder, name) }.select do |path|
        stat = File.lstat(path)
        stat.directory? && !File.basename(path).start_with?(".") && (File.directory?(File.join(path, ".reach")) || File.realpath(path) == current_real)
      end
      workspaces.flat_map do |workspace|
        top = File.basename(workspace)
        walk(workspace, top, true)
      end
    end

    def walk(directory, prefix, top)
      Dir.children(directory).sort.flat_map do |name|
        next [] if top && (name.start_with?(".") || SKIPPED_TOP_FILES.include?(name))

        path = File.join(directory, name)
        stat = File.lstat(path)
        if stat.symlink?
          []
        elsif stat.directory?
          walk(path, "#{prefix}/#{name}", false)
        elsif stat.file?
          [["#{prefix}/#{name}", path, stat.size, stat.mtime]]
        else
          []
        end
      end
    end

    def too_large?(files, extra_bytes = 0)
      limit = max_mb * 1024 * 1024
      files.sum { |entry| entry[2] } + extra_bytes > limit
    end

    def max_mb
      section = Reach::Runtime.load_config["submit"]
      value = section.is_a?(Hash) ? section["archive_max_mb"] : nil
      value.is_a?(Numeric) && value.positive? ? value : DEFAULT_MAX_MB
    rescue StandardError
      DEFAULT_MAX_MB
    end

    def extras_for(meta)
      assignment = meta["assignment"].to_s
      now = Time.now
      extras = Reach::Receipts.list.select { |receipt| receipt["assignment"].to_s == assignment }.map do |receipt|
        ["rEach/receipts/#{receipt["receipt_id"]}.json", JSON.generate(receipt), now]
      end
      unless Reach::Part.questions(assignment).empty?
        extras << ["rEach/own-part.json", JSON.generate(Reach::Part.document(assignment)), now]
      end
      extras
    end

    def lms_name
      given = Reach::CourseProfile.lms_name
      return given if given

      section = Reach::Runtime.load_config["submit"]
      value = section.is_a?(Hash) ? section["lms_name"].to_s.strip : ""
      value.empty? ? nil : value
    rescue StandardError
      nil
    end

    def upload_required?
      return false unless lms_name

      Reach::CourseProfile.lms_name.nil? || Reach::CourseProfile.lms_upload_required?
    rescue StandardError
      false
    end

    def credit(id)
      upload_required? ? " #{Reach::Messages.text(id, lms: lms_name)}" : ""
    end

    def grade_record
      lms_name ? " #{Reach::Messages.text("M-LMS-RECORD", lms: lms_name)}" : ""
    end

    def downloads_dir
      override = ENV["REACH_DOWNLOADS_DIR"].to_s
      return File.expand_path(override) unless override.empty?

      linux = RbConfig::CONFIG["host_os"].to_s.include?("linux")
      configured = linux ? xdg_download_dir : nil
      configured || File.join(Dir.home, "Downloads")
    end

    def xdg_download_dir
      config_home = ENV["XDG_CONFIG_HOME"].to_s.empty? ? File.join(Dir.home, ".config") : ENV["XDG_CONFIG_HOME"]
      file = File.join(config_home, "user-dirs.dirs")
      return nil unless File.file?(file)

      line = File.readlines(file).find { |text| text.match?(/\A\s*XDG_DOWNLOAD_DIR\s*=/) }
      return nil unless line

      value = line.split("=", 2).last.strip
      value = value[1..-2] if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
      value = value.gsub("$HOME", Dir.home).gsub("${HOME}", Dir.home)
      value.empty? || !value.start_with?("/") ? nil : value
    rescue SystemCallError
      nil
    end

    def base_name(meta)
      course = clean(meta["course"])
      assignment = clean(meta["assignment"])
      "#{course}-#{assignment}-#{Reach::CourseTime.stamp(Time.now)}"
    end

    def clean(value)
      value.to_s.gsub(/[^A-Za-z0-9._-]/, "-")
    end

    def claim(destination, base, files, extras)
      claim_zip(destination, base) { |stem| entries(stem, files, extras) }
    end

    def claim_zip(destination, base)
      suffix = 1
      while suffix <= MAX_NAME_TRIES
        stem = suffix == 1 ? base : "#{base}-#{suffix}"
        final = File.join(destination, "#{stem}.zip")
        if File.exist?(final)
          suffix += 1
          next
        end

        tmp = File.join(destination, ".#{stem}.zip.partial-#{Process.pid}")
        begin
          File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |io|
            io.binmode
            Reach::Zip.write(io, yield(stem))
          end
          return final if publish(tmp, final)
        ensure
          FileUtils.rm_f(tmp)
        end
        suffix += 1
      end
      raise Reach::Error, "reach: no free name for the ZIP copy"
    end

    def publish(tmp, final)
      File.link(tmp, final)
      true
    rescue Errno::EEXIST
      false
    rescue SystemCallError
      return false if File.exist?(final)

      File.rename(tmp, final)
      true
    end

    def entries(root, files, extras)
      Enumerator.new do |yielder|
        files.each { |name, path, _size, mtime| yielder << ["#{root}/#{name}", File.binread(path), mtime] }
        extras.each { |name, data, mtime| yielder << ["#{root}/#{name}", data, mtime] }
      end
    end
  end
end
