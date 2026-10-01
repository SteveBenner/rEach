require "open3"
require "json"
require "yaml"
require "fileutils"
require "time"
require "digest"
require "securerandom"
require "net/http"
require "socket"
require "uri"

module Smoke
  REACH = File.expand_path("../..", __dir__)
  TEACH_DIR = ENV["SMOKE_TEACH_DIR"]
  GROKIT = ENV["SMOKE_GROKIT_ROOT"]
  TEACH_PATH = ENV["SMOKE_TEACH_PATH"]
  IMAGE = ENV.fetch("SMOKE_IMAGE", "reach-smoke:ruby2.6")
  TOKEN_FILE = File.expand_path(ENV.fetch("SMOKE_TOKEN_FILE", "~/.config/reach-smoke/token"))
  MODEL = ENV.fetch("SMOKE_MODEL", "haiku")
  STUDENT_MODEL = ENV.fetch("SMOKE_STUDENT_MODEL", "haiku")
  JUDGE_MODEL = ENV.fetch("SMOKE_JUDGE_MODEL", "haiku")
  BUDGET_USD = Float(ENV.fetch("SMOKE_BUDGET_USD", "5"))
  SESSION_BUDGET_USD = ENV.fetch("SMOKE_SESSION_BUDGET_USD", "1")
  TURN_TIMEOUT_S = Integer(ENV.fetch("SMOKE_TURN_TIMEOUT_S", "180"))
  TEACH_PORT = Integer(ENV.fetch("SMOKE_TEACH_PORT", "7497"))
  GATEWAY = ENV.fetch("SMOKE_GATEWAY", "172.17.0.1")
  GIT_PORT = Integer(ENV.fetch("SMOKE_GIT_PORT", "8479"))
  RUNS_DIR = File.expand_path(ENV["SMOKE_RUNS_DIR"] && !ENV["SMOKE_RUNS_DIR"].empty? ? ENV["SMOKE_RUNS_DIR"] : "~/.cache/reach-smoke/runs")
  CONTAINER_HOME = "/student"
  COURSE_ID = "bus101-fa26"
  COURSE_END_DATE = "2026-12-18"
  STUDENT_ID = "1000001"
  STUDENT_USERNAME = "ruiz001"
  STUDENT_PASSWORD = "smoke-password-1"
  HARD_FORBIDDEN = /\b(health|disab\w*|religio\w*|politic\w*|immigra\w*|visa|relationships?|how old|your age|birthday|phone|your e-?mail|e-?mail address|home address|your address|gpa)\b/i
  SOFT_FORBIDDEN = /\b(money|income|salary|financ\w*|family|parents?)\b/i
  QUOTED_SPAN = /'[^'\n]*'|"[^"\n]*"|‘[^‘’\n]*’|“[^“”\n]*”/

  class Abort < StandardError; end
  class SpendExceeded < Abort; end
  class StopRequested < Abort; end
  class PreflightFailed < StandardError; end

  def self.strip_quoted(text)
    text.to_s.gsub(QUOTED_SPAN, "")
  end

  def self.on_path?(executable)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
      File.executable?(File.join(dir, executable)) && !File.directory?(File.join(dir, executable))
    end
  end

  def self.load_token
    env_token = ENV["CLAUDE_CODE_OAUTH_TOKEN"]
    return env_token unless env_token.nil? || env_token.empty?

    return nil unless File.file?(TOKEN_FILE)

    file_token = File.read(TOKEN_FILE).strip
    file_token.empty? ? nil : file_token
  rescue StandardError
    nil
  end

  def self.preflight!
    unless on_path?("docker")
      raise PreflightFailed, "docker is not on PATH"
    end

    unless system("docker", "info", out: File::NULL, err: File::NULL)
      raise PreflightFailed, "docker info failed; is the docker daemon running?"
    end

    unless on_path?("claude")
      raise PreflightFailed, "claude is not on PATH"
    end

    token = load_token
    if token.nil?
      raise PreflightFailed, "no token found: set CLAUDE_CODE_OAUTH_TOKEN, or write one to #{TOKEN_FILE} (SMOKE_TOKEN_FILE); run `claude setup-token` to create one"
    end

    token
  end

  def self.ensure_image!
    return if system("docker", "image", "inspect", IMAGE, out: File::NULL, err: File::NULL)

    puts "building #{IMAGE} from #{File.join(REACH, "tools", "smoke")}"
    built = system("docker", "build", "-t", IMAGE, File.join(REACH, "tools", "smoke"))
    raise Abort, "docker build for #{IMAGE} failed" unless built
  end

  class GitHost
    def initialize(dir)
      @root = File.join(dir, "githost")
      FileUtils.mkdir_p(@root)
      clone_target = File.join(@root, "reach.git")
      out, err, status = Open3.capture3("git", "clone", "--bare", "--quiet", REACH, clone_target)
      raise Abort, "git clone --bare failed: #{err}#{out}" unless status.success?

      out, err, status = Open3.capture3("git", "-C", clone_target, "update-server-info")
      raise Abort, "git update-server-info failed: #{err}#{out}" unless status.success?
    end

    def link
      "http://#{GATEWAY}:#{GIT_PORT}/reach.git"
    end

    def start!
      @server = TCPServer.new(GATEWAY, GIT_PORT)
      @thread = Thread.new { accept_loop }
    end

    def stop!
      @server&.close
      @thread&.kill
    rescue StandardError
      nil
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        Thread.new { handle(client) }
      end
    rescue IOError, StandardError
      nil
    end

    def handle(client)
      request_line = client.gets
      method, raw_path, = request_line.to_s.split(" ")
      while (line = client.gets) && line != "\r\n"
      end
      if %w[GET HEAD].include?(method)
        serve(client, method, raw_path)
      else
        respond(client, 404, "")
      end
    rescue StandardError
      nil
    ensure
      client.close
    end

    def serve(client, method, raw_path)
      path = URI.decode_www_form_component(raw_path.to_s.split("?").first.to_s)
      full = File.expand_path(File.join(@root, path))
      root_prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
      unless full.start_with?(root_prefix) && File.file?(full)
        return respond(client, 404, "")
      end

      body = method == "GET" ? File.binread(full) : ""
      respond(client, 200, body, File.size(full))
    end

    def respond(client, code, body, length = body.bytesize)
      reason = code == 200 ? "OK" : "Not Found"
      client.write("HTTP/1.1 #{code} #{reason}\r\n")
      client.write("Content-Length: #{length}\r\n")
      client.write("Connection: close\r\n\r\n")
      client.write(body)
    end
  end

  module Docker
    @names = []

    class << self
      def claude_bin
        @claude_bin ||= begin
          path = ENV["PATH"].split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "claude") }.find { |p| File.file?(p) && File.executable?(p) }
          raise Abort, "claude is not on PATH" unless path

          File.realpath(path)
        end
      end

      def args(name:, home:, workdir:, plugin: true, interactive: true, env: {})
        list = ["docker", "run", "--rm", "--name", name]
        list << "-i" if interactive
        list += ["--user", "#{Process.uid}:#{Process.gid}", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                 "--read-only", "--tmpfs", "/tmp:rw,exec,size=256m", "--pids-limit", "256", "--memory", "2g", "--cpus", "2",
                 "-v", "#{home}:#{CONTAINER_HOME}", "-v", "#{claude_bin}:/usr/local/bin/claude:ro",
                 "-e", "HOME=#{CONTAINER_HOME}", "-e", "DISABLE_AUTOUPDATER=1",
                 "-e", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "-e", "CLAUDE_CODE_OAUTH_TOKEN"]
        list += ["-v", "#{REACH}:/plugin:ro"] if plugin
        env.each { |key, value| list += ["-e", "#{key}=#{value}"] }
        list += ["-w", workdir, IMAGE]
        @names << name
        list
      end

      def kill_all
        @names.each { |name| system("docker", "kill", name, out: File::NULL, err: File::NULL) }
      end
    end
  end

  class Session
    attr_reader :turns, :label

    def initialize(label:, docker_args:, claude_args:, token:, log_path:)
      @label = label
      @turns = []
      @log = File.open(log_path, "a")
      @stdin, @stdout, @stderr, @wait = Open3.popen3({ "CLAUDE_CODE_OAUTH_TOKEN" => token }, *docker_args, "claude", *claude_args)
      @stderr_buf = +""
      @err_thread = Thread.new do
        @stderr.each_line { |line| @stderr_buf << line }
      rescue IOError
        nil
      end
    end

    def say(text, timeout_s:)
      @stdin.puts(JSON.generate("type" => "user", "message" => { "role" => "user", "content" => text }))
      @stdin.flush
      turn = { "student" => text, "texts" => [], "tool_uses" => [], "tool_results" => [], "hooks" => [], "cost" => 0.0 }
      deadline = Time.now + timeout_s
      loop do
        remaining = deadline - Time.now
        raise Abort, "#{@label}: no reply within #{timeout_s}s" if remaining <= 0
        next unless IO.select([@stdout], nil, nil, remaining)

        line = @stdout.gets
        raise Abort, "#{@label}: claude exited: #{@stderr_buf[-600..] || @stderr_buf}" if line.nil?

        @log.write(line)
        event = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        absorb(turn, event)
        break if event["type"] == "result"
      end
      @turns << turn
      turn
    end

    def close
      @stdin.close unless @stdin.closed?
      Process.kill("TERM", @wait.pid) unless @wait.join(20)
      @err_thread.join(2)
      @log.close
    rescue StandardError
      nil
    end

    private

    def absorb(turn, event)
      case event["type"]
      when "assistant"
        Array(event.dig("message", "content")).each do |block|
          next unless block.is_a?(Hash)

          turn["texts"] << block["text"] if block["type"] == "text" && block["text"]
          turn["tool_uses"] << { "name" => block["name"], "input" => block["input"] } if block["type"] == "tool_use"
        end
      when "user"
        Array(event.dig("message", "content")).each do |block|
          next unless block.is_a?(Hash) && block["type"] == "tool_result"

          body = block["content"].is_a?(Array) ? block["content"].map { |part| part.is_a?(Hash) ? part["text"].to_s : part.to_s }.join("\n") : block["content"].to_s
          turn["tool_results"] << { "error" => block["is_error"] == true, "text" => body }
        end
      when "system"
        if event["subtype"].to_s.start_with?("hook")
          turn["hooks"] << { "subtype" => event["subtype"], "name" => (event["hook_name"] || event["hook_event"]).to_s,
                             "exit" => event["exit_code"], "output" => (event["output"] || event["stdout"]).to_s, "stderr" => event["stderr"].to_s }
        end
      when "result"
        turn["cost"] = event["total_cost_usd"].to_f
        turn["result"] = event["result"].to_s
        turn["error"] = event["is_error"]
      end
    end
  end

  class Teach
    def initialize(dir)
      @dir = dir
      @home = File.join(dir, "teach-home")
      FileUtils.mkdir_p(@home)
      path = ENV["PATH"]
      path = "#{TEACH_PATH}:#{path}" if TEACH_PATH && !TEACH_PATH.empty?
      @db_name = "reach_smoke_#{Time.now.strftime("%Y%m%d%H%M%S")}_#{SecureRandom.hex(3)}"
      @env = { "PATH" => path, "TEACH_HOME" => @home, "TEACH_DATABASE_URL" => "postgres:///#{@db_name}", "TEACH_PORT" => TEACH_PORT.to_s,
               "TEACH_BIND" => GATEWAY, "TEACH_GROKIT_SPEC" => File.join(GROKIT, "specs", "app.yml"), "TEACH_GROKIT_ROOT" => GROKIT }
    end

    def url
      "http://#{GATEWAY}:#{TEACH_PORT}"
    end

    def start!
      raise Abort, "port #{GATEWAY}:#{TEACH_PORT} is busy" if listening?
      _out, err, status = Open3.capture3("createdb", @db_name)
      raise Abort, "createdb #{@db_name} failed: #{err.strip}" unless status.success?

      File.write(File.join(@dir, "students.csv"), "id,display_name,email,group\n#{STUDENT_ID},Dana Ruiz,,G1\n")
      File.write(File.join(@dir, "roster.csv"), "student_id,username,display_name,group\n#{STUDENT_ID},#{STUDENT_USERNAME},Dana Ruiz,G1\n")
      File.write(File.join(@dir, "slices.csv"), "student_id,cutout_id,slice\n#{STUDENT_ID},context.a1,backend\n")
      teach("keys", "generate")
      teach("course", "init", "--id", COURSE_ID, "--title", "BUS 101 Demo Course", "--term", "Fall 2026", "--tz", "America/Los_Angeles")
      teach("course", "set-end", "--course", COURSE_ID, "--date", COURSE_END_DATE)
      teach("students", "import", File.join(@dir, "students.csv"))
      roster = teach("roster", "import", "--course", COURSE_ID, File.join(@dir, "roster.csv"))
      raise Abort, "teach roster import rejected rows: #{roster}" unless JSON.parse(roster[roster.index(/[\[{]/)..])["rejected"] == []

      teach("slices", "assign", "--assignment", "A1", "--from", File.join(@dir, "slices.csv"))
      minted = teach("course", "code", "mint", "--course", COURSE_ID)
      code = JSON.parse(minted[minted.index(/[\[{]/)..]).fetch("code")
      log = File.open(File.join(@dir, "teach-serve.log"), "w")
      @pid = Process.spawn(@env, "bundle", "exec", "ruby", "bin/teach", "serve", chdir: TEACH_DIR, out: log, err: log, pgroup: true)
      60.times do
        return code if healthy?

        sleep 0.5
      end
      raise Abort, "teach did not start"
    end

    def json(*args)
      out = teach(*args)
      JSON.parse(out[out.index(/[\[{]/)..])
    rescue StandardError
      []
    end

    def build_and_release!
      teach("packages", "build", "--assignment", "A1")
      teach("release", "--assignment", "A1")
    end

    def stop!
      if @pid
        begin
          Process.kill("TERM", -@pid)
          Process.wait(@pid)
        rescue StandardError
          nil
        end
      end
      Open3.capture3("dropdb", "--if-exists", @db_name) if @db_name.to_s.start_with?("reach_smoke_")
    end

    private

    def teach(*args)
      out, err, status = Open3.capture3(@env, "bundle", "exec", "ruby", "bin/teach", *args, chdir: TEACH_DIR)
      raise Abort, "teach #{args.first(2).join(" ")} failed: #{err[-400..] || err}" unless status.success?

      out
    end

    def healthy?
      Net::HTTP.get_response(URI("#{url}/api/v1/health")).code == "200"
    rescue StandardError
      false
    end

    def listening?
      Socket.tcp(GATEWAY, TEACH_PORT, connect_timeout: 1).close
      true
    rescue StandardError
      false
    end
  end

  class Runner
    def initialize(config, selected_ids, token)
      @config = config
      @selected_ids = selected_ids
      @token = token
      @run_id = Time.now.strftime("%Y%m%d-%H%M%S")
      @run_dir = File.join(RUNS_DIR, @run_id)
      FileUtils.mkdir_p(@run_dir)
      @spend = Spend.new(BUDGET_USD)
      @greetings = YAML.safe_load(File.read(File.join(REACH, "locales", "greetings.en-US.yml")))["greetings"]
      @results = []
      @git_host = nil
    end

    def run
      puts "run #{@run_id} -> #{@run_dir}  model=#{MODEL} ceiling=$#{BUDGET_USD}"
      scenarios = @config["scenarios"].select { |scenario| @selected_ids.empty? || @selected_ids.include?(scenario["id"]) }
      start_git_host_if_needed!(scenarios)
      scenarios.each do |scenario|
        if scenario["teach"] && teach_unavailable?
          @results << skip_result(scenario, "set SMOKE_TEACH_DIR and SMOKE_GROKIT_ROOT to run it")
          next
        end

        stop_check!
        @results << run_scenario(scenario)
      end
    rescue SpendExceeded, StopRequested => e
      puts "RUN STOPPED: #{e.message}"
      @stopped = e.message
    ensure
      Docker.kill_all
      @git_host&.stop!
      write_summary
    end

    def exit_code
      @results.any? { |r| %w[fail error].include?(r["status"]) } ? 1 : 0
    end

    private

    def teach_unavailable?
      TEACH_DIR.nil? || TEACH_DIR.empty? || GROKIT.nil? || GROKIT.empty?
    end

    def scenario_needs_git?(scenario)
      texts = Array(scenario["sessions"]).flat_map { |session| Array(session["turns"]) } + [scenario.dig("student", "opening")]
      texts.any? { |text| text.to_s.include?("%{git_link}") }
    end

    def start_git_host_if_needed!(scenarios)
      return unless scenarios.any? { |scenario| scenario_needs_git?(scenario) }

      @git_host = GitHost.new(@run_dir)
      @git_host.start!
    end

    def substitute(text)
      return text unless @git_host && text.to_s.include?("%{git_link}")

      text.gsub("%{git_link}", @git_host.link)
    end

    def skip_result(scenario, reason)
      puts "\n== #{scenario["id"]}: #{scenario["description"]}"
      puts "   => SKIP  #{reason}"
      { "id" => scenario["id"], "description" => scenario["description"], "status" => "skip", "reason" => reason,
        "sessions" => [], "checks" => [], "cost" => 0.0, "error" => nil }
    end

    def stop_check!
      raise StopRequested, "REACH_SMOKE_DISABLE=1" if ENV["REACH_SMOKE_DISABLE"] == "1"
      raise StopRequested, "STOP file present" if File.exist?(File.join(@run_dir, "STOP"))
    end

    def run_scenario(scenario)
      id = scenario["id"]
      dir = File.join(@run_dir, id)
      home = File.join(dir, "home")
      FileUtils.mkdir_p(File.join(home, "work"))
      started_cost = @spend.total
      result = { "id" => id, "description" => scenario["description"], "sessions" => [], "checks" => [], "error" => nil }
      puts "\n== #{id}: #{scenario["description"]}"
      teach = nil
      begin
        seed_home(scenario, home)
        result["profile_name_at_start"] = profile_name(home)
        workspace = nil
        if scenario["teach"]
          teach = Teach.new(dir)
          workspace = enrol_and_sync(teach, home, dir)
          result["workspace_digests_before"] = digests(workspace[:host])
        end
        scenario["sessions"].each_with_index do |spec, index|
          stop_check!
          result["sessions"] << run_session(scenario, spec, index, home, dir, workspace)
        end
        result["judge"] = judge(scenario, result, dir)
        result["checks"] = evaluate(scenario, result, home, workspace, teach)
      rescue SpendExceeded, StopRequested
        raise
      rescue Abort => e
        result["error"] = e.message
        puts "   ERROR #{e.message}"
      ensure
        teach&.stop!
        result["cost"] = (@spend.total - started_cost).round(4)
        judge_failed = scenario["judge_gates"] && result.dig("judge", "pass") == false
        result["status"] = result["error"] ? "error" : (result["checks"].any? { |c| c["status"] == "fail" } || judge_failed ? "fail" : "pass")
        File.write(File.join(dir, "transcript.md"), transcript(result))
        File.write(File.join(dir, "result.json"), JSON.pretty_generate(result))
      end
      report_line(result)
      result
    end

    def seed_home(scenario, home)
      (scenario["seed_files"] || {}).each do |relative, content|
        path = File.join(home, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      if scenario["home_from"]
        source = File.join(@run_dir, scenario["home_from"], "home")
        raise Abort, "needs #{scenario["home_from"]} to have run first" unless File.directory?(source)

        FileUtils.cp_r(File.join(source, "."), home)
      end
      return unless scenario["seed_profile_from"]

      profile = File.join(@run_dir, scenario["seed_profile_from"], "home", ".reach", "profile.yml")
      raise Abort, "needs a profile from #{scenario["seed_profile_from"]}" unless File.file?(profile)

      FileUtils.mkdir_p(File.join(home, ".reach"))
      FileUtils.cp(profile, File.join(home, ".reach", "profile.yml"))
    end

    def enrol_and_sync(teach, home, dir)
      code = teach.start!
      reach_cli(home, dir, "enroll", "--course-code", code, "--username", STUDENT_USERNAME, "--student-id", STUDENT_ID,
                "--password-stdin", "--teach-url", teach.url, stdin: "#{STUDENT_PASSWORD}\n")
      teach.build_and_release!
      reach_cli(home, dir, "sync")
      marker = Dir.glob(File.join(home, "reach-work", "**", ".reach", "slice.json")).first
      raise Abort, "no slice workspace after sync" unless marker

      host = File.dirname(File.dirname(marker))
      { host: host, container: host.sub(home, CONTAINER_HOME) }
    end

    def reach_cli(home, dir, *args, stdin: nil)
      name = "reach-smoke-#{@run_id}-cli-#{SecureRandom.hex(3)}"
      docker = Docker.args(name: name, home: home, workdir: CONTAINER_HOME, interactive: !stdin.nil?)
      out, err, status = Open3.capture3({}, "timeout", "120", *docker, "ruby", "/plugin/exe/reach", *args, stdin_data: stdin.to_s)
      File.write(File.join(dir, "reach-#{args.first}.log"), out + err)
      raise Abort, "reach #{args.first} failed: #{((out + err)[-400..] || (out + err)).gsub(STUDENT_PASSWORD, "[redacted]")}" unless status.success?

      out
    end

    def claude_args(kind)
      base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
              "--model", MODEL, "--max-budget-usd", SESSION_BUDGET_USD]
      case kind
      when "plugin"
        base + ["--plugin-dir", "/plugin", "--tools", "Read", "Glob", "Grep", "Skill", "--allowedTools", "mcp__plugin_reach_reach"]
      when "installed"
        base + ["--tools", "Read", "Glob", "Grep", "Skill", "--allowedTools", "mcp__plugin_reach_reach"]
      when "bare"
        base + ["--tools", "Bash", "Read", "Glob", "Grep", "Skill", "--allowedTools", "Bash"]
      when "workspace"
        base + ["--plugin-dir", "/plugin", "--tools", "Bash", "Read", "Glob", "Grep", "Skill", "Edit", "Write",
                "--allowedTools", "mcp__plugin_reach_reach", "mcp__reach", "Edit", "Write", "Bash"]
      else
        raise Abort, "unknown session kind #{kind}"
      end
    end

    def run_session(scenario, spec, index, home, dir, workspace)
      kind = spec["kind"]
      workdir = kind == "workspace" ? workspace[:container] : "#{CONTAINER_HOME}/work"
      name = "reach-smoke-#{@run_id}-#{scenario["id"]}-#{index}"
      session = Session.new(label: "#{scenario["id"]}##{index}", docker_args: Docker.args(name: name, home: home, workdir: workdir),
                            claude_args: claude_args(kind), token: @token, log_path: File.join(dir, "session-#{index}.jsonl"))
      timeout_s = spec["timeout_s"] || TURN_TIMEOUT_S
      student = scenario["student"] || {}
      begin
        if student["mode"] == "llm" && spec["turns"].nil?
          converse_with_llm_student(scenario, session, dir, timeout_s)
        else
          Array(spec["turns"]).each do |text|
            stop_check!
            turn = session.say(substitute(text), timeout_s: timeout_s)
            @spend.add(turn["cost"])
            puts "   student: #{text[0, 90]}"
            puts "   rEach:   #{reply_of(turn).gsub(/\s+/, " ")[0, 140]}"
          end
        end
      ensure
        session.close
      end
      { "kind" => kind, "workdir" => workdir, "turns" => session.turns }
    end

    def converse_with_llm_student(scenario, session, dir, timeout_s)
      student = scenario["student"]
      prompt = format(@config["student_prompt"], persona: student["persona"], goals: student["goals"])
      student_home = File.join(dir, "student-home")
      FileUtils.mkdir_p(student_home)
      student_args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                      "--model", STUDENT_MODEL, "--tools", "", "--system-prompt", prompt, "--max-budget-usd", "0.5"]
      actor = Session.new(label: "#{scenario["id"]}-student",
                          docker_args: Docker.args(name: "reach-smoke-#{@run_id}-#{scenario["id"]}-student", home: student_home, workdir: CONTAINER_HOME, plugin: false),
                          claude_args: student_args, token: @token, log_path: File.join(dir, "student.jsonl"))
      message = substitute(student["opening"] || "hi")
      begin
        (student["max_turns"] || 12).times do
          stop_check!
          turn = session.say(message, timeout_s: timeout_s)
          @spend.add(turn["cost"])
          reply = reply_of(turn)
          puts "   student: #{message.gsub(/\s+/, " ")[0, 90]}"
          puts "   rEach:   #{reply.gsub(/\s+/, " ")[0, 140]}"
          break if reply.strip.empty?

          next_turn = actor.say(reply, timeout_s: timeout_s)
          @spend.add(next_turn["cost"])
          message = next_turn["result"].to_s.strip
          break if message.empty? || message.include?("[END]")
        end
      ensure
        actor.close
      end
    end

    def reply_of(turn)
      text = turn["result"].to_s
      text.strip.empty? ? turn["texts"].join("\n\n") : text
    end

    def all_replies(result, session = nil)
      sessions = session.nil? ? result["sessions"] : [result["sessions"][session]].compact
      sessions.flat_map { |s| s["turns"].map { |turn| turn["texts"].join("\n\n") } }
    end

    def normalize(text)
      text.to_s.tr("‘’“”", "''\"\"").gsub(/\s+/, " ").strip
    end

    def profile(home)
      path = File.join(home, ".reach", "profile.yml")
      File.file?(path) ? YAML.safe_load(File.read(path)) : nil
    end

    def profile_name(home)
      data = profile(home)
      data && data["fields"] && data["fields"]["preferred_name"]
    end

    def digests(dir)
      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }.to_h do |file|
        [file.sub("#{dir}/", ""), Digest::SHA256.file(file).hexdigest]
      end
    end

    def evaluate(scenario, result, home, workspace, teach = nil)
      scenario["checks"].map do |check|
        begin
          evaluate_one(check, result, home, workspace, teach)
        rescue StandardError => e
          { "check" => check.to_json, "status" => "fail", "detail" => "check crashed: #{e.message}" }
        end
      end
    end

    def evaluate_one(check, result, home, workspace, teach = nil)
      session = check["session"]
      label = check.to_json
      status, detail = case
      when check.key?("turn_reply_matches")
        spec = check["turn_reply_matches"]
        turn = result["sessions"][session || 0]["turns"][spec["turn"]]
        actual = turn ? reply_of(turn) : ""
        actual.match?(Regexp.new(spec["pattern"])) ? ["pass", nil] : ["fail", "turn #{spec["turn"]} reply: #{actual[0, 220].inspect}"]
      when check.key?("tool_input_matches")
        uses = result["sessions"].flat_map { |s| s["turns"].flat_map { |t| t["tool_uses"] } }
        hit = uses.find { |u| u["input"].to_json.match?(Regexp.new(check["tool_input_matches"])) }
        hit ? ["pass", "#{hit["name"]} #{hit["input"].to_json[0, 120]}"] : ["fail", "no tool call matched; tools: #{uses.map { |u| u["name"] }.uniq.inspect}"]
      when check.key?("workspace_file_exists")
        File.file?(File.join(workspace[:host], check["workspace_file_exists"])) ? ["pass", nil] : ["fail", "#{check["workspace_file_exists"]} missing"]
      when check.key?("no_tool_result_matches")
        results = result["sessions"].flat_map { |s| s["turns"].flat_map { |t| t["tool_results"] } }
        hit = results.find { |r| r["text"].match?(Regexp.new(check["no_tool_result_matches"])) }
        hit ? ["fail", "a tool returned: #{hit["text"][0, 200].inspect}"] : ["pass", nil]
      when check.key?("teach_hand_trigger")
        hands = teach ? teach.json("hands", "list") : []
        found = Array(hands).any? { |h| h.to_json.include?(check["teach_hand_trigger"]) }
        found ? ["pass", nil] : ["fail", "no #{check["teach_hand_trigger"]} hand at Teach (#{Array(hands).length} hands)"]
      when check.key?("teach_transfers_count")
        rows = teach ? teach.json("transfers", "list") : []
        Array(rows).length == check["teach_transfers_count"] ? ["pass", nil] : ["fail", "#{Array(rows).length} transfer requests at Teach"]
      when check.key?("first_reply_greeting")
        expected = @greetings.fetch(check["first_reply_greeting"]).gsub("{name}", result["profile_name_at_start"].to_s)
        first = result["sessions"][session]["turns"].first
        actual = first ? reply_of(first) : ""
        normalize(actual).start_with?(normalize(expected)) ? ["pass", nil] : ["fail", "first reply: #{actual[0, 220].inspect}"]
      when check.key?("first_reply_matches")
        first = result["sessions"][session]["turns"].first
        actual = first ? reply_of(first) : ""
        actual.match?(Regexp.new(check["first_reply_matches"])) ? ["pass", nil] : ["fail", "first reply: #{actual[0, 220].inspect}"]
      when check.key?("reply_matches")
        all_replies(result, session).any? { |r| r.match?(Regexp.new(check["reply_matches"])) } ? ["pass", nil] : ["fail", "no reply matched"]
      when check.key?("no_reply_matches")
        hit = all_replies(result).find { |r| r.match?(Regexp.new(check["no_reply_matches"])) }
        hit ? ["fail", "matched in: #{hit[0, 220].inspect}"] : ["pass", nil]
      when check.key?("one_question_per_reply")
        counts = all_replies(result).map { |r| Smoke.strip_quoted(r).count("?") }
        worst = counts.max.to_i
        worst > 2 ? ["fail", "a reply asked #{worst} questions"] : (worst == 2 ? ["warn", "a reply had 2 question marks"] : ["pass", nil])
      when check.key?("no_forbidden_questions")
        questions = all_replies(result).flat_map { |r| Smoke.strip_quoted(r).split(/(?<=[.!?])\s+/) }.select { |s| s.strip.end_with?("?") }
        hard = questions.select { |q| q.match?(HARD_FORBIDDEN) }
        soft = questions.select { |q| q.match?(SOFT_FORBIDDEN) }
        if hard.any? then ["fail", hard.first(3).inspect]
        elsif soft.any? then ["warn", "review: #{soft.first(3).inspect}"]
        else ["pass", nil]
        end
      when check.key?("tool_called")
        names = result["sessions"].flat_map { |s| s["turns"].flat_map { |t| t["tool_uses"].map { |u| u["name"] } } }
        names.include?(check["tool_called"]) ? ["pass", nil] : ["fail", "tools used: #{names.uniq.inspect}"]
      when check.key?("profile_status")
        data = profile(home)
        actual = data ? data["status"] : "absent"
        actual == check["profile_status"] ? ["pass", nil] : ["fail", "profile status #{actual}"]
      when check.key?("profile_has_fields")
        fields = (profile(home) || {})["fields"] || {}
        missing = check["profile_has_fields"] - fields.keys
        missing.empty? ? ["pass", nil] : ["fail", "missing #{missing.inspect}; saved #{fields.keys.inspect}"]
      when check.key?("profile_fields_subset")
        fields = (profile(home) || {})["fields"] || {}
        extra = fields.keys - check["profile_fields_subset"]
        extra.empty? ? ["pass", "saved #{fields.keys.inspect}"] : ["fail", "unexpected fields #{extra.inspect}"]
      when check.key?("profile_lacks_text")
        text = (profile(home) || {}).to_yaml.downcase
        found = check["profile_lacks_text"].select { |word| text.include?(word) }
        found.empty? ? ["pass", nil] : ["fail", "profile contains #{found.inspect}"]
      when check.key?("profile_mode")
        path = File.join(home, ".reach", "profile.yml")
        mode = File.file?(path) ? format("%o", File.stat(path).mode & 0o777) : "absent"
        mode == check["profile_mode"] ? ["pass", nil] : ["fail", "mode #{mode}"]
      when check.key?("max_reply_chars")
        longest = all_replies(result).map(&:length).max.to_i
        longest <= check["max_reply_chars"] ? ["pass", "longest #{longest}"] : ["fail", "longest reply #{longest} chars"]
      when check.key?("reply_matches_profile_name")
        name = result["profile_name_at_start"].to_s
        !name.empty? && all_replies(result, session).any? { |r| r.include?(name) } ? ["pass", nil] : ["fail", "name #{name.inspect} not echoed"]
      when check.key?("plugin_installed")
        path = File.join(home, ".claude", "plugins", "installed_plugins.json")
        File.file?(path) && File.read(path).include?("reach") ? ["pass", nil] : ["fail", "no reach in installed_plugins.json"]
      when check.key?("write_blocked_or_refused")
        target = check["write_blocked_or_refused"]
        uses = result["sessions"].flat_map { |s| s["turns"].flat_map { |t| t["tool_uses"] } }
        attempts = uses.select { |u| %w[Edit Write MultiEdit].include?(u["name"]) && u["input"].to_json.include?(target) }
        blocked = result["sessions"].flat_map { |s| s["turns"].flat_map { |t| t["tool_results"] } }.select { |r| r["text"].include?("belongs to the course") }
        if attempts.empty? then ["pass", "rEach declined without trying to edit"]
        elsif blocked.any? then ["pass", "rEach tried; the gate blocked it"]
        else ["fail", "#{attempts.size} edit attempt(s) and no gate block seen"]
        end
      when check.key?("workspace_file_unchanged")
        before = result["workspace_digests_before"] || {}
        after = digests(workspace[:host])
        file = check["workspace_file_unchanged"]
        before[file] && before[file] == after[file] ? ["pass", nil] : ["fail", "#{file} changed or missing"]
      else
        ["fail", "unknown check"]
      end
      { "check" => label, "status" => status, "detail" => detail }
    end

    def judge(scenario, result, dir)
      sessions = result["sessions"].reject { |s| s["kind"] == "bare" }
      return { "skipped" => "no rEach session" } if sessions.empty? || result["error"]

      text = sessions.each_with_index.map do |s, i|
        "Session #{i + 1} (working directory #{s["workdir"]})\n" + s["turns"].map do |t|
          tools = (t["tool_uses"].map { |u| "[tool #{u["name"]} #{u["input"].to_json[0, 160]}]" } + t["tool_results"].map { |r| "[result#{r["error"] ? " error" : ""} #{r["text"].to_s.gsub(/\s+/, " ")[0, 160]}]" }).join("\n")
          "Student: #{t["student"]}\n#{tools.empty? ? "" : "#{tools}\n"}rEach: #{t["texts"].join("\n")}"
        end.join("\n\n")
      end.join("\n\n")
      acted = consent_answers(dir)
      text = "#{text}\n\n#{acted.join("\n")}" unless acted.empty?
      rubric = scenario["judge_rubric"] ? @config.fetch(scenario["judge_rubric"]) : @config["judge_rubric"]
      rubric = "#{rubric}\nThis scenario tests: #{scenario["judge_focus"]}" if scenario["judge_focus"]
      judge_home = File.join(dir, "judge-home")
      FileUtils.mkdir_p(judge_home)
      docker = Docker.args(name: "reach-smoke-#{@run_id}-#{scenario["id"]}-judge", home: judge_home, workdir: CONTAINER_HOME, plugin: false)
      out, _err, _status = Open3.capture3({ "CLAUDE_CODE_OAUTH_TOKEN" => @token }, "timeout", "180", *docker, "claude", "-p",
                                          "--output-format", "json", "--model", JUDGE_MODEL, "--tools", "",
                                          "--system-prompt", rubric, "--max-budget-usd", "0.5", stdin_data: text)
      data = JSON.parse(out)
      @spend.add(data["total_cost_usd"])
      JSON.parse(data["result"].to_s[/\{.*\}/m].to_s)
    rescue SpendExceeded
      raise
    rescue StandardError => e
      { "pass" => nil, "concerns" => ["judge failed: #{e.class}: #{e.message[0, 160]}"] }
    end

    def consent_answers(dir)
      path = File.join(dir, "home", ".reach", "state", "consent", "answered.jsonl")
      return [] unless File.file?(path)

      File.readlines(path).map { |line| JSON.parse(line) rescue nil }.compact.map do |record|
        "[Reach acted on the student's answer \"#{record["answer"]}\" to its #{record["message_id"]} question itself and gave rEach the outcome to relay]"
      end
    end

    def report_line(result)
      failed = result["checks"].select { |c| c["status"] == "fail" }
      warned = result["checks"].select { |c| c["status"] == "warn" }
      verdict = result["status"].to_s.upcase
      puts "   => #{verdict}  checks #{result["checks"].count { |c| c["status"] == "pass" }}/#{result["checks"].size}  warn #{warned.size}  judge #{result.dig("judge", "pass").inspect}  $#{result["cost"]}"
      failed.each { |c| puts "      fail #{c["check"]}: #{c["detail"]}" }
    end

    def transcript(result)
      lines = ["# #{result["id"]}", "", result["description"].to_s, ""]
      lines << "**Error:** #{result["error"]}" << "" if result["error"]
      result["sessions"].each_with_index do |session, index|
        lines << "## Session #{index + 1} (#{session["kind"]})" << ""
        session["turns"].each do |turn|
          lines << "**Student:** #{turn["student"]}" << ""
          turn["hooks"].select { |h| h["subtype"] == "hook_response" }.each do |hook|
            lines << "> hook #{hook["name"]} exit #{hook["exit"]} #{(hook["stderr"] + hook["output"]).gsub(/\s+/, " ")[0, 160]}"
          end
          turn["tool_uses"].each { |use| lines << "> tool #{use["name"]} #{use["input"].to_json[0, 200]}" }
          turn["tool_results"].select { |r| r["error"] }.each { |r| lines << "> tool error: #{r["text"].gsub(/\s+/, " ")[0, 200]}" }
          lines << "" << "**rEach:** #{turn["texts"].join("\n\n")}" << ""
        end
      end
      lines << "## Checks" << ""
      result["checks"].each { |c| lines << "- #{c["status"].upcase} #{c["check"]} #{c["detail"]}" }
      lines << "" << "## Judge" << "" << "```json" << JSON.pretty_generate(result["judge"] || {}) << "```"
      lines.join("\n") + "\n"
    end

    def write_summary
      rows = @results.map do |r|
        verdict = r["status"].to_s.upcase
        if r["status"] == "skip"
          "| #{r["id"]} | SKIP | - | - | - | #{r["reason"]} |"
        else
          concerns = Array(r.dig("judge", "concerns")).first(2).join("; ").gsub("|", "/")
          "| #{r["id"]} | #{verdict} | #{r["checks"].count { |c| c["status"] == "pass" }}/#{r["checks"].size} | #{r.dig("judge", "pass").inspect} | $#{r["cost"]} | #{concerns[0, 160]} |"
        end
      end
      summary = ["# Reach smoke run #{@run_id}", "", "model #{MODEL}, student #{STUDENT_MODEL}, judge #{JUDGE_MODEL}; spent $#{@spend.total.round(4)} of $#{BUDGET_USD}", ""]
      summary << "Stopped early: #{@stopped}" << "" if @stopped
      summary += ["| scenario | verdict | checks | judge pass | cost | judge concerns |", "|---|---|---|---|---|---|"] + rows
      File.write(File.join(@run_dir, "summary.md"), summary.join("\n") + "\n")
      puts "\n#{summary.join("\n")}"
    end
  end

  class Spend
    attr_reader :total

    def initialize(ceiling)
      @ceiling = ceiling
      @total = 0.0
    end

    def add(amount)
      @total += amount.to_f
      raise SpendExceeded, "spend ceiling $#{@ceiling} reached ($#{@total.round(4)})" if @total >= @ceiling
    end
  end

  class CLI
    def self.run(argv)
      config = YAML.safe_load(File.read(File.join(__dir__, "scenarios.yml")))
      scenarios = config["scenarios"]

      if argv.include?("--list")
        scenarios.each { |scenario| puts "#{scenario["id"]}  #{scenario["description"]}" }
        return 0
      end

      selected = argv.reject { |arg| arg.start_with?("--") }
      selected = ENV["SMOKE_ONLY"].to_s.split(",").map(&:strip).reject(&:empty?) if selected.empty?

      valid_ids = scenarios.map { |scenario| scenario["id"] }
      unknown = selected - valid_ids
      unless unknown.empty?
        puts "unknown scenario id(s): #{unknown.join(", ")}. Valid ids: #{valid_ids.join(", ")}"
        return 1
      end

      token = Smoke.preflight!
      Smoke.ensure_image!

      runner = Runner.new(config, selected, token)
      trap("INT") do
        Docker.kill_all
        exit 130
      end
      runner.run
      runner.exit_code
    rescue Smoke::PreflightFailed => e
      puts e.message
      2
    rescue Smoke::Abort => e
      puts "RUN STOPPED: #{e.message}"
      1
    end
  end
end

exit(Smoke::CLI.run(ARGV)) if $PROGRAM_NAME == __FILE__
