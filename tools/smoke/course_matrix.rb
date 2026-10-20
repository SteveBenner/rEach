require "json"
require "yaml"
require "date"
require "time"
require "open3"
require "optparse"
require "fileutils"
require "find"
require "securerandom"
require "digest"
require "timeout"
require_relative "../../lib/reach/crypto"

module CourseMatrix
  ROOT = File.expand_path("../..", __dir__)
  CONFIG = YAML.safe_load(File.read(File.join(__dir__, "course_matrix.yml")))
  STUDENT_ID = (10**6 + 1).to_s
  OTHER_STUDENT_ID = (10**6 + 2).to_s
  class Failure < StandardError; end

  def self.git(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, *args)
    raise Failure, "git #{args.first}: #{err.lines.first}" unless status.success?
    out
  end

  def self.read_yaml(text)
    YAML.safe_load(text, permitted_classes: [Date, Time])
  end

  def self.source_digest
    paths = Dir.glob(File.join(ROOT, "lib", "**", "*.rb")) + ["config.yml", "locales/en-US.yml", "policy/behavior.json", "tools/smoke/course_matrix.rb", "tools/smoke/course_native.rb", "tools/smoke/course_matrix.yml"].map { |path| File.join(ROOT, path) }
    digest = Digest::SHA256.new
    paths.sort.each { |path| digest << path.delete_prefix(ROOT + "/") << "\0" << Digest::SHA256.file(path).hexdigest }
    digest.hexdigest
  end

  def self.save_report(directory, report)
    executed = report.fetch("cases").count { |item| %w[passed failed].include?(item["status"]) }
    report["executed_count"] = executed
    report["execution_complete"] = executed == report.fetch("selected_count")
    File.write(File.join(directory, "report.json"), JSON.pretty_generate(report) + "\n")
    counts = report.fetch("cases").group_by { |item| item.fetch("status") }.transform_values(&:length)
    failed_stages = report.fetch("cases").select { |item| item["status"] == "failed" }.group_by { |item| item.dig("failure", "stage") || "runner" }.transform_values(&:length)
    summary = ["# Course smoke matrix", "", "Mode: #{report['mode']}; engine: #{report['execution_kind']}; complete pipeline pass: #{report['coverage_complete']}.",
               "Executed: #{executed}/#{report['selected_count']}; inventory: #{report['inventory_count']}; accounted cost/reservations: $#{report['cost_usd']} of $#{report['budget_usd']}.", "",
               "Statuses: #{counts.map { |status, count| "#{status}=#{count}" }.join(', ')}.",
               "Failed stages: #{failed_stages.empty? ? 'none' : failed_stages.map { |stage, count| "#{stage}=#{count}" }.join(', ')}.", "",
               "| Assignment / slice | Passed | Failed | Other |", "|---|---:|---:|---:|"]
    report.fetch("cases").group_by do |item|
      parts = item.fetch("id").split("/")
      "#{parts.fetch(2).split('.').fetch(1)[0, 2].upcase} / #{parts.fetch(3)}"
    end.sort.each do |group, items|
      passed = items.count { |item| item["status"] == "passed" }
      failed = items.count { |item| item["status"] == "failed" }
      summary << "| #{group} | #{passed} | #{failed} | #{items.length - passed - failed} |"
    end
    summary.concat(["", "| Case | Status | Failed stage | Reason |", "|---|---|---|---|"])
    report["cases"].each do |item|
      reason = item.dig("failure", "reason") || item["reason"]
      summary << "| #{item['id']} | #{item['status']} | #{item.dig('failure', 'stage')} | #{reason.to_s[0, 500].gsub(/[|\r\n]/, ' ')} |"
    end
    File.write(File.join(directory, "report.md"), summary.join("\n") + "\n")
  end

  def self.merge_reports(paths, inventory, output)
    reports = paths.map { |path| JSON.parse(File.read(File.join(path, "report.json"))) }
    raise Failure, "shards must have the same sources and engine" unless reports.all? { |r| r["sources"] == inventory.sources && r["execution_kind"] == reports.first["execution_kind"] && r["mode"] == "run" }
    cases = reports.flat_map { |r| r.fetch("cases") }
    ids = cases.map { |item| item.fetch("id") }
    raise Failure, "duplicate or unknown shard cases" unless ids.uniq == ids && (ids - inventory.cases.map { |c| c.fetch("id") }).empty?
    raise Failure, "output already exists" if File.exist?(output)
    FileUtils.mkdir_p(output, mode: 0o700)
    report = { "mode" => "run", "execution_kind" => reports.first.fetch("execution_kind"), "sources" => inventory.sources,
               "inventory_count" => inventory.cases.length, "selected_count" => cases.length, "cases" => cases,
               "budget_usd" => reports.sum { |r| r.fetch("budget_usd") }, "cost_usd" => reports.sum { |r| r.fetch("cost_usd") },
               "coverage_complete" => cases.length == inventory.cases.length && cases.all? { |c| c["status"] == "passed" }, "shards" => paths }
    save_report(output, report)
    puts "merged #{cases.length}/#{inventory.cases.length} cases; #{cases.group_by { |r| r['status'] }.transform_values(&:length)}; #{output}/report.json"
    report["coverage_complete"] ? 0 : 1
  end

  def self.scratch_roots
    common = File.expand_path(git(ROOT, "rev-parse", "--git-common-dir").strip, ROOT)
    [ROOT, File.dirname(common)].uniq.map { |repository| [repository, File.join(repository, ".scratch")] }
  end

  def self.scratch_path!(path)
    FileUtils.mkdir_p(File.join(ROOT, ".scratch"), mode: 0o700)
    parent = path
    parent = File.dirname(parent) until File.exist?(parent)
    rest = path.delete_prefix(parent)
    resolved = rest.empty? ? File.realpath(parent) : File.join(File.realpath(parent), rest)
    roots = scratch_roots
    repository, scratch = roots.find { |_repository, root| File.directory?(root) && resolved.start_with?(File.realpath(root) + "/") }
    raise Failure, "output must be under #{roots.map { |_repository, root| root + '/' }.join(' or ')}, never #{path}" unless scratch
    _out, _err, status = Open3.capture3("git", "-C", repository, "check-ignore", "-q", File.join(scratch, "probe"))
    raise Failure, "#{scratch} is not ignored by git" unless status.success?
    resolved
  end

  def self.storage_preflight(directory, count)
    temporary = File.join(File.dirname(directory), ".rs-000000000000")
    raise Failure, "scratch parent path is too long for Chromium sockets; choose a shorter --output path" if temporary.bytesize > 55
    parent = File.dirname(directory)
    parent = File.dirname(parent) until File.directory?(parent)
    limits = CONFIG.fetch("limits")
    headroom = limits.fetch("disk_headroom")
    { "-Pi" => [(limits.fetch("native_fixed_estimated_inodes") + count * limits.fetch("native_case_estimated_inodes")) * headroom, 1, "inodes"],
      "-Pk" => [(limits.fetch("native_fixed_estimated_bytes") + count * limits.fetch("native_case_estimated_bytes")) * headroom, 1024, "bytes"] }.each do |flag, (required, scale, label)|
      out, err, status = Open3.capture3("df", flag, parent)
      raise Failure, "cannot check scratch storage: #{err}" unless status.success?
      available = Integer(out.lines.last.split[-3]) * scale
      raise Failure, "environment: scratch storage has #{available} free #{label}; #{count} cases need #{required} (#{headroom}x the estimate)" if available < required
    end
  end

  def self.grader_preflight
    CONFIG.fetch("grader_images").to_h do |image|
      out, err, status = Open3.capture3("timeout", "10", "docker", "image", "inspect", "--format", "{{.Id}}", image)
      raise Failure, "environment: grader image #{image} is unavailable (#{err.lines.first.to_s.strip}); restore it before a run" unless status.success? && out.strip.start_with?("sha256:")
      [image, out.strip]
    end
  rescue SystemCallError => error
    raise Failure, "environment: cannot inspect grader images: #{error.message}"
  end

  def self.environment_failure?(reason)
    text = reason.to_s.downcase
    text.start_with?("environment:") || CONFIG.fetch("environment_failures").any? { |pattern| text.include?(pattern.downcase) }
  end

  def self.failure_signature(row)
    reason = row.dig("failure", "reason") || row["reason"]
    "#{row.dig('failure', 'stage') || 'runner'}: #{reason.to_s.gsub(/\h{8,}|\d+/, '#')[0, 240]}"
  end

  def self.halt!(output, reason)
    File.write(File.join(output, "STOP"), reason + "\n")
    reason
  end

  def self.remove_tree(path)
    return unless File.exist?(path) || File.symlink?(path)
    unless File.symlink?(path)
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        File.chmod(stat.mode | 0o700, entry) if stat.directory?
      end
    end
    FileUtils.rm_rf(path)
    raise Failure, "could not remove #{path}" if File.exist?(path) || File.symlink?(path)
  end

  def self.prune_passing(directory, test_case)
    errors = []
    steps = Dir.children(directory).reject { |name| %w[case.json evidence.json].include?(name) }.map { |name| -> { remove_tree(File.join(directory, name)) } }
    steps << -> { remove_temporary(directory, test_case) }
    database = test_case.fetch("database")
    steps << lambda do
      _out, err, status = Open3.capture3("timeout", "30", "dropdb", "--if-exists", database)
      raise Failure, "dropdb #{database}: #{err.lines.first}" unless status.success?
    end if database.match?(/\Areach_smoke_\h{20}\z/)
    steps.each do |step|
      step.call
    rescue Failure, SystemCallError => error
      errors << error.message
    end
    raise Failure, "could not prune passing case: #{errors.join('; ')}" unless errors.empty?
  end

  def self.remove_temporary(directory, test_case)
    nonce = test_case["nonce"].to_s
    remove_tree(File.join(File.dirname(File.dirname(directory)), ".rs-#{nonce[0, 12]}")) if nonce.match?(/\A\h{32}\z/)
  end

  def self.archive(run)
    run = scratch_path!(run)
    raise Failure, "#{run} holds no report.json" unless File.file?(File.join(run, "report.json"))
    archive = "#{run}.tar.gz"
    manifest = "#{run}.manifest.json"
    raise Failure, "#{archive} or its manifest already exists" if File.exist?(archive) || File.exist?(manifest)
    _out, err, status = Open3.capture3("tar", "-czf", archive, "-C", File.dirname(run), File.basename(run))
    raise Failure, "archive failed: #{err.lines.first}" unless status.success?
    entries, err, status = Open3.capture3("tar", "-tzf", archive)
    raise Failure, "archive does not read back: #{err.lines.first}" unless status.success?
    tree, _err, _status = Open3.capture3("du", "-sb", run)
    report = JSON.parse(File.read(File.join(run, "report.json")))
    record = { "schema" => "reach.course-smoke-archive/v1", "run" => run, "archive" => archive,
               "archive_sha256" => Digest::SHA256.file(archive).hexdigest, "archive_bytes" => File.size(archive),
               "entries" => entries.lines.length, "tree_bytes" => Integer(tree.split.first, exception: false),
               "created_at" => Time.now.utc.iso8601, "execution_kind" => report["execution_kind"], "sources" => report["sources"],
               "statuses" => report.fetch("cases").group_by { |item| item["status"] }.transform_values(&:length) }
    File.write(manifest, JSON.pretty_generate(record) + "\n")
    puts "archived #{record['entries']} entries, #{record['tree_bytes']} bytes into #{record['archive_bytes']}; #{manifest}"
    0
  end

  def self.prune(run)
    run = scratch_path!(run)
    manifest = "#{run}.manifest.json"
    raise Failure, "#{run} has no archive manifest; run --archive first" unless File.file?(manifest)
    record = JSON.parse(File.read(manifest))
    archive = record.fetch("archive")
    raise Failure, "archive #{archive} is missing or changed" unless File.file?(archive) && Digest::SHA256.file(archive).hexdigest == record.fetch("archive_sha256")
    entries, err, status = Open3.capture3("tar", "-tzf", archive)
    raise Failure, "archive does not read back: #{err.lines.first}" unless status.success? && entries.lines.length == record.fetch("entries")
    Dir.glob(File.join(run, "[0-9][0-9][0-9][0-9]", "case.json")).each do |path|
      remove_temporary(File.dirname(path), JSON.parse(File.read(path)))
    rescue JSON::ParserError
      nil
    end
    remove_tree(run)
    puts "pruned #{run}; evidence remains in #{archive}"
    0
  end

  class Inventory
    attr_reader :cases, :sources

    def initialize(grokit:, teach:, config: CONFIG)
      @cases = []
      ref = config.fetch("grokit_ref")
      sha = CourseMatrix.git(grokit, "rev-parse", "#{ref}^{commit}").strip
      text = CourseMatrix.git(grokit, "show", "#{sha}:specs/app.yml")
      spec = CourseMatrix.read_yaml(text)
      teach_text = File.read(File.join(teach, "teach.spec.yml"))
      assignments = CourseMatrix.read_yaml(teach_text).fetch("course_model").fetch("assignments")
      @sources = { "grokit_ref" => ref, "grokit_sha" => sha,
                   "reach_source_sha256" => CourseMatrix.source_digest,
                   "grokit_spec_sha256" => Digest::SHA256.hexdigest(text),
                   "teach_spec_sha256" => Digest::SHA256.hexdigest(teach_text) }
      modules = spec.fetch("modules").map { |m| m.fetch("id") }
      cutouts = spec.fetch("cutouts")
      ids = cutouts.map { |c| c.fetch("id") }
      raise Failure, "duplicate module or cutout" unless modules.uniq == modules && ids.uniq == ids
      expected = modules.product(assignments.flat_map { |a| a.fetch("cutout_slots") }).map { |m, s| "#{m}.#{s}" }.sort
      raise Failure, "cutout inventory differs from Teach slots: missing #{expected - ids}; extra #{ids - expected}" unless ids.sort == expected
      config.fetch("courses").each do |course|
        course.fetch("selection_modes").each do |mode|
          raise Failure, "invalid selection mode" unless %w[instructor student_choice].include?(mode)
          cutouts.each do |cutout|
            assignment = assignments.find { |a| a["id"] == cutout.fetch("assignment") }
            raise Failure, "wrong assignment for #{cutout['id']}" unless assignment && assignment.fetch("cutout_slots").include?(cutout["id"].split(".").last)
            questions = assignment.fetch("student_part")
            raise Failure, "missing question shapes" if questions.empty? || questions.any? { |q| q["id"].to_s.empty? || !q["min_words"].is_a?(Integer) || q["min_words"] < 1 }
            config.fetch("slices").each do |slice|
              owned = cutout.fetch("owned_paths").select { |p| slice == "backend" ? p.end_with?(".rb") : p.end_with?(".svelte") }
              raise Failure, "no #{slice} owned paths for #{cutout['id']}" if owned.empty?
              scenarios = cutout.fetch("acceptance_features").flat_map do |feature|
                path = feature.fetch("feature")
                source = CourseMatrix.git(grokit, "show", "#{sha}:#{path}")
                tagged_scenarios(source, slice).map { |name| { "feature" => path, "name" => name } }
              end
              raise Failure, "no tagged scenarios for #{cutout['id']}/#{slice}" if scenarios.empty?
              local_scenarios = scenarios
              if slice == "panel"
                practice = "features/practice/#{cutout.fetch('module')}/#{cutout.fetch('id')}.feature"
                source = CourseMatrix.git(grokit, "show", "#{sha}:#{practice}")
                local_scenarios = tagged_scenarios(source, slice).map { |name| { "feature" => practice, "name" => name } }
                raise Failure, "no practice scenarios for #{cutout['id']}" if local_scenarios.empty?
              end
              @cases << { "id" => [course.fetch("id"), mode, cutout.fetch("id"), slice].join("/"),
                          "course" => course.fetch("id"), "selection_mode" => mode,
                          "module" => cutout.fetch("module"), "assignment" => assignment.fetch("id"),
                          "cutout" => cutout.fetch("id"), "slice" => slice, "owned_paths" => owned,
                          "questions" => questions, "scenarios" => scenarios.uniq, "local_scenarios" => local_scenarios.uniq, "sources" => @sources }
            end
          end
        end
      end
      raise Failure, "duplicate cases" unless @cases.map { |c| c["id"] }.uniq.length == @cases.length
    end

    def tagged_scenarios(source, slice)
      inherited = []
      tags = []
      source.lines.filter_map do |line|
        if line.strip.start_with?("@")
          tags.concat(line.strip.split)
          nil
        elsif line.match?(/^\s*Feature:/)
          inherited = tags
          tags = []
          nil
        elsif (match = line.match(/^\s*Scenario(?: Outline)?:\s*(.+)$/))
          selected = (inherited + tags).include?("@#{slice}")
          tags = []
          selected ? match[1].strip : nil
        end
      end
    end
  end

  class Evidence
    def initialize(test_case, directory)
      @case = test_case
      @directory = File.realpath(directory)
    end

    def local_file(relative)
      raise Failure, "missing evidence path" unless relative.is_a?(String) && !relative.empty?
      path = File.realpath(File.join(@directory, relative))
      raise Failure, "evidence escapes scratch case" unless path.start_with?(@directory + "/") && File.file?(path)
      raise Failure, "empty or oversized evidence #{relative}" unless File.size(path).between?(1, 16 * 1024 * 1024)
      path
    rescue Errno::ENOENT
      raise Failure, "missing evidence file #{relative}"
    end

    def json(relative)
      JSON.parse(File.read(local_file(relative)))
    end

    def verify!
      evidence = json("evidence.json")
      %w[id nonce database].each { |key| raise Failure, "wrong case #{key}" unless evidence[key] == @case.fetch(key) }
      raise Failure, "non-synthetic environment" unless evidence["synthetic"] == true
      stages = evidence.fetch("stages")
      raise Failure, "missing, duplicate, or reordered pipeline stage" unless stages.map { |s| s["name"] } == CONFIG.fetch("stages")
      stages.each do |stage|
        raise Failure, "#{stage['name']} did not pass" unless stage["status"] == "passed"
        local_file(stage["evidence"])
      end
      answers = json(evidence.fetch("answers"))
      raise Failure, "answer IDs differ" unless answers.keys.sort == @case.fetch("questions").map { |q| q.fetch("id") }.sort
      @case.fetch("questions").each do |question|
        text = answers[question.fetch("id")]
        raise Failure, "missing/short answer #{question['id']}" unless text.is_a?(String) && text.split.count { |word| word.match?(/[[:alnum:]]/) } >= question.fetch("min_words")
      end
      shape = json(evidence.fetch("shape"))
      raise Failure, "shape check failed or absent" unless shape["errors"] == 0
      %w[local_qualify teach_qualify grade].each do |kind|
        rows = json(evidence.fetch(kind))
        expected = kind == "local_qualify" ? @case.fetch("local_scenarios", @case.fetch("scenarios")) : @case.fetch("scenarios")
        wanted = expected.map { |s| [s["feature"], s["name"]] }.sort
        actual = rows.map { |s| [s["feature"], s["name"]] }.sort
        raise Failure, "#{kind} scenario coverage differs" unless actual == wanted
        raise Failure, "#{kind} has failed/skipped scenarios" unless rows.all? { |s| s["result"] == "passed" }
      end
      receipts = evidence.fetch("receipts")
      public_key = Reach::Crypto.load_public_key(File.read(local_file(evidence.fetch("teach_public_key"))))
      raise Failure, "teach public key file holds a private key" if public_key.private?
      security = json(stages.first.fetch("evidence"))
      raise Failure, "security validation did not complete" unless security["phase"] == "passed"
      security_receipt = security.fetch("receipt")
      raise Failure, "security receipt belongs to another course" unless security_receipt["course_id"] == @case.fetch("course") && security_receipt["kind"] == "security-validation"
      verify_signature!(security_receipt, public_key)
      raise Failure, "stale security receipt" unless Time.iso8601(security_receipt.fetch("issued_at")) >= Time.iso8601(@case.fetch("started_at")) - 1 && Time.iso8601(security_receipt.fetch("expires_at")) > Time.iso8601(@case.fetch("started_at"))
      selection = json(stages.find { |s| s["name"] == "module_selection" }.fetch("evidence"))
      raise Failure, "wrong module-selection path" unless selection["course"] == @case.fetch("course") && selection["mode"] == @case.fetch("selection_mode") && Array(selection["modules"]).include?(@case.fetch("module"))
      manifest = json(evidence.fetch("submission_manifest"))
      { "course" => @case.fetch("course"), "assignment" => @case.fetch("assignment"),
        "cutout_id" => @case.fetch("cutout"), "slice" => @case.fetch("slice") }.each do |key, value|
        raise Failure, "submission manifest #{key} differs" unless manifest[key] == value
      end
      raise Failure, "partial submission manifest" if manifest["partial"] == true
      raise Failure, "owned files missing from submission" unless (@case.fetch("owned_paths") - Array(manifest["owned_files"])).empty?
      submission = evidence.fetch("submission_id")
      raise Failure, "missing submission" unless submission.is_a?(String) && !submission.empty?
      %w[ingest grade].each do |kind|
        pair = receipts.fetch(kind)
        teach = json(pair.fetch("teach"))
        student = json(pair.fetch("student"))
        raise Failure, "#{kind} receipt was not delivered unchanged" unless teach == student
        { "kind" => kind, "submission_id" => submission, "student_id" => @case.fetch("student_id"),
          "cutout_id" => @case.fetch("cutout"), "assignment" => @case.fetch("assignment"), "slice" => @case.fetch("slice") }.each do |key, value|
          raise Failure, "#{kind} receipt #{key} differs" unless teach[key] == value
        end
        raise Failure, "partial submission cannot pass" if teach["partial"] == true
        raise Failure, "receipt predates this run" unless Time.iso8601(teach.fetch("issued_at")) >= Time.iso8601(@case.fetch("started_at")) - 1
        verify_signature!(teach, public_key)
        if kind == "grade"
          expected_names = @case.fetch("scenarios").map { |s| s["name"] }.sort
          graded = teach.fetch("scenarios")
          raise Failure, "signed grade has missing/failed scenarios" unless graded.map { |s| s["name"] }.sort == expected_names && graded.all? { |s| s["result"] == "passed" } && teach["score"] == 1
        else
          message = File.read(local_file(stages.find { |s| s["name"] == "student_receipt" }.fetch("evidence")))
          raise Failure, "student was not told the receipt number" unless message.include?(teach.fetch("receipt_id"))
        end
      end
      cost = evidence.fetch("cost_usd")
      raise Failure, "missing/invalid cost accounting" unless cost.is_a?(Numeric) && cost.finite? && cost >= 0 && cost <= @case.fetch("budget_usd")
      cost
    rescue KeyError, JSON::ParserError, ArgumentError, TypeError, NoMethodError, OpenSSL::OpenSSLError => error
      raise Failure, "invalid evidence: #{error.message}"
    end

    def verify_signature!(receipt, public_key)
      unsigned = receipt.reject { |key, _| key == "signature" }
      signature = Base64.strict_decode64(receipt.fetch("signature"))
      raise Failure, "invalid receipt signature" unless Reach::Crypto.verify_pss(public_key, signature, Reach::Crypto.canonical_json(unsigned))
    end
  end

  def self.materialize(test_case, directory, budget)
    FileUtils.mkdir_p(directory)
    %w[home teach-home reach-home].each { |name| FileUtils.mkdir_p(File.join(directory, name), mode: 0o700) }
    test_case = test_case.merge("nonce" => SecureRandom.hex(16), "student_id" => STUDENT_ID, "username" => "smok001",
                              "database" => "reach_smoke_#{SecureRandom.hex(10)}", "started_at" => Time.now.utc.iso8601,
                              "budget_usd" => budget, "stages" => CONFIG.fetch("stages"))
    File.write(File.join(directory, "case.json"), JSON.pretty_generate(test_case) + "\n")
    prompt = <<~TEXT
      Run the rEach course smoke case in case.json with your provided harness agent.
      Use synthetic data only. Provision a NEW scratch Teach database named database
      from case.json, isolated Teach and Reach homes, and fresh keys. Never access
      production, host secrets, or a live course. Never change a student's configured
      server to a guessed address. Resolve the scratch Teach endpoint through the
      test fixture. Pin Grokit to sources.grokit_sha and use its native package builder.
      Set course selection to selection_mode; test the actual instructor assignment
      or student choice path. Use fabricated answers shaped by every questions entry.
      Execute every stage in order, including the security validation pass BEFORE
      enrollment. Let the harness build the owned slice from its delivered workspace;
      do not copy the instructor reference implementation. Run native Check,
      Checkpoint, local and Teach qualification, submit on synthetic student consent,
      retrieve Teach's ingest and grade receipts through Reach, and confirm the agent
      tells the synthetic student the receipt number. Test all scenarios listed for
      this slice: local_scenarios names the local practice cases for replay panels;
      scenarios names every protected graded case Teach must independently run.
      Never treat partial work, skipped tests, or a dry run as passing.
      Honor budget_usd as a hard reservation across all agent and student calls;
      stop on STOP, REACH_SMOKE_DISABLE=1, or the deadline. Keep failure evidence
      here; a passing case keeps only case.json and evidence.json.
      Write evidence.json following tools/smoke/README.md in the rEach repository.
      A failure should leave evidence and a reason; never fabricate successful logs.
    TEXT
    File.write(File.join(directory, "prompt.md"), prompt)
    test_case
  end

  def self.execute(argv, test_case, directory, timeout_s)
    env = { "HOME" => File.join(directory, "home"), "PATH" => ENV.fetch("PATH"), "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8",
            "TEACH_HOME" => File.join(directory, "teach-home"), "REACH_HOME" => File.join(directory, "reach-home"),
            "TEACH_DATABASE_URL" => "postgres:///#{test_case.fetch('database')}",
            "SMOKE_CASE_BUDGET_USD" => test_case.fetch("budget_usd").to_s }
    log = File.join(directory, "harness.log")
    pid = nil
    File.open(log, "w", 0o600) do |file|
      pid = Process.spawn(env, *argv, File.join(directory, "case.json"), directory,
                          chdir: directory, unsetenv_others: true, pgroup: true, out: file, err: file)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
      loop do
        finished = Process.waitpid2(pid, Process::WNOHANG)
        if finished
          raise Failure, "harness exited #{finished[1].exitstatus}" unless finished[1].success?
          raise Failure, "harness log limit exceeded" if file.size > CONFIG.fetch("limits").fetch("log_max_bytes")
          break
        end
        raise Failure, "case timeout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Failure, "harness log limit exceeded" if file.size > CONFIG.fetch("limits").fetch("log_max_bytes")
        raise Failure, "smoke stopped" if @stopped || ENV["REACH_SMOKE_DISABLE"] == "1" || File.exist?(File.join(File.dirname(directory), "STOP")) || File.exist?(File.join(directory, "STOP"))
        sleep 0.2
      end
    end
  ensure
    if pid
      begin
        Process.kill("TERM", -pid)
        sleep 0.1
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
      cleanup_containers(directory, test_case)
    end
  end

  def self.cleanup_containers(directory, test_case)
    nonce = test_case.fetch("nonce")
    return unless nonce.match?(/\A[0-9a-f]{32}\z/)
    temporary = File.join(File.dirname(File.dirname(directory)), ".rs-#{nonce[0, 12]}")
    out, _err, status = Open3.capture3("timeout", "5", "docker", "ps", "-q")
    return unless status.success?
    out.lines.map(&:strip).grep(/\A[0-9a-f]{12,64}\z/).each do |id|
      details, _err, code = Open3.capture3("timeout", "5", "docker", "inspect", id)
      next unless code.success?
      owned = JSON.parse(details).any? { |item| Array(item["Mounts"]).any? { |mount| [directory, temporary].any? { |root| mount["Source"].to_s.start_with?(root + "/") } } }
      Open3.capture3("timeout", "5", "docker", "stop", "--time", "1", id) if owned
    end
  rescue SystemCallError, JSON::ParserError
    nil
  end

  def self.main(argv)
    candidate = File.join(ROOT, ".scratch/teach-security-validation")
    default_teach = File.file?(File.join(candidate, "lib/teach/security_validation.rb")) ? candidate : File.expand_path("~/bitbucket/paterasai/teach")
    options = { grokit: File.expand_path("~/bitbucket/paterasai/grokit"), teach: default_teach,
                output: File.join(ROOT, ".scratch", "course-smoke-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(3)}"),
                budget: CONFIG.fetch("limits").fetch("run_budget_usd"), mode: "plan", filters: [], cases: [], merge: [] }
    OptionParser.new do |parser|
      parser.on("--grokit DIR") { |v| options[:grokit] = File.expand_path(v) }
      parser.on("--teach DIR") { |v| options[:teach] = File.expand_path(v) }
      parser.on("--output DIR") { |v| options[:output] = File.expand_path(v) }
      parser.on("--select TEXT") { |v| options[:filters] << v }
      parser.on("--case ID") { |v| options[:cases] << v }
      parser.on("--budget-usd N", Float) { |v| options[:budget] = v }
      parser.on("--harness-argv JSON") { |v| options[:harness] = JSON.parse(v) }
      parser.on("--run") { options[:mode] = "run" }
      parser.on("--plan") { options[:mode] = "plan" }
      parser.on("--verify-case DIR") { |v| options[:verify] = File.expand_path(v) }
      parser.on("--bundle DIR") { |v| options[:bundle] = File.expand_path(v) }
      parser.on("--dovetail DIR") { |v| options[:dovetail] = File.expand_path(v) }
      parser.on("--runtime-kit DIR") { |v| options[:runtime_kit] = File.expand_path(v) }
      parser.on("--merge-run DIR") { |v| options[:merge] << File.expand_path(v) }
      parser.on("--keep-passing") { options[:keep_passing] = true }
      parser.on("--archive RUN") { |v| options[:archive] = File.expand_path(v) }
      parser.on("--prune RUN") { |v| options[:prune] = File.expand_path(v) }
    end.parse!(argv)
    raise Failure, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    return archive(options[:archive]) if options[:archive]
    return prune(options[:prune]) if options[:prune]
    raise Failure, "REACH_SMOKE_DISABLE=1" if ENV["REACH_SMOKE_DISABLE"] == "1"
    if options[:verify]
      test_case = JSON.parse(File.read(File.join(options[:verify], "case.json")))
      cost = Evidence.new(test_case, options[:verify]).verify!
      puts "verified #{test_case.fetch('id')}; cost_usd=#{cost}"
      return 0
    end
    raise Failure, "positive finite budget required" unless options[:budget].finite? && options[:budget] > 0
    command = options[:harness]
    native = options[:mode] == "run" && command.nil?
    raise Failure, "invalid harness argv" if command && !(command.is_a?(Array) && !command.empty? && command.all? { |arg| arg.is_a?(String) && !arg.empty? })
    inventory = Inventory.new(grokit: options[:grokit], teach: options[:teach])
    return merge_reports(options[:merge], inventory, scratch_path!(options[:output])) unless options[:merge].empty?
    unknown = options[:cases] - inventory.cases.map { |c| c.fetch("id") }
    raise Failure, "unknown cases: #{unknown.join(', ')}" unless unknown.empty?
    selected = inventory.cases.select { |c| options[:filters].all? { |filter| c.fetch("id").include?(filter) } && (options[:cases].empty? || options[:cases].include?(c.fetch("id"))) }
    raise Failure, "selection matched no cases" if selected.empty?
    options[:output] = scratch_path!(options[:output])
    raise Failure, "output already exists" if File.exist?(options[:output])
    if options[:mode] == "run"
      storage_preflight(options[:output], selected.length)
      graders = grader_preflight
    end
    FileUtils.mkdir_p(options[:output], mode: 0o700)
    if native
      pinned = File.join(options[:output], "grokit")
      FileUtils.mkdir_p(pinned)
      tarball = File.join(options[:output], "grokit.tar")
      git(options[:grokit], "archive", "--format=tar", "--output=#{tarball}", inventory.sources.fetch("grokit_sha"))
      _out, err, status = Open3.capture3("tar", "-xf", tarball, "-C", pinned)
      raise Failure, "could not export pinned Grokit: #{err}" unless status.success?
      File.delete(tarball)
      ruby = File.join(File.expand_path(ENV.fetch("SMOKE_RUBY4_BIN", "~/.rubies/ruby-4.0.6/bin")), "ruby")
      raise Failure, "native smoke needs Ruby 4 at #{ruby}" unless File.executable?(ruby)
      command = [ruby, File.join(__dir__, "course_native.rb"), "--teach", options[:teach], "--grokit", pinned,
                 "--bundle", options[:bundle] || File.expand_path("~/bitbucket/paterasai/teach/vendor/bundle"),
                 "--dovetail", options[:dovetail] || File.expand_path("~/github/foss/dovetail")]
      command += ["--runtime-kit", options[:runtime_kit]] if options[:runtime_kit]
    end
    previous_signals = %w[INT TERM].to_h { |signal| [signal, Signal.trap(signal) { @stopped = true }] }
    report = { "mode" => options[:mode], "execution_kind" => options[:mode] == "plan" ? "plan" : native ? "native_fixture" : "agent_adapter", "sources" => inventory.sources, "inventory_count" => inventory.cases.length,
               "selected_count" => selected.length, "budget_usd" => options[:budget], "cost_usd" => 0.0,
               "coverage_complete" => false, "cases" => selected.each_with_index.map { |test_case, index| { "id" => test_case.fetch("id"), "directory" => File.join(options[:output], format("%04d", index + 1)), "status" => "not_run" } } }
    report["environment"] = { "grader_images" => graders } if graders
    save_report(options[:output], report)
    halted = nil
    signatures = Hash.new(0)
    selected.each_with_index do |test_case, index|
      reservation = native ? 0 : CONFIG.fetch("limits").fetch("case_budget_usd")
      directory = File.join(options[:output], format("%04d", index + 1))
      row = report["cases"].fetch(index)
      if options[:mode] == "run" && (halted || @stopped || report["cost_usd"] + reservation > options[:budget] || File.exist?(File.join(options[:output], "STOP")))
        row["reason"] = halted || "budget reservation or STOP"
        save_report(options[:output], report)
        next
      end
      begin
        test_case = materialize(test_case, directory, reservation)
        row["status"] = "planned"
      rescue SystemCallError => error
        row["status"] = "failed"
        row["reason"] = "case preparation: #{error.message}"
        save_report(options[:output], report)
        next
      end
      if options[:mode] == "run"
        row["canary"] = true if index.zero?
        begin
          execute(command, test_case, directory, CONFIG.fetch("limits").fetch("case_timeout_s"))
          row["cost_usd"] = Evidence.new(test_case, directory).verify!
          report["cost_usd"] += row["cost_usd"]
          row["status"] = "passed"
          unless options[:keep_passing]
            begin
              prune_passing(directory, test_case)
              row["pruned"] = true
            rescue Failure => error
              row["prune_error"] = error.message
            end
          end
        rescue Failure, SystemCallError => error
          row["status"] = "failed"
          row["reason"] = error.message
          failure = File.join(directory, "failure.json")
          row["failure"] = JSON.parse(File.read(failure)) if File.file?(failure)
          report["cost_usd"] += reservation
          row["charged_reservation_usd"] = reservation
          if environment_failure?([row["reason"], row.dig("failure", "reason")].compact.join(" "))
            row["failure_class"] = "environment"
            halted = halt!(options[:output], "halted: environment failure in #{row['id']}#{index.zero? ? ' (canary)' : ''}: #{row.dig('failure', 'reason') || row['reason']}"[0, 600])
          else
            row["failure_class"] = "product"
            signature = failure_signature(row)
            signatures[signature] += 1
            limit = CONFIG.fetch("limits").fetch("repeat_failure_halt")
            halted = halt!(options[:output], "halted: #{limit} cases failed with one signature: #{signature}") if signatures[signature] >= limit
          end
        end
      end
      report["coverage_complete"] = options[:mode] == "run" && selected.length == inventory.cases.length && report["cases"].length == selected.length && report["cases"].all? { |r| r["status"] == "passed" }
      save_report(options[:output], report)
      puts "#{row['id']}: #{row['status']}#{row['reason'] ? ' (' + row['reason'] + ')' : ''}" if options[:mode] == "run"
      $stdout.flush
    end
    puts "#{report['cases'].length}/#{inventory.cases.length} cases #{options[:mode]}; #{report['cases'].group_by { |r| r['status'] }.transform_values(&:length)}; #{options[:output]}/report.json"
    options[:mode] == "plan" || report["cases"].all? { |r| r["status"] == "passed" } ? 0 : 1
  rescue Failure, OptionParser::ParseError, JSON::ParserError, SystemCallError, KeyError => error
    warn "course_matrix: #{error.message}"
    1
  ensure
    previous_signals&.each { |signal, handler| Signal.trap(signal, handler) }
  end
end

exit CourseMatrix.main(ARGV) if $PROGRAM_NAME == __FILE__
