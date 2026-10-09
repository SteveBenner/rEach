#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"
require_relative "release_stable"

module StablePromote
  LABEL = "stable-hold".freeze
  NOTICE_PREFIX = "refs/tags/notice/hooks".freeze
  USAGE = "usage: ruby tools/stable_promote.rb plan [--json] | apply notice|promote|ready --tag vX.Y.Z [--sha COMMIT] [--dry-run] | hold --tag vX.Y.Z --run-url URL [--dry-run] | latest-status [--json]".freeze
  LATEST_SOAK_HOURS = (ENV["LATEST_SOAK_HOURS"] || "24").to_i

  module_function

  def run_command(*command)
    ReleaseStable.run_command(*command)
  end

  def today
    Time.now.utc.strftime("%Y-%m-%d")
  end

  def version_of(tag)
    Gem::Version.new(tag.to_s.sub(/\Av/, ""))
  end

  def notice_refs(tag = nil)
    pattern = tag ? "#{NOTICE_PREFIX}/#{tag}/*" : "#{NOTICE_PREFIX}/*"
    run_command("git", "ls-remote", "origin", pattern).lines.map do |line|
      ref = line.split[1].to_s
      match = %r{\A#{Regexp.escape(NOTICE_PREFIX)}/(v\d+\.\d+\.\d+)/(\d{4}-\d{2}-\d{2})\z}.match(ref)
      match ? { ref: ref, tag: match[1], date: match[2] } : nil
    end.compact
  end

  def version_tags
    commits = {}
    run_command("git", "ls-remote", "--tags", "origin", "refs/tags/v*").lines.map(&:split).each do |sha, ref|
      match = %r{\Arefs/tags/(v\d+\.\d+\.\d+)(\^\{\})?\z}.match(ref.to_s)
      next unless match

      commits[match[1]] = sha if match[2] || !commits.key?(match[1])
    end
    commits
  end

  def plan
    tested = ReleaseStable.remote_sha("refs/heads/#{ReleaseStable::TEST_BRANCH}")
    unless tested
      return { "action" => "wait", "tag" => nil, "target" => nil, "stable" => ReleaseStable.remote_sha("refs/heads/#{ReleaseStable::BRANCH}"), "hooks_changed" => false, "notice_ref" => nil, "reason" => "Polispec test-channel onboarding is pending; stable stays where it is" }
    end

    tag = version_tags.select { |_name, sha| sha == tested }.keys.max_by { |name| version_of(name) }
    raise "origin #{ReleaseStable::TEST_BRANCH} tip #{tested[0, 12]} carries no version tag" unless tag

    stable = ReleaseStable.remote_sha("refs/heads/#{ReleaseStable::BRANCH}")
    target = tested

    result = { "action" => "promote", "tag" => tag, "stable" => stable, "target" => target, "hooks_changed" => false, "notice_ref" => nil }
    if stable == target
      result["action"] = "none"
      return result
    end

    if stable
      run_command("git", "fetch", "--quiet", "origin", "refs/tags/#{tag}:refs/tags/#{tag}", "refs/heads/#{ReleaseStable::BRANCH}:refs/remotes/origin/#{ReleaseStable::BRANCH}")
      result["hooks_changed"] = !run_command("git", "diff", "--name-only", "#{stable}..#{target}", "--", "hooks/").empty?
    end
    return result unless result["hooks_changed"]

    existing = notice_refs(tag)
    if existing.empty?
      result["action"] = "notice"
    else
      newest = existing.max_by { |entry| entry[:date] }
      result["notice_ref"] = newest[:ref]
      result["action"] = "wait" if newest[:date] == today
    end
    result
  end

  def write_output(result)
    path = ENV["GITHUB_OUTPUT"].to_s
    return if path.empty?

    File.open(path, "a") { |handle| handle.puts("action=#{result['action']}", "tag=#{result['tag']}", "target=#{result['target']}") }
  end

  def command_plan(argv)
    options = {}
    OptionParser.new { |opts| opts.on("--json") { options[:json] = true } }.parse!(argv)
    return usage unless argv.empty?

    result = plan
    write_output(result)
    if options[:json]
      puts JSON.generate(result)
    elsif result["action"] == "wait"
      puts result.fetch("reason")
    else
      stable = result["stable"] ? result["stable"][0, 12] : "absent"
      puts "#{result['action']} #{result['tag']} (stable #{stable}, target #{result['target'][0, 12]}, hooks changed: #{result['hooks_changed']})"
    end
    0
  end

  def tag_options(argv, run_url: false)
    options = {}
    parser = OptionParser.new do |opts|
      opts.on("--tag TAG") { |value| options[:tag] = value }
      opts.on("--dry-run") { options[:dry_run] = true }
      opts.on("--sha SHA") { |value| options[:sha] = value }
      opts.on("--run-url URL") { |value| options[:run_url] = value } if run_url
    end
    parser.parse!(argv)
    options
  end

  def apply_notice(options)
    tag = options[:tag]
    result = plan
    raise "#{tag} is not the tag at #{ReleaseStable::TEST_BRANCH}'s tip (#{result['tag']})" unless result["tag"] == tag
    raise "plan says #{result['action']} for #{tag}, not notice; refusing to push a notice" unless result["action"] == "notice"

    ref = "#{NOTICE_PREFIX}/#{tag}/#{today}"
    if options[:dry_run]
      puts "would push #{ref} -> #{result['target'][0, 12]}"
      return 0
    end

    run_command("git", "push", "origin", "#{result['target']}:#{ref}")
    puts "pushed #{ref} -> #{result['target'][0, 12]}"
    0
  end

  def open_holds(name)
    run_command("gh", "issue", "list", "--repo", name, "--label", LABEL, "--state", "open", "--json", "number", "--jq", ".[].number").lines.map(&:strip).reject(&:empty?)
  end

  def apply_promote(options)
    tag = options[:tag]
    name = ReleaseStable.slug
    status = ReleaseStable.run(options[:dry_run] ? [tag, "--dry-run"] : [tag])
    return status unless status.zero?

    stale = notice_refs.select { |entry| version_of(entry[:tag]) <= version_of(tag) }
    holds = open_holds(name)
    if options[:dry_run]
      stale.each { |entry| puts "would remove #{entry[:ref]}" }
      holds.each { |number| puts "would close issue ##{number} labeled #{LABEL}" }
      return 0
    end

    unless stale.empty?
      run_command("git", "push", "origin", *stale.map { |entry| ":#{entry[:ref]}" })
      stale.each { |entry| puts "removed #{entry[:ref]}" }
    end
    holds.each do |number|
      run_command("gh", "issue", "close", number, "--repo", name, "--comment", "stable moved to #{tag}; the platform smoke passed.")
      puts "closed issue ##{number}"
    end
    0
  end

  def stable_name
    stable = ReleaseStable.remote_sha("refs/heads/#{ReleaseStable::BRANCH}")
    return "absent" unless stable

    found = version_tags.select { |_tag, sha| sha == stable }.keys.max_by { |name| version_of(name) }
    found || stable[0, 12]
  end

  READY_LABEL = "stable-ready".freeze

  def open_ready(name)
    run_command("gh", "issue", "list", "--repo", name, "--label", READY_LABEL, "--state", "open", "--json", "number", "--jq", ".[].number").lines.map(&:strip).reject(&:empty?)
  end

  def apply_ready(options)
    tag = options[:tag]
    result = plan
    raise "#{tag} is not the tag at #{ReleaseStable::TEST_BRANCH}'s tip (#{result['tag']})" unless result["tag"] == tag
    raise "plan says #{result['action']} for #{tag}, not promote; no stable-ready issue" unless result["action"] == "promote"
    tested = options[:sha].to_s
    raise "the smoke result does not name the exact planned commit" unless tested.match?(/\A[0-9a-f]{40}\z/) && tested == result["target"]

    name = ReleaseStable.slug
    sha = result["target"][0, 12]
    title = "stable-ready: #{tag} passed the platform smoke on test"
    body = "test is at #{sha} (#{tag}) and the platform smoke passed. Stable moves only when the operator runs `polispec promote reach --to stable`."
    existing = open_ready(name).first
    if options[:dry_run]
      puts(existing ? "would update issue ##{existing}: #{title}" : "would open issue #{title.inspect} labeled #{READY_LABEL}")
      return 0
    end

    if existing
      run_command("gh", "issue", "edit", existing, "--repo", name, "--title", title, "--body", body)
      puts "updated issue ##{existing}"
    else
      run_command("gh", "label", "create", READY_LABEL, "--repo", name, "--description", "test passed the smoke; waiting for the operator", "--force")
      puts run_command("gh", "issue", "create", "--repo", name, "--title", title, "--body", body, "--label", READY_LABEL)
    end
    0
  end

  def command_hold(options)
    tag = options[:tag]
    url = options[:run_url].to_s
    raise "--run-url is required" if url.empty?

    name = ReleaseStable.slug
    title = "stable held at #{stable_name}: smoke failed for #{tag}"
    body = "The platform smoke did not pass on test at #{tag}, so stable stays where it is. Run: #{url}"
    existing = open_holds(name).first
    if options[:dry_run]
      puts(existing ? "would comment on issue ##{existing}: #{body}" : "would open issue #{title.inspect} labeled #{LABEL}")
      return 0
    end

    if existing
      run_command("gh", "issue", "comment", existing, "--repo", name, "--body", body)
      puts "commented on issue ##{existing}"
    else
      run_command("gh", "label", "create", LABEL, "--repo", name, "--description", "stable is held behind test", "--force")
      puts run_command("gh", "issue", "create", "--repo", name, "--title", title, "--body", body, "--label", LABEL)
    end
    0
  end

  def latest_status(now = Time.now.utc)
    name = ReleaseStable.slug
    stable = ReleaseStable.remote_sha("refs/heads/#{ReleaseStable::BRANCH}")
    tag = version_tags.select { |_tag, sha| sha == stable }.keys.max_by { |found| version_of(found) }
    return { "eligible" => false, "tag" => nil, "reasons" => ["origin #{ReleaseStable::BRANCH} tip carries no version tag"] } unless tag

    release = JSON.parse(run_command("gh", "release", "view", tag, "--repo", name, "--json", "tagName,isPrerelease,publishedAt"))
    latest = JSON.parse(run_command("gh", "release", "view", "--repo", name, "--json", "tagName"))["tagName"]
    published = Time.parse(release["publishedAt"].to_s)
    age_hours = ((now - published) / 3600.0).floor(1)
    holds = JSON.parse(run_command("gh", "issue", "list", "--repo", name, "--label", LABEL, "--state", "all", "--json", "number,createdAt", "--limit", "100"))
    later_holds = holds.select { |issue| Time.parse(issue["createdAt"].to_s) > published }.map { |issue| issue["number"] }

    reasons = []
    reasons << "#{tag} is already Latest" if latest == tag
    reasons << "#{tag} is a prerelease" if release["isPrerelease"]
    reasons << "#{tag} was published #{age_hours} h ago, under the #{LATEST_SOAK_HOURS} h soak" if age_hours < LATEST_SOAK_HOURS
    reasons << "stable-hold issue(s) opened since #{tag} was published: #{later_holds.map { |n| "##{n}" }.join(', ')}" unless later_holds.empty?
    { "eligible" => reasons.empty?, "tag" => tag, "latest" => latest, "age_hours" => age_hours, "soak_hours" => LATEST_SOAK_HOURS,
      "reasons" => reasons, "unchecked" => ["desk faults per version are not in the release-gate facts"],
      "flip" => reasons.empty? ? "gh release edit #{tag} --repo #{name} --latest" : nil }
  end

  def command_latest_status(argv)
    json = argv.delete("--json")
    return usage unless argv.empty?

    status = latest_status
    if json
      puts JSON.generate(status)
    elsif status["eligible"]
      puts "#{status['tag']} is eligible for Latest (published #{status['age_hours']} h ago, no stable-hold since). The operator flips it: #{status['flip']}"
    else
      puts "#{status['tag'] || 'stable'} is not eligible for Latest: #{status['reasons'].join('; ')}"
    end
    puts "not checked: #{status['unchecked'].join('; ')}" if status["unchecked"] && !json
    0
  end

  def usage
    warn USAGE
    2
  end

  def run(argv)
    command = argv.shift
    case command
    when "plan"
      command_plan(argv)
    when "apply"
      kind = argv.shift
      return usage unless %w[notice promote ready].include?(kind)

      options = tag_options(argv)
      return usage unless argv.empty? && options[:tag].to_s.match?(ReleaseStable::TAG)

      case kind
      when "notice" then apply_notice(options)
      when "ready" then apply_ready(options)
      else apply_promote(options)
      end
    when "latest-status"
      command_latest_status(argv)
    when "hold"
      options = tag_options(argv, run_url: true)
      return usage unless argv.empty? && options[:tag].to_s.match?(ReleaseStable::TAG)

      command_hold(options)
    else
      usage
    end
  rescue RuntimeError, OptionParser::ParseError, SystemCallError => e
    warn e.message
    1
  end
end

exit StablePromote.run(ARGV) if $PROGRAM_NAME == __FILE__
