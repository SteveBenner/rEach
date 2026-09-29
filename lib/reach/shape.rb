require "open3"
require "json"
require "fileutils"
require "rbconfig"
require "tmpdir"

module Reach
  module Shape
    INVISIBLE_RULES = %w[
      S-LIF-001 S-ID-001 S-STO-001 S-DAT-001 S-EVT-003
      S-KEY-001 S-DYN-001 S-I18N-001 S-CSS-001
    ].freeze

    VISIBLE_RULES = %w[
      S-OVL-001 S-OVL-002 S-LAY-001 S-LAY-003 S-LAY-004 S-CSS-002
      S-CSS-003 S-HTML-001 S-STATE-001 S-NAV-002
    ].freeze

    module_function

    def check(workspace_path:, changed: nil, format: :text)
      unless File.file?(shape_path(workspace_path))
        return format == :text ? "No shape has been published for this slice yet, so there is nothing to check." : []
      end

      findings = run_checker(workspace_path, changed)
      case format
      when :text
        render_text(findings)
      else
        findings
      end
    end

    def brief_path(workspace_path)
      File.join(workspace_path.to_s, "shape", "brief.md")
    end

    def shape_path(workspace_path)
      cutout_id = Reach::Workspace.metadata(workspace_path)["cutout_id"]
      File.join(Reach::Paths.shape_vault_dir, cutout_id.to_s, "shape.json")
    end

    def panel_dir(workspace_path, shape_file)
      module_id = shape_module(shape_file) || Reach::Workspace.metadata(workspace_path)["module"]
      candidate = File.join(File.expand_path(workspace_path.to_s), "modules", module_id.to_s, "panel")
      module_id.to_s.empty? || !File.directory?(candidate) ? File.expand_path(workspace_path.to_s) : candidate
    end

    def shape_module(shape_file)
      value = JSON.parse(File.read(shape_file))["module"]
      value.to_s.empty? ? nil : value.to_s
    rescue JSON::ParserError
      nil
    end

    def checker_command
      vault_exe = File.join(Reach::Paths.shape_vault_dir, "dovetail", "exe", "dovetail")
      return [RbConfig.ruby, vault_exe] if File.file?(vault_exe)

      ["dovetail"]
    end

    def owned_panel_files(workspace_path, module_id)
      prefix = "modules/#{module_id}/panel/"
      Reach::Workspace.owned_files(workspace_path).select { |path| path.start_with?(prefix) && !path.end_with?(".rb") }
    end

    def run_checker(workspace_path, changed)
      shape_file = shape_path(workspace_path)
      panel = panel_dir(workspace_path, shape_file)
      module_id = shape_module(shape_file) || Reach::Workspace.metadata(workspace_path)["module"]
      owned = owned_panel_files(workspace_path, module_id)
      return [] if owned.empty? && !Reach::Workspace.owned_files(workspace_path).empty?

      panel_relative = nil
      if changed
        panel_relative = relative_to(panel, File.expand_path(changed.to_s, workspace_path.to_s))
        return [] unless panel_relative
      end

      reference_panel = owned.empty? ? nil : Reach::Suite.reference_panel_dir(module_id)
      return check_panel(panel, shape_file, panel_relative, workspace_path, panel) unless reference_panel

      Dir.mktmpdir("shapecheck-", Reach::Paths.vault_dir) do |tmp|
        check_dir = File.join(tmp, "panel")
        FileUtils.mkdir_p(check_dir)
        FileUtils.cp_r(Dir.glob(File.join(reference_panel, "*")), check_dir)
        owned.each do |relative_path|
          source = File.join(workspace_path.to_s, relative_path)
          next unless File.file?(source)

          destination = File.join(check_dir, relative_path.sub("modules/#{module_id}/panel/", ""))
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(source, destination)
        end
        check_panel(check_dir, shape_file, panel_relative, workspace_path, panel)
      end
    end

    def check_panel(check_dir, shape_file, panel_relative, workspace_path, workspace_panel)
      args = checker_command + ["check", check_dir, "--shape", shape_file, "--require-signed", "--format", "json"]
      args.push("--changed", panel_relative) if panel_relative
      env = { "DOVETAIL_PUBLIC_KEYS" => signing_key_files.join(File::PATH_SEPARATOR) }
      stdout, stderr, status = Open3.capture3(env, *args)
      report = parse_report(stdout, stderr, status)
      prefix = relative_to(File.expand_path(workspace_path.to_s), workspace_panel)
      report.map { |entry| to_finding(entry, prefix) }
    rescue Errno::ENOENT
      raise Reach::Error, "reach: the shape check could not run: the dovetail checker is not on the PATH"
    end

    def parse_report(stdout, stderr, status)
      unless [0, 1].include?(status.exitstatus)
        detail = stderr.to_s.lines.map(&:strip).reject(&:empty?).first || "dovetail check exited #{status.exitstatus.inspect}"
        raise Reach::Error, "reach: the shape check could not run: #{detail}"
      end
      report = JSON.parse(stdout.to_s)
      findings = report.is_a?(Hash) ? report["findings"] : nil
      raise Reach::Error, "reach: the shape check could not run: dovetail check returned no report" unless findings.is_a?(Array)

      findings
    rescue JSON::ParserError
      raise Reach::Error, "reach: the shape check could not run: dovetail check returned no report"
    end

    def signing_key_files
      install = Reach::Enrol.current || {}
      dir = File.join(Reach::Paths.keys_dir, "teach")
      Array(install["signing_public_keys"]).each_with_object([]) do |key, paths|
        pem = key["pem"].to_s
        next if pem.strip.empty?

        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{key['key_id'].to_s.gsub(/[^A-Za-z0-9._-]/, '_')}.pem")
        File.write(path, pem) unless File.file?(path) && File.read(path) == pem
        paths << path
      end
    end

    def relative_to(base, path)
      return "" if path == base
      return nil unless path.start_with?(base + File::SEPARATOR)

      path[(base.length + 1)..-1]
    end

    def to_finding(entry, prefix)
      rule = entry["rule"]
      file = prefix.to_s.empty? ? entry["file"] : File.join(prefix, entry["file"].to_s)
      {
        id: "CK-SHAPE",
        rule: rule,
        file: file,
        line: entry["line"],
        column: entry["column"],
        message: entry["message"].to_s,
        fix: entry["fix"].to_s,
        severity: entry["severity"],
        classification: classify(rule, entry["severity"]),
        finding_id: "#{rule}:#{file}"
      }
    end

    def classify(rule_id, severity = nil)
      return :invisible if INVISIBLE_RULES.include?(rule_id)
      return :visible if VISIBLE_RULES.include?(rule_id)
      return :invisible if severity == "warning"

      :visible
    end

    def render_text(findings)
      return "reach: shape check found no findings." if findings.empty?

      findings.map do |finding|
        if finding[:classification] == :visible
          Reach::Messages.text("M-SHAPE-VISIBLE", plain_reason: finding[:message].to_s)
        else
          "#{finding[:rule]} at #{finding[:file]}:#{finding[:line]} was fixed automatically."
        end
      end.join("\n")
    end
  end
end
