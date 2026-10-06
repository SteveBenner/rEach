#!/usr/bin/env ruby

require "json"
require "time"
require "net/http"
require "uri"
require "fileutils"
require "digest"
require "securerandom"
require "tmpdir"
require "open3"
require "timeout"
require_relative "scan"

module SecurityAuditGate
  ROOT = begin
    out, status = Open3.capture2("git", "rev-parse", "--show-toplevel", err: File::NULL)
    status.success? && !out.strip.empty? ? out.strip : File.expand_path("../..", __dir__)
  rescue StandardError
    File.expand_path("../..", __dir__)
  end
  ZERO = "0" * 40
  REMOTE = %r{github\.com[:/]SteveBenner/rEach(?:\.git)?}
  DEFAULTS = {
    "enabled" => true, "mode" => "gate", "block_at" => "high", "model" => "fable", "effort" => "default",
    "token_open" => false, "budget_usd" => 10, "timeout_min" => 15, "scope" => "since_release",
    "roster_check" => true, "on_error" => "block"
  }.freeze
  MODEL_IDS = {
    "fable" => "claude-fable-5-1", "opus" => "claude-opus-5-5", "sonnet" => "claude-sonnet-5-5",
    "haiku" => "claude-haiku-4-5-20251001"
  }.freeze
  CUSTOM_MODEL = /\A[a-z0-9][a-z0-9.\-\[\]]{1,63}\z/
  SEVERITIES = %w[critical high medium low info].freeze
  BLOCKING = { "critical" => %w[critical], "high" => %w[critical high], "any" => %w[critical high medium] }.freeze
  HTTP_TIMEOUT = 5
  ATTEMPTS = 3
  RUNS_ROUTE = "/api/v1/ops/security-audit/runs".freeze

  class << self
    attr_accessor :repo, :last_http_error
  end

  module_function

  def root
    repo ? repo.root : ROOT
  end

  def say(text)
    $stderr.puts("#{repo ? repo.name : 'reach'} security audit: #{text}")
  end

  def state_dir
    return repo.state_dir if repo

    File.expand_path(ENV["REACH_SECURITY_AUDIT_STATE"].to_s.empty? ? "~/.local/state/reach-security-audit" : ENV["REACH_SECURITY_AUDIT_STATE"])
  end

  def private_dir(path)
    FileUtils.mkdir_p(path)
    File.chmod(0o700, path)
    path
  end

  def write_private(path, body)
    private_dir(File.dirname(path))
    temp = "#{path}.#{Process.pid}.tmp"
    File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(body) }
    File.rename(temp, path)
  end

  def git(*args)
    out, status = Open3.capture2("git", "-C", root, *args, err: File::NULL)
    status.success? ? out.strip : nil
  end

  def remote_matches?(url)
    return repo.remote_matches?(url) if repo
    return true if url.to_s =~ REMOTE

    pattern = ENV["REACH_SECURITY_AUDIT_REMOTE"].to_s
    return false if pattern.empty?

    !(url.to_s =~ Regexp.new(pattern)).nil?
  rescue RegexpError
    false
  end

  def read_version(sha)
    git("show", "#{sha}:VERSION")
  end

  def releases(lines, remote_name)
    found = []
    lines.each do |row|
      local_ref, local_sha, remote_ref, remote_sha = row.split(" ")
      next if local_sha.nil? || local_sha == ZERO

      if local_ref.to_s.start_with?("refs/tags/v") || remote_ref.to_s.start_with?("refs/tags/v")
        tag = (remote_ref || local_ref).sub("refs/tags/", "")
        found << { sha: local_sha, trigger: "tag", version: tag.sub(/\Av/, "") }
        next
      end
      next unless local_ref.to_s.start_with?("refs/heads/")

      version = read_version(local_sha)
      previous = previous_version(remote_sha, local_sha, remote_name)
      next if previous && previous == version

      found << { sha: local_sha, trigger: "version", version: version.to_s }
    end
    found
  end

  def previous_version(remote_sha, local_sha, remote_name)
    if remote_sha.to_s == ZERO || remote_sha.to_s.empty?
      main = git("rev-parse", "--verify", "--quiet", "refs/remotes/#{remote_name}/main")
      return nil unless main

      mb = git("merge-base", main, local_sha)
      return mb ? read_version(mb) : nil
    end
    return nil unless git("cat-file", "-e", "#{remote_sha}^{commit}")

    read_version(remote_sha)
  end

  def valid_setting?(key, value)
    case key
    when "enabled", "token_open", "roster_check" then value == true || value == false
    when "mode" then %w[gate report_only].include?(value)
    when "block_at" then %w[critical high any].include?(value)
    when "model" then value.is_a?(String) && (MODEL_IDS.key?(value) || value =~ CUSTOM_MODEL)
    when "effort" then %w[default low medium high max].include?(value)
    when "budget_usd" then value.is_a?(Numeric) && value >= 0.5 && value <= 500
    when "timeout_min" then value.is_a?(Integer) && value >= 1 && value <= 60
    when "scope" then %w[since_release whole_tree].include?(value)
    when "on_error" then %w[block allow].include?(value)
    else false
    end
  end

  def normalize(settings)
    out = {}
    DEFAULTS.each do |key, default|
      value = settings.is_a?(Hash) ? settings[key] : nil
      out[key] = valid_setting?(key, value) ? value : default
    end
    out
  end

  def teach_url
    return repo.teach_url if repo

    (ENV["TEACH_URL"].to_s.empty? ? configured_teach_url : ENV["TEACH_URL"]).sub(%r{/+\z}, "")
  end

  def configured_teach_url
    text = File.read(File.join(root, "config.yml"))
    text[/^teach:\s*\n\s+url:\s*(\S+)/, 1].to_s
  rescue StandardError
    ""
  end

  def token
    return repo.token if repo
    return ENV["REACH_SECURITY_AUDIT_TOKEN"].strip unless ENV["REACH_SECURITY_AUDIT_TOKEN"].to_s.strip.empty?

    path = File.expand_path("~/.config/reach-security-audit/token")
    return nil unless File.file?(path)

    if (File.stat(path).mode & 0o077) != 0
      say("token file #{path} must be mode 0600, ignoring it")
      return nil
    end
    value = File.read(path).strip
    value.empty? ? nil : value
  end

  def http(method, path, body = nil, key = nil)
    self.last_http_error = nil
    bearer = token
    if bearer.nil?
      self.last_http_error = "no token"
      return nil
    end
    unless teach_url.start_with?("https://", "http://")
      self.last_http_error = "no Teach URL"
      return nil
    end

    uri = URI.parse("#{teach_url}#{path}")
    last = nil
    ATTEMPTS.times do |attempt|
      sleep(rand * 0.5 + 0.3 * attempt) if attempt.positive?
      begin
        net = Net::HTTP.new(uri.host, uri.port)
        net.use_ssl = uri.scheme == "https"
        net.open_timeout = HTTP_TIMEOUT
        net.read_timeout = HTTP_TIMEOUT
        net.write_timeout = HTTP_TIMEOUT if net.respond_to?(:write_timeout=)
        request = method == :post ? Net::HTTP::Post.new(uri.request_uri) : Net::HTTP::Get.new(uri.request_uri)
        request["Authorization"] = "Bearer #{bearer}"
        request["Accept"] = "application/json"
        if body
          request["Content-Type"] = "application/json"
          request["Idempotency-Key"] = key
          request.body = body
        end
        response = net.request(request)
        code = response.code.to_i
        return JSON.parse(response.body.to_s) if code >= 200 && code < 300
        if code >= 400 && code < 500 && code != 429
          self.last_http_error = "HTTP #{code}"
          return nil
        end

        last = "HTTP #{code}"
      rescue StandardError, Timeout::Error => e
        last = e.class.to_s
      end
    end
    self.last_http_error = last if last
    say("Teach unreachable (#{last})") if last
    nil
  end

  def load_config
    cache = File.join(state_dir, "config.json")
    fetched = http(:get, "/api/v1/ops/security-audit/config")
    if fetched.is_a?(Hash) && fetched["settings"].is_a?(Hash)
      record = { "settings" => normalize(fetched["settings"]), "roster" => fetched["roster"], "fetched_at" => Time.now.utc.iso8601 }
      write_private(cache, JSON.generate(record))
      return record.merge("source" => "teach")
    end
    if File.file?(cache)
      begin
        record = JSON.parse(File.read(cache))
        return { "settings" => normalize(record["settings"]), "roster" => record["roster"], "source" => "cache" }
      rescue StandardError
        nil
      end
    end
    { "settings" => DEFAULTS.dup, "roster" => nil, "source" => "defaults" }
  end

  def base_for(sha, scope)
    return SecurityAuditScan::EMPTY_TREE if scope == "whole_tree"

    tag = git("describe", "--tags", "--abbrev=0", "--match", "v*", "#{sha}^")
    return SecurityAuditScan::EMPTY_TREE unless tag

    git("rev-parse", "#{tag}^{commit}") || SecurityAuditScan::EMPTY_TREE
  end

  def decide(settings, findings, errors)
    blocking = findings.select { |f| BLOCKING[settings["block_at"]].include?(f["severity"]) }
    if settings["mode"] == "gate" && !blocking.empty?
      return ["blocked", 1]
    end
    unless errors.empty?
      return ["error", settings["on_error"] == "allow" ? 0 : 1]
    end
    return ["warned", 0] unless findings.empty?

    ["passed", 0]
  end

  def audit(settings, base, sha, scan_findings, diff_raw)
    binary = [ENV["RELEASE_GATE_CLAUDE"], ENV["REACH_SECURITY_AUDIT_CLAUDE"]].find { |value| !value.to_s.empty? } || "claude"
    model = MODEL_IDS[settings["model"]] || settings["model"]
    workdir = Dir.mktmpdir("reach-security-audit-")
    File.chmod(0o700, workdir)
    begin
      File.write(File.join(workdir, "diff.patch"), diff_raw)
      File.write(File.join(workdir, "scan.json"), JSON.pretty_generate("base" => base, "commit" => sha, "findings" => scan_findings))
      prompt = "#{repo && repo.prompt_paragraph}#{File.read(File.join(__dir__, "prompt.md")).gsub("{{WORKDIR}}", workdir)}"
      args = [binary, "-p", "--model", model]
      args += ["--effort", settings["effort"]] unless settings["effort"] == "default"
      args += ["--max-budget-usd", settings["budget_usd"].to_s] unless settings["token_open"]
      args += ["--output-format", "json", "--no-session-persistence", "--tools", "Read,Grep,Glob",
               "--strict-mcp-config", "--setting-sources", "", "--add-dir", workdir]
      result = run_claude(args, prompt, settings["timeout_min"] * 60)
      parse_audit(result)
    ensure
      FileUtils.rm_rf(workdir)
    end
  end

  def run_claude(args, prompt, seconds)
    stdin, stdout, stderr, thread = Open3.popen3(*args, chdir: root)
    reader = Thread.new { stdout.read }
    errors = Thread.new { stderr.read }
    begin
      stdin.write(prompt)
    rescue Errno::EPIPE
      nil
    end
    stdin.close
    unless thread.join(seconds)
      kill(thread.pid)
      thread.join
      return { error: "audit timed out after #{seconds / 60} minutes" }
    end
    { out: reader.value.to_s, err: errors.value.to_s, ok: thread.value.success? }
  rescue Errno::ENOENT
    { error: "claude binary not found (#{args.first})" }
  rescue StandardError => e
    { error: "audit could not start: #{e.class}" }
  end

  def kill(pid)
    Process.kill("TERM", pid)
    sleep 2
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    nil
  end

  def parse_audit(result)
    return { error: result[:error] } if result[:error]

    data = begin
      JSON.parse(result[:out])
    rescue StandardError
      nil
    end
    return { error: "audit output was not JSON#{result[:err].to_s.empty? ? "" : ": #{result[:err].lines.first.to_s.strip[0, 160]}"}" } unless data.is_a?(Hash)

    cost = data["total_cost_usd"].to_f
    if data["is_error"] || data["subtype"].to_s.start_with?("error")
      return { error: "audit failed (#{data["subtype"] || "error"})", cost: cost }
    end
    text = data["result"].to_s
    block = text.scan(/```json\s*(.*?)```/m).flatten.last
    verdict = block && (JSON.parse(block) rescue nil)
    return { error: "audit verdict was not parsable", cost: cost, text: text } unless verdict.is_a?(Hash) && %w[pass fail].include?(verdict["verdict"])

    findings = Array(verdict["findings"]).select { |f| f.is_a?(Hash) }.map { |f| clean_finding(f) }
    { verdict: verdict["verdict"], summary: verdict["summary"].to_s, findings: findings, cost: cost, text: text }
  end

  def clean_finding(f)
    severity = SEVERITIES.include?(f["severity"].to_s) ? f["severity"].to_s : "info"
    line = f["line"].is_a?(Integer) ? f["line"] : nil
    {
      "severity" => severity,
      "category" => SecurityAuditScan.mask_text(f["category"].to_s)[0, 80],
      "file" => f["file"].nil? ? nil : SecurityAuditScan.mask_text(f["file"].to_s)[0, 300],
      "line" => line,
      "title" => SecurityAuditScan.mask_text(f["title"].to_s)[0, 200],
      "detail" => SecurityAuditScan.mask_text(f["detail"].to_s)[0, 2000]
    }
  end

  def counts(findings)
    SEVERITIES.map { |s| [s, findings.count { |f| f["severity"] == s }] }.select { |_, n| n.positive? }
  end

  def report(release, run, settings, findings, audit_result, errors)
    lines = []
    lines << "# Security audit: #{repo ? repo.name : 'rEach'} #{release[:version]}"
    lines << ""
    lines << "- Status: #{run["status"]}"
    lines << "- Commit: #{run["commit"]}"
    lines << "- Base: #{run["base"]}"
    lines << "- Mode: #{settings["mode"]}, block at #{settings["block_at"]}"
    lines << "- Model: #{settings["model"]}, effort #{settings["effort"]}"
    lines << "- Cost: $#{format("%.4f", run["cost_usd"])}, #{run["duration_s"]} s"
    lines << "- Findings: #{counts(findings).map { |s, n| "#{n} #{s}" }.join(", ")}" unless findings.empty?
    errors.each { |e| lines << "- Error: #{e}" }
    lines << ""
    lines << "## Findings"
    lines << ""
    if findings.empty?
      lines << "None."
    else
      findings.each do |f|
        where = f["file"] ? "#{f["file"]}#{f["line"] ? ":#{f["line"]}" : ""}" : "release"
        lines << "- [#{f["severity"]}] #{f["category"]} #{where}: #{f["title"]}. #{f["detail"]}"
      end
    end
    if audit_result && audit_result[:summary]
      lines << ""
      lines << "## Audit summary"
      lines << ""
      lines << SecurityAuditScan.mask_text(audit_result[:summary])
    end
    lines.join("\n") + "\n"
  end

  def emit(kind, summary, payload, prefix: "security_audit.")
    return false if ENV["RLOGS_DISABLE"] == "1"

    lib = File.expand_path(ENV["RLOGS_LIB"] || "~/rstack/rlogs/lib")
    return false unless File.exist?(File.join(lib, "rlogs", "client.rb"))

    Timeout.timeout(4) do
      $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
      require "rlogs/client"
      version = File.read(File.join(root, "VERSION")).strip
      client = Rlogs::Client.new(
        base_url: rlogs_url,
        token: ENV["RLOGS_AUTH_TOKEN"],
        source: { component: repo ? repo.component : "reach", component_version: version, process_role: "release_gate", workspace: root }
      )
      client.send(client.event(category: "audit", kind: "#{prefix}#{kind}", level: kind == "run" ? "info" : "warn", summary: summary, payload: payload))
    end
    true
  rescue StandardError, LoadError, Timeout::Error
    false
  end

  def rlogs_url
    return ENV["RLOGS_API_URL"] unless ENV["RLOGS_API_URL"].to_s.empty?
    return ENV["RSTACK_URL_RLOGS"] unless ENV["RSTACK_URL_RLOGS"].to_s.empty?
    return "http://127.0.0.1:#{ENV["RSTACK_PORT_RLOGS"]}" unless ENV["RSTACK_PORT_RLOGS"].to_s.empty?

    "http://127.0.0.1:9496"
  end

  def notify(title, body)
    return unless ENV["PATH"].to_s.split(":").any? { |dir| File.executable?(File.join(dir, "notify-send")) }

    pid = Process.spawn("notify-send", "-a", repo ? repo.name : "reach", title, body, out: File::NULL, err: File::NULL)
    Process.detach(pid)
  rescue StandardError
    nil
  end

  def outbox_dir
    File.join(state_dir, "outbox")
  end

  def flush_outbox
    Dir.glob(File.join(outbox_dir, "*.json")).sort.each do |path|
      entry = JSON.parse(File.read(path))
      sent = http(:post, entry["route"] || RUNS_ROUTE, entry["body"], entry["key"])
      File.delete(path) if sent
    rescue StandardError
      next
    end
  end

  def post_run(run, route = RUNS_ROUTE)
    flush_outbox
    body = JSON.generate(run)
    key = SecureRandom.uuid
    response = http(:post, route, body, key)
    return response["id"] if response.is_a?(Hash) && response["id"]

    write_private(File.join(outbox_dir, "#{Time.now.to_i}-#{key}.json"), JSON.generate("key" => key, "route" => route, "body" => body))
    entries = Dir.glob(File.join(outbox_dir, "*.json")).sort
    entries.first(entries.length - 50).each { |old| File.delete(old) } if entries.length > 50
    nil
  end

  def run_record(release, settings, base, tree, status, findings, scan_count, cost, duration, report_md, error)
    {
      "release_version" => release[:version].to_s, "commit" => release[:sha], "tree" => tree, "base" => base,
      "trigger" => release[:trigger], "status" => status, "mode" => settings["mode"],
      "model" => settings["model"], "effort" => settings["effort"], "token_open" => settings["token_open"],
      "budget_usd" => settings["budget_usd"], "cost_usd" => cost.round(6), "duration_s" => duration.round,
      "scan_findings" => scan_count, "findings" => findings.first(200),
      "report_md" => report_md.byteslice(0, 200_000).scrub(""), "error" => error
    }
  end

  def summarize(status, findings, report_path, run_id, reused)
    parts = counts(findings).map { |s, n| "#{n} #{s}" }
    line = "#{status}#{reused ? " (verdict reused)" : ""}: #{parts.empty? ? "no findings" : parts.join(", ")}"
    say(line)
    say("report #{report_path}") if report_path
    say("run #{teach_url}/console/ops/runs/#{run_id}") if run_id
    line
  end

  def cache_key(tree, base, settings)
    digest = Digest::SHA256.hexdigest(JSON.generate(settings.sort.to_h))
    Digest::SHA256.hexdigest("#{tree}\n#{base}\n#{digest}")
  end

  def process(release, config, record: true)
    settings = config["settings"]
    sha = release[:sha]
    commit = git("rev-parse", "#{sha}^{commit}") || sha
    release = release.merge(sha: commit)
    tree = git("rev-parse", "#{commit}^{tree}") || commit
    base = base_for(commit, settings["scope"])
    key = cache_key(tree, base, settings)
    cache_path = File.join(state_dir, "verdicts", "#{key}.json")
    if File.file?(cache_path)
      begin
        cached = JSON.parse(File.read(cache_path))
        summarize(cached["status"], cached["findings"], cached["report_path"], cached["run_id"], true)
        return { code: cached["status"] == "blocked" ? 1 : 0, status: cached["status"], findings: cached["findings"], reused: true, error: nil }
      rescue StandardError
        nil
      end
    end

    started = Time.now
    errors = []
    diff = SecurityAuditScan.diff(root, base, commit)
    roster = config["roster"]
    roster_on = settings["roster_check"]
    errors << "roster unavailable" if roster_on && SecurityAuditScan.roster_index(roster).nil?
    scan_findings = SecurityAuditScan.run(root, base, diff, roster, roster_on)

    scan_blocks = settings["mode"] == "gate" && scan_findings.any? { |f| BLOCKING[settings["block_at"]].include?(f["severity"]) }
    audit_result = scan_blocks ? { summary: "Audit not run: the deterministic scan already blocks this release." } : audit(settings, base, commit, scan_findings, diff[:raw])
    cost = audit_result[:cost].to_f
    errors << audit_result[:error] if audit_result[:error]
    audit_findings = audit_result[:findings] || []
    findings = scan_findings + audit_findings

    status, code = decide(settings, findings, errors)
    duration = Time.now - started
    run = run_record(release, settings, base, tree, status, findings, scan_findings.length, cost, duration, "", errors.empty? ? nil : errors.join("; "))
    report_md = report(release, run, settings, findings, audit_result, errors)
    run["report_md"] = report_md.byteslice(0, 200_000).scrub("")
    report_path = File.join(state_dir, "reports", "#{release[:version]}-#{tree[0, 12]}.md")
    write_private(report_path, report_md)

    run_id = record ? post_run(run) : nil
    summarize(status, findings, report_path, run_id, false)
    return { code: code, status: status, findings: findings, reused: false, error: run["error"] } unless record

    errors.each { |e| say("audit problem: #{e}") }
    say("ALLOWING THE PUSH although the audit failed (on_error=allow)") if status == "error" && code.zero?
    kind = status == "blocked" ? "blocked" : (status == "error" ? "error" : "run")
    emit(kind, "Security audit #{release[:version]} #{status}", { "status" => status, "version" => release[:version], "commit" => commit,
                                                                   "model" => settings["model"], "mode" => settings["mode"], "findings" => findings.length, "scan_findings" => scan_findings.length,
                                                                   "cost_usd" => cost, "duration_s" => duration.round, "error" => run["error"] })
    notify("#{repo ? repo.name : 'rEach'} security audit #{status}", "#{release[:version]}: #{findings.length} findings") if %w[blocked error].include?(status)
    if status != "error"
      write_private(cache_path, JSON.generate("status" => status, "findings" => findings, "report_path" => report_path, "run_id" => run_id))
    end
    { code: code, status: status, findings: findings, reused: false, error: run["error"] }
  end

  def main(argv)
    remote_name = argv[0].to_s
    url = argv[1].to_s
    return 0 unless remote_matches?(url)

    lines = $stdin.read.to_s.split("\n")
    list = releases(lines, remote_name)
    return 0 if list.empty?

    config = load_config
    settings = config["settings"]
    say("REACH_SECURITY_AUDIT=0 is ignored since 0.40.0; the instructor's override is ruby tools/release_gate/gate.rb override") if ENV["REACH_SECURITY_AUDIT"] == "0"
    unless settings["enabled"]
      say("disabled in Teach settings, skipping")
      return 0
    end

    codes = list.uniq { |r| r[:sha] }.map { |release| process(release, config)[:code] }
    codes.max
  end
end

exit(SecurityAuditGate.main(ARGV)) if $PROGRAM_NAME == __FILE__
