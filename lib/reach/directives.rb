require "yaml"

module Reach
  module Directives
    LABEL_WIDTH = 20
    RULE_WIDTH = 88
    POINTER_WIDTH = 26
    ENFORCE_WIDTH = 22
    TABLE_LIMIT = 6000
    ROUTE = "/api/v1/directives".freeze
    OPCODE_PATTERN = /\A[A-Z][A-Z0-9]{2,9}\z/
    ALIAS_PATTERN = /\A[A-Z]\z/
    TIERS = %w[public private].freeze
    SLICES = %w[all code document backend panel verification].freeze
    CODE_SLICES = %w[backend panel verification].freeze
    REQUIRED = %w[id opcode alias tier rule when enforce].freeze
    PUBLIC_ALIASES = ("A".."M").to_a.freeze
    PRIVATE_ALIASES = ("N".."Z").to_a.freeze
    POINTER_SENTENCE = "Every row binds. When a row's condition applies, run `reach directive <OPCODE>` (or the reach_directive tool) and follow the full text. Rows cover different surfaces and do not override one another; the numbered rules above come first.".freeze
    POINTER_SENTENCE_RENDERED = "Every row binds. When a row's condition applies, run `reach directive <OPCODE>` (or the reach_directive tool) and follow the full text. Rows cover different surfaces and do not override one another.".freeze

    INJECTED_FILE = "injected.json".freeze
    INJECTED_KEEP = 40
    INJECTION_DEFAULTS = { "max_bodies" => 10, "max_bytes" => 40_000, "max_private_fetch" => 3 }.freeze
    PHASE_TASKS = {
      "plan" => %w[plan], "part" => %w[readme], "build" => %w[build fix], "submit" => %w[submit after-task],
      "review" => %w[fix after-task]
    }.freeze
    WRITE_TOOLS = %w[Write Edit MultiEdit NotebookEdit apply_patch write_file patch].freeze
    SHELL_TOOLS = %w[Bash PowerShell shell exec_command terminal].freeze

    module_function

    def public_dir
      File.join(Reach::Runtime.root, "directives")
    end

    def public_files
      Dir.glob(File.join(public_dir, "*.md")).sort.reject { |path| File.basename(path) == "README.md" }
    end

    def public_rows
      Reach::BehaviorPolicy.directive_rows.map { |row| normalize(row.merge("path" => File.join(public_dir, "#{row.fetch('opcode').downcase}.md"))) }
    end

    def private_rows(guardrails = nil)
      data = guardrails || Reach::Guardrails.load
      Array(Reach::BehaviorPolicy.course(data)["directives"]).select { |entry| entry.is_a?(Hash) && entry["opcode"] }.map { |entry| normalize(entry.merge("tier" => "private")) }
    rescue StandardError
      []
    end

    def rows(slice: nil, guardrails: nil)
      (private_rows(guardrails) + public_rows).select { |row| applies_to_slice?(row, slice) }
    end

    def applies_to_slice?(row, slice)
      return false unless Array(row["spaces"] || ["slice"]).include?("slice")

      slice_matches?(row, slice)
    end

    def slice_matches?(row, slice)
      scope = row["slice"].to_s
      return true if slice.nil?

      kind = slice.to_s
      return !(scope == "code" || CODE_SLICES.include?(scope)) if kind == "document"
      return false if scope == "document"

      scope.empty? || scope == "all" || scope == kind || (scope == "code" && CODE_SLICES.include?(kind))
    end

    def table(slice: nil, guardrails: nil)
      private_lines = private_rows(guardrails).select { |row| applies_to_slice?(row, slice) }.map { |row| render_row(row) }
      public_lines = public_rows.select { |row| applies_to_slice?(row, slice) }.map { |row| render_row(row) }
      lines = []
      unless private_lines.empty?
        lines << "## Course directives"
        lines << ""
        lines.concat(private_lines)
        lines << ""
      end
      unless public_lines.empty?
        lines << "## Engineering directives"
        lines << ""
        lines.concat(public_lines)
        lines << ""
      end
      lines << pointer_sentence unless private_lines.empty? && public_lines.empty?
      lines.join("\n")
    end

    def space_scope(space)
      Reach::Guardrails::SPACE_SCOPE[space.to_s]
    end

    def scope_applies?(row, space)
      scope = (row["scope"] || "everywhere").to_s
      return false if scope == "repo"

      scope == "everywhere" || (!space.nil? && scope == space_scope(space))
    end

    def course_rows_for(space, guardrails, slice: nil)
      private_rows(guardrails).select do |row|
        scope_applies?(row, space) && (space != "slice" || slice_matches?(row, slice))
      end
    end

    def all_rows(space, guardrails = nil)
      data = guardrails || Reach::Guardrails.safe_load
      public_part = Reach::BehaviorPolicy.directive_rows.select { |row| scope_applies?(row, space) }
      public_part + course_rows_for(space, data)
    end

    def hello_rows_text(space, workspace)
      data = Reach::Guardrails.safe_load
      rows = public_hello_rows(space) + course_rows_for(space, data)
      cutout = workspace ? Reach::Workspace.metadata(workspace)["cutout_id"].to_s : ""
      overlays = cutout.empty? ? [] : Array(data["directives"]).select { |entry| entry["opcode"].nil? && entry["id"].to_s.start_with?("G-CUTOUT-#{cutout}-") }
      lines = rows.map { |row| Reach::BehaviorPolicy.row_line(row) } + overlays.map { |row| Reach::BehaviorPolicy.row_line(row.merge("when" => ["always"], "enforce" => "none")) }
      return nil if lines.empty?

      (["Directive rows. Every row binds. When a row's condition applies and its full text has not been given to you, run `reach directive <OPCODE>` (or the reach_directive tool); rEach also gives you a directive's full text once, the first time its condition applies.", ""] + lines).join("\n")
    rescue StandardError
      nil
    end

    def public_hello_rows(space)
      Reach::BehaviorPolicy.directive_rows.select { |row| space.nil? ? row["scope"].to_s == "everywhere" : scope_applies?(row, space) }
    end

    def injection_settings
      INJECTION_DEFAULTS.merge(Reach::BehaviorPolicy.parameters("directive_injection"))
    rescue StandardError
      INJECTION_DEFAULTS
    end

    def phase_tasks(session)
      thread = Reach::Threads.read["threads"][session.to_s]
      PHASE_TASKS.fetch(thread && thread["phase"], [])
    rescue StandardError
      []
    end

    def tool_event(event)
      input = event["tool_input"].is_a?(Hash) ? event["tool_input"] : {}
      tool = event["tool_name"].to_s
      paths = [input["file_path"], input["path"], input["notebook_path"]].compact.map(&:to_s)
      command = [input["command"], input["cmd"]].compact.map(&:to_s)
      command.each { |text| paths.concat(Reach::Gate.patch_targets(text)) if text.start_with?("*** Begin Patch") }
      tasks = WRITE_TOOLS.include?(tool) || SHELL_TOOLS.include?(tool) ? %w[build fix] : []
      { "event" => ["PreToolUse"], "tool" => [tool], "path" => paths, "command" => command, "task" => tasks }
    rescue StandardError
      { "event" => ["PreToolUse"], "tool" => [event["tool_name"].to_s], "task" => [] }
    end

    def hook_event(kind, event, session)
      case kind.to_s
      when "tool" then tool_event(event).tap { |found| found["task"] = (found["task"] + phase_tasks(session)).uniq }
      when "prompt" then { "event" => ["UserPromptSubmit"], "task" => phase_tasks(session) }
      else { "event" => ["SessionStart", event["source"].to_s].reject(&:empty?), "task" => phase_tasks(session) }
      end
    end

    def injected_for(session)
      Array(Reach::StateFile.read(INJECTED_FILE).dig("sessions", session.to_s, "opcodes"))
    end

    def claim_injected(session, opcodes)
      Reach::StateFile.update(INJECTED_FILE) do |state|
        sessions = state["sessions"] = state["sessions"].is_a?(Hash) ? state["sessions"] : {}
        entry = sessions[session.to_s] ||= { "opcodes" => [] }
        fresh = opcodes - entry["opcodes"]
        entry["opcodes"] = entry["opcodes"] + fresh
        entry["at"] = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        order = (Array(state["order"]) - [session.to_s]) + [session.to_s]
        order.shift.then { |old| sessions.delete(old) } while order.length > INJECTED_KEEP
        state["order"] = order
        fresh
      end
    end

    def inject(kind, event, harness: nil)
      event = {} unless event.is_a?(Hash)
      return nil if event["session_id"].to_s.empty?

      session = Reach::Session.resolve_session_id(event)
      cwd = event["cwd"] || Reach::Paths.cwd
      space = Reach::Workspace.space_for(cwd)
      kind_name = space && space["kind"]
      workspace = space && space["kind"] == "slice" ? space["path"] : nil
      facts = hook_event(kind, event, session)
      settings = injection_settings
      given = injected_for(session)
      candidates = all_rows(kind_name).select { |row| !given.include?(row["opcode"]) && Reach::BehaviorPolicy.when_matches?(row, facts) }
      return nil if candidates.empty?

      texts = {}
      bytes = 0
      fetched = 0
      candidates.each do |row|
        break if texts.size >= settings["max_bodies"].to_i

        if row["tier"] == "public"
          body = public_body(row)
        else
          break if fetched >= settings["max_private_fetch"].to_i

          fetched += 1
          body = remote_body(row, workspace)
          body = Reach::Guardrails.private_body(row["opcode"]) if body.nil?
        end
        next if body.to_s.strip.empty?
        break if bytes + body.bytesize > settings["max_bytes"].to_i && !texts.empty?

        bytes += body.bytesize
        texts[row["opcode"]] = body
      end
      return nil if texts.empty?

      fresh = claim_injected(session, texts.keys)
      selected = texts.select { |opcode, _| fresh.include?(opcode) }
      return nil if selected.empty?

      text = selected.map { |opcode, body| "Directive #{opcode}, full text:\n\n#{body.strip}" }.join("\n\n---\n\n")
      Reach::AgentControl.channel("rules.directives") { text }
    rescue StandardError
      nil
    end

    def pointer_sentence
      Reach::AgentControl.flag?("render") ? POINTER_SENTENCE_RENDERED : POINTER_SENTENCE
    end

    def render_row(row)
      label = row["alias"].to_s.empty? ? "[#{row['opcode']}]" : "[#{row['alias']} · #{row['opcode']}]"
      pointer = "reach directive #{row['opcode']}"
      format("%-#{LABEL_WIDTH}s %-#{RULE_WIDTH}s %-#{POINTER_WIDTH}s ⚙ %-#{ENFORCE_WIDTH}s ⚡ %s", label, row["rule"], pointer, row["enforce"], when_text(row["when"]))
    end

    def when_text(value)
      list = value.is_a?(Array) ? value : value.to_s.delete("[]").split(",").map(&:strip)
      "[#{list.join(', ')}]"
    end

    def find(opcode)
      wanted = opcode.to_s.upcase
      rows.find { |row| row["opcode"] == wanted }
    end

    def show(opcode, workspace: nil)
      row = find(opcode)
      raise Reach::Error, Reach::Messages.text("M-DIRECTIVE-UNKNOWN", opcodes: rows.map { |r| r["opcode"] }.join(", ")) unless row

      body = row["tier"] == "public" ? public_body(row) : private_body(row, workspace)
      Reach::Ledger.append(workspace, "directive", "opcode" => row["opcode"], "tier" => row["tier"]) if workspace
      { "opcode" => row["opcode"], "tier" => row["tier"], "rule" => row["rule"], "body" => body }
    end

    def public_body(row)
      Reach::BehaviorPolicy.directive_rows.find { |entry| entry["opcode"] == row["opcode"] }.fetch("body")
    end

    REFUSAL_CODES = %w[revoked forbidden unauthenticated not_enrolled].freeze

    def private_body(row, workspace = nil)
      body = remote_body(row, workspace)
      body = Reach::Guardrails.private_body(row["opcode"]) if body.nil?
      return body unless body.to_s.strip.empty?

      "#{row['rule']}\n\n#{Reach::Messages.text('M-DIRECTIVE-OFFLINE', opcode: row['opcode'])}"
    end

    def remote_body(row, workspace)
      install = Reach::Enroll.current
      return nil unless install

      query = {}
      if workspace
        meta = Reach::Workspace.metadata(workspace)
        query["cutout_id"] = meta["cutout_id"].to_s unless meta["cutout_id"].to_s.empty?
        query["slice"] = meta["slice"].to_s unless meta["slice"].to_s.empty?
      end
      response = Reach::Client.for_install(install, quick: true).get("#{ROUTE}/#{row['opcode']}", query: query)
      (response.json || {})["body"].to_s
    rescue Reach::RemoteRefused => e
      REFUSAL_CODES.include?(e.code.to_s) ? "" : nil
    rescue StandardError
      nil
    end

    def problems
      found = []
      seen_opcodes = {}
      seen_aliases = {}
      public_files.each do |path|
        row = parse_file(path, "public")
        name = File.basename(path)
        if row.nil?
          found << "#{name}: unreadable frontmatter (#{unreadable_reason(path)})"
          next
        end
        unaliased = row["slice"].to_s == "document"
        REQUIRED.each { |key| found << "#{name}: missing #{key}" if row[key].to_s.empty? && !(unaliased && key == "alias") }
        found << "#{name}: opcode #{row['opcode'].inspect} is not 3-10 uppercase letters or digits" unless row["opcode"].to_s.match?(OPCODE_PATTERN)
        found << "#{name}: alias #{row['alias'].inspect} is not one letter A-M" unless PUBLIC_ALIASES.include?(row["alias"].to_s) || (unaliased && row["alias"].to_s.empty?)
        found << "#{name}: tier must be public" unless row["tier"] == "public"
        found << "#{name}: slice #{row['slice'].inspect} unknown" unless row["slice"].to_s.empty? || SLICES.include?(row["slice"].to_s)
        found << "#{name}: rule longer than #{RULE_WIDTH} characters" if row["rule"].to_s.length > RULE_WIDTH
        found << "#{name}: id must be R-#{row['opcode']}" unless row["id"] == "R-#{row['opcode']}"
        found << "#{name}: file name must be #{row['opcode'].to_s.downcase}.md" unless name == "#{row['opcode'].to_s.downcase}.md"
        found << "#{name}: opcode #{row['opcode']} repeats #{seen_opcodes[row['opcode']]}" if seen_opcodes[row["opcode"]]
        found << "#{name}: alias #{row['alias']} repeats #{seen_aliases[row['alias']]}" if seen_aliases[row["alias"]]
        seen_opcodes[row["opcode"]] = name
        seen_aliases[row["alias"]] = name unless row["alias"].to_s.empty?
      end
      length = table(slice: nil, guardrails: { "directives" => [] }).length
      found << "the public table is #{length} characters, over #{TABLE_LIMIT}" if length > TABLE_LIMIT
      found
    end

    def parse_file(path, tier)
      front, _body = split_frontmatter(File.read(path))
      return nil unless front.is_a?(Hash)

      normalize(front.merge("tier" => tier, "path" => path))
    rescue StandardError
      nil
    end

    def unreadable_reason(path)
      front, _body = split_frontmatter(File.read(path))
      return "no --- block at the top" if front.nil?
      return "the block is not a mapping" unless front.is_a?(Hash)

      "the block could not be read as a directive"
    rescue StandardError => e
      "#{e.class}: #{e.message.sub(/ @ .*\z/m, '')}"
    end

    def normalize(entry)
      row = {}
      entry.each { |k, v| row[k.to_s] = v }
      row["opcode"] = row["opcode"].to_s.upcase
      row["alias"] = row["alias"].to_s.upcase
      row["slice"] = (row["slice"] || "all").to_s
      row["when"] = Array(row["when"]).map(&:to_s)
      row["enforce"] = (row["enforce"] || "none").to_s
      row["spaces"] = row["spaces"] ? Array(row["spaces"]).map(&:to_s) : ["slice"]
      row
    end

    def split_frontmatter(text)
      return [nil, text] unless text.start_with?("---\n")

      closing = text.index("\n---\n", 4)
      return [nil, text] unless closing

      block = text[4...closing]
      front = begin
        YAML.safe_load(block)
      rescue Psych::SyntaxError
        YAML.safe_load(quote_flow_items(block))
      end
      [front, text[(closing + 5)..-1].to_s]
    end

    def quote_flow_items(block)
      block.gsub(/^(\s*[A-Za-z_][\w-]*:\s*)\[([^\]\n]*)\]\s*$/) do
        head = Regexp.last_match(1)
        items = Regexp.last_match(2).split(",").map(&:strip).reject(&:empty?)
        quoted = items.map { |item| item.start_with?("\"", "'") ? item : item.inspect }
        "#{head}[#{quoted.join(", ")}]"
      end
    end
  end
end
