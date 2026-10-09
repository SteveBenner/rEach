#!/usr/bin/env ruby

require "json"
require "time"
require "fileutils"
require "securerandom"
require_relative "repo"
require_relative "checks"
require_relative "override"
require_relative "lease"
require_relative "../security_audit/gate"

module ReleaseGate
  module Gate
    SCAN_CATEGORIES = %w[secret-file secret student-data student-data-shape entropy local-path].freeze
    FACTS_ROUTE = "/api/v1/ops/release-gate/facts".freeze
    RUNS_ROUTE = "/api/v1/ops/release-gate/runs".freeze
    OVERRIDES_ROUTE = "/api/v1/ops/release-gate/overrides".freeze
    USAGE = <<~TEXT.freeze
      usage: ruby tools/release_gate/gate.rb check [--ref REF] [--tag vX.Y.Z] [--no-security] [--as-push]
             ruby tools/release_gate/gate.rb override --reason TEXT [--hours N] [--checks ID,ID]
             ruby tools/release_gate/gate.rb overrides
             ruby tools/release_gate/gate.rb hold stable --reason TEXT [--hours N]
      (as a pre-push hook: ruby tools/release_gate/gate.rb REMOTE URL with the ref lines on stdin)
    TEXT

    module_function

    def say(text)
      $stderr.puts("release gate: #{text}")
    end

    def setup
      repo = Repo.detect
      return nil if repo.nil?

      SecurityAuditGate.repo = repo
      repo
    end

    def option(argv, name)
      index = argv.index(name)
      index && argv[index + 1]
    end

    def main(argv)
      case argv.first
      when "check" then check(argv.drop(1))
      when "override" then override(argv.drop(1))
      when "overrides" then list_overrides
      when "hold" then hold(argv.drop(1))
      when "--help", "-h", "help"
        puts USAGE
        0
      else hook(argv)
      end
    end

    def hook(argv)
      remote_name = argv[0].to_s
      url = argv[1].to_s
      repo = setup
      return 0 if repo.nil? || !repo.remote_matches?(url)

      lines = $stdin.read.to_s.split("\n")
      list = releases(lines, remote_name)
      return 0 if list.empty?

      list.uniq { |release| release[:sha] }.map { |release| run_release(repo, release, security: true, record: true) }.max
    end

    def releases(lines, remote_name)
      found = []
      lines.each do |row|
        local_ref, local_sha, remote_ref, remote_sha = row.split(" ")
        next if local_sha.nil? || local_sha == SecurityAuditGate::ZERO

        if local_ref.to_s.start_with?("refs/tags/v") || remote_ref.to_s.start_with?("refs/tags/v")
          tag = (remote_ref || local_ref).sub("refs/tags/", "")
          found << { sha: local_sha, trigger: "tag", version: tag.sub(/\Av/, ""), tag: tag, branch: nil }
          next
        end
        branch_ref = [remote_ref, local_ref].find { |ref| ref.to_s.start_with?("refs/heads/") }
        next if branch_ref.nil?

        version = SecurityAuditGate.read_version(local_sha)
        previous = SecurityAuditGate.previous_version(remote_sha, local_sha, remote_name)
        next if previous && previous == version

        found << { sha: local_sha, trigger: "version", version: version.to_s, tag: nil, branch: branch_ref.sub("refs/heads/", "") }
      end
      found
    end

    def fetch_facts(repo)
      data = SecurityAuditGate.http(:get, FACTS_ROUTE)
      return [data, nil] if data.is_a?(Hash)

      reason = SecurityAuditGate.last_http_error || "Teach answered without facts"
      [nil, "#{reason} at #{repo.teach_url.to_s.empty? ? 'no Teach URL' : repo.teach_url}#{FACTS_ROUTE}; the broken-state checks cannot run"]
    end

    def security_findings(result, settings)
      out = []
      Array(result[:findings]).each do |row|
        id = SCAN_CATEGORIES.include?(row["category"].to_s) ? "SEC-SCAN" : "SEC-AUDIT"
        where = row["file"] ? "#{row['file']}#{row['line'] ? ":#{row['line']}" : ''}" : "release"
        out << Checks.finding(id, row["severity"], "#{row['category']} #{where}: #{row['title']}", row["detail"], "remove the value from the release")
      end
      if result[:status] == "blocked" && Array(result[:findings]).none? { |row| SecurityAuditGate::BLOCKING.fetch(settings["block_at"], SecurityAuditGate::BLOCKING["high"]).include?(row["severity"].to_s.downcase) }
        out << Checks.finding("SEC-AUDIT", "critical", "The model audit answered fail", "the audit verdict was fail without a blocking finding to name", "read the audit report and remove the cause")
      end
      if result[:status] == "error"
        text = "#{result[:error] || 'the security audit failed'}#{settings['on_error'] == 'allow' ? ' (on_error allow)' : ''}"
        out << { "id" => "SEC-AUDIT", "severity" => "error", "class" => settings["on_error"] == "allow" ? "warn_class" : "critical_class", "title" => "SEC-AUDIT could not run", "detail" => text, "clear" => nil }
      end
      out
    end

    def blocking?(row, block_at)
      return row["class"] == "critical_class" if row["severity"] == "error"

      SecurityAuditGate::BLOCKING.fetch(block_at, SecurityAuditGate::BLOCKING["high"]).include?(row["severity"].to_s.downcase)
    end

    def decide(findings, block_at)
      blocking = findings.select { |row| blocking?(row, block_at) }
      status = if blocking.empty?
                 findings.any? { |row| row["severity"] != "info" } ? "warned" : "passed"
               elsif blocking.all? { |row| row["severity"] == "error" }
                 "error"
               else
                 "blocked"
               end
      { status: status, ids: blocking.map { |row| row["id"] }.uniq }
    end

    def counts(findings)
      (SecurityAuditGate::SEVERITIES + %w[error]).map { |s| [s, findings.count { |f| f["severity"] == s }] }.select { |_, n| n.positive? }
    end

    def report(repo, release, run, findings, settings)
      lines = ["# Release gate: #{repo.name} #{release[:version]}", ""]
      lines << "- Status: #{run['status']}#{run['override_id'] ? " (override #{run['override_id']})" : ''}#{run['lease_id'] ? " (lease #{run['lease_id']})" : ''}"
      lines << "- Commit: #{run['commit']}"
      lines << "- Trigger: #{run['trigger']}#{release[:tag] ? " #{release[:tag]}" : ''}#{release[:branch] ? " #{release[:branch]}" : ''}"
      lines << "- Block at: #{settings ? settings['block_at'] : 'high'}"
      lines << "- Findings: #{counts(findings).map { |s, n| "#{n} #{s}" }.join(', ')}" unless findings.empty?
      lines << "- Duration: #{run['duration_s']} s"
      lines << ""
      lines << "## Findings"
      lines << ""
      if findings.empty?
        lines << "None."
      else
        findings.each do |row|
          lines << "- [#{row['severity']}] #{row['id']}: #{row['title']}. #{row['detail']}#{row['clear'] ? " Clear: #{row['clear']}." : ''}"
        end
      end
      SecurityAuditScan.mask_text(lines.join("\n") + "\n")
    end

    def table(findings)
      return "no findings\n" if findings.empty?

      findings.map do |row|
        "#{row['severity'].ljust(8)} #{row['id'].ljust(16)} #{row['title']}\n    #{row['detail']}#{row['clear'] ? "\n    clear: #{row['clear']}" : ''}"
      end.join("\n") + "\n"
    end

    def run_release(repo, release, security:, record:, as_push: false)
      started = Time.now
      commit = SecurityAuditGate.git("rev-parse", "#{release[:sha]}^{commit}") || release[:sha]
      tree = SecurityAuditGate.git("rev-parse", "#{commit}^{tree}") || commit
      release = release.merge(sha: commit, tree: tree, base: SecurityAuditGate.base_for(commit, "since_release"))
      ctx = Context.new(repo)
      findings = []
      spec_error = Checks.spec_mismatch(repo)
      findings << spec_error if spec_error
      facts, facts_error = fetch_facts(repo)
      findings << Checks.error("GATE-FACTS", facts_error) if facts.nil?
      overrides = Override.active(repo)
      findings.concat(Checks.run(repo, release, facts, ctx, overrides: overrides))
      settings = nil
      if security && spec_error.nil?
        config = SecurityAuditGate.load_config
        settings = config["settings"]
        if settings["enabled"]
          result = SecurityAuditGate.process({ sha: commit, trigger: release[:trigger], version: release[:version] }, config, record: record)
          findings.concat(security_findings(result, settings))
        else
          findings << Checks.finding("SEC-AUDIT", "info", "Security audit disabled in Teach settings", "no scan and no model audit ran", "enable it on the Ops page")
        end
      end
      block_at = settings ? settings["block_at"] : SecurityAuditGate::DEFAULTS["block_at"]
      decision = decide(findings, block_at)
      status = decision[:status]
      override = nil
      lease = nil
      lease = Lease.active(repo.name) if %w[blocked error].include?(status)
      if lease && (record || as_push)
        status = "leased"
      elsif %w[blocked error].include?(status) && (record || as_push)
        override = Override.covering(repo, decision[:ids])
        if override
          status = "overridden"
          Override.consume!(repo, override, "release_version" => release[:version], "commit" => commit, "trigger" => release[:trigger], "at" => Override.stamp) if record
        end
      end
      duration = (Time.now - started).round
      run = {
        "repo" => repo.name, "release_version" => release[:version].to_s, "commit" => commit, "tree" => tree, "trigger" => release[:trigger],
        "status" => status, "findings" => findings.first(200).map { |row| row.reject { |key, _| key == "clear" } },
        "override_id" => override && override["id"], "lease_id" => status == "leased" ? lease["id"] : nil, "duration_s" => duration,
        "error" => findings.select { |row| row["severity"] == "error" }.map { |row| row["detail"] }.first(5).join("; ").then { |text| text.empty? ? nil : text[0, 2000] }
      }
      report_md = report(repo, release, run, findings, settings)
      report_path = File.join(repo.state_dir, "reports", "#{release[:version]}-#{tree[0, 12]}-gate.md")
      SecurityAuditGate.write_private(report_path, report_md)
      run_id = record ? SecurityAuditGate.post_run(run, RUNS_ROUTE) : nil
      say("#{status}#{override ? " (override #{override['id']})" : ''}#{status == 'leased' ? " (lease #{lease['id']} until #{lease['expires_at']})" : ''}: #{counts(findings).empty? ? 'no findings' : counts(findings).map { |s, n| "#{n} #{s}" }.join(', ')}")
      findings.select { |row| blocking?(row, block_at) }.each { |row| say("#{row['severity']} #{row['id']}: #{row['title']}") }
      say("a lease (#{lease['id']} until #{lease['expires_at']}) would let this push through; nothing is recorded") if lease && !record && !as_push
      say("override #{override['id']} would let this push through; the push consumes it, this check does not") if override && !record
      say("report #{report_path}")
      say("run #{repo.teach_url}/console/ops (#{run_id})") if run_id
      if record
        kind = %w[blocked error leased].include?(status) ? status : "run"
        SecurityAuditGate.emit(kind, "Release gate #{repo.name} #{release[:version]} #{status}",
                               { "status" => status, "repo" => repo.name, "version" => release[:version], "commit" => commit, "trigger" => release[:trigger],
                                 "findings" => findings.length, "blocking" => decision[:ids], "override_id" => run["override_id"], "lease_id" => run["lease_id"], "duration_s" => duration }, prefix: "release_gate.")
        SecurityAuditGate.notify("#{repo.name} release gate #{status}", "#{release[:version]}: #{decision[:ids].join(', ')}") if %w[blocked error].include?(status)
      end
      %w[blocked error].include?(status) ? 1 : 0
    end

    def check(argv)
      repo = setup
      if repo.nil?
        say("this folder is neither the rEach nor the Teach repository (set RELEASE_GATE_REPO for a scratch clone)")
        return 2
      end
      ref = option(argv, "--ref") || "HEAD"
      tag = option(argv, "--tag")
      sha = SecurityAuditGate.git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      if sha.nil?
        say("unknown ref #{ref}")
        return 2
      end
      version = tag ? tag.sub(/\Av/, "") : SecurityAuditGate.read_version(sha).to_s
      branch = SecurityAuditGate.git("rev-parse", "--abbrev-ref", "HEAD")
      release = { sha: sha, trigger: tag ? "tag" : "version", version: version, tag: tag, branch: branch }
      say("dry run of #{repo.name} #{version} at #{sha[0, 12]}; nothing is recorded")
      code = run_release(repo, release, security: !argv.include?("--no-security"), record: false, as_push: argv.include?("--as-push"))
      report = Dir.glob(File.join(repo.state_dir, "reports", "#{version}-*-gate.md")).max_by { |path| File.mtime(path) }
      puts File.read(report) if report
      code
    end

    def record_override(repo, record)
      key = SecureRandom.uuid
      response = SecurityAuditGate.http(:post, OVERRIDES_ROUTE, JSON.generate(record), key)
      return response["id"] if response.is_a?(Hash) && response["id"]

      SecurityAuditGate.write_private(File.join(SecurityAuditGate.outbox_dir, "#{Time.now.to_i}-#{key}.json"),
                                      JSON.generate("key" => key, "route" => OVERRIDES_ROUTE, "body" => JSON.generate(record)))
      nil
    end

    def override(argv, checks: nil, default_hours: 2)
      repo = setup
      if repo.nil?
        say("this folder is neither the rEach nor the Teach repository")
        return 2
      end
      reason = option(argv, "--reason").to_s
      hours = (option(argv, "--hours") || default_hours).to_i
      ids = checks || (option(argv, "--checks") ? option(argv, "--checks").split(",").map(&:strip).reject(&:empty?) : ["*"])
      record = Override.create!(repo, reason: reason, hours: hours, checks: ids)
      remote_id = record_override(repo, record)
      SecurityAuditGate.emit("override", "Release gate override #{repo.name} #{record['id']}", record.merge("teach_id" => remote_id), prefix: "release_gate.")
      say("override #{record['id']} covers #{ids.join(', ')} for one #{repo.name} push until #{record['expires_at']}#{remote_id ? '' : ' (Teach not reached; the record waits in the outbox)'}")
      0
    rescue Override::Refused => e
      say("refused: #{e.message}")
      2
    end

    def hold(argv)
      unless argv.first == "stable"
        puts USAGE
        return 2
      end
      override(argv.drop(1), checks: ["VER-STABLE"], default_hours: 24)
    end

    def list_overrides
      repo = setup
      return 2 if repo.nil?

      Override.active(repo).each { |record| puts JSON.generate(record) }
      0
    end
  end
end

exit(ReleaseGate::Gate.main(ARGV)) if $PROGRAM_NAME == __FILE__
