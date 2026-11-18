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
    GENERATED_FILES = %w[AGENTS.md CLAUDE.md GEMINI.md README.md shape/brief.md].freeze
    RETIRED_DIR = ".reach-retired".freeze

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

    def provision_from_package(assignment: nil)
      migrate_layout!

      packages = Reach::Packages.new
      if assignment
        version = packages.latest_version(KIND, assignment: assignment)
      else
        current = Reach::Pace.current_assignment
        version = current && packages.latest_version(KIND, assignment: current["id"])
        version ||= packages.latest_version(KIND)
      end
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

      document = slice_name == Reach::DocumentFiles::SLICE
      carry_forward(target, assignment, cutout_id, slice_name)
      Reach::Checkpoint.autosave(target, via: "provision") if File.file?(File.join(target, MARKER_DIR, MARKER_FILE))
      prune_stale_kit(target, root, entries)
      kept_files = write_package_entries(target, root, entries, owned)

      write_marker(target, course, assignment, slice, version)
      write_readme(target, slice) unless document
      write_rules_files(target)
      copy_brief(target, cutout_id) unless document
      stamp(target) unless document
      delivered = delivered_relatives(target, root, entries)
      delivered -= %w[README.md shape/brief.md] if document
      write_delivered_digests(target, owned, kept_files, delivered, stub_digests(root, entries, owned))
      lock_down(target, owned, delivered)

      configure_harness(target)

      { "path" => target, "cutout_id" => cutout_id, "slice" => slice_name, "kept_files" => kept_files }
    end

    def package_relatives(root, entries)
      prefix = "#{root}/"
      entries.keys.select { |name| name.start_with?(prefix) && !name.end_with?("/") }.map { |name| name.sub(prefix, "") }.reject(&:empty?)
    end

    def delivered_relatives(target, root, entries)
      generated = GENERATED_FILES.select { |relative| File.file?(File.join(target, relative)) }
      (package_relatives(root, entries) + generated).uniq
    end

    def stub_digests(root, entries, owned)
      prefix = "#{root}/"
      owned.each_with_object({}) do |relative, map|
        contents = entries["#{prefix}#{relative}"]
        map[relative] = Reach::Crypto.digest_hex(contents) if contents
      end
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

        if owned_absolute.include?(File.expand_path(full_path)) && File.file?(full_path)
          recorded = delivered_digest_for(target, relative)
          if recorded.nil? || Reach::Crypto.digest_hex(File.binread(full_path)) != recorded
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
      meta = metadata(workspace_path)
      return Reach::DocumentFiles.list(workspace_path) if meta["slice"] == Reach::DocumentFiles::SLICE

      Array(meta["owned_files"])
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
      return "submitted" if latest && latest["kind"] == "ingest"
      if meta["slice"] == Reach::DocumentFiles::SLICE
        return Reach::DocumentFiles.list(workspace_path).empty? ? "not started yet" : "in progress"
      end
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

    def named_slices(name)
      text = name.to_s.strip
      return [] if text.empty?

      wanted = [text, text.tr(" /", "--")].uniq
      slices = current_slices
      exact = slices.select { |path| wanted.include?(File.basename(path)) }
      return exact unless exact.empty?

      slices.select { |path| wanted.any? { |word| File.basename(path).end_with?("-#{word}") } }
    end

    def named_slice!(name)
      found = named_slices(name)
      return found.first if found.length == 1

      names = current_slices.map { |path| File.basename(path) }
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOSLICE") if names.empty?
      raise Reach::Refused, Reach::Gate.pick_slice_text if found.length > 1 || name.to_s.strip.empty?

      raise Reach::Refused, Reach::Messages.text("M-GATE-NOSLICE-NAMED", slice: name.to_s.strip, choices: names.join(", "))
    end

    CURRENT_SLICES_SKIP_DIRS = %w[.git node_modules vendor .bundle tmp .claude .codex .reach-retired].freeze
    CURRENT_SLICES_MAX_DEPTH = 4

    def current_slices
      root = Reach::Paths.workspace_root
      return [] unless Dir.exist?(root)

      root_real = File.expand_path(root)
      extracurricular_real = File.expand_path(Reach::Paths.extracurricular_root)
      pruned = (Reach::Paths.home_dirs + [File.expand_path(Reach::Paths.root), Reach::Paths.legacy_home]).uniq
      slices = []

      Find.find(root_real) do |path|
        next if path == root_real
        next unless File.directory?(path)

        if pruned.include?(path) || (File.dirname(path) == root_real && Reach::Paths.home_name?(File.basename(path)))
          Find.prune
          next
        end

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
      File.open(Reach::Paths.workspace_log, File::WRONLY | File::CREAT | File::APPEND, 0o644) { |file| file.puts(JSON.generate(record)) }
    rescue StandardError
      nil
    end

    def log_workspace_event(event, fields)
      FileUtils.mkdir_p(Reach::Paths.logs_dir)
      record = { "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "event" => event }.merge(fields)
      File.open(Reach::Paths.workspace_log, File::WRONLY | File::CREAT | File::APPEND, 0o644) { |file| file.puts(JSON.generate(record)) }
    rescue SystemCallError => e
      Reach::Debug.fault(e, "workspace:log")
    end

    def carry_forward(target, assignment, cutout_id, slice_name)
      return if File.exist?(target)

      source = same_slice_elsewhere(target, assignment, cutout_id, slice_name).first
      return unless source && !in_use?(source)

      FileUtils.mkdir_p(File.dirname(target))
      File.rename(source, target)
      dismiss_folder(source)
      remove_empty_parents(source)
      log_workspace_event("workspace_carried", "from" => source, "to" => target)
    rescue SystemCallError => e
      Reach::Debug.fault(e, "workspace:carry")
    end

    def same_slice_elsewhere(target, assignment, cutout_id, slice_name)
      wanted = File.expand_path(target)
      deliverable_slices.select do |path|
        next false if File.expand_path(path) == wanted

        meta = metadata(path)
        meta["assignment"].to_s == assignment.to_s && meta["cutout_id"] == cutout_id && meta["slice"] == slice_name
      end.sort_by { |path| -marker_time(path).to_f }
    end

    def consolidate!
      result = { "merged" => [], "warnings" => [] }
      course = safe_current_install&.dig("course", "id").to_s
      groups = deliverable_slices.group_by do |path|
        meta = metadata(path)
        [meta["assignment"].to_s, meta["cutout_id"].to_s, meta["slice"].to_s]
      end
      groups.each do |(_assignment, cutout_id, _slice), paths|
        next if cutout_id.empty? || paths.map { |path| metadata(path)["course"].to_s }.uniq.length < 2

        keeper = paths.find { |path| metadata(path)["course"].to_s == course } || paths.max_by { |path| marker_time(path) }
        (paths - [keeper]).each do |other|
          next if in_use?(other)

          begin
            result["merged"] << merge_into(keeper, other)
          rescue SystemCallError => e
            Reach::Debug.fault(e, "workspace:merge")
            result["warnings"] << "reach: could not move your earlier #{File.basename(other)} work into #{keeper} (#{e.class})"
          end
        end
      end
      result
    end

    def merge_into(keeper, other)
      Reach::Checkpoint.autosave(keeper, via: "provision")
      Reach::Checkpoint.autosave(other, via: "provision")
      keeper_course = safe_name(metadata(keeper)["course"])
      other_course = safe_name(metadata(other)["course"])
      copied = []
      set_aside = []
      student_files(other).each do |relative|
        source = File.join(other, relative)
        next unless student_changed?(other, relative)

        target = File.join(keeper, relative)
        incoming = File.binread(source)
        if !File.file?(target) || !student_changed?(keeper, relative)
          place(keeper, relative, incoming)
          copied << relative
          next
        end

        present = File.binread(target)
        next if present == incoming

        if File.mtime(source) > File.mtime(target)
          aside = "#{relative}.from-#{keeper_course}"
          place(keeper, aside, present)
          place(keeper, relative, incoming)
          copied << relative
        else
          aside = "#{relative}.from-#{other_course}"
          place(keeper, aside, incoming)
        end
        set_aside << aside
      end
      lock_down(keeper, owned_files(keeper), read_delivered_digests(keeper).fetch("readonly", {}).keys)
      retired = retire(other)
      log_workspace_event("workspace_merged", "from" => other, "to" => keeper, "retired" => retired, "copied" => copied, "set_aside" => set_aside)
      { "from" => other, "to" => keeper, "retired" => retired, "copied" => copied, "set_aside" => set_aside }
    end

    def student_files(workspace_path)
      base = Pathname.new(File.expand_path(workspace_path))
      written = WRITABLE_DIRS.flat_map do |dir|
        Dir.glob(File.join(workspace_path, dir, "**", "*")).select { |path| File.file?(path) }.map do |path|
          Pathname.new(File.expand_path(path)).relative_path_from(base).to_s
        end
      end
      (owned_files(workspace_path) + written).uniq
    end

    def student_changed?(workspace_path, relative)
      full = File.join(workspace_path, relative)
      return false unless File.file?(full)

      recorded = read_delivered_digests(workspace_path).fetch("owned", {})[relative]
      recorded.nil? || Reach::Crypto.digest_hex(File.binread(full)) != recorded
    end

    def place(workspace_path, relative, contents)
      full = File.join(workspace_path, relative)
      open_path(workspace_path, File.dirname(relative))
      FileUtils.mkdir_p(File.dirname(full))
      safe_chmod(0o644, full) if File.file?(full)
      File.binwrite(full, contents)
    end

    def retire(path)
      destination = File.join(Reach::Paths.deliverables_root, RETIRED_DIR, Time.now.utc.strftime("%Y%m%dT%H%M%SZ"), *deliverable_parts(path))
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(path, destination)
      dismiss_folder(path)
      remove_empty_parents(path)
      destination
    end

    def deliverable_slices
      root = File.expand_path(Reach::Paths.deliverables_root)
      current_slices.select { |path| File.expand_path(path).start_with?("#{root}#{File::SEPARATOR}") }
    end

    def deliverable_parts(path)
      Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(File.expand_path(Reach::Paths.deliverables_root))).each_filename.to_a
    end

    def dismiss_folder(path)
      Reach::Checkpoint.dismiss_paths!([File.join(Reach::Paths.deliverables_root, *deliverable_parts(path))])
    end

    def remove_empty_parents(path)
      root = File.expand_path(Reach::Paths.deliverables_root)
      parent = File.dirname(File.expand_path(path))
      while parent.start_with?("#{root}#{File::SEPARATOR}") && Dir.exist?(parent) && Dir.empty?(parent)
        Dir.rmdir(parent)
        parent = File.dirname(parent)
      end
    rescue SystemCallError => e
      Reach::Debug.fault(e, "workspace:prune")
    end

    def in_use?(path)
      within_path?(File.realpath(Dir.pwd), path)
    rescue SystemCallError
      false
    end

    def marker_time(path)
      File.mtime(File.join(path, MARKER_DIR, MARKER_FILE))
    rescue SystemCallError
      Time.at(0)
    end

    def safe_name(value)
      value.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
    end

    def space_for(path)
      return nil if path.nil?

      resolved = File.exist?(path) ? File.realpath(path) : File.expand_path(path.to_s)
      return nil if Reach::Paths.inside_home?(resolved)

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

    def space_for_target(absolute)
      return nil if absolute.nil?

      space_for(Reach::Paths.realish(absolute))
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
      ensure_root_readme
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
      texts = {}
      %w[AGENTS.md CLAUDE.md GEMINI.md].each do |name|
        mode = Reach::Harness.rules_mode(name)
        text = texts[mode] ||= Reach::Guardrails.render_rules(space: space, mode: mode)
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
      texts = {}
      %w[AGENTS.md CLAUDE.md GEMINI.md].each do |name|
        mode = Reach::Harness.rules_mode(name)
        text = texts[mode] ||= Reach::Guardrails.render_rules(
          cutout_id: slice["cutout_id"],
          slice: slice["slice"],
          behavior: slice["behavior"],
          due: slice["due"],
          owned_files: slice["owned_files"],
          mode: mode
        )
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
          "assignment_kind" => slice["kind"] || "code",
          "accepts" => slice["accepts"],
          "submit" => slice["submit"] || "reach",
          "submit_note" => slice["submit_note"],
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

    def write_delivered_digests(target, owned, kept_files = [], delivered = [], stub_digests = {})
      owned_absolute = to_absolute(target, owned)
      marker_dir_absolute = File.expand_path(File.join(target, MARKER_DIR))
      delivered_set = delivered.each_with_object({}) { |relative, map| map[relative] = true }
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

        if owned_absolute.include?(absolute)
          digest = Reach::Crypto.digest_hex(File.binread(absolute))
          owned_digests[relative] = kept_files.include?(relative) ? (delivered_digest_for(target, relative) || stub_digests[relative] || digest) : digest
        elsif delivered_set[relative]
          readonly[relative] = Reach::Crypto.digest_hex(File.binread(absolute))
        end
      end

      FileUtils.mkdir_p(File.join(target, MARKER_DIR))
      final = File.join(target, MARKER_DIR, DELIVERED_FILE)
      temp = "#{final}.tmp.#{Process.pid}"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o644) do |handle|
        handle.write(JSON.generate("readonly" => readonly, "owned" => owned_digests))
        handle.flush
        handle.fsync
      end
      File.rename(temp, final)
    end

    def read_delivered_digests(workspace_path)
      path = File.join(workspace_path, MARKER_DIR, DELIVERED_FILE)
      return { "readonly" => {}, "owned" => {} } unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      { "readonly" => {}, "owned" => {} }
    end

    def lock_down(target, owned, delivered = [])
      owned_absolute = to_absolute(target, owned)
      owned_dirs = owned_absolute.map { |path| File.dirname(path) }
      delivered_absolute = to_absolute(target, delivered)
      delivered_set = delivered_absolute.each_with_object({}) { |path, map| map[path] = true }
      delivered_dirs = {}
      delivered_absolute.each do |path|
        directory = File.dirname(path)
        until delivered_dirs[directory] || directory == File.expand_path(target) || directory == File.dirname(directory)
          delivered_dirs[directory] = true
          directory = File.dirname(directory)
        end
      end

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
          if owned_dirs.include?(absolute)
            safe_chmod(0o755, absolute)
          elsif delivered_dirs[absolute]
            safe_chmod(0o555, absolute)
          else
            ensure_owner_access(absolute, 0o700)
          end
        elsif owned_absolute.include?(absolute)
          safe_chmod(0o644, absolute)
        elsif delivered_set[absolute]
          safe_chmod(0o444, absolute)
        else
          ensure_owner_access(absolute, 0o600)
        end
      end
    end

    def ensure_owner_access(path, bits)
      return if File.symlink?(path)

      mode = File.stat(path).mode & 0o7777
      safe_chmod(mode | bits, path) unless mode & bits == bits
    rescue SystemCallError
      nil
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

    def ensure_root_readme
      path = Reach::Paths.root_readme_file
      return false if File.exist?(path) || !Dir.exist?(File.dirname(path))

      Reach::StateFile.write_atomic(path, Reach::Messages.text("M-REACH-WORK-README"), mode: 0o644)
      true
    rescue StandardError
      false
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
