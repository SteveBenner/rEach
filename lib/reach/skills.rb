# frozen_string_literal: true

require "json"
require "time"
require "yaml"

module Reach
  module Skills
    LOADS_FILE = "skill-loads.json"
    MAX_EVENT_BYTES = 65_536
    STDIN_WAIT_S = 2
    GATE_MODES = %w[advise enforce off].freeze
    DEFAULT_GATE = "advise"
    PLUGIN_PREFIX = "reach:"
    SEEN_KEEP = 20
    ERROR_WINDOW_S = 7 * 86_400
    SKILL_COUNTS = %w[loads in_scope out_of_scope preloaded loads_with_pointer triggers_emitted].freeze
    HARNESS_COUNTS = %w[loads in_scope out_of_scope preloaded].freeze
    NAME_PATTERN = "(?:reach-[a-z][a-z0-9-]*|design-taste-frontend)"
    NAMED_SKILL = /\b(#{NAME_PATTERN})\s+skill\b/.freeze
    SKILL_PATH = %r{skills[/\\](#{NAME_PATTERN})[/\\]SKILL\.md}.freeze
    SKILL_READ = %r{([^\s"'<>|;&()]*skills[/\\](#{NAME_PATTERN})[/\\]SKILL\.md)}.freeze
    SKILL_JOIN = /"skills",\s*"(#{NAME_PATTERN})"/.freeze
    SKILL_LIST = /%w\[([^\]]+)\]/.freeze
    GATE_SKILL_COMMAND = /\bgate["']?\s+["']?skill\b/.freeze
    LIB_FILES = %w[hello.rb setup.rb codex_setup.rb mcp_bridge.rb packet.rb].freeze
    SCOPE_WORDS = {
      "space:slice" => "a slice folder of a course workspace",
      "space:root" => "the course workspace folder",
      "space:extracurricular" => "the extracurricular folder",
      "slice:panel" => "a panel slice",
      "slice:backend" => "a logic slice",
      "slice:document" => "a written-work slice",
      "slice:verification" => "a verification slice"
    }.freeze
    RECORD_ERRORS = [Reach::Error, Reach::StateFile::Held, SystemCallError, JSON::ParserError].freeze

    class Fault < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason)
      end
    end

    module_function

    def index
      surfaces = Reach::BehaviorPolicy.application.fetch("surfaces", {})
      surfaces.values.each_with_object({}) do |surface, found|
        invoke = surface["invoke"]
        found[invoke["name"]] = invoke if surface["kind"] == "skill" && invoke.is_a?(Hash)
      end
    end

    def gate_mode
      section = Reach::Runtime.load_config["skills"]
      raw = section.is_a?(Hash) ? section["gate"] : nil
      value = raw == false ? "off" : raw.to_s
      GATE_MODES.include?(value) ? value : DEFAULT_GATE
    end

    def slice_kind(space)
      return nil unless space && space["kind"] == "slice"

      kind = Reach::Workspace.metadata(space["path"])["slice"].to_s
      Reach::Directives::CODE_SLICES.include?(kind) || kind == "document" ? kind : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def facts(base, space, harness)
      found = base.dup
      if space
        found["space"] = [space["kind"]]
        kind = slice_kind(space)
        found["slice"] = [kind] if kind
      end
      found["harness"] = [harness.to_s] unless harness.to_s.empty?
      found
    end

    def matches?(conditions, facts)
      Array(conditions).any? { |condition| Reach::BehaviorPolicy.condition_matches?(condition, facts) }
    end

    def scope_ok?(invoke, facts)
      scope = Array(invoke["scope"])
      scope.empty? || matches?(scope, facts)
    end

    def preloaded?(invoke, facts)
      matches?(invoke["preloaded"], facts)
    end

    def verdict(invoke, facts)
      return "out_of_scope" unless scope_ok?(invoke, facts)
      return "preloaded" if preloaded?(invoke, facts)

      "in_scope"
    end

    def session_entry(session)
      entry = Reach::StateFile.read(Reach::Directives::INJECTED_FILE).dig("sessions", session.to_s)
      entry.is_a?(Hash) ? entry : {}
    end

    def due(facts, session)
      entry = session_entry(session)
      taken = Array(entry["skills"]) + Array(entry["loaded"])
      index.values.select do |invoke|
        triggers = Array(invoke["triggers"])
        !triggers.empty? && !taken.include?(invoke["name"]) && matches?(triggers, facts) && scope_ok?(invoke, facts) && !preloaded?(invoke, facts)
      end
    end

    def pointer_line(invoke)
      "Load the #{invoke['name']} skill now: #{invoke['summary']}"
    end

    def claim_due(due_skills, session)
      return [] if due_skills.empty?

      fresh = Reach::Directives.update_session(session) do |entry|
        names = due_skills.map { |invoke| invoke["name"] } - Array(entry["skills"])
        entry["skills"] = Array(entry["skills"]) + names
        names
      end
      fresh.each { |name| bump_skill(name, "triggers_emitted") }
      due_skills.select { |invoke| fresh.include?(invoke["name"]) }.map { |invoke| pointer_line(invoke) }
    end

    def note_pointer(session, name)
      return nil if session.to_s.empty?

      fresh = Reach::Directives.update_session(session) do |entry|
        given = Array(entry["skills"]).include?(name)
        entry["skills"] = Array(entry["skills"]) + [name] unless given
        !given
      end
      bump_skill(name, "triggers_emitted") if fresh
      nil
    rescue *RECORD_ERRORS => e
      Reach::Debug.fault(e, "skills:pointer")
      nil
    end

    def note_persona(session)
      return nil if session.to_s.empty?

      Reach::Directives.update_session(session) { |entry| entry["persona"] = true }
      nil
    rescue *RECORD_ERRORS => e
      Reach::Debug.fault(e, "skills:persona")
      nil
    end

    def message_triggers
      digest = Reach::BehaviorPolicy.bundle["digest"]
      return @message_triggers[1] if @message_triggers && @message_triggers[0] == digest

      table = {}
      index.each_value do |invoke|
        Array(invoke["triggers"]).each do |condition|
          kind, argument = condition.to_s.split(":", 2)
          next unless kind == "message" && !argument.to_s.empty?

          table[argument] = (table[argument] || []) + [invoke["name"]]
        end
      end
      @message_triggers = [digest, table]
      @message_triggers[1]
    end

    def note_message(id)
      names = message_triggers[id.to_s]
      return nil if names.nil? || names.empty?

      names.each { |name| bump_skill(name, "triggers_emitted") }
      nil
    rescue Reach::BehaviorPolicy::Invalid
      nil
    rescue *RECORD_ERRORS => e
      Reach::Debug.fault(e, "skills:message")
      nil
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def hash_at(state, key)
      state[key] = {} unless state[key].is_a?(Hash)
      state[key]
    end

    def skill_row(state, name)
      table = hash_at(state, "skills")
      row = table[name].is_a?(Hash) ? table[name] : {}
      SKILL_COUNTS.each { |key| row[key] = row[key].to_i }
      row["last_at"] = row["last_at"].to_s
      table[name] = row
    end

    def harness_row(state, harness)
      table = hash_at(state, "harnesses")
      row = table[harness].is_a?(Hash) ? table[harness] : {}
      HARNESS_COUNTS.each { |key| row[key] = row[key].to_i }
      table[harness] = row
    end

    def harness_key(harness)
      value = harness.to_s
      value.match?(/\A[a-z0-9-]{1,24}\z/) ? value : "unknown"
    end

    def bump_skill(name, field)
      Reach::StateFile.update(LOADS_FILE) do |state|
        row = skill_row(state, name)
        row[field] += 1
        row["last_at"] = now_s
      end
    end

    def record_load(name, harness, verdict, pointed)
      Reach::StateFile.update(LOADS_FILE) do |state|
        row = skill_row(state, name)
        totals = harness_row(state, harness_key(harness))
        row["loads"] += 1
        totals["loads"] += 1
        row["loads_with_pointer"] += 1 if pointed
        if verdict
          row[verdict] += 1
          totals[verdict] += 1
        end
        row["last_at"] = now_s
      end
    end

    def record_error
      Reach::StateFile.update(LOADS_FILE) do |state|
        errors = hash_at(state, "gate_errors")
        errors["count"] = errors["count"].to_i + 1
        errors["last_at"] = now_s
      end
    rescue *RECORD_ERRORS => e
      Reach::Debug.fault(e, "skills:error_count")
      nil
    end

    def counts
      state = Reach::StateFile.read(LOADS_FILE)
      {
        "skills" => state["skills"].is_a?(Hash) ? state["skills"] : {},
        "harnesses" => state["harnesses"].is_a?(Hash) ? state["harnesses"] : {},
        "gate_errors" => state["gate_errors"].is_a?(Hash) ? state["gate_errors"] : {}
      }
    end

    def read_event
      raise Fault.new("stdin_unavailable") if STDIN.tty?
      raise Fault.new("stdin_timeout") unless IO.select([STDIN], nil, nil, STDIN_WAIT_S)

      data = STDIN.read(MAX_EVENT_BYTES + 1)
      raise Fault.new("event_empty") if data.nil? || data.strip.empty?
      raise Fault.new("event_too_large") if data.bytesize > MAX_EVENT_BYTES

      event = JSON.parse(data.dup.force_encoding(Encoding::UTF_8))
      raise Fault.new("event_not_an_object") unless event.is_a?(Hash)

      event
    rescue JSON::ParserError
      raise Fault.new("event_unparseable")
    end

    def requested_skill(event)
      return nil unless event["tool_name"].to_s == "Skill"

      input = event["tool_input"]
      value = input.is_a?(Hash) ? input["skill"] : nil
      return nil unless value.is_a?(String)

      name = value.strip.delete_prefix(PLUGIN_PREFIX)
      name.empty? ? nil : name
    end

    def scope_text(invoke)
      words = Array(invoke["scope"]).map { |condition| SCOPE_WORDS.fetch(condition, condition) }
      words.empty? ? "anywhere" : words.join(" or ")
    end

    def reason(verdict, invoke)
      case verdict
      when "out_of_scope" then Reach::Messages.text("M-SKILL-OUT-OF-SCOPE", skill: invoke["name"], where: scope_text(invoke))
      when "preloaded" then Reach::Messages.text("M-SKILL-PRELOADED", skill: invoke["name"])
      end
    end

    def claim_gate(session, name, token)
      Reach::Directives.update_session(session) do |entry|
        seen = Array(entry["gated"])
        if token.empty? || !seen.include?(token)
          entry["gated"] = (seen + [token]).reject(&:empty?).last(SEEN_KEEP)
          pointed = Array(entry["skills"]).include?(name)
          entry["loaded"] = (Array(entry["loaded"]) + [name]).uniq
          { "pointed" => pointed, "persona" => entry["persona"] == true }
        end
      end
    end

    def judge(event, invoke, harness, space)
      session = Reach::Session.resolve_session_id(event)
      claim = claim_gate(session, invoke["name"], event["tool_use_id"].to_s[0, 128])
      return nil unless claim

      base = Reach::Directives.hook_event("tool", event, session)
      base["event"] = base["event"] + ["SessionStart"] if claim["persona"]
      { "verdict" => verdict(invoke, facts(base, space, harness)), "pointed" => claim["pointed"] }
    end

    def emit(decision, text)
      detail = { "hookEventName" => "PreToolUse" }
      if decision == "deny"
        detail["permissionDecision"] = "deny"
        detail["permissionDecisionReason"] = text
      else
        detail["additionalContext"] = text
      end
      puts JSON.generate("hookSpecificOutput" => detail)
    end

    def gate(harness: nil)
      event = read_event
      name = requested_skill(event)
      return 0 unless name

      invoke = index[name]
      return 0 unless invoke

      cwd = event["cwd"].to_s.empty? ? Reach::Paths.cwd : event["cwd"]
      judged = judge(event, invoke, harness, Reach::Workspace.space_for(cwd))
      return 0 unless judged

      mode = gate_mode
      verdict = mode == "off" ? nil : judged["verdict"]
      record_load(name, harness, verdict, judged["pointed"])
      text = verdict && verdict != "in_scope" ? reason(verdict, invoke) : nil
      emit(mode == "enforce" ? "deny" : "advise", text) if text
      0
    rescue Fault => e
      gate_failure(e.reason)
    rescue Reach::Error, SystemCallError, Reach::StateFile::Held, KeyError, TypeError => e
      gate_failure(failure_reason(e))
    end

    def failure_reason(error)
      return "state_unwritable" if error.is_a?(SystemCallError) || error.is_a?(Reach::StateFile::Held)
      return "policy_unreadable" if error.is_a?(Reach::BehaviorPolicy::Invalid)

      "internal_error"
    end

    def gate_failure(reason)
      record_error
      warn "reach gate skill did not run: #{reason}"
      0
    end

    def tool_texts(event)
      input = event["tool_input"]
      return [] unless input.is_a?(Hash)

      %w[file_path path notebook_path command cmd].map { |key| input[key] }.select { |value| value.is_a?(String) }
    end

    def plugin_skill_reads(event, cwd)
      found = []
      tool_texts(event).each do |text|
        text.scan(SKILL_READ) do |token, name|
          path = File.expand_path(token.tr("\\", "/"), cwd)
          next unless File.file?(path)

          found << name if Reach::Gate.plugin_skill_path?(File.realpath(path))
        end
      end
      found.uniq
    end

    def note_reads(event, harness)
      return nil unless event.is_a?(Hash)

      cwd = event["cwd"].to_s.empty? ? Reach::Paths.cwd : event["cwd"]
      names = plugin_skill_reads(event, cwd)
      return nil if names.empty?

      table = index
      mode = gate_mode
      space = Reach::Workspace.space_for(cwd)
      names.each do |name|
        invoke = table[name]
        next unless invoke

        judged = judge(event, invoke, harness, space)
        next unless judged

        record_load(name, harness, mode == "off" ? nil : judged["verdict"], judged["pointed"])
      end
      nil
    rescue *RECORD_ERRORS => e
      Reach::Debug.fault(e, "skills:read")
      nil
    end

    def listed_skills
      path = File.join(Reach::Runtime.root, "reach.rplugin.yml")
      return nil unless File.file?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      contents = data.is_a?(Hash) ? data["contents"] : nil
      Array(contents.is_a?(Hash) ? contents["skills"] : nil).map { |entry| entry.is_a?(Hash) ? entry["id"].to_s : entry.to_s }
    end

    def directory_problems(table)
      root = File.join(Reach::Runtime.root, "skills")
      found = []
      dirs = File.directory?(root) ? Dir.children(root).select { |entry| File.directory?(File.join(root, entry)) }.sort : []
      (dirs - table.keys).each { |name| found << "R-DOC-SKILLS: skills/#{name} has no skill surface with an invoke block in specs/polispec/behavior.yml" }
      (table.keys - dirs).each { |name| found << "R-DOC-SKILLS: the policy declares the skill #{name} but skills/#{name} is missing" }
      listed = listed_skills
      if listed
        (table.keys - listed).each { |name| found << "R-DOC-SKILLS: #{name} is missing from the skills list of reach.rplugin.yml" }
        (listed - table.keys).each { |name| found << "R-DOC-SKILLS: reach.rplugin.yml lists #{name}, which has no skill surface" }
      end
      found
    end

    def message_problems(table)
      found = []
      messages = Reach::Messages.catalogue(Reach::Messages::DEFAULT_LOCALE).fetch("messages", {})
      named = Hash.new { |hash, key| hash[key] = [] }
      messages.each { |id, text| text.to_s.scan(NAMED_SKILL).flatten.uniq.each { |name| named[id] << name } }
      named.each do |id, names|
        names.each do |name|
          if !table.key?(name)
            found << "R-DOC-SKILLS: message #{id} names the #{name} skill, which does not exist"
          elsif !Array(table[name]["triggers"]).include?("message:#{id}")
            found << "R-DOC-SKILLS: message #{id} names the #{name} skill but that skill does not list message:#{id} in its triggers"
          end
        end
      end
      table.each do |name, invoke|
        Array(invoke["triggers"]).each do |condition|
          kind, id = condition.to_s.split(":", 2)
          next unless kind == "message"

          if !messages.key?(id)
            found << "R-DOC-SKILLS: #{name} lists message:#{id}, which is not a message"
          elsif !named[id].include?(name)
            found << "R-DOC-SKILLS: #{name} lists message:#{id}, but that message does not name the #{name} skill"
          end
        end
      end
      found
    end

    def library_problems(table)
      found = []
      directory = File.join(Reach::Runtime.root, "lib", "reach")
      LIB_FILES.each do |file|
        path = File.join(directory, file)
        next unless File.file?(path)

        text = File.read(path)
        names = text.scan(NAMED_SKILL).flatten + text.scan(SKILL_PATH).flatten + text.scan(SKILL_JOIN).flatten
        text.scan(SKILL_LIST) do |(items)|
          words = items.split
          names.concat(words) if !words.empty? && words.all? { |word| word.match?(/\A#{NAME_PATTERN}\z/) }
        end
        names.uniq.each { |name| found << "R-DOC-SKILLS: lib/reach/#{file} names the #{name} skill, which does not exist" unless table.key?(name) }
      end
      found
    end

    def gate_wired?(path)
      return false unless File.file?(path)

      data = JSON.parse(File.read(path))
      entries = Array(data.is_a?(Hash) ? data.dig("hooks", "PreToolUse") : nil)
      entries.any? do |entry|
        entry.is_a?(Hash) && entry["matcher"] == "Skill" && Array(entry["hooks"]).any? { |hook| hook.is_a?(Hash) && hook["command"].to_s.match?(GATE_SKILL_COMMAND) }
      end
    rescue JSON::ParserError, SystemCallError
      false
    end

    def claude_folders
      folders = Reach::Workspace.current_slices + [Reach::Paths.workspace_root, Reach::Paths.extracurricular_root]
      folders.select { |folder| File.file?(File.join(folder, ".claude", "settings.json")) }.uniq
    end

    def wiring_problems
      found = []
      open = claude_folders.reject { |folder| gate_wired?(File.join(folder, ".claude", "settings.json")) }
      found << "R-DOC-SKILLS: the Claude Code settings of #{open.length} rEach folder(s) have no skill gate - open each with reach work to refresh them" unless open.empty?
      found
    end

    def error_problems
      errors = counts["gate_errors"]
      return [] unless errors["count"].to_i.positive? && recent?(errors["last_at"])

      ["R-DOC-SKILLS: the skill gate did not run #{errors['count'].to_i} time(s), last at #{errors['last_at']}"]
    end

    def recent?(stamp)
      Time.now.utc - Time.parse(stamp.to_s) <= ERROR_WINDOW_S
    rescue ArgumentError, TypeError
      true
    end

    def problems
      table = index
      directory_problems(table) + message_problems(table) + library_problems(table) + wiring_problems + error_problems
    rescue Reach::Error, SystemCallError, KeyError, Psych::SyntaxError => e
      ["R-DOC-SKILLS: the skill declarations could not be checked (#{e.class.name})"]
    end

    def report_lines
      data = counts
      rows = data["skills"]
      return [] if rows.empty?

      lines = ["Skill loads counted on this computer (never sent anywhere):"]
      lines << format("%-24s %6s %9s %13s %10s %12s %9s", "skill", "loads", "in_scope", "out_of_scope", "preloaded", "with_pointer", "triggers")
      rows.keys.sort.each do |name|
        row = rows[name]
        lines << format("%-24s %6d %9d %13d %10d %12d %9d", name, row["loads"].to_i, row["in_scope"].to_i, row["out_of_scope"].to_i, row["preloaded"].to_i, row["loads_with_pointer"].to_i, row["triggers_emitted"].to_i)
      end
      data["harnesses"].keys.sort.each do |harness|
        row = data["harnesses"][harness]
        lines << format("harness %-16s %6d loads, %d in scope, %d out of scope, %d preloaded", harness, row["loads"].to_i, row["in_scope"].to_i, row["out_of_scope"].to_i, row["preloaded"].to_i)
      end
      lines
    end
  end
end
