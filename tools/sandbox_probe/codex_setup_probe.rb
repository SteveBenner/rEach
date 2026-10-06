require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__)
REACH = File.join(ROOT, "exe", "reach")
OLD = ARGV[0] ? File.expand_path(ARGV[0]) : nil
PORT = Integer(ENV["PROBE_PORT"] || "7613")
TEACH_URL = "http://127.0.0.1:#{PORT}".freeze
COURSE_CODE = "BUS101-K7QX-94TD".freeze
USERNAME = "mdelgado".freeze
STUDENT_ID = "20410217".freeze
PASSWORD = "smoke-test-password-1".freeze
EXTERNAL = "https://raw.githubusercontent.com/SteveBenner/rEach/main/VERSION".freeze
LIMIT_S = 120

ENV.keys.each { |key| ENV.delete(key) if key.upcase.start_with?("TEACH_") || (key.upcase.start_with?("REACH_") && key != "REACH_PROBE_KEEP") }
ENV["REACH_UPDATE_DISABLE"] = "1"
ENV["REACH_SUBSCRIBE"] = "0"

$LOAD_PATH.unshift(File.join(ROOT, "lib"))
require "reach"

def capture(argv, stdin: "", chdir: ROOT)
  out, err, status = Open3.capture3(*argv, stdin_data: stdin, chdir: chdir)
  [status.exitstatus, out, err]
rescue SystemCallError => e
  [nil, "", e.message]
end

def reach(*args, stdin: "")
  capture([RbConfig.ruby, REACH, *args], stdin: stdin)
end

def old_reach(*args, stdin: "")
  capture([RbConfig.ruby, File.join(OLD, "exe", "reach"), *args], stdin: stdin, chdir: OLD)
end

def hashes(dir)
  Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.each_with_object({}) do |path, table|
    table[path[(dir.length + 1)..-1]] = Digest::SHA256.file(path).hexdigest
  end
end

def tail(text)
  text.to_s.lines.map(&:strip).reject(&:empty?).last.to_s[0, 300]
end

def stop_teach(pid)
  Process.kill(RbConfig::CONFIG["host_os"] =~ /mswin|mingw/ ? "KILL" : "TERM", pid)
  Process.wait(pid)
  20.times do
    begin
      Net::HTTP.get_response(URI("#{TEACH_URL}/api/v1/health"))
      sleep 0.5
    rescue StandardError
      break
    end
  end
rescue StandardError
  nil
end

def start_teach(scratch, root = ROOT)
  log = File.open(File.join(scratch, "fake_teach.log"), "a")
  pid = Process.spawn(RbConfig.ruby, File.join(root, "tools", "fake_teach", "server.rb"), "--port", PORT.to_s, "--home", File.join(scratch, "teach"),
                      in: File::NULL, out: log, err: log, chdir: root)
  log.close
  40.times do
    begin
      return pid if Net::HTTP.get_response(URI("#{TEACH_URL}/api/v1/health")).code == "200"
    rescue StandardError
      sleep 0.5
    end
  end
  raise "fake_teach did not answer: #{File.read(File.join(scratch, "fake_teach.log"))[0, 600]}"
end

def sandboxed(setup, argv)
  cli = setup.codex_cli
  return { "exit" => nil, "out" => "", "err" => "codex command not found" } unless cli

  out, err, code = setup.run_limited([cli, "sandbox"] + setup.probe_mode_args + ["--"] + argv, LIMIT_S, chdir: setup.workspace)
  { "exit" => code.to_s, "out" => tail(out), "err" => tail(err) }
end

def measure(label)
  Reach::Sandbox.reset!
  setup = Reach::CodexSetup
  facts = begin
    setup.facts
  rescue StandardError => e
    { "error" => e.message }
  end
  probe = setup.probe!
  6.times do
    break unless probe["reason"].to_s.include?("pacing")

    sleep 15
    probe = setup.probe!
  end
  external = sandboxed(setup, [RbConfig.ruby, "-ruri", "-rnet/http", "-e", "begin; puts Net::HTTP.get_response(URI(#{EXTERNAL.inspect})).code; rescue StandardError => e; puts \"blocked: \#{e.class}\"; end"])
  legacy = sandboxed(setup, [RbConfig.ruby, "-rfileutils", "-e", "d = File.join(Dir.home, '.reach-probe-legacy'); begin; FileUtils.mkdir_p(d); File.write(File.join(d, 'x'), 'ok'); puts 'ok'; rescue StandardError => e; puts \"denied: \#{e.class}\"; end"])
  sync = sandboxed(setup, [RbConfig.ruby, REACH, "sync"])
  {
    "label" => label,
    "facts" => facts,
    "probe" => probe.reject { |key, _| key == "text" },
    "probe_text" => probe["text"],
    "external_https" => external,
    "write_outside_workspace" => legacy,
    "sandboxed_sync" => sync
  }
end

def apply(mode)
  result = Reach::CodexSetup.apply!(mode: mode, via: "terminal")
  { "mode" => mode, "state" => result["state"], "ok" => result["ok"], "text" => result["text"] }
end

