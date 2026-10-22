require "json"
require "yaml"
require "fileutils"

module Reach
  module Guardrails
    KIND = "guardrails"
    MANIFEST_FILE = ".manifest.json"
    BODIES_PREFIX = "directives/"
    COURSE_POLICY_FILE = "course_policy.json".freeze
    COURSE_POLICY_SCHEMA = "teach.course_policy/v1".freeze
    SPACE_SCOPE = { "slice" => "slice", "root" => "course_root", "extracurricular" => "extracurricular" }.freeze

    class Missing < Reach::Refused
      def to_s
        @rendered ||= Reach::Messages.text("M-GATE-NOGUARD")
      end
    end

    module_function

    def ensure_current
      packages = Reach::Packages.new
      latest = packages.latest_version(KIND)
      return unless latest

      return if unpacked_version == latest && !legacy_bodies?

      unpack(packages, latest)
    end

    def legacy_bodies?
      File.directory?(File.join(vault_path, BODIES_PREFIX))
    end

    def private_body(opcode)
      version = unpacked_version
      return nil unless version

      _header, entries = Reach::Packages.new.open(KIND, version)
      raw = entries["#{BODIES_PREFIX}#{opcode.to_s.downcase}.md"]
      return nil if raw.nil?

      Reach::Directives.split_frontmatter(raw.dup.force_encoding("UTF-8")).last
    rescue StandardError
      nil
    end

    def heal
      packages = Reach::Packages.new
      latest = packages.latest_version(KIND)
      return unless latest
      return if unpacked_version == latest && mismatches.empty?

      unpack(packages, latest)
    rescue StandardError
      nil
    end

    def unpack(packages, version)
      packages.unpack(KIND, version, into: vault_path, skip: [BODIES_PREFIX])
      write_manifest
      File.write(version_marker_path, version.to_s)
    end

    def load
      ensure_current
      raise Missing unless File.file?(directives_path)

      report_mismatches

      course = YAML.safe_load(File.read(course_path)) || {}
      packaged = course_policy
      directives = packaged ? packaged_directives(packaged) : (YAML.safe_load(File.read(directives_path), permitted_classes: [Symbol]) || [])

      data = { "version" => unpacked_version, "directives" => directives, "course" => course }
      policy = Reach::BehaviorPolicy.course(data)
      data.merge("directives" => policy.fetch("directives"), "course" => policy.fetch("parameters").fetch("course"), "policy_source" => packaged ? "course_policy" : "legacy")
    end

    def course_policy
      return nil unless File.file?(course_policy_path)

      data = JSON.parse(File.read(course_policy_path))
      valid = data.is_a?(Hash) && data["schema"] == COURSE_POLICY_SCHEMA && data["directives"].is_a?(Array) && data["overlays"].is_a?(Array) &&
              data["directives"].all? { |row| row.is_a?(Hash) && row["opcode"].is_a?(String) && row["rule"].is_a?(String) && row["id"].is_a?(String) }
      valid ? data : nil
    rescue StandardError
      nil
    end

    def packaged_directives(packaged)
      overlays = packaged["overlays"].select { |entry| entry.is_a?(Hash) && entry["id"].is_a?(String) && entry["rule"].is_a?(String) }.map do |entry|
        { "id" => entry["id"], "scope" => entry["scope"] || "slice", "rule" => entry["rule"] }
      end
      packaged["directives"].map { |row| row.reject { |key, _| key == "body_ref" } } + overlays
    end

    def packaged?
      !course_policy.nil?
    end

    def body_hash(opcode)
      row = Array(course_policy && course_policy["directives"]).find { |entry| entry["opcode"] == opcode.to_s.upcase }
      row && row["body_sha256"]
    end

    def version
      unpacked_version
    rescue StandardError
      nil
    end

    def course_question
      data = load
      data.dig("course", "interview", "course_question")
    rescue StandardError
      nil
    end

    def digest
      return nil unless File.file?(directives_path)

      Reach::Crypto.digest_hex(File.read(directives_path))
    rescue StandardError
      nil
    end

    def write_manifest
      entries = {}
      Dir.glob(File.join(vault_path, "**", "*"), File::FNM_DOTMATCH).sort.each do |file|
        next unless File.file?(file)

        relative = file.sub("#{vault_path}/", "")
        next if relative == MANIFEST_FILE || relative == ".version"

        entries[relative] = Reach::Crypto.digest_hex(File.binread(file))
      end
      File.write(manifest_path, JSON.generate(entries))
    end

    def mismatches
      return [] unless File.file?(manifest_path)

      expected = JSON.parse(File.read(manifest_path))
      expected.keys.sort.reject do |relative|
        file = File.join(vault_path, relative)
        File.file?(file) && Reach::Crypto.digest_hex(File.binread(file)) == expected[relative]
      end
    rescue StandardError
      []
    end

    def report_mismatches
      changed = mismatches
      return if changed.empty?

      Reach::Integrity.report("vault_tampered", detail: changed.join(", "), workspace: current_workspace)
    rescue StandardError
      nil
    end

    def current_workspace
      Reach::Gate.focus_workspace
    rescue StandardError
      nil
    end

    def render_rules(space: "slice", cutout_id: nil, slice: nil, behavior: nil, due: nil, owned_files: nil, mode: "stub")
      @rules_mode = mode.to_s == "full" ? "full" : "stub"
      body = render_space_rules(space: space, cutout_id: cutout_id, slice: slice, behavior: behavior, due: due, owned_files: owned_files)
      section = Reach::AgentControl.rules_section(space)
      section ? "#{section}\n\n#{body}" : body
    end

    def render_space_rules(space:, cutout_id:, slice:, behavior:, due:, owned_files:)
      case space.to_s
      when "extracurricular"
        render_extracurricular_rules
      when "root"
        render_root_rules
      else
        render_slice_rules(cutout_id: cutout_id, slice: slice, behavior: behavior, due: due, owned_files: owned_files)
      end
    end

    def render_slice_rules(cutout_id:, slice:, behavior:, due:, owned_files:)
      data = load
      lines = []
      lines << "# Course rules for this workspace"
      lines << ""
      lines << "You are helping a student with one slice of a course module. These rules come from the instructors and always apply."
      lines << ""

      numbered = Array(data["directives"]).select { |d| d.is_a?(Hash) && d["opcode"].nil? }
      other = numbered.reject { |d| d["id"].to_s.start_with?("G-CUTOUT-") }.select { |d| %w[slice everywhere].include?(rule_scope(d)) }
      cutout = numbered.select { |d| d["id"].to_s.start_with?("G-CUTOUT-#{cutout_id}-") }

      index = 1
      (other + cutout).each do |directive|
        lines << "#{index}. #{directive['rule']}"
        index += 1
      end
      lines << ""
      lines << Reach::BehaviorPolicy.message("TOOLS-RULE")
      lines << ""
      lines << Reach::BehaviorPolicy.message("WAIT-RULE")

      table = rules_table("slice", data, slice: slice)
      tail = ["Your files: #{Array(owned_files).join(', ')}", "Slice: #{cutout_id} (#{slice}) - #{behavior}", "Due: #{due}"]
      assemble("rules.slice", lines, table, tail)
    end

    def assemble(channel_id, head, table, tail)
      blocks = [Reach::AgentControl.channel(channel_id) { head.join("\n") }]
      blocks << Reach::AgentControl.channel("rules.directives") { table } unless table.empty?
      blocks << Reach::AgentControl.channel(channel_id) { tail.join("\n") }
      "#{blocks.join("\n\n")}\n"
    end

    def render_extracurricular_rules
      data = safe_load
      lines = []
      lines << "# Course rules for this folder"
      lines << ""
      lines << "You are helping a student with their own code, outside any assignment. These rules come from the instructors and always apply."
      lines << ""

      numbered = Array(data["directives"]).select { |d| d.is_a?(Hash) && d["opcode"].nil? }
      everywhere = numbered.select { |d| rule_scope(d) == "everywhere" }
      extracurricular = numbered.select { |d| rule_scope(d) == "extracurricular" }
      extracurricular = extracurricular_fallback if extracurricular.empty?

      index = 1
      (everywhere + extracurricular).each do |directive|
        lines << "#{index}. #{directive['rule']}"
        index += 1
      end
      lines << ""
      lines << Reach::BehaviorPolicy.message("TOOLS-RULE")
      lines << ""
      lines << Reach::BehaviorPolicy.message("WAIT-RULE")

      table = rules_table("extracurricular", data)
      tail = ["Folder: #{Reach::Paths.extracurricular_root}", "This is the student's own code folder. Nothing here is graded or submitted."]
      assemble("rules.extracurricular", lines, table, tail)
    end

    def render_root_rules
      data = safe_load
      lines = []
      lines << "# Course rules for this workspace"
      lines << ""
      lines << "This is the top of your course workspace, not a place to write code."
      lines << ""

      numbered = Array(data["directives"]).select { |d| d.is_a?(Hash) && d["opcode"].nil? }
      everywhere = numbered.select { |d| rule_scope(d) == "everywhere" }

      index = 1
      everywhere.each do |directive|
        lines << "#{index}. #{directive['rule']}"
        index += 1
      end
      lines << ""
      lines << Reach::BehaviorPolicy.message("TOOLS-RULE")
      lines << ""
      lines << Reach::BehaviorPolicy.message("WAIT-RULE")

      table = data["policy_source"] == "course_policy" ? rules_table("root", data) : ""
      tail = [
        "Coursework goes in deliverables/<course>/<assignment>/<slice>/; anything else goes in extracurricular/.",
        "From this chat, work on a slice by its full path, or name it with --slice (the slice argument of the reach_* tools); the student does not need to open the slice's own folder or start another chat."
      ]
      assemble("rules.root", lines, table, tail)
    end

    def rule_scope(directive)
      (directive["scope"] || "slice").to_s
    end

    def safe_load
      load
    rescue Reach::Refused
      { "directives" => [] }
    end

    def extracurricular_fallback
      (1..5).map { |index| { "rule" => Reach::BehaviorPolicy.message("EXTRA-RULE-#{index}") } }
    end

    def rules_table(space, data, slice: nil)
      blocks = []
      course = Reach::Directives.course_rows_for(space, data, slice: slice)
      unless course.empty?
        blocks << (["## Course directives", ""] + course.map { |row| Reach::BehaviorPolicy.row_line(row) }).join("\n")
      end
      engineering = engineering_section(space)
      blocks << engineering unless engineering.to_s.empty?
      blocks.join("\n\n")
    end

    def engineering_section(space)
      return "" if space == "root"

      name = "#{space == 'extracurricular' ? 'extra' : 'workspace'}-#{@rules_mode || 'stub'}"
      text = Reach::BehaviorPolicy.generated_section(name)
      return text.rstrip if text

      fallback_section(space)
    end

    def fallback_section(space)
      rows = Reach::BehaviorPolicy.directive_rows.select { |row| space == "slice" || row["opcode"] == "CODEFILE" }
      lines = ["## Engineering directives", ""]
      lines.concat(rows.map { |row| Reach::BehaviorPolicy.row_line(row) })
      lines << ""
      lines << Reach::BehaviorPolicy.message(@rules_mode == "full" ? "WS-POINTER-FULL" : "WS-POINTER")
      if @rules_mode == "full"
        lines << ""
        lines << "## Engineering directive texts"
        lines << ""
        rows.each { |row| lines << row.fetch("body").rstrip << "" }
      end
      lines.join("\n").rstrip
    end

    def vault_path
      Reach::Paths.guardrails_vault_dir
    end

    def directives_path
      File.join(vault_path, "directives.yml")
    end

    def course_policy_path
      File.join(vault_path, COURSE_POLICY_FILE)
    end

    def course_path
      File.join(vault_path, "course.yml")
    end

    def manifest_path
      File.join(vault_path, MANIFEST_FILE)
    end

    def version_marker_path
      File.join(vault_path, ".version")
    end

    def unpacked_version
      return nil unless File.file?(version_marker_path)

      File.read(version_marker_path).strip.to_i
    end
  end
end
