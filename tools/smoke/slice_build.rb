#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["SMOKE_IMAGE"] = ENV.fetch("SMOKE_SLICE_IMAGE", "reach-smoke:noble")
require_relative "run"
require "date"
require "tmpdir"

module SliceBuild
  CONFIG = YAML.safe_load(File.read(File.join(__dir__, "slice_build.yml")))
  LIMITS = CONFIG["limits"]
  AGENT_MODEL = ENV.fetch("SMOKE_SLICE_MODEL", LIMITS["agent_model"])
  STUDENT_MODEL = ENV.fetch("SMOKE_STUDENT_MODEL", LIMITS["student_model"])
  SESSION_BUDGET_USD = ENV.fetch("SMOKE_SLICE_SESSION_BUDGET_USD", LIMITS["session_budget_usd"].to_s)
  RUN_BUDGET_USD = Float(ENV.fetch("SMOKE_SLICE_BUDGET_USD", LIMITS["run_budget_usd"].to_s))
  TURN_TIMEOUT_S = Integer(ENV.fetch("SMOKE_SLICE_TURN_TIMEOUT_S", LIMITS["turn_timeout_s"].to_s))
  MAX_TURNS = Integer(ENV.fetch("SMOKE_SLICE_MAX_TURNS", LIMITS["max_turns"].to_s))
  MODULE_TIMEOUT_S = Integer(ENV.fetch("SMOKE_SLICE_MODULE_TIMEOUT_S", LIMITS["module_timeout_s"].to_s))
  GRADER_TIMEOUT_S = Integer(ENV.fetch("GRADER_TIMEOUT_S", LIMITS["grader_timeout_s"].to_s))
  STUDENT_BUDGET_USD = LIMITS["student_budget_usd"].to_s
  RUNS_DIR = File.expand_path(ENV["SMOKE_SLICE_RUNS_DIR"].to_s.empty? ? "~/.cache/reach-smoke/slice-build" : ENV["SMOKE_SLICE_RUNS_DIR"])
  TEACH_SRC = File.expand_path(ENV.fetch("SMOKE_SLICE_TEACH_SRC", "~/bitbucket/paterasai/teach"))
  GROKIT_SRC = File.expand_path(ENV.fetch("SMOKE_SLICE_GROKIT_SRC", "~/bitbucket/paterasai/grokit"))
  TEACH_REF = ENV.fetch("SMOKE_SLICE_TEACH_REF", "origin/main")
  GROKIT_TAG = ENV.fetch("SMOKE_SLICE_GROKIT_TAG", "v0.9.1")
  DOVETAIL_ROOT = File.expand_path(ENV.fetch("SMOKE_SLICE_DOVETAIL_ROOT", "~/github/foss/dovetail"))
  TEACH_BUNDLE = File.expand_path(ENV.fetch("SMOKE_SLICE_TEACH_BUNDLE", "~/bitbucket/paterasai/teach/vendor/bundle"))
  RUBY4_BIN = File.expand_path(ENV.fetch("SMOKE_RUBY4_BIN", "~/.rubies/ruby-4.0.6/bin"))
  GRADER_IMAGES = %w[teach-grader:ruby-4.0.7 teach-grader:ruby-2.6.10].freeze
  GUARD_MARKER = "belongs to the course"
  LIVE_TEACH_PORT = 7400

  class Interrupted < Smoke::Abort; end
  class UsageLimit < Interrupted; end
  USAGE_LIMIT = /hit your (?:weekly |daily |session |usage )?limit|usage limit reached|limit .{0,20}resets \d/i

  $interrupted = false

  def self.sh(*cmd, env: {}, chdir: nil, timeout: 300)
    opts = chdir ? { chdir: chdir } : {}
    out, err, status = Open3.capture3(env, "timeout", timeout.to_s, *cmd, **opts)
    [out, err, status]
  end

  def self.sh!(*cmd, **opts)
    out, err, status = sh(*cmd, **opts)
    raise Smoke::Abort, "#{cmd.first(3).join(" ")} failed: #{(err + out)[-500..] || (err + out)}" unless status.success?

    out
  end

  def self.git_head(dir)
    out, _err, status = Open3.capture3("git", "-C", dir, "rev-parse", "HEAD")
    status.success? ? out.strip : nil
  end

  class Cost
    attr_reader :total, :turns

    def initialize
      @total = 0.0
      @last = 0.0
      @turns = 0
    end

    def add(reported)
      reported = reported.to_f
      delta = reported >= @last ? reported - @last : reported
      @last = reported
      @total += delta
      @turns += 1
      delta
    end
  end

  class Phase
    attr_reader :assignment, :targets, :dir, :db, :port, :dates, :teach_sha

    def initialize(run, assignment, targets)
      @run = run
      @teach_sha = run.teach_sha
      @assignment = assignment
      @targets = targets
      @dir = File.join(run.dir, "phase-#{assignment}")
      @teach_dir = File.join(@dir, "teach")
      @db = "reach_smoke_#{run.id}_#{assignment.downcase}"
      @home = File.join(@dir, "teach-home")
      @codes = {}
      @pids = {}
    end

    def url
      "http://#{Smoke::GATEWAY}:#{@port}"
    end

    def env
      {
        "PATH" => "#{RUBY4_BIN}:#{ENV["PATH"]}",
        "TEACH_HOME" => @home,
        "TEACH_PORT" => @port.to_s,
        "TEACH_BIND" => Smoke::GATEWAY,
        "TEACH_DATABASE_URL" => "postgres:///#{@db}",
        "TEACH_GROKIT_SPEC" => File.join(@run.grokit_dir, "specs", "app.yml"),
        "TEACH_GROKIT_ROOT" => @run.grokit_dir,
        "TEACH_DOVETAIL" => File.join(DOVETAIL_ROOT, "exe", "dovetail"),
        "TEACH_BUILD_CACHE" => File.join(@dir, "build-cache"),
        "TEACH_SANDBOX_RUNNER" => File.join(@teach_dir, "bin", "teach-sandbox-runner"),
        "TEACH_GRADER_DOCKER" => "docker",
        "TEACH_GRADER_IMAGE" => GRADER_IMAGES[0],
        "TEACH_GRADER_IMAGE_RUBY26" => GRADER_IMAGES[1],
        "TEACH_HANDS_DISABLE" => "0",
        "TEACH_MCP_DISABLE" => "0",
        "TEACH_COURSE_TIMEZONE" => "America/Los_Angeles"
      }
    end

    def provision
      FileUtils.mkdir_p(@dir)
      FileUtils.mkdir_p(@home)
      raise Smoke::Abort, "refusing to use the live teach home" if File.expand_path(@home).start_with?(File.expand_path("~/.teach"))

      @port = free_port
      raise Smoke::Abort, "refusing the live teach port" if @port == LIVE_TEACH_PORT

      clone_teach
      rewrite_due_dates
      SliceBuild.sh!("createdb", @db)
      teach("keys", "generate")
      teach("course", "init", "--id", "mgmt327-fa26", "--title", "MGMT 327 Information Systems", "--term", "Fall 2026", "--tz", "America/Los_Angeles")
      roster = ["id,display_name,email,group"] + @targets.map { |t| "#{t["student"]},Student #{t["student"]},,#{t["group"]}" }
      File.write(File.join(@dir, "roster.csv"), roster.join("\n") + "\n")
      slices = ["student_id,cutout_id,slice"] + @targets.map { |t| "#{t["student"]},#{t["cutout"]},#{t["slice"]}" }
      File.write(File.join(@dir, "slices.csv"), slices.join("\n") + "\n")
      teach("students", "import", File.join(@dir, "roster.csv"))
      teach("slices", "assign", "--assignment", @assignment, "--from", File.join(@dir, "slices.csv"))
      teach("release", "--assignment", @assignment)
      codes = JSON.parse(teach("enroll", "codes"))
      codes.each { |row| @codes[row["student_id"]] = row["code"] }
      missing = @targets.map { |t| t["student"] } - @codes.keys
      raise Smoke::Abort, "no enroll code for #{missing.join(", ")}" unless missing.empty?
    end

    def code_for(student)
      @codes.fetch(student)
    end

    def start
      FileUtils.mkdir_p(File.join(@dir, "logs"))
      @pids[:serve] = spawn_teach("serve", File.join(@dir, "logs", "teach-serve.log"))
      60.times do
        return true if healthy?

        raise Smoke::Abort, "teach serve exited early: #{File.read(File.join(@dir, "logs", "teach-serve.log")).lines.last(6).join}" if exited?(@pids[:serve])
        sleep 0.5
      end
      raise Smoke::Abort, "teach did not become healthy on #{url}"
    end

    def start_grader
      @pids[:grader] = spawn_teach("grader", File.join(@dir, "logs", "teach-grader.log"))
    end

    def stop
      @pids.each_value { |pid| terminate(pid) }
      @pids.clear
    end

    def listening?
      Socket.tcp(Smoke::GATEWAY, @port, connect_timeout: 1).close
      true
    rescue StandardError
      false
    end

    def teach(*args, timeout: 300)
      out, err, status = SliceBuild.sh(*%w[bundle exec ruby bin/teach], *args, env: env, chdir: @teach_dir, timeout: timeout)
      raise Smoke::Abort, "teach #{args.first(2).join(" ")} failed: #{(err + out).lines.last(6).join}" unless status.success?

      out
    end

    def teach_json(*args)
      out = teach(*args)
      JSON.parse(out[out.index(/[\[{]/)..])
    end

    def psql_rows(sql)
      out = SliceBuild.sh!("psql", "-X", "-At", "-d", @db, "-c", sql, timeout: 60)
      out.lines.map(&:strip).reject(&:empty?).map { |line| JSON.parse(line) }
    end

    def qualifications(student, cutout)
      psql_rows("select row_to_json(q) from (select id, attempt, status, created_at, started_at, finished_at, result_json from qualifications where student_id = '#{student}' and cutout_id = '#{cutout}' order by created_at) q")
    end

    def teach_sha_value
      @teach_sha
    end

    private

    def free_port
      server = TCPServer.new(Smoke::GATEWAY, 0)
      server.addr[1]
    ensure
      server&.close
    end

    def clone_teach
      SliceBuild.sh!("git", "clone", "--quiet", TEACH_SRC, @teach_dir)
      SliceBuild.sh!("git", "-C", @teach_dir, "checkout", "--quiet", "--detach", @teach_sha)
      FileUtils.mkdir_p(File.join(@teach_dir, ".bundle"))
      File.write(File.join(@teach_dir, ".bundle", "config"), "---\nBUNDLE_PATH: \"#{TEACH_BUNDLE}\"\n")
    end

    def rewrite_due_dates
      path = File.join(@teach_dir, "teach.spec.yml")
      text = File.read(path)
      ids = YAML.safe_load(text, permitted_classes: [Date, Time]).dig("course_model", "assignments").map { |a| a["id"] }
      index = ids.index(@assignment)
      raise Smoke::Abort, "assignment #{@assignment} is not in teach.spec.yml" unless index

      gap = Integer(CONFIG["phase_gap_days"])
      today = Date.today
      @dates = {}
      ids.each_with_index do |id, k|
        offset = k >= index ? gap * (k - index + 1) : -gap * (index - k)
        @dates[id] = "#{(today + offset).strftime("%Y-%m-%d")} 23:59"
      end
      seen = -1
      rewritten = text.gsub(/^(\s+due: ')\d{4}-\d{2}-\d{2} \d{2}:\d{2}(')/) do
        seen += 1
        "#{Regexp.last_match(1)}#{@dates.fetch(ids.fetch(seen))}#{Regexp.last_match(2)}"
      end
      raise Smoke::Abort, "found #{seen + 1} due lines for #{ids.length} assignments" unless seen + 1 == ids.length

      File.write(path, rewritten)
    end

    def spawn_teach(command, log_path)
      log = File.open(log_path, "w")
      Process.spawn(env, "bundle", "exec", "ruby", "bin/teach", command, chdir: @teach_dir, out: log, err: log, pgroup: true)
    end

    def exited?(pid)
      Process.wait(pid, Process::WNOHANG) ? true : false
    rescue Errno::ECHILD
      true
    end

    def healthy?
      Net::HTTP.get_response(URI("#{url}/api/v1/health")).code == "200"
    rescue StandardError
      false
    end

    def terminate(pid)
      Process.kill("TERM", -pid)
      Timeout.timeout(15) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      begin
        Process.kill("KILL", -pid)
        Process.wait(pid)
      rescue StandardError
        nil
      end
    end
  end

  class Run
    attr_reader :id, :dir, :grokit_dir, :teach_sha

    def initialize(targets, dry_run:)
      @targets = targets
      @dry_run = dry_run
      @id = Time.now.strftime("%Y%m%d_%H%M%S")
      @dir = File.join(RUNS_DIR, @id)
      @grokit_dir = File.join(@dir, "grokit")
      @spend = Smoke::Spend.new(RUN_BUDGET_USD)
      @spec = nil
      @results = []
      @phases = []
      @aborted = nil
      @started = Time.now
      @prompt = YAML.safe_load(File.read(File.join(__dir__, "scenarios.yml")))["student_prompt"]
    end

    def exit_code
      return 1 if @aborted
      return 1 if @results.any? { |r| %w[stalled aborted].include?(r["outcome"]) && !@dry_run }

      0
    end

    def run
      FileUtils.mkdir_p(@dir)
      puts "run #{@id} -> #{@dir}#{@dry_run ? " (dry run)" : ""}"
      preflight!
      @teach_sha = SliceBuild.sh!("git", "-C", TEACH_SRC, "rev-parse", TEACH_REF).strip
      puts "teach #{@teach_sha[0, 10]} (#{TEACH_REF}) for every phase"
      clone_grokit
      load_spec
      fetch_runtime_kit
      assign_students
      phases = @targets.group_by { |t| t["assignment"] }.sort.map { |a, list| Phase.new(self, a, list) }
      @phases = phases
      phases.each do |phase|
        stop_check!
        run_phase(phase)
      end
    rescue Smoke::SpendExceeded, Smoke::StopRequested, Interrupted => e
      @aborted = e.message
      puts "RUN STOPPED: #{e.message}"
    rescue Smoke::Abort, Smoke::PreflightFailed => e
      @aborted = e.message
      puts "RUN FAILED: #{e.message}"
    ensure
      Smoke::Docker.kill_all
      @phases.each(&:stop)
      mark_unrun
      write_report
    end

    private

    def preflight!
      raise Smoke::PreflightFailed, "REACH_SMOKE_DISABLE=1" if ENV["REACH_SMOKE_DISABLE"] == "1"
      raise Smoke::PreflightFailed, "docker is not on PATH" unless Smoke.on_path?("docker")
      raise Smoke::PreflightFailed, "docker info failed" unless system("docker", "info", out: File::NULL, err: File::NULL)
      raise Smoke::PreflightFailed, "claude is not on PATH" unless Smoke.on_path?("claude")
      %w[createdb psql git].each { |bin| raise Smoke::PreflightFailed, "#{bin} is not on PATH" unless Smoke.on_path?(bin) }
      @token = Smoke.load_token
      raise Smoke::PreflightFailed, "no token: write one to #{Smoke::TOKEN_FILE}" if @token.nil? && !@dry_run

      ensure_image!
      GRADER_IMAGES.each do |image|
        raise Smoke::PreflightFailed, "docker image #{image} is missing; teach grader cannot start" unless system("docker", "image", "inspect", image, out: File::NULL, err: File::NULL)
      end
      raise Smoke::PreflightFailed, "ruby 4 not found at #{RUBY4_BIN}" unless File.executable?(File.join(RUBY4_BIN, "ruby"))
      raise Smoke::PreflightFailed, "dovetail not found at #{DOVETAIL_ROOT}" unless File.executable?(File.join(DOVETAIL_ROOT, "exe", "dovetail"))
      raise Smoke::PreflightFailed, "teach bundle at #{TEACH_BUNDLE} has no pg gem" if Dir.glob(File.join(TEACH_BUNDLE, "ruby", "*", "gems", "pg-*")).empty?
      raise Smoke::PreflightFailed, "teach source #{TEACH_SRC} is not a repository" unless File.directory?(File.join(TEACH_SRC, ".git"))
      raise Smoke::PreflightFailed, "grokit source #{GROKIT_SRC} is not a repository" unless File.directory?(File.join(GROKIT_SRC, ".git"))
    end

    def ensure_image!
      return if system("docker", "image", "inspect", Smoke::IMAGE, out: File::NULL, err: File::NULL)

      dockerfile = Smoke::IMAGE == "reach-smoke:noble" ? "Dockerfile.noble" : "Dockerfile"
      puts "building #{Smoke::IMAGE} from #{dockerfile}"
      raise Smoke::PreflightFailed, "docker build for #{Smoke::IMAGE} failed" unless system("docker", "build", "-q", "-t", Smoke::IMAGE, "-f", File.join(__dir__, dockerfile), __dir__, out: File::NULL)
    end

    def runtime_constants
      text = File.read(File.join(Smoke::REACH, "lib", "reach", "runtime_kit.rb"))
      { "tag" => text[/RUNTIME_TAG = "([^"]+)"/, 1], "base" => text[/RELEASE_BASE = "([^"]+)"/, 1], "manifest" => text[/MANIFEST_ASSET = "([^"]+)"/, 1] }
    end

    def fetch_runtime_kit
      constants = runtime_constants
      raise Smoke::PreflightFailed, "could not read the runtime pin from lib/reach/runtime_kit.rb" if constants.values.any?(&:nil?)

      @kit_dir = File.join(@dir, "runtime-kit")
      FileUtils.mkdir_p(@kit_dir)
      manifest_path = File.join(@kit_dir, constants["manifest"])
      SliceBuild.sh!("curl", "-fsSL", "-o", manifest_path, "#{constants["base"]}/#{constants["tag"]}/#{constants["manifest"]}", timeout: 120)
      data = JSON.parse(File.read(manifest_path))
      entry = data.fetch("platforms").fetch("linux-x86_64")
      assets = []
      assets << [entry.dig("bundle", "asset"), "#{constants["base"]}/#{constants["tag"]}/#{entry.dig("bundle", "asset")}", entry["bundle"]]
      assets << [File.basename(entry["chrome"]["url"]), entry["chrome"]["url"], entry["chrome"]] if entry["chrome"]
      assets.each do |name, url, meta|
        path = File.join(@kit_dir, name)
        puts "runtime kit: downloading #{name}"
        SliceBuild.sh!("curl", "-fsSL", "-o", path, url, timeout: 900)
        raise Smoke::PreflightFailed, "runtime asset #{name} failed its checksum" unless Digest::SHA256.file(path).hexdigest == meta["sha256"].to_s
      end
      @runtime = { "tag" => constants["tag"], "runtime_id" => data["runtime_id"], "ruby_version" => data["ruby_version"], "chrome_version" => data["chrome_version"] }
    end

    def clone_grokit
      SliceBuild.sh!("git", "clone", "--quiet", GROKIT_SRC, @grokit_dir)
      SliceBuild.sh!("git", "-C", @grokit_dir, "checkout", "--quiet", "--detach", GROKIT_TAG)
    end

    def load_spec
      @spec = YAML.safe_load(File.read(File.join(@grokit_dir, "specs", "app.yml")), permitted_classes: [Date, Time])
    end

    def cutout_entry(id)
      entry = @spec["cutouts"].find { |c| c["id"] == id }
      raise Smoke::Abort, "grokit spec has no cutout #{id}" unless entry

      entry
    end

    def assign_students
      all = CONFIG["targets"]
      @targets.each do |target|
        entry = cutout_entry(target["cutout"])
        raise Smoke::Abort, "#{target["cutout"]} is assigned #{entry["assignment"]} in the spec, not #{target["assignment"]}" unless entry["assignment"] == target["assignment"]

        target["student"] = format("s%02d", all.index { |t| t["cutout"] == target["cutout"] } + 1)
        target["group"] = entry["group"]
        target["owned"] = Array(entry["owned_paths"]).find { |p| p.end_with?(".svelte") }
        raise Smoke::Abort, "#{target["cutout"]} has no owned panel file" unless target["owned"]
      end
    end

    def stop_check!
      raise Interrupted, "interrupted" if $interrupted
      raise Smoke::StopRequested, "REACH_SMOKE_DISABLE=1" if ENV["REACH_SMOKE_DISABLE"] == "1"
      raise Smoke::StopRequested, "STOP file present" if File.exist?(File.join(@dir, "STOP"))
    end

    def run_phase(phase)
      puts "\n== phase #{phase.assignment}: #{phase.targets.map { |t| t["module"] }.join(", ")}"
      phase.provision
      puts "   database #{phase.db}, port #{phase.port}, due dates #{phase.dates.inspect}"
      phase.start
      phase.start_grader
      phase.targets.each do |target|
        stop_check!
        record = new_record(phase, target)
        @results << record
        begin
          if @dry_run
            dry_run_module(phase, target, record)
          else
            run_module(phase, target, record)
          end
        ensure
          Smoke::Docker.kill_all if $interrupted
          write_report
        end
      end
    ensure
      phase.stop
      puts "   teach and grader stopped; port #{phase.port} listening: #{phase.listening?}" if phase.port
    end

    def new_record(phase, target)
      home = File.join(@dir, target["module"], "home")
      FileUtils.mkdir_p(home)
      { "module" => target["module"], "cutout" => target["cutout"], "assignment" => phase.assignment, "student" => target["student"],
        "database" => phase.db, "outcome" => "not_run", "reason" => nil, "grade" => nil, "submitted" => false, "qualifications" => [], "qualify_attempts" => 0, "ladder" => [], "shape" => nil, "home" => home, "dir" => File.join(@dir, target["module"]) }
    end

    def reach_cli(home, name, *args)
      docker = Smoke::Docker.args(name: "reach-slice-#{@id}-#{name}-#{SecureRandom.hex(3)}", home: home, workdir: Smoke::CONTAINER_HOME, interactive: false)
      out, err, status = Open3.capture3({}, "timeout", "300", *docker, "ruby", "/plugin/exe/reach", *args)
      File.write(File.join(File.dirname(home), "reach-#{args.first}.log"), out + err)
      raise Smoke::Abort, "reach #{args.first} failed: #{(out + err)[-400..] || (out + err)}" unless status.success?

      out
    end

    def install_runtime(home, target, record)
      docker = Smoke::Docker.args(name: "reach-slice-#{@id}-#{target["module"]}-rt-#{SecureRandom.hex(3)}", home: home, workdir: Smoke::CONTAINER_HOME, interactive: false)
      docker.insert(docker.index("-w"), "-v", "#{@kit_dir}:/kit:ro")
      out, err, status = Open3.capture3({}, "timeout", "600", *docker, "ruby", "/plugin/exe/reach", "runtime", "install", "--from", "/kit", "--yes")
      File.write(File.join(File.dirname(home), "reach-runtime-install.log"), out + err)
      raise Smoke::Abort, "reach runtime install failed: #{(out + err)[-400..] || (out + err)}" unless status.success?

      status_out = reach_cli(home, target["module"], "runtime", "status", "--json")
      info = JSON.parse(status_out[status_out.index("{")..])
      record["runtime"] = { "installed" => info["installed"], "runtime_id" => info["runtime_id"], "ruby" => info["ruby"], "chrome" => info["chrome"], "profiles" => info["profiles"], "components" => info["components"] }
      raise Smoke::Abort, "runtime not installed in #{target["module"]}'s home" unless info["installed"]
    end

    def enroll_and_sync(phase, target, record)
      home = record["home"]
      reach_cli(home, target["module"], "enroll", phase.code_for(target["student"]), "--teach-url", phase.url)
      install_runtime(home, target, record)
      reach_cli(home, target["module"], "sync")
      marker = Dir.glob(File.join(home, "reach-work", "**", ".reach", "slice.json")).first
      raise Smoke::Abort, "no slice workspace after sync for #{target["module"]}" unless marker

      host = File.dirname(File.dirname(marker))
      workspace = { host: host, container: host.sub(home, Smoke::CONTAINER_HOME) }
      record["workspace"] = host
      workspace
    end

    def workspace_problems(workspace, target)
      problems = []
      problems << "owned panel file #{target["owned"]} missing" unless File.file?(File.join(workspace[:host], target["owned"]))
      problems << "api/slice-api.json missing" unless File.file?(File.join(workspace[:host], "api", "slice-api.json"))
      problems << "qualify/ missing" unless File.directory?(File.join(workspace[:host], "qualify"))
      problems
    end

    def dry_run_module(phase, target, record)
      workspace = enroll_and_sync(phase, target, record)
      problems = workspace_problems(workspace, target)
      record["outcome"] = problems.empty? ? "dry_run_ok" : "dry_run_failed"
      record["reason"] = problems.join("; ") unless problems.empty?
      puts "   #{target["module"]}: student #{target["student"]} enrolled and synced; workspace #{workspace[:host].sub(@dir + "/", "")}"
      puts "      owned #{target["owned"]}"
      puts "      would run an agent session (#{AGENT_MODEL}) with the student actor (#{STUDENT_MODEL}), up to #{MAX_TURNS} student turns, #{MODULE_TIMEOUT_S}s, budget $#{SESSION_BUDGET_USD} per session"
      puts "      problems: #{problems.join("; ")}" unless problems.empty?
      raise Smoke::Abort, "dry run failed for #{target["module"]}: #{problems.join("; ")}" unless problems.empty?
    end

    def agent_args
      ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", AGENT_MODEL,
       "--max-budget-usd", SESSION_BUDGET_USD, "--plugin-dir", "/plugin", "--tools", "Read", "Glob", "Grep", "Skill", "Edit", "Write",
       "--allowedTools", "mcp__plugin_reach_reach", "mcp__reach", "Edit", "Write"]
    end

    def student_args(prompt)
      ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", STUDENT_MODEL,
       "--tools", "", "--system-prompt", prompt, "--max-budget-usd", STUDENT_BUDGET_USD]
    end

    def submitted?(home)
      Dir.glob(File.join(home, ".reach", "receipts", "*.json")).any? do |path|
        JSON.parse(File.read(path))["kind"] == "ingest"
      rescue StandardError
        false
      end
    end

    def reply_of(turn)
      text = turn["result"].to_s
      text.strip.empty? ? turn["texts"].join("\n\n") : text
    end

    def run_module(phase, target, record)
      started = Time.now
      agent_cost = Cost.new
      student_cost = Cost.new
      record["agent_turns"] = 0
      record["student_turns"] = 0
      transcript = []
      session = nil
      actor = nil
      begin
        workspace = enroll_and_sync(phase, target, record)
        problems = workspace_problems(workspace, target)
        raise Smoke::Abort, "workspace incomplete: #{problems.join("; ")}" unless problems.empty?

        persona = format(@prompt, persona: CONFIG["student"]["persona"].gsub("{student_id}", target["student"]), goals: CONFIG["student"]["goals"])
        dir = record["dir"]
        FileUtils.mkdir_p(File.join(dir, "student-home"))
        session = Smoke::Session.new(
          label: "#{target["module"]}-agent",
          docker_args: Smoke::Docker.args(name: "reach-slice-#{@id}-#{target["module"]}-agent", home: record["home"], workdir: workspace[:container]),
          claude_args: agent_args, token: @token, log_path: File.join(dir, "session-0.jsonl")
        )
        actor = Smoke::Session.new(
          label: "#{target["module"]}-student",
          docker_args: Smoke::Docker.args(name: "reach-slice-#{@id}-#{target["module"]}-student", home: File.join(dir, "student-home"), workdir: Smoke::CONTAINER_HOME, plugin: false),
          claude_args: student_args(persona), token: @token, log_path: File.join(dir, "student.jsonl")
        )
        message = CONFIG["student"]["opening"]
        deadline = started + MODULE_TIMEOUT_S
        ended = nil
        MAX_TURNS.times do
          stop_check!
          remaining = deadline - Time.now
          if remaining <= 0
            ended = "module timeout #{MODULE_TIMEOUT_S}s"
            break
          end
          turn = session.say(message, timeout_s: [TURN_TIMEOUT_S, remaining.ceil].min)
          usage_limit!(turn, "agent")
          spend_add(agent_cost, turn)
          record["agent_turns"] += 1
          reply = reply_of(turn)
          transcript << { "student" => message, "agent" => reply }
          puts "   [#{target["module"]}] student: #{message.gsub(/\s+/, " ")[0, 80]}"
          puts "   [#{target["module"]}] rEach:   #{reply.gsub(/\s+/, " ")[0, 120]}"
          break if submitted?(record["home"])
          if reply.strip.empty?
            ended = "empty reply from the agent"
            break
          end

          stop_check!
          answer = actor.say(reply, timeout_s: TURN_TIMEOUT_S)
          usage_limit!(answer, "student")
          spend_add(student_cost, answer)
          record["student_turns"] += 1
          message = answer["result"].to_s.strip
          if message.empty?
            ended = "empty reply from the student"
            break
          end
          if message.include?("[END]")
            ended = "student ended"
            break
          end
        end
        ended ||= "turn limit #{MAX_TURNS}" unless submitted?(record["home"])
        record["end_reason"] = ended
      rescue Smoke::SpendExceeded, Smoke::StopRequested, Interrupted => e
        record["outcome"] = "aborted"
        record["reason"] = e.message
        raise
      rescue Smoke::Abort => e
        record["outcome"] = "stalled"
        record["reason"] = e.message
      ensure
        session&.close
        actor&.close
        record["turns_log"] = session ? session.turns.map { |t| { "student" => t["student"], "agent" => reply_of(t), "cost" => t["cost"] } } : []
        record["agent_cost"] = agent_cost.total.round(4)
        record["student_cost"] = student_cost.total.round(4)
        record["cost"] = (agent_cost.total + student_cost.total).round(4)
        record["agent_replies_tail"] = transcript.last(3).map { |t| t["agent"] }
        record["guard_refusals"] = guard_refusals(session)
        record["minutes"] = ((Time.now - started) / 60.0).round(2)
        record["wall_seconds"] = (Time.now - started).round(1)
        File.write(File.join(record["dir"], "transcript.md"), render_transcript(transcript)) if File.directory?(record["dir"])
      end
      finish_module(phase, target, record) unless record["outcome"] == "aborted"
    end

    def usage_limit!(turn, who)
      text = turn["result"].to_s
      return unless turn["cost"].to_f.zero? && text.match?(USAGE_LIMIT)

      raise UsageLimit, "the #{who}'s Claude account hit a usage limit: #{text.gsub(/\s+/, " ")[0, 160]}"
    end

    def spend_add(tracker, turn)
      @spend.add(tracker.add(turn["cost"]))
    end

    def guard_refusals(session)
      return [] unless session

      session.turns.flat_map do |turn|
        turn["tool_results"].select { |r| r["text"].to_s.include?(GUARD_MARKER) }.map { |r| r["text"].gsub(/\s+/, " ")[0, 200] }
      end
    end

    def render_transcript(entries)
      entries.map { |e| "**Student:** #{e["student"]}\n\n**rEach:** #{e["agent"]}\n" }.join("\n")
    end

    def finish_module(phase, target, record)
      student = target["student"]
      submission = submitted?(record["home"])
      rows = safe { phase.teach_json("submissions", "list", "--assignment", phase.assignment, "--student", student) } || []
      record["submission_id"] = rows.first && rows.first["id"]
      record["submitted"] = submission || !rows.empty?
      if record["submitted"] && record["outcome"] != "stalled"
        grade = wait_for_grade(phase, student)
        record["grade"] = grade
        record["outcome"] = grade ? "graded" : "stalled"
        record["reason"] = "no grade within #{GRADER_TIMEOUT_S}s" unless grade
      elsif record["outcome"] != "stalled"
        record["outcome"] = %w[student\ ended].include?(record["end_reason"]) ? "not_submitted" : "stalled"
        record["reason"] = record["end_reason"] if record["outcome"] == "stalled"
      end
      collect_evidence(phase, target, record)
      puts "   => #{target["module"]} #{record["outcome"].upcase} score #{record.dig("grade", "score").inspect} #{record["minutes"]} min $#{record["cost"]}"
    end

    def safe
      yield
    rescue StandardError
      nil
    end

    def wait_for_grade(phase, student)
      deadline = Time.now + GRADER_TIMEOUT_S
      loop do
        stop_check!
        rows = safe { phase.teach_json("grades", "export", "--assignment", phase.assignment) } || []
        row = rows.find { |r| r["student_id"] == student }
        return grade_detail(phase, row) if row

        return nil if Time.now > deadline

        sleep 5
      end
    end

    def grade_detail(phase, row)
      grade = { "score" => row["score"], "receipt_id" => row["receipt_id"], "late" => row["late"], "passed" => nil, "total" => nil, "failed_scenarios" => [], "scenarios" => [] }
      submissions = safe { phase.teach_json("submissions", "list", "--assignment", phase.assignment, "--student", row["student_id"]) } || []
      sub = submissions.first
      return grade unless sub

      shown = safe { phase.teach_json("submissions", "show", sub["id"]) } || {}
      receipt = Array(shown["receipts"]).find { |r| r["kind"] == "grade" }
      scenarios = receipt ? Array(receipt["scenarios"]) : []
      grade["scenarios"] = scenarios
      grade["total"] = scenarios.length
      grade["passed"] = scenarios.count { |s| s["result"] == "passed" }
      grade["failed_scenarios"] = scenarios.reject { |s| s["result"] == "passed" }.map { |s| { "name" => s["name"], "result" => s["result"], "reason" => s["reason"] } }
      grade
    end

    def collect_evidence(phase, target, record)
      record["qualifications"] = (safe { phase.qualifications(target["student"], target["cutout"]) } || []).map do |q|
        result = q["result_json"].is_a?(String) ? (safe { JSON.parse(q["result_json"]) } || {}) : (q["result_json"] || {})
        sets = %w[agent hidden].map { |k| Array(result[k]) }
        failed = sets.flatten.reject { |s| s["result"] == "passed" }.map { |s| s["name"] }
        passed = result.key?("passed") ? result["passed"] : (q["status"] == "done" && !sets.flatten.empty? ? failed.empty? : nil)
        { "id" => q["id"], "attempt" => q["attempt"], "status" => q["status"], "passed" => passed, "failed_scenarios" => failed.uniq, "created_at" => q["created_at"], "finished_at" => q["finished_at"] }
      end
      record["qualify_attempts"] = record["qualifications"].length
      record["ladder"] = ladder_state(record)
      record["shape"] = shape_findings(target, record)
    end

    def ladder_state(record)
      files = Dir.glob(File.join(record["home"], ".reach", "state", "ladder", "*.json"))
      files.map do |path|
        data = JSON.parse(File.read(path))
        { "slice" => File.basename(path, ".json"), "failed" => data["failed"], "hand_id" => data["hand_id"], "hand_ref" => data["hand_ref"],
          "hand_created_at" => data["hand_created_at"], "consent_at" => data["consent_at"], "history_length" => Array(data["history"]).length }
      end
    rescue StandardError => e
      [{ "error" => e.message }]
    end

    def shape_findings(target, record)
      return { "not_run" => true, "errors" => nil, "warnings" => nil, "findings" => [] } unless record["workspace"]

      work = File.join(record["dir"], "shape-check")
      FileUtils.mkdir_p(work)
      mod = target["module"]
      dovetail = File.join(DOVETAIL_ROOT, "exe", "dovetail")
      SliceBuild.sh!(dovetail, "compile", File.join(@grokit_dir, "modules", mod, "contract.rb"), "--out", File.join(work, "compiled"), timeout: 180)
      shape = File.join(work, "compiled", "shape", "#{mod}.shape.json")
      panel = File.join(work, "panel")
      FileUtils.rm_rf(panel)
      FileUtils.cp_r(File.join(@grokit_dir, "modules", mod, "panel"), panel)
      agent_file = File.join(record["workspace"], target["owned"])
      relative = target["owned"].sub(%r{\Amodules/#{Regexp.escape(mod)}/panel/}, "")
      FileUtils.cp(agent_file, File.join(panel, relative)) if File.file?(agent_file)
      out, err, _status = SliceBuild.sh(dovetail, "check", panel, "--shape", shape, "--profile", "strict", "--format", "json", timeout: 180)
      report = JSON.parse(out[out.index("{")..])
      findings = Array(report["findings"]).map do |f|
        { "rule" => f["rule"] || f["id"] || f["code"], "severity" => f["severity"], "message" => (f["message"] || f["detail"]).to_s[0, 200], "file" => f["file"] }
      end
      summary = report["summary"] || {}
      { "errors" => summary["errors"], "warnings" => summary["warnings"], "findings" => findings }
    rescue StandardError => e
      { "errors" => nil, "warnings" => nil, "findings" => [], "error" => "#{e.class}: #{e.message}"[0, 300] }
    end

    def mark_unrun
      done = @results.map { |r| r["cutout"] }
      @targets.each do |target|
        next if done.include?(target["cutout"])

        @results << { "module" => target["module"], "cutout" => target["cutout"], "assignment" => target["assignment"], "outcome" => "not_run", "reason" => @aborted || "run ended first", "cost" => 0.0 }
      end
      @results.each do |r|
        next unless @aborted && r["outcome"] == "not_run"

        r["outcome"] = "aborted"
        r["reason"] = @aborted
      end
    end

    def commits
      { "reach" => SliceBuild.git_head(Smoke::REACH), "teach" => @teach_sha, "grokit" => SliceBuild.git_head(@grokit_dir),
        "dovetail" => SliceBuild.git_head(DOVETAIL_ROOT) }
    end

    def verdict
      @aborted ? "aborted: #{@aborted}" : "complete"
    end

    def write_report
      return unless File.directory?(@dir)

      total = @results.sum { |r| r["cost"].to_f }.round(4)
      clean = @results.map { |r| r.reject { |k, _| %w[turns_log home dir workspace].include?(k) } }
      report = {
        "run_id" => @id, "dry_run" => @dry_run, "status" => verdict, "aborted" => @aborted, "run_dir" => @dir,
        "commits" => commits,
        "teach_ref" => TEACH_REF,
        "image" => Smoke::IMAGE,
        "runtime" => @runtime,
        "models" => { "agent" => AGENT_MODEL, "student" => STUDENT_MODEL },
        "limits" => { "session_budget_usd" => SESSION_BUDGET_USD, "run_budget_usd" => RUN_BUDGET_USD, "turn_timeout_s" => TURN_TIMEOUT_S,
                      "max_turns" => MAX_TURNS, "module_timeout_s" => MODULE_TIMEOUT_S, "grader_timeout_s" => GRADER_TIMEOUT_S },
        "databases" => @phases.map { |p| { "assignment" => p.assignment, "database" => p.db, "port" => p.port } },
        "due_dates" => @phases.select(&:dates).to_h { |p| [p.assignment, p.dates] },
        "total_cost_usd" => total,
        "wall_minutes" => ((Time.now - @started) / 60.0).round(2),
        "modules" => clean
      }
      File.write(File.join(@dir, "report.json"), JSON.pretty_generate(report) + "\n")
      File.write(File.join(@dir, "report.md"), markdown(report))
    end

    def markdown(report)
      lines = ["# Slice-build smoke #{@id}", "", "Status: #{report["status"]}#{@dry_run ? " (dry run)" : ""}", ""]
      lines << "Commits: #{report["commits"].map { |k, v| "#{k} #{v.to_s[0, 10]}" }.join(", ")}"
      lines << "Teach ref #{report["teach_ref"]}; image #{report["image"]}; runtime #{report["runtime"] ? "#{report["runtime"]["runtime_id"]} (Ruby #{report["runtime"]["ruby_version"]}, Chrome #{report["runtime"]["chrome_version"]})" : "not fetched"}"
      lines << "Models: agent #{AGENT_MODEL}, student #{STUDENT_MODEL}"
      lines << "Limits: #{report["limits"].map { |k, v| "#{k} #{v}" }.join(", ")}"
      lines << "Scratch databases (never dropped): #{report["databases"].map { |d| "#{d["database"]} (#{d["assignment"]}, port #{d["port"]})" }.join(", ")}"
      lines << "Due dates used: #{report["due_dates"].map { |a, d| "#{a}: #{d.map { |k, v| "#{k} #{v}" }.join(", ")}" }.join("; ")}"
      lines << ""
      lines << "| module | cutout | outcome | score | passed/total | qualify attempts | shape errors/warnings | minutes | cost |"
      lines << "|---|---|---|---|---|---|---|---|---|"
      report["modules"].each do |m|
        grade = m["grade"] || {}
        shape = m["shape"] || {}
        outcome = m["outcome"] == "aborted" || m["reason"] ? "#{m["outcome"]}#{m["reason"] ? " (#{m["reason"].to_s.gsub("|", "/")[0, 80]})" : ""}" : m["outcome"]
        lines << "| #{m["module"]} | #{m["cutout"]} | #{outcome} | #{grade["score"].inspect} | #{grade["passed"].inspect}/#{grade["total"].inspect} | #{m["qualify_attempts"].inspect} | #{shape.empty? || shape["not_run"] ? "not run" : "#{shape["errors"].inspect}/#{shape["warnings"].inspect}"} | #{m["minutes"].inspect} | $#{m["cost"].to_f.round(4)} |"
      end
      lines << ""
      lines << "Run total cost: $#{report["total_cost_usd"]}"
      report["modules"].each do |m|
        lines << "" << "## #{m["module"]} (#{m["cutout"]})" << ""
        lines << "Outcome: #{m["outcome"]}#{m["reason"] ? " - #{m["reason"]}" : ""}"
        lines << "Turns: agent #{m["agent_turns"].inspect}, student #{m["student_turns"].inspect}; wall #{m["minutes"].inspect} min; agent cost $#{m["agent_cost"].inspect}, student cost $#{m["student_cost"].inspect}"
        lines << "Guarded-write refusals: #{Array(m["guard_refusals"]).length}"
        Array(m["guard_refusals"]).first(3).each { |g| lines << "  - #{g}" }
        lines << "Qualify attempts: #{Array(m["qualifications"]).map { |q| "##{q["attempt"]} #{q["status"]}#{q["passed"].nil? ? "" : q["passed"] ? " pass" : " fail"}#{Array(q["failed_scenarios"]).empty? ? "" : " (#{q["failed_scenarios"].join("; ")})"}" }.join(", ")}"
        lines << "Ladder: #{m["ladder"].to_a.map(&:to_json).join("; ")}"
        failed = Array(m.dig("grade", "failed_scenarios"))
        lines << "Failing scenarios: #{failed.empty? ? "none" : failed.map { |s| "#{s["name"]} (#{s["reason"] || s["result"]})" }.join("; ")}"
        shape = m["shape"] || {}
        findings = Array(shape["findings"])
        lines << "Shape findings: #{shape.empty? || shape["not_run"] ? "not run" : findings.empty? ? (shape["error"] || "none") : findings.map { |f| "#{f["severity"]} #{f["rule"]}: #{f["message"]}" }.join("; ")}"
        lines << "Last agent replies:"
        Array(m["agent_replies_tail"]).each { |r| lines << "  > #{r.to_s.gsub(/\s+/, " ")[0, 600]}" }
      end
      lines.join("\n") + "\n"
    end
  end

  def self.targets_for(selected)
    all = CONFIG["targets"].map(&:dup)
    return all if selected.empty?

    unknown = selected - all.map { |t| t["module"] }
    raise Smoke::Abort, "unknown module(s): #{unknown.join(", ")}" unless unknown.empty?

    all.select { |t| selected.include?(t["module"]) }
  end

  def self.main(argv)
    if argv.include?("--list")
      CONFIG["targets"].each { |t| puts "#{t["module"]}  #{t["cutout"]}  #{t["slice"]}  #{t["assignment"]}" }
      return 0
    end

    $stdout.sync = true
    dry_run = argv.include?("--dry-run")
    selected = argv.reject { |arg| arg.start_with?("--") }
    selected = ENV["SMOKE_ONLY"].to_s.split(",").map(&:strip).reject(&:empty?) if selected.empty?
    run = Run.new(targets_for(selected), dry_run: dry_run)
    trap("INT") do
      $interrupted = true
      Smoke::Docker.kill_all
    end
    trap("TERM") do
      $interrupted = true
      Smoke::Docker.kill_all
    end
    run.run
    run.exit_code
  rescue Smoke::Abort => e
    puts "slice_build: #{e.message}"
    1
  end
end

exit(SliceBuild.main(ARGV)) if $PROGRAM_NAME == __FILE__
