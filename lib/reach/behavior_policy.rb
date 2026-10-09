require "json"
require "digest"
require "yaml"

module Reach
  module BehaviorPolicy
    class Invalid < Reach::Refused; end

    SCHEMA = "polispec.behavior/v1".freeze
    COMPILED_SCHEMA = "polispec.behavior.compiled/v1".freeze
    MAX_BYTES = 2 * 1024 * 1024
    CONTROL_EVENTS = {
      "control.pause" => ["C-PAUSE", %w[space active]],
      "control.tool" => ["C-TEST", %w[locked]],
      "control.submit" => ["C-HOLD", %w[active]],
      "control.mcp" => ["C-TEST-TOOL", %w[locked allowed]]
    }.freeze

    module_function

    def path
      File.join(Reach::Runtime.root, "policy", "behavior.json")
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value.fetch(key)) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def digest(value)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
    end

    def freeze_tree(value)
      case value
      when Hash then value.each { |key, item| key.freeze; freeze_tree(item) }
      when Array then value.each { |item| freeze_tree(item) }
      end
      value.freeze
    end

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def bundle
      stat = File.stat(path)
      key = [stat.size, stat.mtime.to_r, stat.ctime.to_r, stat.ino]
      return @bundle if @key == key && @bundle

      raise Invalid, "policy artifact is too large" if stat.size > MAX_BYTES
      candidate = JSON.parse(File.read(path))
      validate_bundle!(candidate)
      @bundle = freeze_tree(candidate)
      @key = key
      @bundle
    rescue SystemCallError, JSON::ParserError, KeyError, TypeError, ArgumentError => e
      raise Invalid, "rEach policy could not be read: #{e.message}"
    end

    def validate_bundle!(candidate)
      unless candidate.is_a?(Hash) && candidate["schema"] == COMPILED_SCHEMA && candidate["policy"].is_a?(Hash)
        raise Invalid, "unrecognized compiled policy"
      end
      doc = candidate.fetch("policy")
      raise Invalid, "policy digest mismatch" unless candidate["digest"] == digest(doc)
      unless doc["schema"] == SCHEMA && doc["id"] == "reach.engineering" && doc["version"].is_a?(Integer) && doc["version"] > 0
        raise Invalid, "unrecognized application policy"
      end
      unless doc["authority"] == { "id" => "reach", "kind" => "application", "authentication" => "release" } && doc.dig("scope", "application") == "reach"
        raise Invalid, "policy authority mismatch"
      end
      raise Invalid, "policy directives are missing" unless doc["directives"].is_a?(Array) && !doc["directives"].empty?
      ids = doc["directives"].map { |row| row.is_a?(Hash) ? row["id"] : nil }
      raise Invalid, "invalid or duplicate directive ids" if ids.include?(nil) || ids.uniq != ids
      doc["directives"].each do |row|
        unless row["tier"] == "public" && row["opcode"].is_a?(String) && row["opcode"].match?(/\A[A-Z][A-Z0-9]{2,9}\z/) && row["body"].is_a?(String) && row["rule"].is_a?(String) && row["when"].is_a?(Array)
          raise Invalid, "invalid engineering directive #{row['id']}"
        end
      end
      params = doc["parameters"]
      unless params.is_a?(Hash) && params["course_defaults"].is_a?(Hash) && params["control"].is_a?(Hash)
        raise Invalid, "policy parameters are missing"
      end
      %w[login limits support student_part module_selection enrollment].each do |section|
        raise Invalid, "missing default #{section}" unless params["course_defaults"][section].is_a?(Hash)
      end
      %w[test_tools].each do |name|
        value = params["control"][name]
        raise Invalid, "invalid control #{name}" unless value.is_a?(Array) && !value.empty? && value.all? { |item| item.is_a?(String) && !item.empty? }
      end
      defaults = params.fetch("course_defaults")
      login = defaults.fetch("login")
      %w[required password].each { |key| raise Invalid, "invalid login #{key}" unless [true, false].include?(login[key]) }
      %w[max_hours lockout_failures lockout_minutes].each { |key| raise Invalid, "invalid login #{key}" unless login[key].is_a?(Numeric) && login[key] > 0 }
      %w[corpus_max_bytes transcript_spool_max_bytes materials_max_bytes import_max_bytes import_max_per_prompt].each do |key|
        value = defaults.fetch("limits")[key]
        raise Invalid, "invalid limit #{key}" unless value.is_a?(Integer) && value > 0
      end
      raise Invalid, "invalid support text" unless defaults.fetch("support")["text"].is_a?(String)
      part = defaults.fetch("student_part")
      raise Invalid, "invalid student-part defaults" unless [true, false].include?(part["required"]) && part["questions"].is_a?(Hash)
      selection = defaults.fetch("module_selection")
      unless %w[instructor student_choice].include?(selection["mode"]) && selection["count"].is_a?(Integer) && selection["count"] > 0 && selection["options"].is_a?(Array) && selection["slices"].is_a?(Array)
        raise Invalid, "invalid module-selection defaults"
      end
      rules = doc["rules"]
      raise Invalid, "policy rules are missing" unless rules.is_a?(Array) && rules.all? { |rule| rule.is_a?(Hash) }
      raise Invalid, "duplicate policy rules" unless rules.map { |rule| rule["id"] }.uniq.size == rules.size
      CONTROL_EVENTS.each do |event, (id, facts)|
        selected = rules.select { |rule| rule["event"] == event }
        unless selected.size == 1 && selected.first["id"] == id && selected.first["mode"] == "declarative" && selected.first["failure"] == "deny"
          raise Invalid, "missing or ambiguous control policy #{id}"
        end
        rule = selected.first
        predicates = rule["all"]
        unless predicates.is_a?(Hash) && predicates.keys.sort == facts.sort && predicates.values.all? { |values| values.is_a?(Array) && !values.empty? }
          raise Invalid, "invalid control facts for #{id}"
        end
        active = event == "control.pause" || event == "control.submit" ? "active" : "locked"
        raise Invalid, "#{id} must require an active control" unless predicates[active] == [true]
        raise Invalid, "#{id} must preserve permitted test tools" if event == "control.mcp" && predicates["allowed"] != [false]
        raise Invalid, "missing control message for #{id}" unless Reach::Messages.catalogue("en-US").fetch("messages").key?(rule["message_id"])
      end
      true
    end

    def application
      bundle.fetch("policy")
    end

    def parameters(name)
      copy(application.fetch("parameters").fetch(name))
    end

    def directive_rows
      copy(application.fetch("directives"))
    end

    def course(data)
      unless data.is_a?(Hash) && data["course"].is_a?(Hash) && data["directives"].is_a?(Array)
        raise Invalid, "the course package contains an unreadable policy"
      end
      given = data.fetch("course")
      rows = data.fetch("directives").map do |entry|
        raise Invalid, "the course package contains an unreadable directive" unless entry.is_a?(Hash) && entry["id"].is_a?(String) && entry["rule"].is_a?(String)
        row = entry.select { |key, _| %w[id opcode alias tier slice scope spaces rule when enforce].include?(key) }
        row["when"] = Array(row["when"] || "always")
        row["enforce"] ||= "none"
        if row["opcode"]
          row["tier"] = "private"
          row["body_ref"] = "reach directive #{row['opcode']}"
        end
        row
      end
      {
        "schema" => SCHEMA, "id" => "reach.course", "version" => [data["version"].to_i, 1].max,
        "authority" => { "id" => "teach", "kind" => "course", "authentication" => "signed-package" },
        "scope" => { "application" => "reach", "spaces" => %w[slice root extracurricular], "course" => given["id"].to_s, "assignment" => given.dig("current_assignment", "id").to_s },
        "directives" => rows, "parameters" => { "course" => copy(given) },
        "rules" => rows.map { |row| course_rule(row) }
      }
    end

    def course_rule(row)
      bindings = {
        "G-SCOPE-1" => "Reach::Gate.write", "G-SCOPE-3" => "Reach::Gate.check_time_and_module!",
        "G-SHAPE-1" => "Reach::Check.run", "G-SHAPE-2" => "Reach::Ladder.blocked_message",
        "G-PART-1" => "Reach::Submit.require_part!", "G-TEST-1" => "Reach::Qualify.run"
      }
      binding = bindings[row["id"]]
      binding ||= case row["enforce"]
                  when "gate:write" then "Reach::Gate.write"
                  when "gate:shell" then "Reach::Gate.shell"
                  end
      {
        "id" => row["id"], "description" => row["rule"], "event" => "course.directive",
        "mode" => binding ? "native" : "advisory", "binding" => binding || "Reach::Guardrails.render_rules",
        "failure" => binding ? "report" : "instruct"
      }
    end

    def guard_bindings
      %w[gate controls submit qualify check agent_control].flat_map do |name|
        owner = "Reach::#{name.split('_').map(&:capitalize).join}"
        file = File.join(Reach::Runtime.root, "lib", "reach", "#{name}.rb")
        File.read(file).scan(/^    (?:  )?def (\w+[!?=]?)[^\n]*\n(.*?)(?=^    (?:  )?def |\z)/m).map do |method, body|
          next unless body.include?("raise_blocked!") || (%w[submit qualify].include?(name) && body.include?("raise Reach::Refused"))
          "#{owner}.#{method}"
        end.compact
      end.uniq.sort
    end

    def agent_control_problems
      contract = application.fetch("parameters").fetch("agent_control_contract")
      actual = Digest::SHA256.hexdigest(File.binread(Reach::AgentControl::BUNDLED_FILE).gsub("\r\n", "\n"))
      actual == contract.fetch("sha256") ? [] : ["R-DOC-POLICY: the instructor-control baseline differs from its declared digest"]
    end

    def decision(event, facts)
      raise Invalid, "unknown control event #{event}" unless CONTROL_EVENTS.key?(event)
      rule = application.fetch("rules").find { |item| item["event"] == event }
      predicates = rule.fetch("all")
      missing = predicates.keys - facts.keys
      raise Invalid, "missing control facts: #{missing.join(', ')}" unless missing.empty?
      matched = predicates.all? { |name, values| values.any? { |value| value.class == facts[name].class && value == facts[name] } }
      matched ? rule : nil
    end

    def ensure!
      bundle
      true
    rescue Invalid
      Reach::Gate.raise_blocked!("M-POLICY-INVALID")
    end

    def projection(row)
      front = row.reject { |key, _| key == "body" }
      "#{YAML.dump(front)}---\n#{row.fetch('body')}"
    end

    def problems
      doc = application
      found = agent_control_problems
      declared = doc.fetch("rules").map { |rule| rule["binding"] }
      (guard_bindings - declared).each { |binding| found << "R-DOC-POLICY: unregistered native guard #{binding}" }
      source = File.join(Reach::Runtime.root, "specs", "polispec", "behavior.yml")
      raw = YAML.safe_load(File.read(source), aliases: false)
      found << "R-DOC-POLICY: compiled policy differs from specs/polispec/behavior.yml" unless digest(raw) == bundle.fetch("digest")
      expected = doc.fetch("directives").map { |row| "#{row.fetch('opcode').downcase}.md" }.sort
      actual = Dir.glob(File.join(Reach::Runtime.root, "directives", "*.md")).map { |file| File.basename(file) }.reject { |file| file == "README.md" }.sort
      found << "R-DOC-POLICY: directive projections are missing or unexpected" unless actual == expected
      doc.fetch("directives").each do |row|
        file = File.join(Reach::Runtime.root, "directives", "#{row.fetch('opcode').downcase}.md")
        found << "R-DOC-POLICY: #{File.basename(file)} differs from its policy source" unless File.file?(file) && File.read(file) == projection(row)
      end
      doc.fetch("rules").reject { |rule| rule["mode"] == "advisory" }.each do |rule|
        owner, method = rule.fetch("binding").split(".", 2)
        raise NameError, "binding outside Reach" unless owner.match?(/\AReach::[A-Z][A-Za-z0-9]*\z/)
        object = owner.split("::").reject(&:empty?).reduce(Object) { |memo, name| memo.const_get(name, false) }
        found << "R-DOC-POLICY: missing enforcement binding #{rule['id']}" unless method && object.respond_to?(method, true)
      rescue NameError, KeyError
        found << "R-DOC-POLICY: missing enforcement binding #{rule['id']}"
      end
      found
    rescue StandardError => e
      ["R-DOC-POLICY: #{e.message}"]
    end

    def summary
      doc = application
      status = { "schema" => SCHEMA, "application" => { "id" => doc["id"], "version" => doc["version"], "authority" => doc["authority"], "digest" => bundle["digest"], "directives" => doc["directives"].size, "enforcement" => doc["rules"].group_by { |rule| rule["mode"] }.transform_values(&:size) }, "problems" => problems }
      begin
        policy = course(Reach::Guardrails.load)
        status["course"] = { "authority" => policy["authority"], "version" => policy["version"], "digest" => digest(policy), "directives" => policy["directives"].size, "format" => "signed Teach package adapted locally", "enforcement" => policy["rules"].group_by { |rule| rule["mode"] }.transform_values(&:size) }
      rescue Reach::Guardrails::Missing
        status["course"] = { "state" => "not enrolled or not synchronized" }
      rescue StandardError
        status["course"] = { "state" => "policy unavailable; run reach doctor" }
      end
      status
    end
  end
end