report = {
  "platform" => RUBY_PLATFORM,
  "ruby" => RUBY_VERSION,
  "reach_version" => File.read(File.join(ROOT, "VERSION")).strip,
  "home_dir" => Dir.home,
  "steps" => []
}
scratch = Dir.mktmpdir("reach-codex-probe")
teach_pid = nil
failures = []
begin
  teach_pid = start_teach(scratch, OLD || ROOT)
  enroll_args = ["enroll", "--course-code", COURSE_CODE, "--username", USERNAME, "--student-id", STUDENT_ID, "--password-stdin", "--teach-url", TEACH_URL]
  if OLD
    legacy = File.join(Dir.home, ".reach")
    code, out, err = old_reach(*enroll_args, stdin: "#{PASSWORD}\n")
    report["enroll"] = { "exit" => code, "out" => tail(out), "err" => tail(err), "with" => File.read(File.join(OLD, "VERSION")).strip }
    failures << "legacy enroll exited #{code.inspect}" unless code == 0
    code, out, err = old_reach("sync")
    report["legacy_sync"] = { "exit" => code, "out" => tail(out), "err" => tail(err) }
    stop_teach(teach_pid)
    teach_pid = start_teach(scratch)
    before = hashes(legacy)
    code, out, err = reach("relocate", "--format", "json")
    after = hashes(legacy)
    moved = hashes(File.join(Dir.home, "reach-work", ".reach-home"))
    changed = (before.keys | after.keys).reject { |key| before[key] == after[key] }
    missing = before.keys.reject { |key| moved.key?(key) }
    different = before.keys.select { |key| moved.key?(key) && moved[key] != before[key] }
    report["relocate"] = {
      "exit" => code, "out" => tail(out), "err" => tail(err), "legacy_files" => before.size, "legacy_changed" => changed,
      "missing_in_new_home" => missing.first(20), "missing_count" => missing.size, "different_in_new_home" => different.first(20), "different_count" => different.size
    }
    failures << "relocate exited #{code.inspect}" unless code == 0
    failures << "legacy home had no files" if before.empty?
    failures << "relocation changed the legacy home: #{(changed - ["RELOCATED.json"]).first(5).join(", ")}" unless (changed - ["RELOCATED.json"]).empty?
    failures << "#{missing.size} legacy files are missing from the new home" unless missing.empty?
    failures << "#{different.size} files differ in the new home" unless different.empty?
    code, out, err = reach("status")
    report["status_after_relocate"] = { "exit" => code, "names_student" => out.include?("Maria Delgado"), "mismatch" => out.include?("fingerprint_mismatch"), "out" => tail(out), "err" => tail(err) }
    failures << "status after relocation does not name the enrolled student" unless out.include?("Maria Delgado") && !out.include?("fingerprint_mismatch")
  else
    code, out, err = reach(*enroll_args, stdin: "#{PASSWORD}\n")
    report["enroll"] = { "exit" => code, "out" => tail(out), "err" => tail(err) }
    failures << "enroll exited #{code.inspect}" unless code == 0
  end
  code, out, err = reach("sync")
  report["sync"] = { "exit" => code, "out" => tail(out), "err" => tail(err) }
  failures << "sync exited #{code.inspect}" unless code == 0

  Reach::Paths.reset_persona_memo! if Reach::Paths.respond_to?(:reset_persona_memo!)
  report["reach_root"] = Reach::Paths.root
  report["workspace"] = Reach::CodexSetup.workspace
  report["home_inside_workspace"] = Reach::Paths.root.start_with?(Reach::CodexSetup.workspace + File::SEPARATOR)
  report["codex_cli"] = Reach::CodexSetup.codex_cli
  report["codex_version"] = Reach::CodexSetup.codex_cli ? tail(capture([Reach::CodexSetup.codex_cli, "--version"])[1]) : nil
  report["mode_wanted"] = Reach::CodexSetup.mode_wanted
  failures << "rEach's home is not inside the workspace" unless report["home_inside_workspace"]
  failures << "codex command not found" unless report["codex_cli"]

  report["steps"] << measure("before")
  %w[workspace full].each do |mode|
    report["steps"] << { "label" => "apply #{mode}", "apply" => apply(mode) }
    report["steps"] << measure(mode)
  end

  wanted = report["steps"].find { |step| step["label"] == report["mode_wanted"] }
  if wanted
    probe = wanted["probe"]
    failures << "#{report["mode_wanted"]} mode: probe unavailable (#{probe["reason"]})" unless probe["available"]
    failures << "#{report["mode_wanted"]} mode: the sandbox blocks the course server" unless probe["network"] == true
    failures << "#{report["mode_wanted"]} mode: the sandbox blocks rEach's folder" unless probe["home_writable"] == true
    failures << "#{report["mode_wanted"]} mode: a sandboxed reach sync exited #{wanted["sandboxed_sync"]["exit"]}" unless wanted["sandboxed_sync"]["exit"] == "0"
  else
    failures << "no measurement for mode #{report["mode_wanted"]}"
  end
rescue StandardError => e
  failures << "#{e.class}: #{e.message}"
ensure
  stop_teach(teach_pid) if teach_pid
end

report["failures"] = failures
puts JSON.pretty_generate(report)
path = ENV["GITHUB_STEP_SUMMARY"].to_s
unless path.empty?
  rows = report["steps"].select { |step| step["probe"] }.map do |step|
    "| #{step["label"]} | #{step["probe"]["available"]} | #{step["probe"]["network"]} | #{step["probe"]["home_writable"]} | #{step["external_https"]["out"]} | #{step["write_outside_workspace"]["out"]} | #{step["sandboxed_sync"]["exit"]} |"
  end
  File.open(path, "a") do |file|
    file.puts "### #{report["platform"]} · Codex #{report["codex_version"]} · wanted mode #{report["mode_wanted"]}"
    file.puts "relocation: #{report["relocate"].to_json}" if report["relocate"]
    file.puts "| settings | probe ran | course server | rEach folder | external https | write outside reach-work | sandboxed sync exit |"
    file.puts "|---|---|---|---|---|---|---|"
    rows.each { |row| file.puts row }
    file.puts failures.empty? ? "PASS" : "FAIL: #{failures.join("; ")}"
  end
end
exit(failures.empty? ? 0 : 1)
