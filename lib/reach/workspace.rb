require "fileutils"
require "json"
require "find"
require "pathname"

module Reach
  module Workspace
    KIND = "workspace"
    MARKER_DIR = ".reach"
    MARKER_FILE = "slice.json"
    DELIVERED_FILE = "delivered.json"
    NEVER_LOCKABLE_DIRS = %w[.reach .claude .codex].freeze
    NEVER_LOCKABLE_FILES = %w[.mcp.json].freeze
    WRITABLE_DIRS = %w[qualify/features qualify/step_definitions].freeze

    DEFAULT_README_LINES = [
      "# {cutout_id} - {slice} slice",
      "",
      "**What it should do:** {behavior}",
      "",
      "**Input:** {input}",
      "**Output:** {output}",
      "",
      "**Your files:** {owned_files}",
      "**You can use:** {instructor_apis}",
      "",
      "**How it's checked:** your AI partner proves the work with checks of its own before anything is submitted, and the course server runs the instructors' checks that decide your grade.",
      "",
      "**Where it shows up:** {panel_slice}",
      "",
      "Start by asking your AI partner to explain the input, the output and the first scenario in plain words."
    ].freeze

    DEFAULT_README = "#{DEFAULT_README_LINES.join("\n")}\n"

    module_function

    def provision_from_package
      migrate_layout!

      packages = Reach::Packages.new
      version = packages.latest_version(KIND)
      return [] unless version

      _header, entries = packages.open(KIND, version)
      manifest = JSON.parse(entries.fetch("slices.json", "{}"))
      course = manifest["course"]
      assignment = manifest["assignment"]

      Array(manifest["slices"]).map do |slice|
        provision_slice(course, assignment, slice, entries, version)
      end
    end

    def provision_slice(course, assignment, slice, entries, version)
      cutout_id = slice["cutout_id"]
      slice_name = slice["slice"]
      root = slice["root"] || "#{cutout_id}-#{slice_name}"
      owned = Array(slice["owned_files"])
      target = Reach::Paths.workspace_path(course, assignment, cutout_id, slice_name)

      prune_stale_kit(target, root, entries)
      kept_files = write_package_entries(target, root, entries, owned)

      write_marker(target, course, assignment, slice, version)
      write_readme(target, slice)
      write_rules_files(target)
      copy_brief(target, cutout_id)
      stamp(target)
      write_delivered_digests(target, owned, kept_files)
      lock_down(target, owned)

      configure_harness(target)

      { "path" => target, "cutout_id" => cutout_id, "slice" => slice_name, "kept_files" => kept_files }
    end

    def prune_stale_kit(target, root, entries)
      prefix = "#{root}/"
      wanted = entries.keys.select { |name| name.start_with?(prefix) }.map { |name| name.sub(prefix, "") }
      delivered = read_delivered_digests(target).fetch("readonly", {}).keys.select { |relative| relative.start_with?("qualify/kit/") }
      (delivered - wanted).each do |relative|
        full_path = File.join(target, relative)
        next unless File.file?(full_path)

        open_path(target, File.dirname(relative))
        FileUtils.rm_f(full_path)
      end
    end

    def write_package_entries(target, root, entries, owned)
      prefix = "#{root}/"
      kept_files = []
      owned_absolute = to_absolute(target, owned)

      entries.each do |name, contents|
        next unless name.start_with?(prefix)

        relative = name.sub(prefix, "")
        next if relative.empty?

        full_path = File.join(target, relative)

        if owned_absolute.include?(File.expand_path(full_path))
          if File.file?(full_path) && delivered_digest_for(target, relative) &&
             Reach::Crypto.digest_hex(File.binread(full_path)) != delivered_digest_for(target, relative)
            kept_files << relative
            next
          end
        end

        open_path(target, File.dirname(relative))
        FileUtils.mkdir_p(File.dirname(full_path))
        safe_chmod(0o644, full_path) if File.file?(full_path)
        File.open(full_path, "wb") { |f| f.write(contents) }
      end

      kept_files
    end

    def open_path(target, relative_dir)
      current = File.expand_path(target)
      relative_dir.to_s.split("/").each do |segment|
        next if segment.empty? || segment == "."

        current = File.join(current, segment)
        safe_chmod(0o755, current) if File.directory?(current)
      end
    end

    def writable_path?(relative)
      WRITABLE_DIRS.any? { |dir| relative == dir || relative.start_with?("#{dir}/") }
    end

    def delivered_digest_for(target, relative)
      read_delivered_digests(target).fetch("owned", {})[relative]
    end

    def metadata(workspace_path)
      path = File.join(workspace_path, MARKER_DIR, MARKER_FILE)
      return {} unless File.file?(path)

      JSON.parse(File.read(path))
    end

    def owned_files(workspace_path)
      Array(metadata(workspace_path)["owned_files"])
    end

    def verify(workspace_path)
      digests = read_delivered_digests(workspace_path).fetch("readonly", {})
      digests.all? do |relative_path, expected_digest|
        absolute = File.join(workspace_path, relative_path)
        File.file?(absolute) && Reach::Crypto.digest_hex(File.binread(absolute)) == expected_digest
      end
    end

    def changed_owned_files(workspace_path)
      digests = read_delivered_digests(workspace_path).fetch("owned", {})
      digests.select do |relative_path, expected_digest|
        absolute = File.join(workspace_path, relative_path)
        !File.file?(absolute) || Reach::Crypto.digest_hex(File.binread(absolute)) != expected_digest
      end.keys
    end

    def state_word(workspace_path)
      meta = metadata(workspace_path)
      latest = Reach::Receipts.latest_for(cutout_id: meta["cutout_id"], slice: meta["slice"])
      return "graded" if latest && latest["kind"] == "grade"
      return "received" if latest && latest["kind"] == "ingest"
      return "in progress" unless changed_owned_files(workspace_path).empty?

      "not started yet"
    rescue StandardError
      "not started yet"
    end

    def find(cutout_id:, slice:)
      current_slices.find do |path|
        meta = metadata(path)
        meta["cutout_id"] == cutout_id && meta["slice"] == slice
      end
    end

    CURRENT_SLICES_SKIP_DIRS = %w[.git node_modules vendor .bundle tmp .claude .codex].freeze
    CURRENT_SLICES_MAX_DEPTH = 4

    def current_slices
      root = Reach::Paths.workspace_root
      return [] unless Dir.exist?(root)

      root_real = File.expand_path(root)
      extracurricular_real = File.expand_path(Reach::Paths.extracurricular_root)
      slices = []

      Find.find(root_real) do |path|
        next if path == root_real
        next unless File.directory?(path)

        if File.file?(File.join(path, MARKER_DIR, MARKER_FILE))
          slices << path
          Find.prune
          next
        end

        if path == extracurricular_real || CURRENT_SLICES_SKIP_DIRS.include?(File.basename(path))
          Find.prune
          next
        end

        relative = path.sub("#{root_real}#{File::SEPARATOR}", "")
        depth = relative.count(File::SEPARATOR) + 1
        Find.prune if depth > CURRENT_SLICES_MAX_DEPTH
      end
      slices
    end

    def migrate_layout!
      root = Reach::Paths.workspace_root
      result = { "moved" => [], "warnings" => [] }
      return result unless Dir.exist?(root)

      legacy_slice_paths.each do |old_path|
        meta = metadata(old_path)
        course = meta["course"]
        assignment = meta["assignment"]
        cutout_id = meta["cutout_id"]
        slice_name = meta["slice"]
        next unless course && assignment && cutout_id && slice_name

        target = Reach::Paths.workspace_path(course, assignment, cutout_id, slice_name)
        if File.exist?(target)
          result["warnings"] << "reach: #{old_path} could not move to #{target} because it already exists"
          next
        end

        FileUtils.mkdir_p(File.dirname(target))
        File.rename(old_path, target)
        result["moved"] << { "from" => old_path, "to" => target }
        log_workspace_moved(old_path, target)
      end

      result
    end

    def legacy_slice_paths
      deliverables_absolute = File.expand_path(Reach::Paths.deliverables_root)
      current_slices.reject do |path|
        absolute = File.expand_path(path)
        absolute == deliverables_absolute || absolute.start_with?("#{deliverables_absolute}#{File::SEPARATOR}")
      end
    end

    def log_workspace_moved(from, to)
      FileUtils.mkdir_p(Reach::Paths.logs_dir)
      record = { "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "event" => "workspace_moved", "from" => from, "to" => to }
      File.open(Reach::Paths.transcript_log, File::WRONLY | File::CREAT | File::APPEND, 0o644) { |file| file.puts(JSON.generate(record)) }
    rescue StandardError
      nil
    end

    def space_for(path)
      return nil if path.nil?

      resolved = File.exist?(path) ? File.realpath(path) : File.expand_path(path.to_s)

      slice = current_slices.find { |workspace_path| within_path?(resolved, workspace_path) }
      return { "kind" => "slice", "path" => slice } if slice

      extracurricular = Reach::Paths.extracurricular_root
      return { "kind" => "extracurricular", "path" => extracurricular } if within_path?(resolved, extracurricular)

      root = Reach::Paths.workspace_root
      return { "kind" => "root", "path" => root } if within_path?(resolved, root)

      nil
    rescue StandardError
      nil
    end

    def within_path?(resolved, root)
      return false unless File.exist?(root)

      real_root = File.realpath(root)
      resolved == real_root || resolved.start_with?("#{real_root}#{File::SEPARATOR}")
    rescue StandardError
      false
    end

    def provision_extracurricular!
      extracurricular_root = Reach::Paths.extracurricular_root
      FileUtils.mkdir_p(extracurricular_root)
      write_extracurricular_marker(extracurricular_root)
      write_space_rules_files(extracurricular_root, "extracurricular")
      configure_harness(extracurricular_root)

      root = Reach::Paths.workspace_root
      FileUtils.mkdir_p(root)
      write_space_rules_files(root, "root")
      configure_harness(root)
      nil
    end

    def write_extracurricular_marker(extracurricular_root)
      install = safe_current_install
      course_id = install && install["course"] && install["course"]["id"]
      File.write(
        File.join(extracurricular_root, ".reach-space.json"),
        JSON.generate("schema" => "reach.space/v1", "kind" => "extracurricular", "course" => course_id)
      )
    end

    def safe_current_install
      Reach::Enroll.current
    rescue StandardError
      nil
    end

    def write_space_rules_files(target, space)
      text = Reach::Guardrails.render_rules(space: space)
      %w[AGENTS.md CLAUDE.md GEMINI.md].each do |name|
        path = File.join(target, name)
        safe_chmod(0o644, path) if File.file?(path)
        File.write(path, text)
        safe_chmod(0o444, path)
      end
    end

    def write_readme(target, slice)
      path = File.join(target, "README.md")
      return if File.file?(path)

      contract_refs = Array(slice["contract_refs"])
      input = contract_refs.find { |line| line.to_s.start_with?("input ") }
      output = contract_refs.find { |line| line.to_s.start_with?("output ") }
      text = fill_template(
        DEFAULT_README,
        "cutout_id" => slice["cutout_id"],
        "slice" => slice["slice"],
        "behavior" => slice["behavior"],
        "input" => input ? input.sub(/\Ainput /, "") : "",
        "output" => output ? output.sub(/\Aoutput /, "") : "",
        "owned_files" => Array(slice["owned_files"]).join(", "),
        "instructor_apis" => Array(slice["instructor_apis"]).join(", "),
        "panel_slice" => slice["panel_slice"]
      )
      File.write(path, text)
    end

    def write_rules_files(workspace_path)
      slice = metadata(workspace_path)
      text = Reach::Guardrails.render_rules(
        cutout_id: slice["cutout_id"],
        slice: slice["slice"],
        behavior: slice["behavior"],
        due: slice["due"],
        owned_files: slice["owned_files"]
      )
      %w[AGENTS.md CLAUDE.md GEMINI.md].each do |name|
        path = File.join(workspace_path, name)
        safe_chmod(0o644, path) if File.file?(path)
        File.write(path, text)
        safe_chmod(0o444, path)
      end
    end

    def stamp(target)
      Reach::Seal.stamp(target, report: false)
    rescue StandardError
      nil
    end

    def copy_brief(target, cutout_id)
      source = File.join(Reach::Paths.shape_vault_dir, cutout_id, "brief.md")
      return unless File.file?(source)

      dest_dir = File.join(target, "shape")
      safe_chmod(0o755, dest_dir) if File.directory?(dest_dir)
      FileUtils.mkdir_p(dest_dir)
      dest_file = File.join(dest_dir, "brief.md")
      safe_chmod(0o644, dest_file) if File.file?(dest_file)
      FileUtils.cp(source, dest_file)
    end

    def write_marker(target, course, assignment, slice, version)
      dir = File.join(target, MARKER_DIR)
      FileUtils.mkdir_p(dir)
      File.write(
        File.join(dir, MARKER_FILE),
        JSON.generate(
          "course" => course,
          "assignment" => assignment,
          "cutout_id" => slice["cutout_id"],
          "slice" => slice["slice"],
          "kind" => "slice",
          "behavior" => slice["behavior"],
          "due" => slice["due"],
          "owned_files" => slice["owned_files"],
          "tags" => slice["tags"],
          "module" => slice["module"],
          "class" => slice["class"],
          "acceptance_mode" => slice["acceptance_mode"],
          "scenarios" => slice["scenarios"],
          "qualify" => slice["qualify"],
          "package_version" => version
        )
      )
    end

    def write_delivered_digests(target, owned, kept_files = [])
      owned_absolute = to_absolute(target, owned)
      marker_dir_absolute = File.expand_path(File.join(target, MARKER_DIR))
      readonly = {}
      owned_digests = {}

      Find.find(target) do |path|
        next if File.directory?(path)

        absolute = File.expand_path(path)
        relative = Pathname.new(absolute).relative_path_from(Pathname.new(File.expand_path(target))).to_s
        top = relative.split(File::SEPARATOR).first
        next if absolute.start_with?("#{marker_dir_absolute}#{File::SEPARATOR}")
        next if NEVER_LOCKABLE_DIRS.include?(top) || NEVER_LOCKABLE_FILES.include?(top)
        next if writable_path?(relative)

        digest = Reach::Crypto.digest_hex(File.binread(absolute))
        if owned_absolute.include?(absolute)
          owned_digests[relative] = kept_files.include?(relative) ? delivered_digest_for(target, relative) : digest
        else
          readonly[relative] = digest
        end
      end

      FileUtils.mkdir_p(File.join(target, MARKER_DIR))
      File.write(File.join(target, MARKER_DIR, DELIVERED_FILE), JSON.generate("readonly" => readonly, "owned" => owned_digests))
    end

    def read_delivered_digests(workspace_path)
      path = File.join(workspace_path, MARKER_DIR, DELIVERED_FILE)
      return { "readonly" => {}, "owned" => {} } unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      { "readonly" => {}, "owned" => {} }
    end

    def lock_down(target, owned)
      owned_absolute = to_absolute(target, owned)
      owned_dirs = owned_absolute.map { |path| File.dirname(path) }

      Find.find(target) do |path|
        next if File.expand_path(path) == File.expand_path(target)

        absolute = File.expand_path(path)
        relative = Pathname.new(absolute).relative_path_from(Pathname.new(File.expand_path(target))).to_s
        top = relative.split(File::SEPARATOR).first

        if NEVER_LOCKABLE_DIRS.include?(top) || NEVER_LOCKABLE_FILES.include?(top) || writable_path?(relative)
          safe_chmod(File.directory?(absolute) ? 0o755 : 0o644, absolute)
          next
        end

        if File.directory?(absolute)
          mode = owned_dirs.include?(absolute) ? 0o755 : 0o555
          safe_chmod(mode, absolute)
        else
          mode = owned_absolute.include?(absolute) ? 0o644 : 0o444
          safe_chmod(mode, absolute)
        end
      end
    end

    def safe_chmod(mode, path)
      File.chmod(mode, path)
    rescue NotImplementedError, Errno::ENOENT, Errno::EPERM
      nil
    end

    def to_absolute(workspace_path, relative_paths)
      relative_paths.map { |relative| File.expand_path(File.join(workspace_path, relative)) }
    end

    def configure_harness(target)
      Reach::Harness.configure_all(target) if defined?(Reach::Harness)
    rescue StandardError
      nil
    end

    def fill_template(template, fields)
      text = template.dup
      fields.each do |key, value|
        text = text.gsub("{#{key}}", value.to_s)
      end
      text
    end
  end
end
