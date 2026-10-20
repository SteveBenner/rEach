require "json"
require "yaml"
require "time"
require "fileutils"
require "open3"
require "rbconfig"

module Reach
  module Passes
    SCHEMA_PACKET = "reach.passes-packet/v1".freeze
    SCHEMA_SCORE = "reach.passes-score/v1".freeze
    SCHEMA_PICK = "reach.passes-pick/v1".freeze
    DIR = "passes".freeze
    POINTS = %w[plan scenarios code].freeze
    MODES = %w[enforce advise off].freeze
    DEFAULT_COUNT = 8
    MAX_COUNT = 8
    LOW_CONFIDENCE = 0.5
    CRITERIA = %w[contract coverage check ledger ports starting_copy probe consistency].freeze
    QUALIFY_DIRS = %w[qualify/features qualify/step_definitions].freeze
    PLAN_FILE = "plan.yml".freeze
    CHECK_ERROR_WEIGHT = 0.25
    WORD = /[a-z][a-z0-9_]{3,}/.freeze
    STOPWORDS = %w[that this with from when then they them have must should would only each every into than does there their which what will your input output].freeze
    LENSES = [
      { "n" => 1, "id" => "contract", "name" => "Contract literal", "focus" => "do exactly what behaviour, contract and output say, with the smallest change",
        "weights" => { "contract" => 3, "coverage" => 2, "check" => 2, "ledger" => 1, "ports" => 1, "starting_copy" => 1, "probe" => 1, "consistency" => 1 } },
      { "n" => 2, "id" => "ports", "name" => "Port fidelity", "focus" => "every required instructor API used as its constraint describes; nothing recomputed locally",
        "weights" => { "ports" => 3, "probe" => 3, "contract" => 1, "ledger" => 2, "check" => 1, "coverage" => 1, "starting_copy" => 1, "consistency" => 1 } },
      { "n" => 3, "id" => "format", "name" => "Normalisation and format", "focus" => "keys, units, decimals, rounding, ordering and text formats as the constraints state",
        "weights" => { "contract" => 2, "ledger" => 2, "check" => 1, "coverage" => 1, "starting_copy" => 1, "probe" => 1, "ports" => 1, "consistency" => 2 } },
      { "n" => 4, "id" => "edges", "name" => "Edge and adversarial cases", "focus" => "invalid, empty, unavailable and boundary inputs; scenarios that a wrong solution would fail",
        "weights" => { "starting_copy" => 3, "probe" => 2, "coverage" => 2, "contract" => 1, "ledger" => 1, "check" => 1, "ports" => 1, "consistency" => 1 } },
      { "n" => 5, "id" => "ledger", "name" => "Ledger avoidance", "focus" => "none of the ledger's patterns, read before writing",
        "weights" => { "ledger" => 4, "check" => 2, "ports" => 1, "contract" => 1, "coverage" => 1, "starting_copy" => 1, "probe" => 1, "consistency" => 1 } },
      { "n" => 6, "id" => "intent", "name" => "Student intent", "focus" => "the student's business reasoning from README.md and the plan, kept inside the constraints",
        "weights" => { "consistency" => 3, "contract" => 2, "coverage" => 1, "check" => 1, "ledger" => 1, "ports" => 1, "starting_copy" => 1, "probe" => 1 } },
      { "n" => 7, "id" => "panel", "name" => "Panel states and step vocabulary", "focus" => "every data-state, existing message keys only, the kit's step vocabulary (I run the ... example ...)",
        "weights" => { "check" => 3, "ledger" => 3, "contract" => 1, "coverage" => 1, "starting_copy" => 1, "probe" => 1, "ports" => 1, "consistency" => 1 } },
      { "n" => 8, "id" => "fresh", "name" => "Fresh read", "focus" => "written from the packet alone with no earlier pass in context",
        "weights" => { "contract" => 1, "coverage" => 1, "check" => 1, "ledger" => 1, "ports" => 1, "starting_copy" => 1, "probe" => 1, "consistency" => 1 } }
    ].freeze

    module_function

    def mode
      section = Reach::CourseProfile.section("qualify")["passes"]
      value = section.is_a?(Hash) ? section["mode"].to_s : ""
      MODES.include?(value) ? value : "advise"
    rescue StandardError
      "advise"
    end

    def count
      section = Reach::CourseProfile.section("qualify")["passes"]
      value = section.is_a?(Hash) ? section["count"].to_i : 0
      value.between?(1, MAX_COUNT) ? value : DEFAULT_COUNT
    rescue StandardError
      DEFAULT_COUNT
    end

    def lenses
      LENSES.first(count)
    end

    def valid_point!(point)
      value = point.to_s
      raise Reach::Refused, Reach::Messages.text("M-PASSES-POINT", points: POINTS.join(", ")) unless POINTS.include?(value)

      value
    end

    def base_dir(workspace)
      File.join(workspace, Reach::Workspace::MARKER_DIR, DIR)
    end

    def point_dir(workspace, point)
      File.join(base_dir(workspace), point)
    end

    def candidate_dir(workspace, point, number)
      File.join(point_dir(workspace, point), number.to_s)
    end

    def score_path(workspace, point)
      File.join(point_dir(workspace, point), "score.json")
    end

    def pick_path(workspace, point)
      File.join(point_dir(workspace, point), "pick.json")
    end

    def relative_dir(point, number = nil)
      parts = [Reach::Workspace::MARKER_DIR, DIR, point]
      parts << number.to_s if number
      "#{parts.join('/')}/"
    end

    def read_json(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def candidate_numbers(workspace, point)
      dir = point_dir(workspace, point)
      return [] unless File.directory?(dir)

      Dir.children(dir).select { |name| name.match?(/\A[1-8]\z/) && File.directory?(File.join(dir, name)) }.map(&:to_i).sort.select do |number|
        !candidate_files(candidate_dir(workspace, point, number)).empty?
      end
    end

    def candidate_files(dir)
      return [] unless File.directory?(dir)

      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) || File.symlink?(path) }.map { |path| path.sub("#{dir}/", "") }.reject { |relative| File.basename(relative) == ".keep" }.sort
    end

    def files_digest(dir, files)
      map = files.map do |relative|
        full = File.join(dir, relative)
        [relative, File.symlink?(full) ? "link:#{File.readlink(full)}" : Reach::Crypto.digest_hex(File.binread(full))]
      end.to_h
      Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(map))
    end

    def candidate_digest(workspace, point, number)
      dir = candidate_dir(workspace, point, number)
      files_digest(dir, candidate_files(dir))
    end

    def allowed_path?(meta, point, relative)
      return relative == PLAN_FILE if point == "plan"

      Array(meta["owned_files"]).include?(relative) || QUALIFY_DIRS.any? { |dir| relative.start_with?("#{dir}/") }
    end

    def plan_digest(workspace)
      Reach::PlanAudit.plan_digest(Reach::Plan.load(workspace))
    end

    def upstream_digest(workspace, point)
      case point
      when "plan" then nil
      when "scenarios" then plan_digest(workspace)
      else
        picked = read_json(pick_path(workspace, "scenarios"))
        picked ? picked["candidate_digest"] : plan_digest(workspace)
      end
    end

    def packet(workspace, point)
      point = valid_point!(point)
      meta = Reach::Workspace.metadata(workspace)
      constraints = Reach::PlanAudit.constraints(workspace)
      upstream = {}
      plan = Reach::Plan.load(workspace)
      upstream["plan"] = Reach::PlanAudit.normalized(plan) if plan && point != "plan"
      if point == "code"
        qualify = meta["qualify"].is_a?(Hash) ? meta["qualify"] : {}
        upstream["scenarios"] = Reach::Qualify.agent_scenarios(workspace, qualify["tag"].to_s)
      end
      mirrors = point == "plan" ? [PLAN_FILE] : Array(meta["owned_files"]).reject { |relative| relative == Reach::ReadmeCheck::FILE } + QUALIFY_DIRS.map { |dir| "#{dir}/" }
      mirrors = QUALIFY_DIRS.map { |dir| "#{dir}/" } if point == "scenarios"
      {
        "schema" => SCHEMA_PACKET,
        "point" => point,
        "count" => count,
        "constraints" => constraints,
        "constraints_digest" => Reach::PlanAudit.constraints_digest(workspace),
        "lenses" => lenses.map { |lens| lens.slice("n", "id", "name", "focus") },
        "ledger" => Reach::Patterns.describe(point == "plan" ? :plan : point, workspace),
        "upstream" => upstream,
        "write_to" => { "root" => relative_dir(point), "candidate" => "#{relative_dir(point)}<n>/", "mirrors" => mirrors },
        "instructions" => Reach::Messages.text("M-PASSES-PACKET", count: count, point: point)
      }
    end

    def score(workspace, point)
      point = valid_point!(point)
      numbers = candidate_numbers(workspace, point).select { |number| number <= count }
      raise Reach::Refused, Reach::Messages.text("M-PASSES-NO-CANDIDATES", point: point, dir: relative_dir(point)) if numbers.empty?

      meta = Reach::Workspace.metadata(workspace)
      constraints = Reach::PlanAudit.constraints(workspace)
      rows = numbers.map { |number| score_candidate(workspace, meta, constraints, point, number) }
      record = {
        "schema" => SCHEMA_SCORE,
        "point" => point,
        "constraints_digest" => Reach::PlanAudit.constraints_digest(workspace),
        "upstream_digest" => upstream_digest(workspace, point),
        "at" => now,
        "candidates" => rows
      }
      Reach::StateFile.write_atomic(score_path(workspace, point), JSON.generate(record))
      Reach::Ledger.append(workspace, "passes_score", "point" => point, "candidates" => rows.length)
      record
    end

    def now
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def confidence_for(lens, criteria)
      weights = lens["weights"]
      total = weights.values.sum.to_f
      (weights.map { |name, weight| weight * criteria.fetch(name, 0.0) }.sum / total).round(3)
    end

    def score_candidate(workspace, meta, constraints, point, number)
      dir = candidate_dir(workspace, point, number)
      lens = LENSES[number - 1]
      files = candidate_files(dir)
      hard = []
      outside = files.reject { |relative| allowed_path?(meta, point, relative) && !File.symlink?(File.join(dir, relative)) }
      hard << "a write outside owned or qualify paths: #{outside.first(3).join(', ')}" unless outside.empty?
      criteria = begin
        point == "plan" ? plan_criteria(workspace, constraints, dir, hard) : system_criteria(workspace, meta, constraints, point, dir, files - outside, hard)
      rescue StandardError => e
        hard << "could not be scored: #{e.message.to_s[0, 160]}"
        CRITERIA.map { |name| [name, 0.0] }.to_h
      end
      confidence = hard.empty? ? confidence_for(lens, criteria) : 0.0
      {
        "n" => number, "lens" => lens["id"], "digest" => candidate_digest(workspace, point, number),
        "criteria" => criteria, "hard_zero" => hard, "confidence" => confidence
      }
    end

    def tokens(text)
      text.to_s.downcase.scan(WORD).uniq - STOPWORDS
    end

    def covered?(line, haystack)
      words = tokens(line)
      return true if words.empty?

      words.count { |word| haystack.include?(word) } >= (words.length / 2.0).ceil
    end

    def plan_criteria(workspace, constraints, dir, hard)
      file = File.join(dir, PLAN_FILE)
      plan = begin
        data = YAML.safe_load(File.read(file))
        data.is_a?(Hash) ? data : nil
      rescue StandardError
        nil
      end
      if plan.nil? || plan["behaviour"].to_s.strip.empty?
        hard << "the candidate's files do not parse"
        return CRITERIA.map { |name| [name, 0.0] }.to_h
      end

      lists = %w[steps edge_cases scenarios].map { |field| [field, Array(plan[field]).map(&:to_s)] }.to_h
      haystack = ([plan["behaviour"], plan["input"], plan["output"]] + lists.values.flatten).join(" ").downcase
      lines = Array(constraints["constraints"]).map(&:to_s)
      lines << JSON.generate(constraints["operation"]) if constraints["operation"].is_a?(Hash)
      contract = lines.empty? ? 1.0 : lines.count { |line| covered?(line, haystack) }.to_f / lines.length
      graded = Array(constraints["graded_scenarios"])
      scenario_text = lists["scenarios"].map(&:downcase)
      matched = graded.count { |name| scenario_text.any? { |item| item.include?(name.downcase) } }
      coverage = graded.empty? ? 1.0 : matched.to_f / graded.length
      steps_text = lists["steps"].join(" ").downcase
      required = Array(constraints["required_apis"]).map { |line| line.to_s.sub(/\Aports\./, "").split("(").first.to_s.downcase }.reject(&:empty?)
      ports = required.empty? ? 1.0 : required.count { |chain| steps_text.include?(chain) }.to_f / required.length
      equal = graded.empty? ? 1.0 : matched.to_f / [scenario_text.length, graded.length].max
      edges = lists["edge_cases"]
      mentioned = edges.empty? ? 1.0 : edges.count { |edge| covered?(edge, steps_text) }.to_f / edges.length
      {
        "contract" => contract.round(3), "coverage" => coverage.round(3), "check" => 1.0, "ledger" => 1.0, "ports" => ports.round(3),
        "starting_copy" => 1.0, "probe" => 1.0, "consistency" => ((equal + mentioned) / 2.0).round(3)
      }
    end

    def ruby_parses?(path)
      _out, _err, status = Open3.capture3(RbConfig.ruby, "-c", path)
      status.success?
    end

    def system_criteria(workspace, meta, constraints, point, dir, files, hard)
      qualify = meta["qualify"].is_a?(Hash) ? meta["qualify"] : {}
      ruby_files = files.select { |relative| File.extname(relative) == ".rb" }
      broken = ruby_files.reject { |relative| ruby_parses?(File.join(dir, relative)) }
      hard << "the candidate's files do not parse: #{broken.first(3).join(', ')}" unless broken.empty?
      hard << "the candidate's files do not parse: no feature file" if point == "scenarios" && files.none? { |relative| relative.end_with?(".feature") }

      matches = %i[scenarios code].flat_map { |name| Reach::Patterns.match(workspace, point: name, root: dir) }.uniq { |row| [row["id"], row["file"], row["line"]] }
      blocked = matches.select { |row| row["severity"] == "block" }
      hard << "a block-severity ledger match: #{blocked.map { |row| row['id'] }.uniq.join(', ')}" unless blocked.empty?
      penalty = matches.sum { |row| row["severity"] == "block" ? 1.0 : (row["severity"] == "warn" ? 0.5 : 0.0) }
      ledger = [1.0 - penalty, 0.0].max

      findings = check_findings(workspace, meta, dir, files)
      check = [1.0 - CHECK_ERROR_WEIGHT * findings.length, 0.0].max

      operation = constraints["operation"].is_a?(Hash) ? constraints["operation"] : {}
      output_keys = output_keys_of(operation["output"])
      source = ruby_files.map { |relative| File.binread(File.join(dir, relative)).force_encoding(Encoding::UTF_8).scrub }.join("\n")
      contract = if point == "code"
                   shape = findings.none? { |entry| %w[CK-RUBY-SHAPE CK-FUSE].include?(entry[:id]) } ? 1.0 : 0.0
                   produced = output_keys.empty? ? 1.0 : output_keys.count { |key| source.match?(/(?:["':]#{Regexp.escape(key)}\b|\b#{Regexp.escape(key)}:)/) }.to_f / output_keys.length
                   (shape + produced) / 2.0
                 else
                   scenario_contract(dir, output_keys)
                 end

      graded = Array(constraints["graded_scenarios"])
      features_source = File.directory?(File.join(dir, Reach::Qualify::FEATURES_DIR)) ? dir : workspace
      covered = Reach::Qualify.agent_scenarios(features_source, qualify["tag"].to_s)
      missing = graded.reject { |name| covered.include?(name) }
      coverage = graded.empty? ? 1.0 : 1.0 - missing.length.to_f / graded.length

      required = Array(constraints["required_apis"])
      uncalled = required.reject { |line| api_called?(line, source, workspace, meta, dir) }
      hard << "a required instructor API is never called: #{uncalled.first(3).join(', ')}" unless uncalled.empty? || point == "scenarios"
      called = required.empty? ? 1.0 : (required.length - uncalled.length).to_f / required.length
      faked = matches.any? { |row| row["id"] == "P-PORT-FAKED" }
      ports = faked ? 0.0 : called

      local = local_scores(workspace, meta, qualify, point, dir, hard)
      probe_rows = Reach::Probe.run(workspace, root: dir)
      probe = if Reach::Probe.mode == "off" || Reach::Probe.required_ports(workspace).empty?
                1.0
              else
                probe_rows.empty? ? 0.0 : probe_rows.count { |row| row["sensitive"] }.to_f / probe_rows.length
              end

      {
        "contract" => contract.round(3), "coverage" => coverage.round(3), "check" => check.round(3), "ledger" => ledger.round(3),
        "ports" => ports.round(3), "starting_copy" => local[:starting_copy].round(3), "probe" => probe.round(3), "consistency" => local[:consistency].round(3)
      }
    end

    def output_keys_of(output)
      case output
      when Hash then output.keys.map(&:to_s)
      when Array then output.map(&:to_s)
      when String then output.scan(/[a-z_]{3,}/).uniq - STOPWORDS - %w[string number integer boolean array hash object]
      else []
      end
    end

    def scenario_contract(dir, output_keys)
      return 1.0 if output_keys.empty?

      blocks = []
      Dir.glob(File.join(dir, Reach::Qualify::FEATURES_DIR, "**", "*.feature")).sort.each do |path|
        blocks.concat(Reach::Patterns.scenario_blocks(File.binread(path).force_encoding(Encoding::UTF_8).scrub))
      end
      return 0.0 if blocks.empty?

      blocks.count do |block|
        thens = block.map(&:first).select { |line| line.strip.start_with?("Then", "And") }.join(" ")
        output_keys.any? { |key| thens.include?(key) }
      end.to_f / blocks.length
    end

    def check_findings(workspace, meta, dir, files)
      found = []
      files.each do |relative|
        full = File.join(dir, relative)
        next unless Array(meta["owned_files"]).include?(relative)

        content = File.binread(full).force_encoding(Encoding::UTF_8).scrub
        case File.extname(relative)
        when ".rb" then found.concat(Reach::Check.check_ruby(workspace, meta, relative, full, content).reject { |entry| entry[:id] == "CK-INSTRUCTOR-API" })
        when ".svelte" then found.concat(Reach::Check.check_svelte(meta, relative, content))
        end
      end
      found
    end

    def api_called?(line, source, workspace, meta, dir)
      chain = line.to_s.split("(").first.to_s.sub(/\Aports\./, "")
      port, method = chain.split(".", 2)
      return true if port.to_s.empty? || method.to_s.empty?

      text = source
      text = owned_source(workspace, meta, dir) if text.empty?
      text.match?(/\b(?:ports\.)?#{Regexp.escape(port)}\s*\.\s*#{Regexp.escape(method)}\b/)
    end

    def owned_source(workspace, meta, dir)
      Array(meta["owned_files"]).select { |relative| File.extname(relative) == ".rb" }.map do |relative|
        path = File.file?(File.join(dir, relative)) ? File.join(dir, relative) : File.join(workspace, relative)
        File.file?(path) ? File.binread(path).force_encoding(Encoding::UTF_8).scrub : ""
      end.join("\n")
    end

    def code_is_starting_copy?(workspace, meta)
      starting = Reach::Qualify.starting_copies(workspace, meta)
      Array(meta["owned_files"]).all? do |relative|
        data = Reach::SafeFiles.read_or_skip(workspace, relative).first
        starting[relative] && data == starting[relative]
      end
    rescue StandardError
      false
    end

    def local_scores(workspace, meta, qualify, point, dir, hard)
      zero = { starting_copy: 0.0, consistency: 0.0 }
      return { starting_copy: 1.0, consistency: 1.0 } unless qualify["local"] && qualify["tag"]

      env, _dropped = Reach::Qualify.sanitize_env(qualify["env"])
      judge_pass = point == "code" || !code_is_starting_copy?(workspace, meta)
      pass_dir = Reach::Qualify.assemble_local(workspace, meta, stub: false, root: dir, name: "score-#{File.basename(dir)}-pass")
      Reach::Suite.select_lock!(pass_dir)
      gems = Reach::Suite.install_gems(pass_dir)
      rows = run_rows(pass_dir, gems, qualify["tag"], env)
      passed = !rows.nil? && !rows.empty? && rows.all? { |row| row["result"] == "passed" }
      hard << "local_pass failed" if judge_pass && !passed

      stub_dir = Reach::Qualify.assemble_local(workspace, meta, stub: true, root: dir, name: "score-#{File.basename(dir)}-stub")
      stub_rows = run_rows(stub_dir, gems, qualify["tag"], env)
      starting = stub_rows.nil? || stub_rows.empty? ? 0.0 : stub_rows.count { |row| row["result"] != "passed" }.to_f / stub_rows.length
      return zero.merge(starting_copy: starting) if rows.nil?

      { starting_copy: starting, consistency: judge_pass ? (passed ? 1.0 : 0.0) : 1.0 }
    end

    def run_rows(run_dir, gems, tag, env)
      output = Reach::Suite.cucumber(run_dir, gems, [tag], env)
      return nil if output["timed_out"]

      Reach::Suite.report_rows(output["stdout"])
    end

    def best(rows)
      viable = rows.reject { |row| !row["hard_zero"].empty? }
      return nil if viable.empty?

      viable.max_by { |row| [row["confidence"], -row["n"]] }
    end

    def pick(workspace, point)
      point = valid_point!(point)
      record = read_json(score_path(workspace, point))
      raise Reach::Refused, Reach::Messages.text("M-PASSES-NO-SCORE", point: point) unless record

      stale = record["constraints_digest"] != Reach::PlanAudit.constraints_digest(workspace) ||
              Array(record["candidates"]).any? { |row| !File.directory?(candidate_dir(workspace, point, row["n"])) || row["digest"] != candidate_digest(workspace, point, row["n"]) }
      raise Reach::Refused, Reach::Messages.text("M-PASSES-STALE", point: point) if stale

      winner = best(Array(record["candidates"]))
      raise Reach::Refused, Reach::Messages.text("M-PASSES-NOT-VIABLE", point: point) unless winner

      meta = Reach::Workspace.metadata(workspace)
      guard_links!(workspace, point)
      Reach::Checkpoint.save(workspace, note: "before passes pick #{point}", extras: true, force: true)
      dir = candidate_dir(workspace, point, winner["n"])
      installed = install(workspace, meta, point, dir)
      pick_record = {
        "schema" => SCHEMA_PICK,
        "point" => point,
        "lens" => winner["lens"],
        "confidence" => winner["confidence"],
        "low_confidence" => winner["confidence"] < LOW_CONFIDENCE,
        "candidate_digest" => winner["digest"],
        "workspace_digest" => installed,
        "constraints_digest" => record["constraints_digest"],
        "upstream_digest" => upstream_digest(workspace, point),
        "scores" => Array(record["candidates"]).map { |row| [row["lens"], row["confidence"]] }.to_h,
        "at" => now
      }
      Reach::StateFile.write_atomic(pick_path(workspace, point), JSON.generate(pick_record))
      Reach::Ledger.append(workspace, "passes_pick", "point" => point, "lens" => winner["lens"], "confidence" => winner["confidence"], "candidate_digest" => winner["digest"])
      clear_others(workspace, point, winner["n"])
      pick_record
    end

    def guard_links!(workspace, point)
      watched = point == "plan" ? [".reach"] : [".reach", "qualify", *QUALIFY_DIRS]
      linked = watched.find { |relative| !Reach::Checkpoint.link_free?(workspace, relative) }
      raise Reach::Refused, Reach::Messages.text("M-PASSES-LINK", path: linked) if linked
    end

    def install(workspace, meta, point, dir)
      guard_links!(workspace, point)
      files = candidate_files(dir).reject { |relative| File.symlink?(File.join(dir, relative)) }
      if point == "plan"
        raise Reach::Refused, Reach::Messages.text("M-PASSES-NOT-VIABLE", point: point) unless files.include?(PLAN_FILE)

        plan = YAML.safe_load(File.read(File.join(dir, PLAN_FILE))) || {}
        fields = plan.select { |key, _| (Reach::Plan::TEXT_FIELDS + Reach::Plan::LIST_FIELDS).include?(key.to_s) }
        Reach::Plan.save(workspace, fields)
        return plan_digest(workspace)
      end

      QUALIFY_DIRS.each do |qualify_dir|
        next unless files.any? { |relative| relative.start_with?("#{qualify_dir}/") }

        Dir.glob(File.join(workspace, qualify_dir, "**", "*")).each do |path|
          FileUtils.rm_f(path) if File.file?(path) && File.basename(path) != ".keep"
        end
      end
      files.each do |relative|
        target = File.join(workspace, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.rm_f(target)
        File.binwrite(target, File.binread(File.join(dir, relative)))
        File.chmod(0o644, target)
      end
      Reach::Seal.stamp(workspace, report: false) if files.any? { |relative| Array(meta["owned_files"]).include?(relative) }
      files_digest(workspace, files)
    end

    def clear_others(workspace, point, keep)
      candidate_numbers(workspace, point).each do |number|
        next if number == keep

        FileUtils.rm_rf(candidate_dir(workspace, point, number))
      end
      Dir.glob(File.join(point_dir(workspace, point), "[1-8]")).each do |path|
        FileUtils.rm_rf(path) if File.directory?(path) && File.basename(path).to_i != keep
      end
    end

    def current_pick(workspace, point)
      record = read_json(pick_path(workspace, point))
      return nil unless record
      return nil unless record["constraints_digest"] == Reach::PlanAudit.constraints_digest(workspace)
      return nil unless record["upstream_digest"] == upstream_digest(workspace, point)

      record
    end

    def status(workspace)
      POINTS.map do |point|
        pick = current_pick(workspace, point)
        scored = read_json(score_path(workspace, point))
        {
          "point" => point,
          "candidates" => candidate_numbers(workspace, point).length,
          "scored" => !scored.nil?,
          "picked" => !pick.nil?,
          "lens" => pick && pick["lens"],
          "confidence" => pick && pick["confidence"],
          "low_confidence" => pick ? pick["low_confidence"] : nil
        }
      end
    end

    def missing_points(workspace)
      POINTS.reject { |point| current_pick(workspace, point) }
    end

    def render_score(record)
      lines = ["Point: #{record['point']}"]
      Array(record["candidates"]).each do |row|
        flag = row["hard_zero"].empty? ? "" : "  hard zero: #{row['hard_zero'].join('; ')}"
        lines << "  #{row['n']} #{row['lens']}: #{format('%.3f', row['confidence'])}#{flag}"
      end
      winner = best(Array(record["candidates"]))
      lines << (winner ? "Highest: #{winner['n']} #{winner['lens']} (#{format('%.3f', winner['confidence'])})" : "No candidate can be installed.")
      lines.join("\n")
    end

    def render_pick(record)
      lines = ["Installed #{record['point']}: #{record['lens']} with confidence #{format('%.3f', record['confidence'])}"]
      lines << Reach::Messages.text("M-PASSES-LOW-CONFIDENCE") if record["low_confidence"]
      lines.concat(record["scores"].map { |lens, value| "  #{lens}: #{format('%.3f', value)}" })
      lines.join("\n")
    end

    def render_status(rows)
      rows.map do |row|
        detail = row["picked"] ? "picked #{row['lens']} (#{format('%.3f', row['confidence'])})" : (row["scored"] ? "scored, not picked" : "#{row['candidates']} candidates written")
        "#{row['point']}: #{detail}"
      end.join("\n")
    end
  end
end
