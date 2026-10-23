require "json"
require "yaml"
require "date"
require "time"
require "fileutils"
require "open3"
require "optparse"
require "securerandom"
require "stringio"
require_relative "course_matrix"

module CourseNative
  ROOT = File.expand_path("../..", __dir__)
  class Failure < StandardError; end

  class Run
    def initialize(test_case, directory, options)
      @case = test_case
      @directory = File.realpath(directory)
      @options = options
      @teach = File.join(@directory, "teach")
      @grokit = options.fetch(:grokit)
      @stages = []
      @session = "course-smoke-#{@case.fetch('nonce')}"
      @password = SecureRandom.hex(16)
      @evidence = @case.slice("id", "nonce", "database").merge("synthetic" => true, "cost_usd" => 0, "execution_kind" => "native_fixture", "transport" => "in_process_rack", "stages" => @stages)
    end

    def write(name, value)
      File.write(File.join(@directory, name), JSON.pretty_generate(value) + "\n")
      name
    end

    def stage(name)
      @stage = name
      puts "#{@case.fetch('id')}: #{name}"
      $stdout.flush
      value = yield
      path = write("#{name}.json", value)
      @stages << { "name" => name, "status" => "passed", "evidence" => path }
      write("evidence.json", @evidence)
      value
    end

    def command(*argv)
      out, err, status = Open3.capture3(*argv)
      raise Failure, "#{argv.first(2).join(' ')}: #{(err + out)[-1200..] || (err + out)}" unless status.success?
      out
    end

    def setup
      raise Failure, "Reach source changed after matrix planning" unless @case.fetch("sources").fetch("reach_source_sha256") == CourseMatrix.source_digest
      raise Failure, "not a scratch database name" unless @case.fetch("database").match?(/\Areach_smoke_[a-f0-9]{20}\z/)
      raise Failure, "case database environment differs" unless ENV["TEACH_DATABASE_URL"] == "postgres:///#{@case.fetch('database')}"
      raise Failure, "Teach source must implement the security validation contract" unless File.file?(File.join(@options.fetch(:teach), "lib/teach/security_validation.rb"))
      FileUtils.mkdir_p(@teach)
      %w[lib bin specs policy directives agent_control sidecar templates assets locales Gemfile Gemfile.lock VERSION teach.spec.yml teach.rstack_component.yml].each do |name|
        source = File.join(@options.fetch(:teach), name)
        FileUtils.cp_r(source, File.join(@teach, name)) if File.exist?(source)
      end
      path = File.join(@teach, "teach.spec.yml")
      spec = YAML.safe_load(File.read(path), permitted_classes: [Date, Time])
      spec.fetch("course_model").fetch("assignments").each_with_index do |assignment, index|
        current = @case.fetch("assignment").delete_prefix("A").to_i - 1
        offset = index < current ? -(current - index) * 14 : (index - current + 1) * 14
        assignment["due"] = "#{Date.today + offset} 23:59"
      end
      File.write(path, YAML.dump(spec))
      temporary = File.join(File.dirname(File.dirname(@directory)), ".rs-#{@case.fetch('nonce')[0, 12]}")
      raise Failure, "scratch parent path is too long for Chromium sockets; choose a shorter --output path" if temporary.bytesize > 55
      FileUtils.mkdir_p(temporary, mode: 0o700)
      @evidence["temporary_directory"] = temporary
      ENV.update(
        "PATH" => [File.dirname(RbConfig.ruby), ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "TMPDIR" => temporary,
        "BUNDLE_GEMFILE" => File.join(@teach, "Gemfile"), "BUNDLE_PATH" => @options.fetch(:bundle),
        "BUNDLE_APP_CONFIG" => File.join(@directory, "bundle-config"), "REACH_HARNESS" => "codex",
        "CODEX_THREAD_ID" => @session, "REACH_WORKSPACE_ROOT" => File.join(@directory, "work"),
        "REACH_DOWNLOADS_DIR" => File.join(@directory, "downloads"), "TEACH_GROKIT_ROOT" => @grokit,
        "TEACH_GROKIT_SPEC" => File.join(@grokit, "specs/app.yml"),
        "TEACH_DOVETAIL" => File.join(@options.fetch(:dovetail), "exe/dovetail"),
        "TEACH_BUILD_CACHE" => File.join(File.dirname(@directory), "build-cache"),
        "TEACH_SANDBOX_RUNNER" => File.join(@teach, "bin/teach-sandbox-runner"),
        "TEACH_GRADER_IMAGE" => "teach-grader:ruby-4.0.7", "TEACH_GRADER_IMAGE_RUBY26" => "teach-grader:ruby-2.6.10"
      )
      policy = { "module_selection" => { "mode" => @case.fetch("selection_mode"), "count" => 2, "slices" => %w[backend panel] } }
      File.write(File.join(ENV.fetch("TEACH_HOME"), "course_policy.yml"), YAML.dump(policy))
      command("createdb", @case.fetch("database"))
      require "bundler/setup"
      require "rack/mock"
      $LOAD_PATH.unshift(File.join(@teach, "lib"), File.join(ROOT, "lib"))
      require "teach/web/app"
      require "teach/admin"
      require "teach/keys"
      require "teach/packages/builder"
      require "teach/releases"
      require "teach/grader"
      require "reach"
      Reach::Runtime.define_singleton_method(:spawn_background) { |*args, **options| nil }
      install_transport
      Reach::TokenBucket.define_singleton_method(:acquire!) { |**options| nil }
      @evidence["network_rate_limiter_exercised"] = false
      Teach::Keys.generate
      Teach::Models::Course.create(id: @case.fetch("course"), title: "Synthetic course smoke", term: "Smoke", timezone: "America/Los_Angeles", ends_on: (Date.today + 180).to_s)
      roster = File.join(@directory, "roster.csv")
      File.write(roster, "student_id,username,display_name,group\n#{@case.fetch('student_id')},#{@case.fetch('username')},Synthetic Smoke Student,SMOKE\n")
      imported = Teach::Roster.import!(course_id: @case.fetch("course"), path: roster, actor: "smoke")
      raise Failure, "scratch roster rejected: #{imported}" unless imported["added"] == 1 && imported["rejected"].empty?
      minted = Teach::CourseCodes.mint!(course_id: @case.fetch("course"), actor: "smoke")
      secret = minted.fetch("secret")
      @code = "#{Teach::Enrollment.normalize_course_id(@case.fetch('course'))}-#{secret[0, 4]}-#{secret[4, 4]}"
      public_key = Teach::Models::SigningKey.active.fetch("public_key_pem")
      File.write(File.join(@directory, "teach-public.pem"), public_key)
      @evidence["teach_public_key"] = "teach-public.pem"
    end

    def install_transport
      Reach::Client.class_eval do
        define_method(:perform) do |method, path, query_string, body, headers, target|
          request = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(target)
          headers.each { |key, value| request[key] = value }
          sign!(request, method: method, target: target, body: body)
          env = { input: body.to_s, "CONTENT_TYPE" => "application/json", "HTTPS" => "on" }
          request.each_header { |key, value| env["HTTP_#{key.upcase.tr('-', '_')}"] = value }
          response = Rack::MockRequest.new(Teach::Web::App).request(method.to_s.upcase, target, env)
          Teach::Qualify.run_pending if method == :post && path == "/api/v1/qualifications" && response.status.between?(200, 299)
          Reach::Client::Response.new(status: response.status, headers: response.headers, body: response.body)
        end
      end
    end

    def practice
      state = Reach::Validation.start(course_code: @code, harness: "codex")
      answers = {}
      state.fetch("questions").each do |question|
        answers[question.fetch("id")] = answer(question)
        Reach::Validation.advance("answer", question: question.fetch("id"), text: answers.fetch(question.fetch("id")))
      end
      Reach::Validation.advance("plan", text: "Save invented answers in answers.json and explain this synthetic practice in README.md.")
      Reach::Validation.advance("artifact", question: "answers.json", text: JSON.generate(answers))
      Reach::Validation.advance("artifact", question: "README.md", text: readme)
      %w[check qualify submit finish].each { |action| Reach::Validation.advance(action) }
      state = Reach::Validation.read
      raise Failure, "security validation did not pass" unless state["phase"] == "passed"
      state.reject { |key, _| %w[questions answers].include?(key) }
    end

    def answer(question)
      text = "In this invented cafe, a fictional manager checks made up sales and stock information before deciding what to prepare. The manager reviews the result and keeps responsibility for the decision. No real student or business is represented."
      text += " All values and feedback in this case are synthetic." while Reach::Part.word_count(text) < question.fetch("min_words")
      text
    end

    def readme
      Reach::ReadmeCheck::SECTIONS.map do |section|
        "## #{section}\n\nThis synthetic cafe smoke checks the delivered contract and expected behavior with invented evidence. The fictional manager reviews the decision, the information flow, the boundaries, and the expected outcome. This is developer test machinery, not a student's work.\n"
      end.join("\n")
    end

    def consent
      pending = Reach::Login.read_json(Reach::Consent.pending_path)
      raise Failure, "native consent question missing" unless pending
      transcript = File.join(@directory, "conversation.jsonl")
      File.open(transcript, "a") { |file| file.puts(JSON.generate("type" => "assistant", "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => pending.fetch("question") }] })) }
      entry = { "text" => "yes", "gate" => "allowed", "session_id" => @session, "seq" => 1,
                "digest" => Reach::Crypto.digest_hex("yes"), "transcript_path" => transcript }
      raise Failure, "synthetic student consent was not captured" unless Reach::Consent.observe(entry)
    end

    def enrollment
      preview = Reach::Enroll.preview(@code, Reach::Runtime.default_teach_url)
      rules = Reach::Identity.rules(preview["identity"], preview["hints"])
      username = Reach::Identity.normalize_username(@case.fetch("username"), rules)
      value = Reach::Enroll.register_v2(course_code: @code, username: username, student_id: @case.fetch("student_id"),
                                       teach_url: Reach::Runtime.default_teach_url, harness: "codex", enrolled_via: "chat", password: @password)
      Reach::EnrollFlow.finish("smoke")
      Reach::Sync.run
      signed, message = Reach::Login.terminal_signin(@case.fetch("student_id"), @password)
      raise Failure, "native sign-in failed: #{message}" unless signed == true
      Reach::Login.sign_in_session(@session, "codex")
      value.slice("install_id", "student_id", "course")
    end

    def select_modules
      spec = YAML.safe_load(File.read(File.join(@grokit, "specs/app.yml")), permitted_classes: [Date, Time])
      choices = spec.fetch("modules").map { |mod| mod.fetch("id") }
      companion = choices.find { |id| id != @case.fetch("module") }
      selected = [@case.fetch("module"), companion]
      if @case.fetch("selection_mode") == "instructor"
        Teach::Modules.issue!(student_id: @case.fetch("student_id"), modules: selected, source: "instructor", actor: "smoke", include_current: true)
        Reach::Modules.refresh!
      else
        outcome = Reach::Modules.choose!(selected, session_id: @session)
        raise Failure, "module choice did not ask: #{outcome}" unless outcome["state"] == "asked"
        consent
        outcome = Reach::Modules.choose!(selected, session_id: @session)
        raise Failure, "module choice did not lock: #{outcome}" unless outcome["state"] == "locked"
      end
      Teach::Releases.create(assignment: @case.fetch("assignment"))
      { "course" => @case.fetch("course"), "mode" => @case.fetch("selection_mode"), "modules" => Reach::Modules.module_ids }
    end

    def sync
      result = Reach::Sync.run
      @workspace = Reach::Workspace.current_slices.find do |path|
        meta = Reach::Workspace.metadata(path)
        meta["cutout_id"] == @case.fetch("cutout") && meta["slice"] == @case.fetch("slice")
      end
      raise Failure, "target workspace not delivered: #{result}" unless @workspace
      %w[AGENTS.md README.md contract/README.md api/README.md api/slice-api.json shape/brief.md].each do |relative|
        raise Failure, "delivered contract missing #{relative}" unless File.file?(File.join(@workspace, relative)) && File.size(File.join(@workspace, relative)) > 0
      end
      @meta = Reach::Workspace.metadata(@workspace)
      output = StringIO.new
      configured = Reach::CodexSetup.configure_terminal(input: StringIO.new("yes\n"), output: output)
      write("codex-setup.json", configured)
      Reach::HookLiveness.record_hook!("codex", "prompt")
      result
    end

    def handoff
      answers = {}
      @case.fetch("questions").each do |question|
        text = answer(question)
        recorded = Reach::Transcript.record(@session, kind: "prompt", harness: "codex", cutout_id: @case.fetch("cutout"), slice: @case.fetch("slice"), space: "slice", fields: { "text" => text, "gate" => "allowed" })
        Reach::Part.observe_prompt({ "kind" => "slice", "path" => @workspace }, text, recorded)
        Reach::Part.record!(question.fetch("id"), workspace: @workspace)
        answers[question.fetch("id")] = text
      end
      @evidence["answers"] = write("answers.json", answers)
      Reach::Part.document(@case.fetch("assignment"))
    end

    def build
      paths = @case.fetch("owned_paths")
      adaptations = []
      paths.each do |relative|
        destination = File.join(@workspace, relative)
        original = File.binread(destination)
        FileUtils.mkdir_p(File.join(@directory, "starting-copy", File.dirname(relative)))
        File.binwrite(File.join(@directory, "starting-copy", relative), original)
        source = File.binread(File.join(@grokit, relative))
        if relative.end_with?(".rb") && source.include?("Grokit::Decimal") && !Reach::Check.granted_constants(@workspace).include?("Decimal")
          helper = File.read(File.join(@grokit, "lib/grokit/decimal.rb"))
          body = helper.match(/^  module Decimal\n(?<body>.*)^  end\nend\s*\z/m)
          declaration = source.match(/^(?<indent>\s*)class #{Regexp.escape(@meta.fetch('class').split('::').last)}\s*$/)
          raise Failure, "pinned Decimal fixture source shape differs" unless body && declaration
          indentation = declaration[:indent]
          nested = "\n#{indentation}  module SmokeDecimal\n" + body[:body].lines.map { |line| "#{indentation}#{line}" }.join + "#{indentation}  end\n"
          source = source.sub(declaration[0], declaration[0] + nested).gsub("Grokit::Decimal", "SmokeDecimal")
          source = source.lines.reject { |line| line.match?(/\A\s*require\s+["']grokit\/decimal["']\s*\z/) }.join
          adaptations << { "owned_path" => relative, "owned_helper" => "SmokeDecimal", "source" => "lib/grokit/decimal.rb" }
        end
        if @case.fetch("cutout") == "finance.a3s2" && @case.fetch("slice") == "backend" && relative == "modules/finance/lib/grokit/finance/behaviours/restrict_sensitive.rb"
          seed = "          first = lines.first[:amount]\n          total = lines.reduce(Grokit::Money.new(0, first.currency)) { |sum, line| sum + line[:amount] }\n"
          raise Failure, "pinned Finance aggregation fixture source shape differs" unless source.scan(seed).length == 1 && source.include?("MINIMUM_PEOPLE = 3")
          source = source.sub(seed, "          total = lines.map { |line| line[:amount] }.reduce(:+)\n")
          adaptations << { "owned_path" => relative, "operation" => "reduce existing typed amounts", "minimum_people" => 3 }
        end
        header = original.lines.first.to_s
        source = source.lines.reject { |line| line.match?(/^\s*#/) }.join if relative.end_with?(".rb")
        File.binwrite(destination, header + source)
      end
      File.write(File.join(@workspace, "README.md"), readme)
      features = @case.fetch("local_scenarios").map { |s| s.fetch("feature") }.uniq
      features.each do |relative|
        destination = File.join(@workspace, "qualify/features", File.basename(relative))
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(@grokit, relative), destination)
      end
      steps_dir = File.join(@workspace, "qualify/step_definitions")
      FileUtils.mkdir_p(steps_dir)
      FileUtils.cp(File.join(@grokit, "features/step_definitions", "#{@case.fetch('module')}_steps.rb"), steps_dir)
      fixtures = Dir.glob(File.join(@grokit, "fixtures", "*", "*.yml")).to_h do |path|
        [[File.basename(File.dirname(path)), File.basename(path, ".yml")], YAML.safe_load(File.read(path), permitted_classes: [Date, Time])]
      end
      helper = "require 'yaml'\nrequire 'date'\nBefore do\n  data = YAML.safe_load(#{YAML.dump(fixtures).dump}, permitted_classes: [Date, Time])\n  Grokit::Fixtures.send(:cache).merge!(data)\nend\n"
      File.write(File.join(steps_dir, "smoke_fixture_steps.rb"), helper)
      { "fixture" => "pinned Grokit reference slice and developer scenarios", "owned_paths" => paths, "adaptations" => adaptations, "grokit_sha" => @case.fetch("sources").fetch("grokit_sha") }
    end

    def runtime
      shared = File.join(File.dirname(@directory), "runtime")
      FileUtils.mkdir_p(shared)
      FileUtils.ln_s(shared, Reach::Paths.runtime_dir) unless File.exist?(Reach::Paths.runtime_dir)
      return if Reach::RuntimeKit.active
      out = StringIO.new
      Reach::RuntimeKit.install!(from: @options[:runtime_kit], out: out)
      File.write(File.join(@directory, "runtime-install.log"), out.string)
    end

    def rows(values, expected: @case.fetch("scenarios"))
      features = expected.to_h { |s| [s.fetch("name"), s.fetch("feature")] }
      Array(values).select { |row| features.key?(row["name"]) }.map { |row| { "feature" => features.fetch(row.fetch("name")), "name" => row.fetch("name"), "result" => row.fetch("result") } }
    end

    def qualify(local_only:)
      result = nil
      3.times do |attempt|
        result = Reach::Qualify.run(@workspace, local_only: local_only)
        write("qualification-#{local_only ? 'local' : 'remote'}-attempt-#{attempt + 1}.json", result)
        break unless !local_only && result["pending"] == true && attempt < 2
        sleep 1
      end
      write(local_only ? "qualification-local-raw.json" : "qualification-remote-raw.json", result)
      raise Failure, "qualification failed: #{result['findings']}" unless result["findings"].empty? && (local_only || result["passed"] == true)
      result
    end

    def submit
      pending = Reach::Submit.submit(slice: File.basename(@workspace))
      raise Failure, "submission did not ask consent: #{pending}" unless pending["state"] == "asked"
      consent
      result = Reach::Submit.submit(slice: File.basename(@workspace))
      raise Failure, "submission not ingested: #{result}" unless result["state"] == "ingested"
      @submission_id = result.fetch("submission_id")
      @evidence["submission_id"] = @submission_id
      @evidence["submission_manifest"] = write("submission-manifest.json", Reach::Submit.send(:build_manifest, @workspace, @meta))
      @student_message = result.fetch("text")
      result
    end

    def receipts(kind)
      server = Teach::Models::Receipt.for_submission(@submission_id).find { |r| r["kind"] == kind }
      raise Failure, "Teach #{kind} receipt missing" unless server
      body = server.fetch("body")
      student = Reach::Receipts.wait(submission_id: @submission_id, kind: kind, timeout_s: 5)
      raise Failure, "Reach #{kind} receipt missing" unless student
      @evidence["receipts"] ||= {}
      @evidence["receipts"][kind] = { "teach" => write("teach-#{kind}.json", body), "student" => write("student-#{kind}.json", student) }
      student
    end

    def run
      setup
      stage("security_validation") { practice }
      stage("enroll") { enrollment }
      stage("module_selection") { select_modules }
      stage("sync") { sync }
      Dir.chdir(@workspace) do
        stage("answer_handoff") { handoff }
        stage("plan") { Reach::Plan.save(@workspace, "behaviour" => "Exercise #{@case.fetch('cutout')} with synthetic cafe data", "steps" => ["Check the delivered contract", "Install the deterministic fixture", "Qualify and verify receipts"], "scenarios" => @case.fetch("scenarios").first(12).map { |s| s.fetch("name")[0, 200] }) }
        stage("build") { build }
        findings = stage("check") { Reach::Check.run(@workspace, format: :agent) }
        @evidence["shape"] = write("shape.json", { "errors" => findings.length, "findings" => findings })
        raise Failure, "native check findings: #{findings}" unless findings.empty?
        stage("checkpoint") { Reach::Checkpoint.save(@workspace, note: "Synthetic full-course smoke fixture") }
        local = stage("local_qualify") { runtime; qualify(local_only: true) }
        @evidence["local_qualify"] = write("local-scenarios.json", rows(local.dig("steps", "local_pass", "rows"), expected: @case.fetch("local_scenarios")))
        remote = stage("teach_qualify") { qualify(local_only: false) }
        @evidence["teach_qualify"] = write("teach-scenarios.json", rows(remote.dig("steps", "remote", "rows", "hidden")))
        stage("submit") { submit }
        stage("teach_receipt") { receipts("ingest") }
        stage("student_receipt") { { "text" => @student_message } }
        grade = stage("grade") do
          submission = Teach::Models::Submission.find(@submission_id)
          Teach::Grader.grade_one(submission, strict: true)
          receipts("grade")
        end
        @evidence["grade"] = write("graded-scenarios.json", rows(grade.fetch("scenarios")))
        write("evidence.json", @evidence)
      end
    rescue StandardError => error
      write("failure.json", { "stage" => @stage || "setup", "error" => error.class.name, "reason" => error.message, "backtrace" => error.backtrace.first(8) })
      warn "#{@stage || 'setup'}: #{error.class}: #{error.message}"
      raise
    end
  end

  def self.main(argv)
    options = {}
    OptionParser.new do |parser|
      parser.on("--teach DIR") { |v| options[:teach] = File.expand_path(v) }
      parser.on("--grokit DIR") { |v| options[:grokit] = File.expand_path(v) }
      parser.on("--bundle DIR") { |v| options[:bundle] = File.expand_path(v) }
      parser.on("--dovetail DIR") { |v| options[:dovetail] = File.expand_path(v) }
      parser.on("--runtime-kit DIR") { |v| options[:runtime_kit] = File.expand_path(v) }
    end.parse!(argv)
    raise Failure, "case and scratch directory required" unless argv.length == 2
    test_case = JSON.parse(File.read(argv[0]))
    Run.new(test_case, argv[1], options).run
    0
  rescue StandardError => error
    warn "course_native: #{error.message}"
    1
  end
end

exit CourseNative.main(ARGV) if $PROGRAM_NAME == __FILE__
