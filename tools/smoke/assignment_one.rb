#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "csv"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "socket"
require "time"
require "yaml"
require "timeout"
require "securerandom"

module AssignmentOne
  REPO = File.expand_path("../..", __dir__)
  HOME_DIR = Dir.home
  ASSIGNMENT = "A1"
  CUTOUT = "context.a1"
  SLICE = "backend"
  COURSE_ID = "bus101-fa26"
  COURSE_END_DATE = "2026-12-18"
  OWNED_RELATIVE = "modules/context/lib/grokit/context/behaviours/return_profile_value.rb"
  STUDENT_ID = "1000001"
  STUDENT_USERNAME = "smok001"
  SECOND_STUDENT_ID = "1000002"
  SECOND_STUDENT_USERNAME = "smok002"
  WRONG_STUDENT_ID = "1999999"
  STUDENT_PASSWORD = "smoke-password-1"
  README_SOURCE = File.join(__dir__, "assignment_one_readme.md")
  COMMAND_TIMEOUT_S = 180
  GRADER_TIMEOUT_S = Integer(ENV.fetch("SMOKE_GRADER_TIMEOUT", "900"))

  class Skip < StandardError; end
  class Fail < StandardError; end
  class Fatal < StandardError; end

  Result = Struct.new(:name, :group, :status, :detail, :command, :output, :expected, :actual, keyword_init: true) do
    def to_h
      { "name" => name, "group" => group, "status" => status, "detail" => detail, "command" => command,
        "output" => output, "expected" => expected, "actual" => actual }
    end
  end

  class Runner
    def initialize(options)
      @options = options
      @teach_dir = options[:teach_dir] && File.expand_path(options[:teach_dir])
      @teach_repo = File.expand_path(options[:teach_repo])
      @grokit = File.expand_path(options[:grokit])
      @dovetail = File.expand_path(options[:dovetail])
      @ruby4_bin = File.expand_path(options[:ruby4_bin])
      @teach_bundle = File.expand_path(options[:teach_bundle])
      @run_dir = File.expand_path(options[:run_dir] || File.join(HOME_DIR, ".cache", "reach-smoke", "a1", Time.now.strftime("%Y%m%d-%H%M%S")))
      @results = []
      @receipts = {}
      @secrets = []
      @teach_pid = nil
      @grader_pid = nil
      @last = nil
    end

    attr_reader :run_dir, :results

    def run
      guard_real_homes!
      FileUtils.mkdir_p(@run_dir)
      export_teach unless @teach_dir
      prepare_paths
      create_scratch_database
      begin
        execute
      ensure
        stop_process(@grader_pid)
        stop_process(@teach_pid)
        drop_scratch_database
        write_summary
      end
      @results.none? { |result| result.status == "fail" }
    end

    private

    def execute
      step("dovetail-revision-pin", "install") { check_dovetail_pin }
      return skip_rest("prerequisites missing") unless step("prerequisites", "install") { check_prerequisites }
      return skip_rest("teach could not be provisioned") unless step("teach-course-provision", "handshake") { provision_teach }

      step("reference-pack", "reference") { reference_pack }
      step("release-before-enroll", "handshake") { release_before_enroll }
      step("teach-serve", "handshake") { start_teach }
      return skip_rest("teach did not start") unless @teach_pid

      installed = step("install-local-archive", "install") { install_plugin(false) }
      installed ||= step("install-local-archive-dereferenced", "install") { install_plugin(true) }
      step("install-public-zip", "install") { install_public } if @options[:public]
      return skip_rest("plugin did not install") unless installed

      step("blocked-before-enroll", "handshake") { blocked_before_enroll }

      step("reference-locked-before-enroll", "reference") { reference_locked_before_enroll }
      step("setup-codex", "install") { setup_codex }
      step("doctor", "install") { doctor }
      return skip_rest("enrollment did not complete") unless step("enroll-handshake", "handshake") { enroll }

      step("enroll-wrong-student-id-refused", "handshake") { wrong_student_id_refused }
      return skip_rest("no workspace delivered") unless step("sync-delivers-workspace", "handshake") { sync_workspace }

      step("reference-after-sync", "reference") { reference_after_sync }
      step("reference-tamper-refused", "reference") { reference_tamper_refused }
      step("status-after-sync", "handshake") { status_after_sync }
      step("login-gate-and-sign-in", "local") { login_sign_in }
      step("guarded-write-owned", "local") { guarded_write_owned }
      step("edit-outside-owned-blocked", "local") { edit_outside_blocked }
      step("plan-save", "local") { plan_save }
      step("implementation-written", "local") { write_implementation }
      step("readme-filled", "local") { fill_readme }
      step("reach-check", "local") { reach_check }
      step("checkpoint", "local") { checkpoint }
      step("submit-refused-unqualified", "local") { submit_refused_unqualified }
      step("qualify-scenarios-written", "local") { write_qualify_scenarios }
      step("qualify-list", "local") { qualify_list }
      if step("grader-started", "remote") { start_grader }
        if step("qualify-passes", "remote") { qualify_passes } &&
           step("submit-refused-without-part", "local") { submit_refused_without_part } &&
           step("student-part-recorded", "local") { record_student_part } &&
           step("submit-and-ingest-receipt", "ingest") { submit }
          step("ingest-receipt-ids", "ingest") { ingest_receipt_ids }
          if step("grader", "remote") { run_grader }
            step("sync-grade-receipt", "remote") { sync_grade }
          else
            step("sync-grade-receipt", "remote") { raise Skip, "no grade receipt was produced" }
          end
        end
      else
        %w[qualify-passes submit-and-ingest-receipt ingest-receipt-ids grader sync-grade-receipt].each do |name|
          step(name, "remote") { raise Skip, "the grader is not running, so nothing can qualify or be graded" }
        end
      end
      step("codex-conversation", "codex") { raise Skip, "not run by the transport smoke; see docs/smoke-assignment-1.md" }
      step("lan-second-device", "lan") { raise Skip, "manual; see docs/smoke-assignment-1.md" }
    end

    def skip_rest(reason)
      @results << Result.new(name: "remaining-steps", group: "install", status: "skip", detail: reason)
      nil
    end

    def step(name, group)
      started = Time.now
      @last = { command: nil, output: nil, expected: nil, actual: nil }
      result = Result.new(name: name, group: group)
      ok = false
      begin
        detail = yield
        result.status = "pass"
        result.detail = detail.is_a?(String) ? detail : nil
        ok = true
      rescue Skip => e
        result.status = "skip"
        result.detail = e.message
      rescue Fail => e
        result.status = "fail"
        result.detail = e.message
      rescue StandardError => e
        result.status = "fail"
        result.detail = "#{e.class}: #{e.message}"
      end
      result.command = @last[:command]
      result.output = scrub(@last[:output].to_s.length > 1500 ? @last[:output].to_s[-1500..] : @last[:output].to_s)
      result.expected = @last[:expected]
      result.actual = scrub(@last[:actual].to_s)
      result.detail = scrub(result.detail.to_s) if result.detail
      @results << result
      $stdout.puts format("%-4s %-9s %-30s %5.1fs %s", result.status.upcase, result.group, name, Time.now - started, result.detail.to_s.lines.first.to_s.strip)
      $stdout.flush
      ok
    end

    def scrub(text)
      out = text.to_s.dup
      @secrets.each { |secret| out = out.gsub(secret, "[redacted]") unless secret.to_s.empty? }
      out
    end

    def guard_real_homes!
      [File.join(HOME_DIR, ".reach"), File.join(HOME_DIR, ".teach")].each do |real|
        raise Fatal, "run dir must not be inside #{real}" if File.expand_path(@run_dir).start_with?(real)
      end
    end

    def export_teach
      @teach_dir = File.join(@run_dir, "teach")
      FileUtils.mkdir_p(@teach_dir)
      statuses = Open3.pipeline(["git", "-C", @teach_repo, "archive", "--format=tar", "HEAD"], ["tar", "-x", "-C", @teach_dir])
      raise Fatal, "could not export the HEAD of #{@teach_repo} into #{@teach_dir}" unless statuses.all?(&:success?)
    end

    def prepare_paths
      @reach_home = File.join(@run_dir, "reach_home")
      @reach_home_b = File.join(@run_dir, "reach_home_b")
      @workspace_root = File.join(@run_dir, "workspaces")
      @student_home = File.join(@run_dir, "student_home")
      @teach_home = File.join(@run_dir, "teach_home")
      @plugin_dir = File.join(@run_dir, "plugin")
      @codex_home = File.join(@run_dir, "codex_home")
      @private_dir = File.join(@run_dir, "private")
      @reference_dir = File.join(@run_dir, "reference")
      @logs = File.join(@run_dir, "logs")
      [@reach_home, @reach_home_b, @workspace_root, @student_home, @teach_home, @codex_home, @private_dir, @reference_dir, @logs].each { |dir| FileUtils.mkdir_p(dir) }
      File.chmod(0o700, @private_dir)
      @port = free_port
      @teach_url = "http://127.0.0.1:#{@port}"
    end

    def create_scratch_database
      @db_name = "reach_smoke_#{Time.now.strftime("%Y%m%d%H%M%S")}_#{SecureRandom.hex(3)}"
      _out, err, status = Open3.capture3("createdb", @db_name)
      raise Fatal, "createdb #{@db_name} failed: #{err.strip}" unless status.success?

      @db_url = "postgres:///#{@db_name}"
    end

    def drop_scratch_database
      return unless @db_name.to_s.start_with?("reach_smoke_")

      Open3.capture3("dropdb", "--if-exists", @db_name)
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def teach_env
      {
        "PATH" => "#{@ruby4_bin}:#{ENV["PATH"]}",
        "TEACH_HOME" => @teach_home,
        "TEACH_REFERENCE_DIR" => @reference_dir.to_s,
        "TEACH_DATABASE_URL" => @db_url,
        "TEACH_PORT" => @port.to_s,
        "TEACH_BIND" => "127.0.0.1",
        "TEACH_GROKIT_SPEC" => File.join(@grokit, "specs", "app.yml"),
        "TEACH_GROKIT_ROOT" => @grokit,
        "TEACH_DOVETAIL" => File.join(@dovetail, "exe", "dovetail"),
        "TEACH_BUILD_CACHE" => File.join(@run_dir, "build_cache"),
        "TEACH_SANDBOX_RUNNER" => File.join(@teach_dir, "bin", "teach-sandbox-runner"),
        "TEACH_HANDS_DISABLE" => "1",
        "TEACH_MCP_DISABLE" => "1",
        "TEACH_COURSE_TIMEZONE" => "America/Los_Angeles",
        "BUNDLE_GEMFILE" => File.join(@teach_dir, "Gemfile"),
        "BUNDLE_PATH" => @teach_bundle,
        "BUNDLE_APP_CONFIG" => File.join(@run_dir, "bundle_config")
      }
    end

    def reach_env(home = @reach_home)
      {
        "REACH_HOME" => home,
        "REACH_WORKSPACE_ROOT" => @workspace_root,
        "REACH_TEACH_URL" => @teach_url,
        "HOME" => @student_home,
        "CODEX_HOME" => @codex_home
      }
    end

    def reach_exe
      File.join(@plugin_dir, "exe", "reach")
    end

    def capture(env, argv, chdir: nil, stdin: "", timeout: COMMAND_TIMEOUT_S)
      command = argv.map(&:to_s)
      opts = chdir ? { chdir: chdir } : {}
      output = +""
      status = nil
      Open3.popen2e(env, *command, **opts) do |input, out, wait|
        begin
          input.write(stdin.to_s)
        rescue Errno::EPIPE
          nil
        end
        input.close
        reader = Thread.new { out.each_line { |line| output << line } }
        unless wait.join(timeout)
          Process.kill("KILL", wait.pid)
          wait.join
          output << "\n[timed out after #{timeout}s]"
        end
        reader.join(5)
        status = wait.value
      end
      if @last
        @last[:command] = scrub(command.join(" "))
        @last[:output] = output
      end
      [output, status]
    end

    def teach(*args, timeout: COMMAND_TIMEOUT_S)
      out, status = capture(teach_env, ["bundle", "exec", "ruby", "bin/teach", *args], chdir: @teach_dir, timeout: timeout)
      raise Fail, "teach #{args.first(2).join(" ")} exited #{status.exitstatus}: #{out.lines.last(6).join}" unless status.success?

      out
    end

    def teach_json(*args)
      out = teach(*args)
      JSON.parse(out[out.index(/[\[{]/)..])
    end

    def reach(*args, home: @reach_home, chdir: nil, stdin: "", timeout: COMMAND_TIMEOUT_S)
      capture(reach_env(home), ["ruby", reach_exe, *args], chdir: chdir, stdin: stdin, timeout: timeout)
    end

    def reach!(*args, **kwargs)
      out, status = reach(*args, **kwargs)
      raise Fail, "reach #{args.first(2).join(" ")} exited #{status.exitstatus}: #{out.lines.last(6).join}" unless status.success?

      out
    end

    def check_dovetail_pin
      pin = File.read(File.join(REPO, "dovetail-revision.txt")).strip
      line, status = Open3.capture2("git", "-C", REPO, "ls-files", "-s", "dovetail")
      raise Fail, "git ls-files failed" unless status.success?

      gitlink = line.split[1].to_s
      @last[:expected] = gitlink
      @last[:actual] = pin
      raise Fail, "dovetail-revision.txt #{pin} differs from gitlink #{gitlink}" unless pin == gitlink && pin.match?(/\A[0-9a-f]{40}\z/)

      pin
    end

    def check_prerequisites
      missing = []
      missing << "ruby 4.0.6 at #{@ruby4_bin}" unless File.executable?(File.join(@ruby4_bin, "ruby"))
      missing << "teach checkout at #{@teach_dir}" unless File.file?(File.join(@teach_dir, "bin", "teach"))
      missing << "teach gems at #{@teach_bundle}" unless Dir.exist?(@teach_bundle)
      missing << "grokit at #{@grokit}" unless File.file?(File.join(@grokit, "specs", "app.yml"))
      missing << "dovetail at #{@dovetail}" unless File.file?(File.join(@dovetail, "exe", "dovetail"))
      missing << "zip and unzip" unless system("which zip unzip > /dev/null 2>&1")
      raise Fail, "missing: #{missing.join("; ")}" unless missing.empty?

      version, = capture(teach_env, ["ruby", "-e", "print RUBY_VERSION"])
      @last[:actual] = version
      raise Fail, "teach ruby is #{version}, want 4.0.x" unless version.start_with?("4.0.")

      "teach ruby #{version}, reach ruby #{RUBY_VERSION}"
    end

    def provision_teach
      File.write(File.join(@run_dir, "students.csv"), "id,display_name,email,group\n#{STUDENT_ID},Synthetic Student One,,G1\n#{SECOND_STUDENT_ID},Synthetic Student Two,,G1\n")
      File.write(File.join(@run_dir, "roster.csv"), "student_id,username,display_name,group\n#{STUDENT_ID},#{STUDENT_USERNAME},Synthetic Student One,G1\n#{SECOND_STUDENT_ID},#{SECOND_STUDENT_USERNAME},Synthetic Student Two,G1\n")
      File.write(File.join(@run_dir, "slices.csv"), "student_id,cutout_id,slice\n#{STUDENT_ID},#{CUTOUT},#{SLICE}\n")
      teach("keys", "generate")
      teach("course", "init", "--id", COURSE_ID, "--title", "BUS 101 Smoke", "--term", "Fall 2026", "--tz", "America/Los_Angeles")
      teach("course", "set-end", "--course", COURSE_ID, "--date", COURSE_END_DATE)
      teach("students", "import", File.join(@run_dir, "students.csv"))
      roster = teach_json("roster", "import", "--course", COURSE_ID, File.join(@run_dir, "roster.csv"))
      raise Fail, "roster import rejected rows: #{roster["rejected"].inspect}" unless roster["added"] == 2 && roster["rejected"].empty?

      minted = teach_json("course", "code", "mint", "--course", COURSE_ID)
      @code = minted.fetch("code")
      @secrets << @code
      @secrets << STUDENT_PASSWORD
      File.write(File.join(@private_dir, "course_code.json"), JSON.generate(minted), perm: 0o600)
      out = teach("slices", "assign", "--assignment", ASSIGNMENT, "--from", File.join(@run_dir, "slices.csv"))
      @last[:output] = out
      "course #{COURSE_ID} provisioned with 2 synthetic students, slice #{CUTOUT}-#{SLICE} assigned to #{STUDENT_ID}"
    end

    def release_before_enroll
      installs = teach_json("installs", "list")
      raise Fail, "expected no installs before release, saw #{installs.length}" unless installs.empty?

      out = teach("release", "--assignment", ASSIGNMENT)
      @last[:actual] = out
      "released #{ASSIGNMENT} with zero installs"
    end

    def start_teach
      log_path = File.join(@logs, "teach-serve.log")
      log = File.open(log_path, "w")
      @teach_pid = Process.spawn(teach_env, "bundle", "exec", "ruby", "bin/teach", "serve", chdir: @teach_dir, out: log, err: log, pgroup: true)
      File.write(File.join(@run_dir, "teach.pid"), "#{@teach_pid}\n")
      80.times do
        return "teach serving at #{@teach_url} pid #{@teach_pid}" if healthy?

        if Process.wait(@teach_pid, Process::WNOHANG)
          @teach_pid = nil
          raise Fail, "teach exited early: #{File.read(log_path).lines.last(8).join}"
        end
        sleep 0.5
      end
      stop_process(@teach_pid)
      @teach_pid = nil
      raise Fail, "teach did not become healthy: #{File.read(log_path).lines.last(8).join}"
    end

    def healthy?
      Socket.tcp("127.0.0.1", @port, connect_timeout: 1).close
      true
    rescue StandardError
      false
    end

    def stop_process(pid)
      return unless pid

      Process.kill("TERM", -pid)
      Timeout.timeout(10) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      begin
        Process.kill("KILL", -pid)
        Process.wait(pid)
      rescue StandardError
        nil
      end
    rescue StandardError
      nil
    end

    def blocked_before_enroll
      out, status = reach("gate", "session", "--harness", "codex", stdin: "{}")
      @last[:expected] = "exit 2 (blocked)"
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "gate session before enroll exited #{status.exitstatus}, want 2: #{out}" unless status.exitstatus == 2

      work_out, work_status = reach("work", "--harness", "codex")
      raise Fail, "work before enroll exited #{work_status.exitstatus}, want nonzero: #{work_out}" if work_status.success?
      raise Fail, "a workspace exists before enroll" unless Dir.glob(File.join(@workspace_root, "**", "slice.json")).empty?

      "gate refused (#{out.strip[0, 120]}); reach work refused; no workspace"
    end

    def build_archive(dereference)
      stage = File.join(@run_dir, "archive_stage")
      root = File.join(stage, "rEach-main")
      FileUtils.rm_rf(stage)
      FileUtils.mkdir_p(root)
      names, status = Open3.capture2("git", "-C", REPO, "ls-files", "-co", "--exclude-standard", "-z")
      raise Fail, "git ls-files failed" unless status.success?

      names.split("\0").each do |name|
        next if name == "dovetail" || name.start_with?("dovetail/")

        source = File.join(REPO, name)
        next unless File.file?(source) || File.symlink?(source)

        destination = File.join(root, name)
        FileUtils.mkdir_p(File.dirname(destination))
        if File.symlink?(source) && !dereference
          File.symlink(File.readlink(source), destination)
        else
          FileUtils.cp(source, destination, preserve: true)
        end
      end
      archive = File.join(@run_dir, "reach-main.zip")
      FileUtils.rm_f(archive)
      out, zip_status = Open3.capture2e("zip", "-qry", archive, "rEach-main", chdir: stage)
      raise Fail, "zip failed: #{out}" unless zip_status.success?

      archive
    end

    def install_plugin(dereference)
      FileUtils.rm_rf(@plugin_dir) if dereference
      archive = build_archive(dereference)
      installer = File.join(REPO, "bin", "reach-install")
      out, status = capture({ "HOME" => @student_home }, ["ruby", installer, "--archive", archive, "--destination", @plugin_dir, "--dovetail-revision", File.join(REPO, "dovetail-revision.txt")])
      @last[:expected] = "GitHub-shaped archive installs to #{@plugin_dir}"
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "reach-install exited #{status.exitstatus}: #{out.lines.last(6).join}" unless status.success?
      raise Fail, "exe/reach missing after install" unless File.file?(reach_exe)
      raise Fail, "dovetail bundle missing after install" unless File.file?(File.join(@plugin_dir, "dovetail", "exe", "dovetail"))

      "local archive mode#{dereference ? " (symlinks dereferenced, a workaround)" : ""}, which does not prove public availability: #{out.strip}"
    end

    def install_public
      target = File.join(@run_dir, "plugin_public")
      installer = File.join(REPO, "bin", "reach-install")
      out, status = capture({ "HOME" => @student_home }, ["ruby", installer, "--destination", target])
      raise Fail, "public install exited #{status.exitstatus}: #{out.lines.last(6).join}" unless status.success?

      "public GitHub ZIP install: #{out.strip}"
    end

    def setup_codex
      raise Skip, "codex not on PATH" unless system("which codex > /dev/null 2>&1")

      out, status = reach("setup", "--harness", "codex", "--source", @plugin_dir)
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "setup exited #{status.exitstatus}: #{out.lines.last(8).join}" unless status.success?

      "setup with isolated CODEX_HOME=#{@codex_home}: #{out.lines.first.to_s.strip}"
    end

    def doctor
      out, status = reach("doctor")
      @last[:actual] = "exit #{status.exitstatus}"
      "doctor exit #{status.exitstatus}: #{out.lines.map(&:strip).reject(&:empty?).first(4).join(" | ")}"
    end

    def enroll_args(student_id)
      ["enroll", "--course-code", @code, "--username", STUDENT_USERNAME, "--student-id", student_id, "--password-stdin", "--teach-url", @teach_url]
    end

    def enroll
      out = reach!(*enroll_args(STUDENT_ID), stdin: "#{STUDENT_PASSWORD}\n")
      raise Fail, "enroll printed no course-ready confirmation" if out.strip.empty?

      installs = teach_json("installs", "list")
      @last[:expected] = "1 install"
      @last[:actual] = "#{installs.length} install(s)"
      raise Fail, "teach lists #{installs.length} installs after enroll, want 1" unless installs.length == 1

      @install_id = installs.first["id"]
      "enrolled install #{@install_id}; #{out.lines.first.to_s.strip}"
    end

    def wrong_student_id_refused
      out, status = reach(*enroll_args(WRONG_STUDENT_ID), stdin: "#{STUDENT_PASSWORD}\n", home: @reach_home_b)
      @last[:expected] = "nonzero exit, no second install"
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "a wrong student id enrolled an install" if status.success?

      installs = teach_json("installs", "list")
      raise Fail, "teach holds #{installs.length} installs after the refused attempt, want 1" unless installs.length == 1

      "wrong student id refused: #{out.strip[0, 160]}"
    end

    def sync_workspace
      out = reach!("sync")
      @last[:output] = out
      found = Dir.glob(File.join(@workspace_root, "**", ".reach", "slice.json"))
      raise Fail, "sync delivered no workspace under #{@workspace_root}" if found.empty?

      @workspace = File.dirname(File.dirname(found.first))
      @marker = JSON.parse(File.read(found.first))
      readme = File.join(@workspace, "README.md")
      problems = []
      problems << "README.md missing" unless File.file?(readme)
      problems << "README.md holds no template text" if File.file?(readme) && File.read(readme).strip.empty?
      mode = @marker["acceptance_mode"]
      problems << "acceptance_mode is #{mode.inspect}, want \"remote\"" unless mode == "remote"
      names = scenario_names(@marker)
      problems << "no scenario names in slice.json" if names.empty?
      @last[:expected] = "acceptance_mode remote, scenario names, README.md"
      @last[:actual] = "mode=#{mode.inspect} scenarios=#{names.length} readme=#{File.file?(readme)}"
      raise Fail, problems.join("; ") unless problems.empty?

      "workspace #{@workspace}; #{names.length} scenario names; acceptance_mode remote"
    end

    def scenario_names(marker)
      list = marker["scenarios"] || marker["acceptance_scenarios"] || marker["scenario_names"]
      Array(list).map { |entry| entry.is_a?(Hash) ? entry["name"] : entry }.compact
    end

    def status_after_sync
      out = reach!("status")
      "status: #{out.lines.first.to_s.strip}"
    end

    def slice_id
      File.basename(@workspace)
    end

    def owned_path
      File.join(@workspace, OWNED_RELATIVE)
    end

    def guarded_write_owned
      event = JSON.generate("tool_name" => "Write", "tool_input" => { "file_path" => owned_path })
      out, status = reach("gate", "write", chdir: @workspace, stdin: event)
      @last[:expected] = "exit 0"
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "gate refused an owned-file write: #{out}" unless status.success?

      "gate allows #{OWNED_RELATIVE}"
    end

    def edit_outside_blocked
      outside = File.join(@workspace, "lib", "grokit", "errors.rb")
      outside = File.join(@workspace, "NOT_OWNED.rb") unless File.exist?(outside)
      event = JSON.generate("tool_name" => "Write", "tool_input" => { "file_path" => outside })
      out, status = reach("gate", "write", chdir: @workspace, stdin: event)
      @last[:expected] = "exit 2"
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "gate allowed a write to #{outside}" unless status.exitstatus == 2

      "gate refused #{outside.sub(@workspace, ".")}: #{out.strip[0, 120]}"
    end

    def plan_save
      out = reach!(
        "plan", "save", "--slice", slice_id,
        "--behaviour", "Return one requested profile value for a normalised key, with status ok or not_found",
        "--input", "key: String", "--output", "key, value, status",
        "--steps", "normalise the key|ask the profile port for it|return ok with the value or not_found with the normalised key",
        "--edge-cases", "capitals and spaces in the key|unknown key",
        "--scenarios", "known key returns ok|unknown key returns not_found|capitals and spaces resolve the same value",
        "--evidence", "reach check clean, then remote acceptance results after submission",
        chdir: @workspace
      )
      shown = reach!("plan", "show", "--slice", slice_id, "--format", "json", chdir: @workspace)
      raise Fail, "saved plan did not read back" unless shown.include?("normalise")

      out.strip
    end

    def write_implementation
      stub = File.read(owned_path)
      raise Fail, "could not read the class layout from the delivered stub" unless stub.match?(/^\s*(module|class)\s/)

      contract = %w[README.md contract/README.md api/README.md].map { |name| File.read(File.join(@workspace, name)) }.join("\n") + JSON.generate(@marker)
      raise Fail, "workspace text does not name the fetch port" unless contract.include?("profile.fetch")
      raise Fail, "workspace text does not state the output shape" unless contract.include?("not_found")
      raise Fail, "grokit a1-course-path.md missing" unless File.file?(File.join(@grokit, "docs", "a1-course-path.md"))

      File.write(owned_path, implementation_source(stub))
      out, status = capture({ "PATH" => "#{@ruby4_bin}:#{ENV["PATH"]}" }, ["ruby", "-c", owned_path])
      raise Fail, "written implementation does not parse: #{out}" unless status.success?

      "wrote #{OWNED_RELATIVE} (#{File.size(owned_path)} bytes) from the released contract"
    end

    def implementation_source(stub)
      header = stub.lines.take_while { |line| !line.match?(/^\s*(module|class)\s/) }.map(&:rstrip)
      layout = stub.lines.select { |line| line.match?(/^\s*(module|class)\s/) }.map(&:strip)
      header.pop while header.last == ""
      lines = header.dup
      lines << "" unless lines.empty?
      layout.each_with_index { |decl, index| lines << "#{"  " * index}#{decl}" }
      indent = "  " * layout.length
      body = <<~RUBY
        def call(input, ports)
          key = normalise(input.fetch(:key))
          value = ports.profile.fetch(key)
          if value.nil?
            { key: key, value: nil, status: "not_found" }
          else
            { key: key, value: value, status: "ok" }
          end
        end

        private

        def normalise(raw)
          raw.to_s.strip.downcase.gsub(/\\s+/, "_")
        end
      RUBY
      body.lines.each { |line| lines << (line.strip.empty? ? "" : "#{indent}#{line.rstrip}") }
      (layout.length - 1).downto(0) { |index| lines << "#{"  " * index}end" }
      "#{lines.join("\n")}\n"
    end

    def fill_readme
      text = File.read(README_SOURCE)
      File.write(File.join(@workspace, "README.md"), text)
      "README.md filled (#{text.lines.length} lines)"
    end

    def reach_check
      out, status = reach("check", "--slice", slice_id, chdir: @workspace)
      @last[:expected] = "exit 0, clean"
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "reach check exited #{status.exitstatus}: #{out.lines.last(8).join}" unless status.success?

      out.strip
    end

    def checkpoint
      out = reach!("checkpoint", "save", "--slice", slice_id, "--note", "smoke implementation and README", chdir: @workspace)
      list = reach!("checkpoint", "list", "--slice", slice_id, chdir: @workspace)
      raise Fail, "checkpoint list is empty" if list.strip.empty?

      out.strip
    end

    LOGIN_SESSION = "smoke-login-session"

    def hook_prompt(text)
      event = JSON.generate("hook_event_name" => "UserPromptSubmit", "session_id" => LOGIN_SESSION, "cwd" => @workspace, "prompt" => text)
      reach("gate", "prompt", "--harness", "claude-code", chdir: @workspace, stdin: event)
    end

    def login_sign_in
      target = File.join(@workspace, owned_path)
      write_event = JSON.generate("tool_name" => "Write", "session_id" => LOGIN_SESSION, "tool_input" => { "file_path" => target })
      out, status = reach("gate", "write", chdir: @workspace, stdin: write_event)
      raise Fail, "an owned write was allowed before sign-in" if status.success?

      out, status = hook_prompt("hi there")
      raise Fail, "first prompt was not asked for an id: #{out}" if status.success? || !out.include?("student ID")
      out, status = hook_prompt("I am someone else")
      raise Fail, "a wrong id was not refused: #{out}" if status.success? || !out.include?("doesn't match")
      out, status = hook_prompt("my id is #{STUDENT_ID}")
      raise Fail, "the id was not confirmed by name: #{out}" if status.success? || !out.include?("Synthetic Student One")
      out, status = hook_prompt("Yes!")
      raise Fail, "yes did not sign in: #{out}" if status.success? || !out.include?("signed in")

      login = reach!("login", "status", chdir: @workspace)
      raise Fail, "login status does not show an active sign-in: #{login}" unless login.include?("yes")

      "write refused before sign-in; ask, wrong id, confirm by name, yes -> signed in"
    end

    def submit_refused_without_part
      out, status = reach("submit", "--slice", slice_id, chdir: @workspace, timeout: 120)
      raise Fail, "submit succeeded without the student's part" if status.success?
      raise Fail, "submit refused for another reason: #{out.lines.last(4).join}" unless out.include?("isn't finished yet")

      "refused: #{out.strip[0, 120]}"
    end

    def record_student_part
      listing = JSON.parse(reach!("part", "--format", "json", chdir: @workspace))
      questions = listing.is_a?(Hash) ? Array(listing["questions"]) : Array(listing)
      raise Fail, "no student part questions listed: #{listing.inspect[0, 200]}" if questions.empty?

      questions.each_with_index do |question, index|
        answer = "For question #{index + 1}, I chose a small neighborhood cafe where the owner decides each week which drinks to keep, based on margins and what regulars actually order."
        out, status = hook_prompt(answer)
        raise Fail, "the answer prompt was blocked: #{out}" unless status.success?
        reach!("part", "record", question["id"], chdir: @workspace)
      end
      after = JSON.parse(reach!("part", "--format", "json", chdir: @workspace))
      rows = after.is_a?(Hash) ? Array(after["questions"]) : Array(after)
      missing = rows.reject { |row| row["answered"] }
      raise Fail, "questions still unanswered: #{missing.map { |row| row['id'] }.join(', ')}" unless missing.empty?

      "recorded #{rows.length} answers from typed prompts"
    end

    def submit_refused_unqualified
      out, status = reach("submit", "--slice", slice_id, chdir: @workspace, timeout: 120)
      @last[:expected] = "nonzero exit, M-SUBMIT-UNQUALIFIED"
      @last[:actual] = "exit #{status.exitstatus}: #{out.strip[0, 160]}"
      raise Fail, "submit succeeded before any qualification" if status.success?
      raise Fail, "submit refused for another reason: #{out.lines.last(4).join}" unless out.include?("hasn't passed its checks")
      raise Fail, "teach holds a submission" unless teach_json("submissions", "list", "--assignment", ASSIGNMENT).empty?

      "refused: #{out.strip[0, 120]}"
    end

    def write_qualify_scenarios
      source = File.join(__dir__, "qualify")
      written = Dir.glob(File.join(source, "{features,step_definitions}", "*")).map do |path|
        relative = path.sub("#{source}/", "")
        target = File.join(@workspace, "qualify", relative)
        event = JSON.generate("tool_name" => "Write", "tool_input" => { "file_path" => target })
        out, status = reach("gate", "write", chdir: @workspace, stdin: event)
        raise Fail, "gate refused #{relative}: #{out}" unless status.success?

        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(path, target)
        relative
      end
      raise Fail, "no scenario fixtures under #{source}" if written.empty?

      "wrote #{written.join(', ')}"
    end

    def qualify_list
      out = reach!("qualify", "--slice", slice_id, "--list", chdir: @workspace)
      raise Fail, "qualify --list names no @backend tag: #{out}" unless out.include?("@backend")

      out.lines.map(&:strip).reject(&:empty?).first(4).join(" | ")
    end

    def start_grader
      raise Skip, "Docker images teach-grader:ruby-4.0 and teach-grader:ruby-2.6.10 are not both present; nothing qualifies or is graded" unless docker_images_present?

      log = File.open(File.join(@logs, "teach-grader.log"), "w")
      @grader_pid = Process.spawn(teach_env, "bundle", "exec", "ruby", "bin/teach", "grader", chdir: @teach_dir, out: log, err: log, pgroup: true)
      File.write(File.join(@run_dir, "grader.pid"), "#{@grader_pid}\n")
      "grader pid #{@grader_pid}"
    end

    def qualify_passes
      out, status = reach("qualify", "--slice", slice_id, "--format", "json", chdir: @workspace, timeout: 600)
      @last[:expected] = "exit 0, passed"
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "qualify exited #{status.exitstatus}: #{out.lines.last(12).join}" unless status.success?

      record = JSON.parse(out[out.index("{")..])
      raise Fail, "qualification did not pass: #{out[0, 400]}" unless record["passed"]

      "qualified: #{record['steps'].keys.join(', ')}"
    end

    def submit
      before = teach_json("submissions", "list", "--assignment", ASSIGNMENT)
      raise Fail, "teach already holds submissions" unless before.empty?

      out, status = reach("submit", "--slice", slice_id, chdir: @workspace, timeout: 300)
      @last[:actual] = "exit #{status.exitstatus}"
      raise Fail, "submit exited #{status.exitstatus}: #{out.lines.last(8).join}" unless status.success?

      rows = teach_json("submissions", "list", "--assignment", ASSIGNMENT)
      raise Fail, "teach lists #{rows.length} submissions, want 1" unless rows.length == 1

      @submission = rows.first
      out.strip
    end

    def reach_receipts(kind)
      Dir.glob(File.join(@reach_home, "receipts", "*.json")).map { |path| JSON.parse(File.read(path)) }
         .select { |receipt| receipt["kind"] == kind }.map { |receipt| receipt["receipt_id"] }
    end

    def ingest_receipt_ids
      shown = teach_json("submissions", "show", @submission["id"])
      teach_receipts = Array(shown["receipts"]).select { |receipt| receipt["kind"] == "ingest" }
      expected = teach_receipts.map { |receipt| receipt["receipt_id"] }
      actual = reach_receipts("ingest")
      @receipts["submission_id"] = @submission["id"]
      @receipts["ingest"] = { "expected" => expected, "actual" => actual }
      @last[:expected] = expected.join(",")
      @last[:actual] = actual.join(",")
      raise Fail, "teach issued no ingest receipt" if expected.empty?
      raise Fail, "reach stored ingest receipts #{actual.inspect}, teach issued #{expected.inspect}" unless expected.sort == actual.sort
      raise Fail, "ingest receipt carries no signature" unless teach_receipts.first["signature"]

      "signed ingest receipt #{expected.first} for submission #{@submission["id"]}"
    end

    def docker_images_present?
      %w[teach-grader:ruby-4.0 teach-grader:ruby-2.6.10].all? do |image|
        _out, status = Open3.capture2e("docker", "image", "inspect", image)
        status.success?
      end
    rescue StandardError
      false
    end

    def run_grader
      raise Skip, "Docker images teach-grader:ruby-4.0 and teach-grader:ruby-2.6.10 are not both present; not graded, not passed" unless docker_images_present?

      log_path = File.join(@logs, "teach-grader.log")
      raise Skip, "the grader is not running" unless @grader_pid

      deadline = Time.now + GRADER_TIMEOUT_S
      rows = []
      loop do
        rows = teach_json("grades", "export", "--assignment", ASSIGNMENT)
        break if rows.any?
        raise Fail, "no grade receipt within #{GRADER_TIMEOUT_S}s; grader log tail: #{File.read(log_path).lines.last(8).join}" if Time.now > deadline

        sleep 5
      end
      stop_process(@grader_pid)
      @grader_pid = nil
      row = rows.first
      @receipts["grade"] = { "expected" => [row["receipt_id"]], "score" => row["score"] }
      @last[:expected] = row["receipt_id"]
      "grade receipt #{row["receipt_id"]} score #{row["score"]}"
    end

    REFERENCE_SENTINEL = %w[REFERENCE SENTINEL 7f3a9c].join("-").freeze

    def reference_pack
      source_dir = File.join(@private_dir, "reference-source")
      FileUtils.mkdir_p(source_dir)
      File.write(File.join(source_dir, "syllabus.md"), "# Syllabus\nWeek one covers gross margin.\n#{REFERENCE_SENTINEL} appears here.\nMargin is revenue minus cost.\n")
      File.write(File.join(source_dir, "glossary.txt"), "Cost: what the business pays.\nRevenue: what the business earns.\n")
      spec = File.join(source_dir, "reference.yml")
      File.write(spec, YAML.dump(
        "entries" => [
          { "path" => "syllabus.md", "title" => "Syllabus", "source" => File.join(source_dir, "syllabus.md") },
          { "path" => "glossary.txt", "title" => "Glossary", "source" => File.join(source_dir, "glossary.txt") }
        ],
        "links" => [{ "title" => "Textbook", "url" => "https://openstax.org/details/books/principles-management", "licence" => "CC BY 4.0" }]
      ))
      @reference_blob = File.join(@reference_dir, "#{COURSE_ID}.rref")
      out = teach("reference", "pack", "--course", COURSE_ID, "--spec", spec, "--out", @reference_blob)
      @last[:output] = out
      raise Fail, "reference blob was not written" unless File.file?(@reference_blob)
      raise Fail, "reference blob holds the sentinel in plaintext" if File.binread(@reference_blob).include?(REFERENCE_SENTINEL)

      "packed #{File.size(@reference_blob)} bytes with the Teach packer; sentinel absent from the blob"
    end

    def reference_locked_before_enroll
      out, status = reach("reference", "list")
      @last[:expected] = "nonzero exit, connect-to-course message, no plaintext"
      @last[:actual] = "exit #{status.exitstatus}: #{out.strip[0, 160]}"
      raise Fail, "reference list before enroll exited 0" if status.success?
      raise Fail, "reference list before enroll printed no enroll hint: #{out}" unless out.include?("reach enroll")
      raise Fail, "reference list before enroll leaked a path" if out.include?("syllabus.md")

      "refused before enroll: #{out.strip[0, 120]}"
    end

    def reference_after_sync
      list = reach!("reference", "list")
      raise Fail, "list lacks the entries: #{list}" unless list.include?("syllabus.md") && list.include?("Glossary")

      shown = reach!("reference", "show", "syllabus.md")
      raise Fail, "show lacks the sentinel: #{shown}" unless shown.include?(REFERENCE_SENTINEL)

      found = reach!("reference", "search", "gross", "margin")
      raise Fail, "search lacks syllabus.md: #{found}" unless found.include?("syllabus.md") && found.include?("Week one covers gross margin.")
      raise Fail, "search matched a file without both words: #{found}" if found.include?("glossary.txt")

      links = reach!("reference", "links")
      raise Fail, "links lacks the textbook: #{links}" unless links.include?("openstax.org") && links.include?("CC BY 4.0")

      leaked = Dir.glob(File.join(@run_dir, "{reach_home,workspaces,student_home,codex_home,plugin}", "**", "*"), File::FNM_DOTMATCH).select do |path|
        File.file?(path) && File.size(path) < 5_000_000 && File.binread(path).include?(REFERENCE_SENTINEL)
      end
      @last[:expected] = "no plaintext sentinel on the student's disk"
      @last[:actual] = leaked.empty? ? "none found" : leaked.join(", ")
      raise Fail, "plaintext reference found on disk: #{leaked.join(', ')}" unless leaked.empty?

      "list, show, search and links succeed after sync; sentinel not on the student's disk"
    end

    def reference_tamper_refused
      tampered = File.join(@run_dir, "reference-tampered")
      FileUtils.mkdir_p(tampered)
      bytes = File.binread(@reference_blob)
      bytes.setbyte(bytes.bytesize - 20, bytes.getbyte(bytes.bytesize - 20) ^ 1)
      File.binwrite(File.join(tampered, "#{COURSE_ID}.rref"), bytes)
      out, status = capture(reach_env.merge("REACH_REFERENCE_DIR" => tampered), ["ruby", reach_exe, "reference", "show", "syllabus.md"])
      @last[:expected] = "nonzero exit, refused, no sentinel"
      @last[:actual] = "exit #{status.exitstatus}: #{out.strip[0, 160]}"
      raise Fail, "tampered blob was accepted" if status.success?
      raise Fail, "tampered blob printed plaintext" if out.include?(REFERENCE_SENTINEL)
      raise Fail, "tampered blob gave no refusal message: #{out}" unless out.include?("refused")

      "tampered blob refused: #{out.strip[0, 120]}"
    end

    def sync_grade
      out = reach!("sync", timeout: 300)
      @last[:output] = out
      ids = reach_receipts("grade")
      @receipts["grade"]["actual"] = ids
      @last[:expected] = @receipts["grade"]["expected"].join(",")
      @last[:actual] = ids.join(",")
      raise Fail, "reach holds grade receipts #{ids.inspect}, teach issued #{@receipts["grade"]["expected"].inspect}" unless ids.sort == @receipts["grade"]["expected"].sort

      "grade receipt verified and stored by reach sync: #{ids.join(",")}"
    end

    def write_summary
      counts = @results.group_by(&:status).transform_values(&:length)
      summary = {
        "schema" => "reach.smoke.assignment-one/v1",
        "finished_at" => Time.now.utc.iso8601,
        "run_dir" => @run_dir,
        "teach_dir" => @teach_dir,
        "reach_repo" => REPO,
        "mode" => @options[:public] ? "local-archive+public-zip" : "local-archive",
        "teach_url" => @teach_url,
        "counts" => counts,
        "receipts" => @receipts,
        "steps" => @results.map(&:to_h)
      }
      File.write(File.join(@run_dir, "summary.json"), "#{JSON.pretty_generate(summary)}\n")
      lines = ["# Assignment one transport smoke", "", "Run dir: `#{@run_dir}`", "Mode: #{summary["mode"]}", "Counts: #{counts.map { |k, v| "#{k}=#{v}" }.join(" ")}", ""]
      lines << "| Step | Group | Status | Detail |"
      lines << "| --- | --- | --- | --- |"
      @results.each { |result| lines << "| #{result.name} | #{result.group} | #{result.status} | #{result.detail.to_s.lines.first.to_s.strip.gsub("|", "/")} |" }
      lines << ""
      lines << "Receipts: `#{JSON.generate(@receipts)}`"
      File.write(File.join(@run_dir, "summary.md"), "#{lines.join("\n")}\n")
    end
  end

  module_function

  def main(argv)
    options = {
      teach_dir: ENV["SMOKE_TEACH_DIR"],
      teach_repo: ENV.fetch("SMOKE_TEACH_REPO", File.join(HOME_DIR, "bitbucket", "paterasai", "teach")),
      grokit: ENV.fetch("SMOKE_GROKIT_ROOT", File.join(HOME_DIR, "bitbucket", "paterasai", "grokit")),
      dovetail: ENV.fetch("SMOKE_DOVETAIL_ROOT", File.join(HOME_DIR, "github", "foss", "dovetail")),
      ruby4_bin: ENV.fetch("SMOKE_RUBY4_BIN", File.join(HOME_DIR, ".rubies", "ruby-4.0.6", "bin")),
      teach_bundle: ENV.fetch("SMOKE_TEACH_BUNDLE", File.join(HOME_DIR, "bitbucket", "paterasai", "teach", "vendor", "bundle")),
      run_dir: ENV["SMOKE_RUN_DIR"],
      public: false
    }
    OptionParser.new do |parser|
      parser.on("--run-dir DIR") { |value| options[:run_dir] = value }
      parser.on("--teach-dir DIR") { |value| options[:teach_dir] = value }
      parser.on("--public") { options[:public] = true }
    end.parse!(argv)
    runner = Runner.new(options)
    ok = runner.run
    puts "summary: #{File.join(runner.run_dir, "summary.md")}"
    ok ? 0 : 1
  rescue Fatal => e
    warn "assignment_one: #{e.message}"
    2
  end
end

exit AssignmentOne.main(ARGV) if $PROGRAM_NAME == __FILE__
