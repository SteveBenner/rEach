require "open3"
require "json"
require "rbconfig"

module Reach
  module Check
    RUBY_REQUIRE_ALLOWLIST = %w[bigdecimal date json set time].freeze
    GROKIT_ALLOWED = %w[NotImplemented InvalidInput Unavailable CurrencyMismatch].freeze
    STRING_LITERAL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/
    PURE_TOKENS = [
      [/\bFile\b/, "File"], [/\bIO\b/, "IO"], [/\bDir\b/, "Dir"], [/\bopen\(/, "open("], [/`/, "backticks"],
      [/\bsystem\(/, "system("], [/\bspawn\b/, "spawn"], [/\bexec\(/, "exec("], [/\bNet::/, "Net::"], [/\bSocket\b/, "Socket"],
      [/\bENV\b/, "ENV"], [/\bARGV\b/, "ARGV"], [/\$std(in|out|err)\b/, "$stdout"], [/\bputs\b/, "puts"], [/\bprint\b/, "print"],
      [/^\s*p\s+/, "p"], [/\bwarn\b/, "warn"], [/\bTime\.now\b/, "Time.now"], [/\bDate\.today\b/, "Date.today"],
      [/\bProcess\b/, "Process"], [/\brand\b/, "rand"], [/\bRandom\b/, "Random"], [/\bSecureRandom\b/, "SecureRandom"],
      [/\bsleep\b/, "sleep"], [/\bThread\b/, "Thread"], [/\bat_exit\b/, "at_exit"], [/\btrap\b/, "trap"],
      [/\$[a-zA-Z_]/, "a global variable"], [/@@\w+/, "a class variable"], [/\brequire_relative\b/, "require_relative"],
      [/\beval\(/, "eval"], [/\.send\(/, "send("], [/\bdefine_method\b/, "define_method"], [/\balias_method\b/, "alias_method"],
      [/\binstance_variable_set\b/, "instance_variable_set"],
      [/^\s*class\s+(String|Hash|Array|Integer|Float|Object|Kernel|Module)\b/, "reopening a core class"]
    ].freeze
    FLOOR_RULES = [
      [/\A\s*def\s+[A-Za-z_][\w?!]*(\([^)]*\))?\s+=\s*\S/, "an endless method definition; use def ... end"],
      [/\A\s*in\s+[\[{\w:"']/, "pattern matching (case/in); use case/when or if"],
      [/\b_[1-9]\b/, "a numbered block parameter; name the parameter"],
      [/\(\.\.\.\)/, "argument forwarding (...); pass the arguments by name"],
      [/\.filter_map\b/, "filter_map; use map then compact"],
      [/\.except\(/, "Hash#except; use reject"],
      [/[{,(]\s*[a-z_]\w*:\s*[,})]/, "hash shorthand ({x:}); write the value out"]
    ].freeze
    TEST_TOKENS_RUBY = [/require\s+["'](minitest|rspec|test\/unit)/, /\bRSpec\b/, /^\s*describe\s/, /^\s*it\s+["']/, /\bdef test_/, /\bassert(_\w+)?\(/].freeze
    TEST_TOKENS_SVELTE = [/\bvitest\b/, /\bjest\b/, /^\s*describe\(/, /^\s*it\(/, /^\s*expect\(/].freeze
    PANEL_RULES = [
      [/\b(localStorage|sessionStorage|indexedDB)\b|document\.cookie/, "S-STO-001", "browser storage; use store(key) with a declared storage key"],
      [/\bfetch\(|\bXMLHttpRequest\b|\bEventSource\b|\bWebSocket\b/, "S-DAT-001", "a direct request; use the generated client"],
      [/window\.location|\bhistory\.(pushState|replaceState|back|go)/, "S-NAV-001", "writing the location; use navigate or link"],
      [/\bsetInterval\(|\bsetTimeout\(|\brequestAnimationFrame\(/, "S-LIF-001", "a raw timer; use every, after or frame"],
      [/<svelte:(window|document)|\b(window|document)\.addEventListener\(/, "S-KEY-001", "a window or document listener; use shortcut or on"],
      [/position:\s*fixed|\bclass=["'][^"']*\bfixed\b/, "S-OVL-001", "a fixed layer; open it with openOverlay or <Overlay>"],
      [/\.showModal\(|document\.body\.style/, "S-OVL-002", "direct modal or scroll control; use the overlay host"],
      [/\b(vw|vh|dvh|svh|lvh)\b|\bclass=["'][^"']*\b(h|w|min-h|max-h|min-w|max-w)-screen\b/, "S-LAY-001", "viewport sizing; the slot sets the size"],
      [/z-index|\bclass=["'][^"']*\bz-\d/, "S-LAY-002", "a z-index; stacking belongs to the overlay host"],
      [/:global\(/, "S-CSS-004", "a global selector; style the component's own elements"],
      [/\{@html\b/, "S-HTML-004", "raw HTML; render structured content with components"],
      [/\bid=["']/, "S-ID-001", "a literal id; use useId"],
      [/window\.postMessage|\b(window|document)\.dispatchEvent\(/, "S-EVT-003", "a global DOM event; use emit"],
      [/\beval\(|new Function\(|globalThis\[|window\[/, "S-DYN-001", "computed global access; use the primitives directly"]
    ].freeze
    PANEL_VISIBLE = %w[S-OVL-001 S-OVL-002 S-LAY-001 S-CSS-002 S-CSS-003 S-HTML-001 S-STATE-001 S-NAV-002].freeze

    module_function

    def run(workspace, changed: nil, format: :agent, stamp: true)
      meta = Reach::Workspace.metadata(workspace)
      Reach::Seal.stamp(workspace) if stamp
      findings = []
      owned = Array(meta["owned_files"])
      owned = owned.select { |relative| changed.nil? || same_file?(File.join(workspace, relative), changed) } if changed
      owned.each do |relative|
        full = File.join(workspace, relative)
        next unless File.file?(full)

        content = File.binread(full).force_encoding(Encoding::UTF_8)
        case File.extname(relative)
        when ".rb"
          findings.concat(check_ruby(workspace, meta, relative, full, content))
        when ".svelte"
          findings.concat(check_svelte(meta, relative, content))
        end
      end
      findings.concat(shape_findings(workspace, changed))
      record(workspace, changed, findings)
      format == :text ? render_text(findings) : findings
    end

    def same_file?(a, b)
      File.expand_path(a) == File.expand_path(b) || File.basename(a) == File.basename(b.to_s)
    end

    def check_ruby(workspace, meta, relative, full, content)
      findings = []
      findings.concat(syntax_findings(relative, full))
      lines = content.lines.map(&:chomp)
      lines.each_with_index do |line, index|
        number = index + 1
        bare = line.gsub(STRING_LITERAL, "\"\"")
        FLOOR_RULES.each do |pattern, message|
          next if message.start_with?("hash shorthand") && bare.match?(/\A\s*def\s/)

          findings << finding("CK-RUBY-FLOOR", relative, number, "line #{number} uses #{message}", "Rewrite it in the Ruby 2.6 form named") if bare.match?(pattern)
        end
        PURE_TOKENS.each do |pattern, name|
          findings << finding("CK-PURE", relative, number, "line #{number} uses #{name}, which reaches outside input and ports", "Take the value from input or a granted port") if bare.match?(pattern)
        end
        TEST_TOKENS_RUBY.each do |pattern|
          findings << finding("CK-TEST", relative, number, "line #{number} is test code", "Delete it; the instructors' suite is the only test") if line.match?(pattern)
        end
        if bare.match?(/^\s*require\s+["']([^"']+)["']/)
          name = bare[/^\s*require\s+["']([^"']+)["']/, 1]
          findings << finding("CK-PURE", relative, number, "line #{number} requires #{name}, which is not one of #{RUBY_REQUIRE_ALLOWLIST.join(', ')}", "Remove the require") unless RUBY_REQUIRE_ALLOWLIST.include?(name)
        end
        findings.concat(comment_findings_ruby(relative, number, line, index))
        findings.concat(ports_findings(workspace, meta, relative, number, bare))
      end
      findings.concat(shape_findings_ruby(meta, relative, lines))
      findings
    end

    def syntax_findings(relative, full)
      _out, err, status = Open3.capture3(RbConfig.ruby, "-wc", full)
      return [] if status.success? && err.to_s.strip.empty?

      err.to_s.lines.map(&:strip).reject(&:empty?).first(5).map do |text|
        line = text[/:(\d+):/, 1].to_i
        finding("CK-RUBY-SYNTAX", relative, line, text.sub(/\A.*?:\d+: /, ""), "Fix the Ruby so ruby -wc is silent")
      end
    end

    def comment_findings_ruby(relative, number, line, index)
      stripped = line.strip
      return [] if index.zero? && stripped.start_with?("# frozen_string_literal")
      return [] if stripped.start_with?("# reach ") || stripped.start_with?("#!") || stripped.include?("SPDX-License-Identifier")

      if stripped.start_with?("#")
        return [finding("CK-COMMENT", relative, number, "line #{number} is a comment", "Delete it; the plan and README carry the why")]
      end
      if !line.match?(/["']/) && line.match?(/\s#\s/)
        return [finding("CK-COMMENT", relative, number, "line #{number} ends with a comment", "Delete the comment")]
      end
      []
    end

    def ports_findings(workspace, meta, relative, number, bare)
      findings = []
      module_name = camel(meta["module"])
      granted = granted_constants(workspace)
      bare.scan(/\bGrokit::([A-Z]\w*(?:::[A-Z]\w*)*)/).flatten.each do |constant|
        head = constant.split("::").first
        next if GROKIT_ALLOWED.include?(head)
        next if head == module_name
        next if granted.include?(constant)

        findings << finding("CK-PORTS", relative, number, "line #{number} reaches Grokit::#{constant}, which the slice was not given", "Use the granted instructor API named in api/README.md")
      end
      allowed = granted_ports(workspace)
      bare.scan(/\bports\.(\w+)/).flatten.uniq.each do |name|
        next if allowed.include?(name)

        findings << finding("CK-PORTS", relative, number, "line #{number} calls ports.#{name}, which is not granted to this slice", "Only these ports are granted: #{allowed.empty? ? 'none' : allowed.join(', ')}")
      end
      findings
    end

    def granted_ports(workspace)
      file = File.join(workspace, "api", "README.md")
      return [] unless File.file?(file)

      File.readlines(file).map { |line| line[/\bports\.(\w+)/, 1] }.compact.uniq
    rescue StandardError
      []
    end

    def granted_constants(workspace)
      file = File.join(workspace, "api", "README.md")
      return [] unless File.file?(file)

      File.read(file).scan(/\bGrokit::([A-Z]\w*(?:::[A-Z]\w*)*)/).flatten.uniq
    rescue StandardError
      []
    end

    def shape_findings_ruby(meta, relative, lines)
      class_name = meta["class"].to_s
      return [] if class_name.empty?

      parts = class_name.split("::")
      return [] unless parts.length == 4 && parts[0] == "Grokit" && parts[2] == "Behaviours"

      findings = []
      code = lines.each_with_index.reject { |line, index| skippable_line?(line, index) }
      first_code = code.first
      if first_code.nil?
        return [] if lines.all? { |line| line.strip.empty? || line.strip.start_with?("#") }

        return [finding("CK-RUBY-SHAPE", relative, 1, "the file has no module Grokit nest", "Wrap the behaviour in module Grokit / module #{parts[1]} / module Behaviours / class #{parts[3]}")]
      end
      unless first_code[0].strip == "module Grokit"
        findings << finding("CK-RUBY-SHAPE", relative, first_code[1] + 1, "line #{first_code[1] + 1} is outside the module Grokit nest", "Nothing but the two header lines and allowed requires may come before module Grokit")
      end
      expected = ["module Grokit", "module #{parts[1]}", "module Behaviours", "class #{parts[3]}"]
      expected.each_with_index do |text, depth|
        unless lines.any? { |line| line.strip == text }
          findings << finding("CK-RUBY-SHAPE", relative, depth + 3, "the file does not declare `#{text}`", "Declare exactly #{class_name} as the contract's class")
        end
      end
      unless lines.any? { |line| line.strip.match?(/\Adef call\(_?input, _?ports\)\z/) }
        findings << finding("CK-RUBY-SHAPE", relative, 1, "the class has no def call(input, ports)", "Define def call(input, ports) and return the contract's output hash")
      end
      top_level_defs = lines.each_with_index.select { |line, _| line.match?(/\Adef\s/) }
      top_level_defs.each { |_, index| findings << finding("CK-FUSE", relative, index + 1, "line #{index + 1} defines a top-level method", "Move it inside the class as a private method") }
      last_end = lines.rindex { |line| line == "end" }
      if last_end
        lines.each_with_index do |line, index|
          next if index <= last_end || line.strip.empty?

          findings << finding("CK-FUSE", relative, index + 1, "line #{index + 1} is code after the class", "Nothing may follow the module nest")
        end
      end
      lines.each_with_index do |line, index|
        next unless line.match?(/\A\s{0,4}[A-Z][A-Z0-9_]+\s*=/)

        findings << finding("CK-FUSE", relative, index + 1, "line #{index + 1} defines a constant outside the class", "Keep constants inside the class, or pass the value in")
      end
      findings
    end

    def skippable_line?(line, index)
      stripped = line.strip
      return true if stripped.empty?
      return true if stripped.start_with?("#")
      return true if index < 2 && stripped.start_with?("# ")
      return true if stripped.match?(/\Arequire\s+["'](#{RUBY_REQUIRE_ALLOWLIST.join('|')})["']\z/)

      false
    end

    def check_svelte(meta, relative, content)
      findings = []
      lines = content.lines.map(&:chomp)
      unless content.include?('<script lang="ts">')
        findings << finding("CK-PANEL", relative, 1, "the component has no <script lang=\"ts\"> block", "Write the script in TypeScript", rule: "CK-PANEL-TS")
      end
      in_script = false
      lines.each_with_index do |line, index|
        number = index + 1
        in_script = true if line.include?("<script")
        PANEL_RULES.each do |pattern, rule, message|
          findings << finding("CK-PANEL", relative, number, "line #{number} uses #{message}", "See the DOVETAIL directive's seam table", rule: rule) if line.match?(pattern)
        end
        if line.match?(/#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b/) && !line.include?("<!--")
          findings << finding("CK-PANEL", relative, number, "line #{number} has a literal colour", "Use a token class or var(--token)", rule: "S-CSS-003")
        end
        if line.match?(/class=["'][^"']*\[[^\]]+\]/)
          findings << finding("CK-PANEL", relative, number, "line #{number} has an arbitrary-value class", "Use a token", rule: "S-CSS-002")
        end
        if in_script && line.match?(/:\s*any\b|@ts-ignore|as any\b/)
          findings << finding("CK-PANEL", relative, number, "line #{number} uses any or @ts-ignore", "Give it a real type", rule: "CK-PANEL-TS")
        end
        if in_script && line.match?(/^\s*export\s+(function|const|class|default)\b/)
          findings << finding("CK-FUSE", relative, number, "line #{number} exports from the component", "A panel exports nothing; other panels reach it through events")
        end
        if line.match?(/\bfrom\s+["'][^"']*(\.\.\/\.\.\/|\/modules\/)/)
          findings << finding("CK-FUSE", relative, number, "line #{number} imports from another module", "Communicate through a declared event", rule: "S-EVT-001")
        end
        TEST_TOKENS_SVELTE.each do |pattern|
          findings << finding("CK-TEST", relative, number, "line #{number} is test code", "Delete it; the instructors' suite is the only test") if line.match?(pattern)
        end
        findings.concat(comment_findings_svelte(relative, number, line, index, in_script))
        in_script = false if line.include?("</script>")
      end
      findings
    end

    def comment_findings_svelte(relative, number, line, index, in_script)
      stripped = line.strip
      return [] if index.zero? && stripped.start_with?("<!-- reach ")

      if stripped.include?("<!--")
        return [finding("CK-COMMENT", relative, number, "line #{number} is a comment", "Delete it")]
      end
      if in_script && !line.match?(/["'`]/) && (stripped.start_with?("//") || stripped.start_with?("/*") || line.match?(/\s\/\/\s/))
        return [finding("CK-COMMENT", relative, number, "line #{number} is a comment", "Delete it")]
      end
      []
    end

    def shape_findings(workspace, changed)
      Reach::Shape.check(workspace_path: workspace, changed: changed, format: :agent).map do |shape_finding|
        entry = {}
        shape_finding.each { |k, v| entry[k.to_sym] = v }
        entry[:id] ||= "CK-SHAPE"
        entry[:finding_id] ||= "#{entry[:rule]}:#{entry[:file]}"
        entry
      end
    rescue StandardError => e
      [{
        id: "CK-SHAPE",
        rule: nil,
        file: "shape",
        line: nil,
        message: e.message.sub(/\Areach: /, ""),
        fix: "Run reach sync, then raise a hand if the shape check still cannot run",
        classification: :visible,
        finding_id: "CK-SHAPE:unavailable"
      }]
    end

    def finding(id, file, line, message, fix, rule: nil)
      klass = rule && PANEL_VISIBLE.include?(rule) ? :visible : :invisible
      {
        id: id,
        rule: rule,
        file: file,
        line: line,
        message: message,
        fix: fix,
        classification: klass,
        finding_id: "#{rule || id}:#{file}:#{message.sub(/\Aline \d+ /, '')}"
      }
    end

    def record(workspace, changed, findings)
      Reach::Ledger.append(workspace, "write", "path" => relative_of(workspace, changed), "before" => previous_digest(workspace, changed), "after" => digest_of(workspace, changed)) if changed
      Reach::Ledger.append(workspace, "check", "changed" => changed && relative_of(workspace, changed), "findings" => findings.length)
    rescue StandardError
      nil
    end

    def relative_of(workspace, path)
      expanded = File.expand_path(path.to_s, workspace)
      expanded.start_with?(File.expand_path(workspace) + File::SEPARATOR) ? expanded.sub(File.expand_path(workspace) + File::SEPARATOR, "") : path.to_s
    end

    def previous_digest(workspace, path)
      relative = relative_of(workspace, path)
      Reach::Ledger.witnessed(workspace)[relative] || Reach::Workspace.delivered_digest_for(workspace, relative)
    end

    def digest_of(workspace, path)
      full = File.expand_path(path.to_s, workspace)
      File.file?(full) ? Reach::Crypto.digest_hex(File.binread(full)) : nil
    end

    def camel(name)
      name.to_s.split(/[_\s]+/).map { |part| part[0].to_s.upcase + part[1..-1].to_s }.join
    end

    def render_text(findings)
      return Reach::Messages.text("M-CHECK-CLEAN") if findings.empty?

      findings.map { |f| "#{f[:id]}#{f[:rule] ? " (#{f[:rule]})" : ''} #{f[:file]}: #{f[:message]}. #{f[:fix]}." }.join("\n")
    end
  end
end
