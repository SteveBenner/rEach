require "json"
require "yaml"
require "fileutils"

module Reach
  module Guardrails
    KIND = "guardrails"
    MANIFEST_FILE = ".manifest.json"
    BODIES_PREFIX = "directives/"

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
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOGUARD") unless File.file?(directives_path)

      report_mismatches

      directives = YAML.safe_load(File.read(directives_path), permitted_classes: [Symbol]) || []
      course = YAML.safe_load(File.read(course_path)) || {}
      tips = File.file?(tips_path) ? (YAML.safe_load(File.read(tips_path)) || []) : []

      {
        "version" => unpacked_version,
        "directives" => directives,
        "course" => course,
        "tips" => tips
      }
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
      Reach::Gate.current_workspace_path
    rescue StandardError
      nil
    end

    def render_rules(cutout_id:, slice:, behavior:, due:, owned_files:)
      data = load
      lines = []
      lines << "# Course rules for this workspace"
      lines << ""
      lines << "You are helping a student with one slice of a course module. These rules come from the instructors and always apply."
      lines << ""

      numbered = Array(data["directives"]).select { |d| d.is_a?(Hash) && d["opcode"].nil? }
      other = numbered.reject { |d| d["id"].to_s.start_with?("G-CUTOUT-") }
      cutout = numbered.select { |d| d["id"].to_s.start_with?("G-CUTOUT-#{cutout_id}-") }

      index = 1
      (other + cutout).each do |directive|
        lines << "#{index}. #{directive['rule']}"
        index += 1
      end

      table = Reach::Directives.table(slice: slice, guardrails: data)
      unless table.empty?
        lines << ""
        lines << table
      end

      lines << ""
      lines << "Your files: #{Array(owned_files).join(', ')}"
      lines << "Slice: #{cutout_id} (#{slice}) - #{behavior}"
      lines << "Due: #{due}"
      "#{lines.join("\n")}\n"
    end

    def vault_path
      Reach::Paths.guardrails_vault_dir
    end

    def directives_path
      File.join(vault_path, "directives.yml")
    end

    def course_path
      File.join(vault_path, "course.yml")
    end

    def tips_path
      File.join(vault_path, "tips.yml")
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
