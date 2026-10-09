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
  COURSE_CODE = "BUS101-K7QX-94TD".freeze
  TEST_PASSWORD = "smoke-test-password-1".freeze
  USERNAME = "mdelgado".freeze
  STUDENT_NAME = "Maria Delgado".freeze
  STUDENT_ID = "20410217".freeze
  RUNTIME_ID = "4.0.7-r3".freeze
  RUNTIME_RUBY = "4.0.7".freeze
  BLOCK_EXIT = 2
  STEP_TIMEOUT_S = 120
  RUNTIME_TIMEOUT_S = 900
  BACKGROUND_WAIT_S = 900
  BACKGROUND_POLL_S = 10
  RUNTIME_BUSY = "the runtime is already being installed in the background".freeze
  EXPECTED_DOCTOR_FINDINGS = %w[R-DOC-HARNESS].freeze
  BUCKET_CAPACITY = 20.0
  BUCKET_RATE_PER_SECOND = 20.0 / 60.0
  BUCKET_RESERVE = 6.0
  PACKAGE_KINDS = %w[guardrails workspace].freeze
  KNOWN_ANSWER_DIR = File.join(ROOT, "tools", "platform_smoke", "fixtures", "known-answer").freeze
  CHROME_FINDING = "R-DOC-CHROME".freeze
  EXPECTED_DOCTOR_LINES = {
    "R-DOC-BRAIN-PLANES" => /\Aplanes: spool mode \(SDK not installed\)\z/,
    "R-DOC-SUBSCRIBE" => /\Abackground job installed; last check never\z/,
    "R-DOC-CODEX" => /\ACodex's sandbox blocks rEach \(internet \w+, folder \w+\) - run reach codex configure\z/
  }.freeze
  NO_KIT_DOCTOR_LINES = {
    "R-DOC-BRAIN-PLANES" => /\Aplanes: spool mode \(no runtime kit\)\z/
  }.freeze

  SYSTEMD_SKIP = "skipped capability: systemd user manager unavailable".freeze
  SUBSCRIBE_UNINSTALLED = /\Abackground job not installed/.freeze

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
        @environment = read_environment
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
      env["REACH_WORKSPACE_ROOT"] = File.join(@scratch, "work")
      env["RPLUGIN_HOME"] = File.join(@scratch, "rplugin")
      env["XDG_STATE_HOME"] = File.join(@scratch, "state")
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
      step("package_known_answer") { package_known_answer_step } if installed
      unless installed
        %w[package_known_answer fake_teach hook_session_start hook_prompt_locked hook_codex enroll runtime kit_known_answer sync_packages doctor_report codex_sandbox_decrypt machine_id hook_prompt_open status doctor].each do |name|
          record(Step.new(name, :skip, "install failed", 0.0))
        end
        return
      end
      step("fake_teach") { fake_teach_step }
      if @steps.last.result != :pass
        %w[hook_session_start hook_prompt_locked hook_codex enroll runtime kit_known_answer sync_packages doctor_report codex_sandbox_decrypt machine_id hook_prompt_open status doctor].each do |name|
          record(Step.new(name, :skip, "fake_teach failed", 0.0))
        end
        return
      end
      step("hook_session_start") { hook_session_start_step }
      step("hook_prompt_locked") { hook_prompt_locked_step }
      step("hook_codex") { hook_codex_step }
      step("enroll") { enroll_step }
      if @options[:skip_runtime]
        %w[runtime kit_known_answer].each { |name| record(Step.new(name, :skip, "--skip-runtime", 0.0)) }
      else
        step("runtime") { runtime_step }
        step("kit_known_answer") { kit_known_answer_step }
      end
      step("sync_packages") { sync_packages_step }
      step("doctor_report") { doctor_report_step }
      step("codex_sandbox_decrypt") { codex_sandbox_decrypt_step }
      step("machine_id") { machine_id_step }
      step("hook_prompt_open") { hook_prompt_open_step }
      step("status") { status_step }
      step("doctor") { doctor_step }
    end

    def install_step
      zip = File.join(@scratch, "reach.zip")
      code, out, err = spawn_capture(["git", "-C", ROOT, "archive", "--format=zip", "--prefix=reach/", "-o", zip, "HEAD"])
      return [:fail, "git archive exited #{code.inspect}: #{tail(out, err)}"] unless code == 0

      code, out, err = spawn_capture(
        [RbConfig.ruby, File.join(ROOT, "scripts", "reach-install"), "--archive", zip, "--destination", @install],
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
      return [:pass, "blocked with exit 0 and a JSON block on stdout"] if codex_block_reason(code, out)

      [:fail, "expected exit 0 with {\"decision\":\"block\",\"reason\":...} on stdout, got exit #{code.inspect}: #{tail(out, err)}"]
    end

    def enroll_step
      code, out, err = reach("enroll", "--course-code", COURSE_CODE, "--username", USERNAME, "--student-id", STUDENT_ID, "--password-stdin", "--teach-url", @teach_url, stdin: "#{TEST_PASSWORD}\n")
      return [:fail, "exit #{code.inspect}: #{tail(out, err)}"] unless code == 0
      return [:fail, "output does not say connected: #{tail(out, err)}"] unless out =~ /connected to/i

      [:pass, out.lines.map(&:strip).reject(&:empty?).first.to_s]
    end

    KNOWN_ANSWER_SCRIPT = <<'RUBY'.freeze
lib, dir = ARGV
require "json"
require File.join(lib, "reach", "errors.rb")
require File.join(lib, "reach", "crypto.rb")
require File.join(lib, "reach", "tarball.rb")
begin
  envelope = JSON.parse(File.read(File.join(dir, "envelope.json")))
  recipient = Reach::Crypto.load_private_key(File.read(File.join(dir, "recipient-test-key.pem")))
  signer = Reach::Crypto.load_public_key(File.read(File.join(dir, "signing-test-key.pub.pem")))
  header, plaintext = Reach::Crypto.open_envelope(
    envelope,
    expected_kind: "guardrails",
    expected_student_id: "test0000000",
    recipient_private_key: recipient,
    signer_public_key_for: lambda { |_id| signer }
  )
  entries = Reach::Tarball.read(plaintext)
  puts JSON.generate(
    "content_digest" => header["content_digest"],
    "entries" => entries.keys.sort,
    "hello_sha256" => Reach::Crypto.digest_hex(entries["hello.txt"])
  )
rescue Exception => e
  puts "#{e.class}: #{e.message}"
  exit 1
end
RUBY

    def package_known_answer_step
      code, out, err = spawn_capture(
        [RbConfig.ruby, "-e", KNOWN_ANSWER_SCRIPT, File.join(@install, "lib"), KNOWN_ANSWER_DIR],
        chdir: @scratch
      )
      return [:fail, "known-answer envelope did not open: #{tail(out, err)}"] unless code == 0

      known_answer_result(out)
    end

    def libressl?(ruby)
      code, out, _err = spawn_capture([ruby, "-ropenssl", "-e", "print OpenSSL::OPENSSL_LIBRARY_VERSION"], chdir: @scratch)
      code == 0 && out.include?("LibreSSL")
    end

    def kit_ruby
      File.join(@env["REACH_HOME"], "runtime", RUNTIME_ID, "ruby", "bin", windows? ? "ruby.exe" : "ruby")
    end

    def kit_known_answer_step
      return [:skip, "no runtime kit was installed on this platform"] unless File.file?(kit_ruby)

      code, out, err = spawn_capture([kit_ruby, "-e", KNOWN_ANSWER_SCRIPT, File.join(@install, "lib"), KNOWN_ANSWER_DIR], chdir: @scratch)
      return [:fail, "the kit Ruby could not open the known-answer envelope: #{tail(out, err)}"] unless code == 0

      result, detail = known_answer_result(out)
      [result, "kit Ruby #{RUNTIME_RUBY}: #{detail}"]
    end

    def codex_sandbox_decrypt_step
      return [:skip, "codex sandbox runs only on the macOS legs"] unless macos?

      codex = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "codex") }.find { |path| File.executable?(path) }
      return [:fail, "codex is not on PATH"] unless codex

      argv = [codex, "sandbox", "--", RbConfig.ruby, File.join(@install, "exe", "reach"), "doctor", "--report", "--offline", "--format", "json"]
      codex_home = File.join(@scratch, "codex-home")
      FileUtils.mkdir_p(codex_home)
      code, out, err = spawn_capture(argv, chdir: @scratch, extra_env: { "CODEX_HOME" => codex_home })
      return [:fail, "codex sandbox doctor --report exited #{code.inspect}: #{tail(out, err)}"] unless code == 0

      report = JSON.parse(out[out.index("{")..-1])
      runtime = report["runtime"] || {}
      stored = ((report["packages"] || {})["guardrails"] || {})["stored"] || {}
      return [:fail, "inside the Codex sandbox the command did not move to the kit Ruby: #{report_summary(report)}"] unless runtime["kit_ruby"] == true || !libressl?(RbConfig.ruby)
      return [:fail, "inside the Codex sandbox the stored guardrails package did not open: #{report_summary(report)}"] unless stored["ok"] == true

      [:pass, "codex sandbox ran reach under #{runtime['ruby_path']} (#{runtime['openssl_library']}) and opened guardrails v#{stored['version']}"]
    rescue JSON::ParserError, ArgumentError, TypeError => e
      [:fail, "codex sandbox doctor --report was not JSON (#{e.message}): #{tail(out.to_s, err.to_s)}"]
    end

    def report_summary(report)
      runtime = report["runtime"] || {}
      tests = report["self_test"] || {}
      gcm = tests["gcm"] || {}
      packages = report["packages"] || {}
      opened = %w[guardrails workspace].map do |kind|
        entry = packages[kind] || {}
        stored = entry["stored"] || {}
        latest = entry["latest"] || {}
        "#{kind} stored=#{stored['ok'].inspect}/#{stored['stage']} latest=#{latest['ok'].inspect}/#{latest['stage']} #{latest['error']}"
      end
      rubies = Array(report["rubies"]).map { |entry| "#{entry['label']}:#{entry['ruby_version'] || '-'}:#{entry['openssl_library'] || '-'}:gcm=#{entry['gcm_ok'].inspect}/#{entry['gcm_stage']}" }
      "ruby #{runtime['ruby_version']} #{runtime['ruby_path']} #{runtime['openssl_library']} kit_ruby=#{runtime['kit_ruby']} | gcm=#{gcm['ok'].inspect} #{gcm['stage']} #{gcm['error']} | kit=#{(report['kit'] || {})['active'].inspect} | #{opened.join(' ; ')} | rubies #{rubies.join(' ')} | env #{Array((report['environment'] || {})['set']).join(',')}"
    end

    def doctor_report_step
      code, out, err = reach("doctor", "--report", "--format", "json")
      return [:fail, "doctor --report exited #{code.inspect}: #{tail(out, err)}"] unless code == 0

      [:pass, report_summary(JSON.parse(out[out.index("{")..-1]))]
    rescue JSON::ParserError, ArgumentError, TypeError => e
      [:fail, "doctor --report was not JSON (#{e.message}): #{tail(out.to_s, err.to_s)}"]
    end

    def known_answer_result(out)
      actual = JSON.parse(out.lines.last.to_s)
      expected = JSON.parse(File.read(File.join(KNOWN_ANSWER_DIR, "expected.json")))
      expected.each do |key, value|
        return [:fail, "#{key} is #{actual[key].inspect}, expected #{value.inspect}"] unless actual[key] == value
      end

      [:pass, "opened Teach's sealed envelope; digest #{actual['content_digest'][0, 12]}, entries #{actual['entries'].join(',')}"]
    end

    def request_hits(kind, status)
      path = File.join(@scratch, "teach", "requests.jsonl")
      return 0 unless File.file?(path)

      File.readlines(path).count do |line|
        row = JSON.parse(line)
        row["method"] == "GET" && row["path"] == "/api/v1/packages/#{kind}" && row["status"] == status
      end
    rescue JSON::ParserError
      0
    end

    def sync_packages_step
      code, out, err = reach("sync")
      combined = out + err
      return [:fail, "first sync exit #{code.inspect}: #{tail(out, err)}"] unless code == 0
      warning = combined.lines.map(&:strip).find { |line| line =~ /could not fetch (guardrails|shape|workspace) package|could not update course rules|could not provision your workspace/ }
      return [:fail, "first sync warned: #{warning}"] if warning

      PACKAGE_KINDS.each do |kind|
        stored = File.join(@env["REACH_HOME"], "packages", kind, "1.pkg")
        return [:fail, "#{stored} was not stored: #{tail(out, err)}"] unless File.file?(stored)
        return [:fail, "fake_teach served #{kind} #{request_hits(kind, 200)} time(s) with 200, expected 1"] unless request_hits(kind, 200) == 1
      end

      before = PACKAGE_KINDS.map { |kind| request_hits(kind, 304) }
      code, out, err = reach("sync")
      return [:fail, "second sync exit #{code.inspect}: #{tail(out, err)}"] unless code == 0

      PACKAGE_KINDS.each_with_index do |kind, index|
        gained = request_hits(kind, 304) - before[index]
        return [:fail, "second sync made fake_teach answer #{gained} 304(s) for #{kind}, expected 1: #{tail(out, err)}"] unless gained == 1
      end

      wait_for_request_budget
      [:pass, "guardrails and workspace fetched, stored as 1.pkg and revalidated with 304 on the second sync"]
    end

    def wait_for_request_budget
      path = File.join(state_dir, "bucket.json")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      loop do
        state = File.file?(path) ? JSON.parse(File.read(path)) : nil
        return if state.nil?

        tokens = [BUCKET_CAPACITY, state["tokens"].to_f + (Time.now.to_f - state["updated_at"].to_f) * BUCKET_RATE_PER_SECOND].min
        return if tokens >= BUCKET_RESERVE || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 2
      end
    rescue StandardError
      nil
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

    def codex_turn(session, turn, prompt)
      payload = JSON.generate(
        "session_id" => session, "turn_id" => turn, "hook_event_name" => "UserPromptSubmit",
        "prompt" => prompt, "cwd" => FileUtils.mkdir_p(File.join(@scratch, "work")).first
      )
      run_hook(@codex_command, payload)
    end

    def codex_block_reason(code, out)
      return nil unless code == 0

      block = JSON.parse(out)
      block.is_a?(Hash) && block["decision"] == "block" && !block["reason"].to_s.strip.empty? ? block["reason"] : nil
    rescue StandardError
      nil
    end

    def hook_prompt_open_step
      session = "platform-smoke-codex"
      [["t1", "hello", "student ID"], ["t2", STUDENT_ID, STUDENT_NAME], ["t3", "yes", "password"], ["t4", "not-the-password", "isn't your rEach password"], ["t5", TEST_PASSWORD, "signed in"]].each do |turn, prompt, expected|
        code, out, err = codex_turn(session, turn, prompt)
        return [:fail, "codex #{turn}: expected a block naming #{expected.inspect}, got exit #{code.inspect}: #{tail(out, err)}"] unless codex_block_reason(code, out).to_s.include?(expected)
      end
      code, out, err = codex_turn(session, "t5", TEST_PASSWORD)
      return [:fail, "codex t5 answered twice: exit #{code.inspect}: #{tail(out, err)}"] unless code == 0 && err.strip.empty? && codex_block_reason(code, out).nil?

      code, out, err = codex_turn(session, "t6", "hello")
      return [:fail, "codex t6: exit #{code.inspect}: #{tail(out, err)}"] unless code == 0
      return [:fail, "codex t6 lacks the signed-in context: #{tail(out, err)}"] unless out.include?(STUDENT_NAME)

      code, out, err = run_hook(@prompt_command, JSON.generate(JSON.parse(prompt_payload).merge("session_id" => session)))
      return [:fail, "exit #{code.inspect}: #{tail(out, err)}"] unless code == 0
      return [:fail, "still blocked: #{tail(out, err)}"] if blocked?(code, out, err)

      [:pass, "signed in through the plugin hook (ask, confirm, yes, wrong password, password once per turn, signed-in context), gate open"]
    end

    def status_step
      code, out, err = reach("status")
      return [:fail, "exit #{code.inspect}: #{tail(out, err)}"] unless code == 0

      combined = out + err
      return [:fail, "fingerprint_mismatch reported: #{tail(out, err)}"] if combined.include?("fingerprint_mismatch")
      return [:fail, "output does not name #{STUDENT_NAME}: #{tail(out, err)}"] unless combined.include?(STUDENT_NAME)

      [:pass, "names #{STUDENT_NAME}, no fingerprint_mismatch"]
    end

    def systemd_user_available?
      return true if windows? || macos?

      _out, _err, status = Open3.capture3("systemctl", "--user", "show-environment")
      status.success?
    rescue SystemCallError
      false
    end

    def doctor_step
      systemd_skipped = !systemd_user_available?
      code, out, err = reach("doctor")
      pairs = out.lines.map { |line| line.strip.match(/\A(R-[A-Z0-9-]+):\s*(.*)\z/) }.compact.map { |m| [m[1], m[2]] }
      findings = pairs.map(&:first).uniq
      allowed = EXPECTED_DOCTOR_FINDINGS.dup
      allowed << CHROME_FINDING unless @kit_installed
      tolerated = @kit_installed ? EXPECTED_DOCTOR_LINES : EXPECTED_DOCTOR_LINES.merge(NO_KIT_DOCTOR_LINES) { |_code, kit, bare| Regexp.union(kit, bare) }
      tolerated = tolerated.merge("R-DOC-SUBSCRIBE" => Regexp.union(tolerated["R-DOC-SUBSCRIBE"], SUBSCRIBE_UNINSTALLED)) if systemd_skipped
      unexpected = pairs.reject { |code, text| allowed.include?(code) || tolerated[code]&.match?(text) }.map(&:first).uniq
      if code.nil?
        return [:fail, "doctor did not finish: #{tail(out, err)}"]
      end
      unless unexpected.empty?
        return [:fail, "unexpected findings #{unexpected.join(', ')}\n#{out}#{err}"]
      end
      return [:fail, "doctor exited #{code} with no findings: #{tail(out, err)}"] if code != 0 && findings.empty?

      detail = findings.empty? ? "no findings" : "only expected findings: #{findings.join(', ')}"
      detail += "; #{SYSTEMD_SKIP}" if systemd_skipped && pairs.any? { |code, text| code == "R-DOC-SUBSCRIBE" && SUBSCRIBE_UNINSTALLED.match?(text) }
      [:pass, detail]
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

    def read_environment
      return nil unless @install && File.directory?(File.join(@install, "lib"))

      script = 'require "reach"; require "json"; puts JSON.generate(Reach::Environment.fields)'
      code, out, _err = spawn_capture([RbConfig.ruby, "-I", File.join(@install, "lib"), "-e", script], chdir: @scratch)
      return nil unless code == 0

      parsed = JSON.parse(out.to_s.lines.last.to_s)
      parsed.is_a?(Hash) && !parsed.empty? ? parsed : nil
    rescue StandardError
      nil
    end

    def reach_version
      File.read(File.join(ROOT, "VERSION")).strip
    rescue StandardError
      "unknown"
    end

    def commit_id
      env_sha = ENV["GITHUB_SHA"].to_s.strip
      return env_sha unless env_sha.empty?

      code, out, _err = spawn_capture(["git", "-C", ROOT, "rev-parse", "HEAD"])
      sha = out.to_s.strip
      code == 0 && !sha.empty? ? sha : "unknown"
    rescue StandardError
      "unknown"
    end

    def leg_name
      @options[:leg] || "#{RbConfig::CONFIG['host_os']} #{RbConfig::CONFIG['host_cpu']}"
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
        "leg" => leg_name,
        "reach_version" => reach_version,
        "commit" => commit_id,
        "environment" => @environment || os_version,
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
      parser.on("--leg NAME") { |value| options[:leg] = value }
    end.parse!(argv)
    Run.new(options).execute
  end
end

exit PlatformSmoke.main(ARGV) if $PROGRAM_NAME == __FILE__
