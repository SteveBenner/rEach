#!/usr/bin/env ruby

require "json"
require "net/http"
require "open3"
require "optparse"
require "rbconfig"
require "socket"
require "tmpdir"
require "timeout"
require "fileutils"

module PlatformSmoke
  ROOT = File.expand_path("../..", __dir__)
  COURSE_CODE = "MGMT327-K7QX-94TD".freeze
  TEST_PASSWORD = "smoke-test-password-1".freeze
  USERNAME = "mdel101".freeze
  STUDENT_NAME = "Maria Delgado".freeze
  STUDENT_ID = "1040217".freeze
  RUNTIME_ID = "4.0.7-r3".freeze
  RUNTIME_RUBY = "4.0.7".freeze
  BLOCK_EXIT = 2
  STEP_TIMEOUT_S = 120
  RUNTIME_TIMEOUT_S = 900
  BACKGROUND_WAIT_S = 900
  BACKGROUND_POLL_S = 10
  RUNTIME_BUSY = "the runtime is already being installed in the background".freeze
  EXPECTED_DOCTOR_FINDINGS = %w[R-DOC-GUARD R-DOC-HARNESS].freeze
  CHROME_FINDING = "R-DOC-CHROME".freeze

  Step = Struct.new(:name, :result, :detail, :duration)

  class Run
    attr_reader :steps

    def initialize(options)
      @options = options
      @steps = []
      @scratch = nil
      @server_pid = nil
      @server_log = nil
      @teach_url = nil
      @install = nil
      @prompt_command = nil
      @codex_command = nil
      @env = nil
      @kit_installed = false
    end

    def execute
      @scratch = make_scratch
      @env = build_env
      @install = File.join(@scratch, "reach smoke", "plugin")
      FileUtils.mkdir_p(File.join(@scratch, "reach smoke"))
      begin
        run_steps
      ensure
        stop_server
        cleanup
      end
      summary
    end

    private

    def windows?
      RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/ ? true : false
    end

    def macos?
      RbConfig::CONFIG["host_os"] =~ /darwin/ ? true : false
    end

    def make_scratch
      path = Dir.mktmpdir("rs", Dir.tmpdir)
      path
    end

    def build_env
      env = {}
      ENV.each_key do |key|
        env[key] = nil if key.upcase.start_with?("TEACH_") || key.upcase.start_with?("REACH_")
      end
      env["REACH_HOME"] = File.join(@scratch, "home")
      env["REACH_UPDATE_DISABLE"] = "1"
      env
    end

    def spawn_capture(argv, stdin: "", timeout: STEP_TIMEOUT_S, chdir: nil, extra_env: {})
      env = @env.merge(extra_env)
      opts = {}
      opts[:chdir] = chdir if chdir
      out = +""
      err = +""
      status = nil
      Open3.popen3(env, *argv, opts) do |i, o, e, t|
        readers = [
          Thread.new { out << o.read.to_s },
          Thread.new { err << e.read.to_s }
        ]
        begin
          i.write(stdin.to_s)
        rescue Errno::EPIPE, IOError
          nil
        end
        begin
          i.close
        rescue IOError
          nil
        end
        begin
          Timeout.timeout(timeout) { t.join }
        rescue Timeout::Error
          kill(t.pid)
          t.join
          readers.each { |r| r.join(5) }
          return [nil, out, err + "timed out after #{timeout}s"]
        end
        readers.each(&:join)
        status = t.value
      end
      [status.exitstatus, out, err]
    rescue SystemCallError => e
      [nil, out, "#{e.class}: #{e.message}"]
    end

    def kill(pid)
      Process.kill(windows? ? "KILL" : "TERM", pid)
    rescue SystemCallError
      nil
    end

    def reach(*args, timeout: STEP_TIMEOUT_S, stdin: "")
      spawn_capture([RbConfig.ruby, File.join(@install, "exe", "reach"), *args], stdin: stdin, timeout: timeout, chdir: @scratch)
    end

    def step(name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result, detail = begin
        yield
      rescue StandardError => e
        [:fail, "#{e.class}: #{e.message}"]
      end
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      record(Step.new(name, result, detail.to_s, duration.round(3)))
    end

    def record(step)
      @steps << step
      label = { pass: "PASS", fail: "FAIL", skip: "SKIP" }.fetch(step.result)
      line = "#{label} #{step.name}"
      one = step.detail.to_s.strip.gsub(/\s*\n\s*/, " | ")
      line += " #{one}" unless one.empty?
      puts line
      $stdout.flush
    end

    def tail(*parts)
      parts.map { |p| p.to_s.strip }.reject(&:empty?).join(" | ")[0, 600]
    end

    def run_steps
      step("install") { install_step }
      installed = @steps.last.result == :pass
      unless installed
        %w[fake_teach hook_session_start hook_prompt_locked hook_codex enroll machine_id hook_prompt_open status runtime doctor].each do |name|
          record(Step.new(name, :skip, "install failed", 0.0))
        end
        return
      end
      step("fake_teach") { fake_teach_step }
      if @steps.last.result != :pass
        %w[hook_session_start hook_prompt_locked hook_codex enroll machine_id hook_prompt_open status runtime doctor].each do |name|
          record(Step.new(name, :skip, "fake_teach failed", 0.0))
        end
        return
      end
      step("hook_session_start") { hook_session_start_step }
      step("hook_prompt_locked") { hook_prompt_locked_step }
      step("hook_codex") { hook_codex_step }
      step("enroll") { enroll_step }
      step("machine_id") { machine_id_step }
      step("hook_prompt_open") { hook_prompt_open_step }
      step("status") { status_step }
      if @options[:skip_runtime]
        record(Step.new("runtime", :skip, "--skip-runtime", 0.0))
      else
        step("runtime") { runtime_step }
      end
      step("doctor") { doctor_step }
    end

    def install_step
      zip = File.join(@scratch, "reach.zip")
      code, out, err = spawn_capture(["git", "-C", ROOT, "archive", "--format=zip", "--prefix=reach/", "-o", zip, "HEAD"])
      return [:fail, "git archive exited #{code.inspect}: #{tail(out, err)}"] unless code == 0

      code, out, err = spawn_capture(
        [RbConfig.ruby, File.join(ROOT, "bin", "reach-install"), "--archive", zip, "--destination", @install],
        timeout: 300
      )
      return [:fail, "reach-install exited #{code.inspect}: #{tail(out, err)}"] unless code == 0

      expected = File.read(File.join(ROOT, "VERSION")).strip
      installed = File.file?(File.join(@install, "VERSION")) ? File.read(File.join(@install, "VERSION")).strip : nil
      return [:fail, "installed VERSION #{installed.inspect} is not #{expected}"] unless installed == expected
      return [:fail, "#{File.join(@install, 'exe', 'reach')} is missing"] unless File.file?(File.join(@install, "exe", "reach"))

      [:pass, "version #{installed} at #{@install}"]
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    end

    def webrick_loads?(extra_env = {})
      code, _out, _err = spawn_capture([RbConfig.ruby, "-e", 'require "webrick"'], timeout: 60, chdir: @scratch, extra_env: extra_env)
      code == 0
    end

    def ensure_webrick
      return [{}, "webrick present"] if webrick_loads?

      dir = File.join(@scratch, "gems")
      gem_env = {
        "GEM_HOME" => nil,
        "GEM_PATH" => ([dir] + Gem.path).join(File::PATH_SEPARATOR)
      }
      note = nil
      2.times do |attempt|
        code, out, err = spawn_capture(
          [RbConfig.ruby, "-S", "gem", "install", "--no-document", "--install-dir", dir, "webrick"],
          timeout: 180, chdir: @scratch, extra_env: { "GEM_HOME" => nil, "GEM_PATH" => nil }
        )
        if code == 0 && webrick_loads?(gem_env)
          return [gem_env, "webrick installed into scratch gems (attempt #{attempt + 1})"]
        end

        note = "gem install attempt #{attempt + 1} exit #{code.inspect}: #{tail(out, err)}"
        sleep 3 if attempt == 0
      end
      raise "webrick is missing and could not be installed: #{note}"
    end

    def fake_teach_step
      gem_env, webrick_note = ensure_webrick
      port = free_port
      @teach_url = "http://127.0.0.1:#{port}"
      @server_log = File.join(@scratch, "fake_teach.log")
      log = File.open(@server_log, "w")
      begin
        @server_pid = Process.spawn(
          @env.merge(gem_env),
          RbConfig.ruby, File.join(ROOT, "tools", "fake_teach", "server.rb"), "--port", port.to_s, "--home", File.join(@scratch, "teach"),
          in: File::NULL, out: log, err: log, chdir: ROOT
        )
      ensure
        log.close
      end
      30.times do |attempt|
        begin
          http = Net::HTTP.new("127.0.0.1", port)
          http.open_timeout = 2
          http.read_timeout = 2
          response = http.get("/api/v1/health")
          return [:pass, "health 200 on #{@teach_url} after #{attempt + 1} attempt(s); #{webrick_note}"] if response.code == "200"
        rescue StandardError
          nil
        end
        sleep 1
      end
      log_text = File.file?(@server_log) ? File.read(@server_log)[0, 400] : ""
      [:fail, "health did not answer 200 in 30 attempts: #{log_text.strip}"]
    end

    def stop_server
      return unless @server_pid

      pid = @server_pid
      @server_pid = nil
      begin
        Process.kill(windows? ? "KILL" : "TERM", pid)
      rescue SystemCallError
        return
      end
      begin
        Timeout.timeout(10) { Process.wait(pid) }
      rescue Timeout::Error
        begin
          Process.kill("KILL", pid)
          Timeout.timeout(5) { Process.wait(pid) }
        rescue StandardError
          nil
        end
      rescue SystemCallError
        nil
      end
    end

    def git_bash
      return @git_bash if defined?(@git_bash)

      @git_bash = locate_git_bash
    end

    def locate_git_bash
      exts = (ENV["PATHEXT"] || ".EXE").split(";")
      dirs = (ENV["PATH"] || "").split(File::PATH_SEPARATOR)
      candidates = []
      dirs.each do |dir|
        exts.each do |ext|
          git = File.join(dir, "git#{ext.downcase}")
          next unless File.file?(git)

          base = File.dirname(git)
          candidates << File.join(base, "..", "bin", "bash.exe")
          candidates << File.join(base, "..", "..", "bin", "bash.exe")
          candidates << File.join(base, "bash.exe")
        end
      end
      %w[ProgramFiles ProgramFiles(x86) LocalAppData].each do |var|
        root = ENV[var]
        candidates << File.join(root, "Git", "bin", "bash.exe") if root
      end
      found = candidates.map { |c| File.expand_path(c) }.find { |c| File.file?(c) && !c.downcase.include?("system32") }
      found
    end

    def hook_argv(command)
      if windows?
        bash = git_bash
        raise "no Git Bash found next to git.exe" unless bash

        [bash, "-c", command]
      else
        ["sh", "-c", command]
      end
    end

    def hook_path(path)
      windows? ? path.tr("\\", "/") : path
    end

    def hook_command(file, variable, event)
      data = JSON.parse(File.read(File.join(@install, "hooks", file)))
      entry = data.fetch("hooks").fetch(event).first.fetch("hooks").first
      entry.fetch("command").gsub("${#{variable}}", hook_path(@install))
    end

    def run_hook(command, payload)
      spawn_capture(hook_argv(command), stdin: payload, timeout: 60, chdir: @scratch)
    end

    def prompt_payload
      JSON.generate(
        "session_id" => "platform-smoke",
        "hook_event_name" => "UserPromptSubmit",
        "prompt" => "hello",
        "cwd" => @scratch
      )
    end

    def hook_session_start_step
      command = hook_command("hooks.json", "CLAUDE_PLUGIN_ROOT", "SessionStart")
      code, out, err = run_hook(command, "{}")
      return [:pass, "exit 0"] if code == 0

      [:fail, "exit #{code.inspect}: #{tail(out, err)}"]
    end

    def blocked?(code, out, err)
      code == BLOCK_EXIT && !err.strip.empty? && out.strip.empty?
    end

    def hook_prompt_locked_step
      @prompt_command = hook_command("hooks.json", "CLAUDE_PLUGIN_ROOT", "UserPromptSubmit")
      code, out, err = run_hook(@prompt_command, prompt_payload)
      return [:pass, "blocked with exit #{BLOCK_EXIT} and a message on stderr"] if blocked?(code, out, err)

      [:fail, "expected exit #{BLOCK_EXIT} with a stderr message and empty stdout, got exit #{code.inspect}: #{tail(out, err)}"]
    end

    def hook_codex_step
      @codex_command = hook_command("codex.json", "PLUGIN_ROOT", "UserPromptSubmit")
      code, out, err = run_hook(@codex_command, prompt_payload)
      return [:pass, "blocked with exit #{BLOCK_EXIT} and a message on stderr"] if blocked?(code, out, err)

      [:fail, "expected exit #{BLOCK_EXIT} with a stderr message and empty stdout, got exit #{code.inspect}: #{tail(out, err)}"]
    end

    def enroll_step
      code, out, err = reach("enroll", "--course-code", COURSE_CODE, "--username", USERNAME, "--student-id", STUDENT_ID, "--password-stdin", "--teach-url", @teach_url, stdin: "#{TEST_PASSWORD}\n")
      return [:fail, "exit #{code.inspect}: #{tail(out, err)}"] unless code == 0
      return [:fail, "output does not say connected: #{tail(out, err)}"] unless out =~ /connected to/i

      [:pass, out.lines.map(&:strip).reject(&:empty?).first.to_s]
    end

    def machine_id_step
      code, out, err = spawn_capture(
        [RbConfig.ruby, "-I", File.join(@install, "lib"), "-e", 'require "reach"; puts Reach::Fingerprint.machine_id'],
        chdir: @scratch
      )
      return [:fail, "exit #{code.inspect}: #{tail(out, err)}"] unless code == 0

      value = out.strip
      return [:fail, "machine id is unknown"] if value.empty? || value == "unknown"

      if windows?
        shape = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
        form = "MachineGuid"
      elsif macos?
        shape = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
        form = "IOPlatformUUID"
      else
        shape = /\A[0-9a-fA-F]{32}\z/
        form = "machine-id"
      end
      return [:fail, "machine id does not have the #{form} form (starts #{value[0, 8]})"] unless value =~ shape

      [:pass, "#{form} #{value[0, 8]}"]
    end

    def hook_prompt_open_step
      code, out, err = run_hook(@prompt_command, prompt_payload)
      return [:fail, "exit #{code.inspect}: #{tail(out, err)}"] unless code == 0
      return [:fail, "still blocked: #{tail(out, err)}"] if blocked?(code, out, err)

      [:pass, "exit 0, gate open"]
    end

    def status_step
      code, out, err = reach("status")
      return [:fail, "exit #{code.inspect}: #{tail(out, err)}"] unless code == 0

      combined = out + err
      return [:fail, "fingerprint_mismatch reported: #{tail(out, err)}"] if combined.include?("fingerprint_mismatch")
      return [:fail, "output does not name #{STUDENT_NAME}: #{tail(out, err)}"] unless combined.include?(STUDENT_NAME)

      [:pass, "names #{STUDENT_NAME}, no fingerprint_mismatch"]
    end

    def doctor_step
      code, out, err = reach("doctor")
      findings = out.lines.map { |line| line[/\A(R-[A-Z0-9-]+):/, 1] }.compact.uniq
      allowed = EXPECTED_DOCTOR_FINDINGS.dup
      allowed << CHROME_FINDING unless @kit_installed
      unexpected = findings - allowed
      if code.nil?
        return [:fail, "doctor did not finish: #{tail(out, err)}"]
      end
      unless unexpected.empty?
        return [:fail, "unexpected findings #{unexpected.join(', ')}\n#{out}#{err}"]
      end
      return [:fail, "doctor exited #{code} with no findings: #{tail(out, err)}"] if code != 0 && findings.empty?

      [:pass, findings.empty? ? "no findings" : "only expected findings: #{findings.join(', ')}"]
    end

    def runtime_step
      code, out, err = spawn_capture(
        [RbConfig.ruby, "-I", File.join(@install, "lib"), "-e", 'require "reach"; puts Reach::RuntimeKit.platform.inspect; puts Reach::RuntimeKit::PLATFORMS.join(",")'],
        chdir: @scratch
      )
      return [:fail, "platform probe exited #{code.inspect}: #{tail(out, err)}"] unless code == 0

      platform = out.lines.first.to_s.strip
      if platform == "nil"
        code, out, err = reach("runtime", "install")
        combined = out + err
        return [:pass, "no runtime kit exists for this platform: #{tail(out, err)}"] if combined.include?("no runtime is built for this platform")

        return [:fail, "unsupported platform did not report the unsupported message (exit #{code.inspect}): #{tail(out, err)}"]
      end

      code, out, err = reach("runtime", "install", timeout: RUNTIME_TIMEOUT_S)
      origin = "installed by reach runtime install"
      if code != 0
        return [:fail, "runtime install exit #{code.inspect}: #{tail(out, err)}"] unless (out + err).include?(RUNTIME_BUSY)

        waited, failure = wait_for_background_install
        return [:fail, failure] if failure

        origin = "installed by the background self-install after waiting #{waited.round}s"
      end

      code, out, err = reach("runtime", "status", "--json")
      return [:fail, "runtime status exit #{code.inspect}: #{tail(out, err)}"] unless code == 0

      state = JSON.parse(out)
      return [:fail, "active runtime is #{state['runtime_id'].inspect}, not #{RUNTIME_ID}"] unless state["runtime_id"] == RUNTIME_ID && state["active"]

      exe = File.join(state["root"].to_s, "ruby", "bin", windows? ? "ruby.exe" : "ruby")
      return [:fail, "runtime ruby missing at #{exe}"] unless File.file?(exe)

      code, out, err = spawn_capture([exe, "-e", "puts RUBY_VERSION"], timeout: 60)
      return [:fail, "runtime ruby exit #{code.inspect}: #{tail(out, err)}"] unless code == 0
      return [:fail, "runtime ruby prints #{out.strip.inspect}, not #{RUNTIME_RUBY}"] unless out.strip == RUNTIME_RUBY

      @kit_installed = true
      [:pass, "#{platform} runtime #{RUNTIME_ID} active, ruby #{out.strip}, #{origin}"]
    end

    def state_dir
      File.join(@env["REACH_HOME"], "state")
    end

    def install_lock_free?
      path = File.join(state_dir, "runtime-install.lock")
      return true unless File.file?(path)

      File.open(path, File::RDWR) do |file|
        free = file.flock(File::LOCK_EX | File::LOCK_NB)
        file.flock(File::LOCK_UN) if free
        free ? true : false
      end
    rescue StandardError
      true
    end

    def background_last_error
      path = File.join(state_dir, "runtime-auto.json")
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      error = data.is_a?(Hash) ? data["last_error"].to_s : ""
      error.empty? ? nil : error
    rescue StandardError
      nil
    end

    def wait_for_background_install
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      last = ""
      loop do
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        code, out, err = reach("runtime", "status", "--json")
        last = tail(out, err)
        if code == 0
          begin
            state = JSON.parse(out)
            return [elapsed, nil] if state["runtime_id"] == RUNTIME_ID && state["active"]
          rescue JSON::ParserError
            nil
          end
        end
        error = background_last_error
        if error && install_lock_free?
          return [elapsed, "background runtime install failed and is not running: #{error}"]
        end
        return [elapsed, "background runtime install did not finish in #{BACKGROUND_WAIT_S}s: #{last}"] if elapsed >= BACKGROUND_WAIT_S

        sleep BACKGROUND_POLL_S
      end
    end

    def wait_for_install_lock
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      until install_lock_free?
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          warn "warning: a background runtime install still holds the lock"
          return
        end
        sleep 2
      end
    end

    def cleanup
      return unless @scratch && File.exist?(@scratch)

      wait_for_install_lock
      if @options[:keep]
        puts "scratch kept at #{@scratch}"
        return
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      loop do
        begin
          FileUtils.remove_entry(@scratch)
          return
        rescue StandardError => e
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline || !windows?
            warn "warning: could not remove #{@scratch}: #{e.message}"
            return
          end
          sleep 2
        end
      end
    end

    def summary
      passed = @steps.count { |s| s.result == :pass }
      failed = @steps.count { |s| s.result == :fail }
      skipped = @steps.count { |s| s.result == :skip }
      write_report if @options[:report]
      puts "platform smoke: #{passed} passed, #{failed} failed, #{skipped} skipped"
      failed.zero? ? 0 : 1
    end

    def os_version
      if windows?
        out, _status = Open3.capture2("cmd", "/c", "ver")
        out.strip
      elsif macos?
        out, _status = Open3.capture2("sw_vers", "-productVersion")
        "macOS #{out.strip}"
      else
        out, _status = Open3.capture2("uname", "-sr")
        out.strip
      end
    rescue StandardError
      RbConfig::CONFIG["host_os"].to_s
    end

    def write_report
      report = {
        "schema" => "reach.platform-smoke/v1",
        "platform" => "#{RbConfig::CONFIG['host_os']} #{RbConfig::CONFIG['host_cpu']}",
        "ruby_version" => RUBY_VERSION,
        "os_version" => os_version,
        "steps" => @steps.map do |s|
          { "name" => s.name, "result" => s.result.to_s, "detail" => s.detail, "duration_s" => s.duration }
        end
      }
      path = File.expand_path(@options[:report])
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(report) + "\n")
    rescue StandardError => e
      warn "warning: could not write report: #{e.message}"
    end
  end

  def self.main(argv)
    options = {}
    OptionParser.new do |parser|
      parser.on("--skip-runtime") { options[:skip_runtime] = true }
      parser.on("--report PATH") { |value| options[:report] = value }
      parser.on("--keep") { options[:keep] = true }
    end.parse!(argv)
    Run.new(options).execute
  end
end

exit PlatformSmoke.main(ARGV) if $PROGRAM_NAME == __FILE__
