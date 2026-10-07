#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"

module ReleaseStable
  ROOT = File.expand_path("..", __dir__)
  BRANCH = "stable".freeze
  TAG = /\Av\d+\.\d+\.\d+\z/.freeze

  module_function

  def run_command(*command)
    out, err, status = Open3.capture3(*command, chdir: ROOT)
    raise "#{command.join(' ')} failed: #{(err.empty? ? out : err).lines.first.to_s.strip}" unless status.success?

    out.strip
  end

  def slug
    url = run_command("git", "remote", "get-url", "origin")
    match = url.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/*\z})
    raise "origin #{url} is not a GitHub repository" unless match

    "#{match[1]}/#{match[2]}"
  end

  def latest_tag(name)
    run_command("gh", "api", "repos/#{name}/releases/latest", "--jq", ".tag_name")
  end

  def remote_sha(ref)
    line = run_command("git", "ls-remote", "origin", ref)
    line.empty? ? nil : line.split.first
  end

  def tag_commit(tag)
    lines = run_command("git", "ls-remote", "origin", "refs/tags/#{tag}", "refs/tags/#{tag}^{}").lines.map(&:strip).reject(&:empty?)
    line = lines.find { |entry| entry.end_with?("^{}") } || lines.first
    line&.split&.first
  end

  def ancestor?(older, newer)
    _out, _err, status = Open3.capture3("git", "merge-base", "--is-ancestor", older, newer, chdir: ROOT)
    status.success?
  end

  def run(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = "usage: ruby tools/release_stable.rb vX.Y.Z [--dry-run]"
      opts.on("--dry-run") { options[:dry_run] = true }
    end
    parser.parse!(argv)
    tag = argv.first.to_s
    unless argv.length == 1 && tag.match?(TAG)
      warn parser.banner
      return 2
    end

    name = slug
    latest = latest_tag(name)
    raise "#{tag} is not the Latest release of #{name} (Latest is #{latest}); stable moves only to the Latest release" unless latest == tag

    current = remote_sha("refs/heads/#{BRANCH}")
    refspecs = ["refs/tags/#{tag}:refs/tags/#{tag}"]
    refspecs << "refs/heads/#{BRANCH}:refs/remotes/origin/#{BRANCH}" if current
    run_command("git", "fetch", "--quiet", "origin", *refspecs)
    target = run_command("git", "rev-parse", "#{tag}^{commit}")
    raise "the remote tag #{tag} is not #{target}" unless remote_sha("refs/tags/#{tag}^{}") == target || remote_sha("refs/tags/#{tag}") == target

    if current == target
      puts "#{BRANCH} already at #{tag} (#{target[0, 12]})"
      return 0
    end
    raise "origin #{BRANCH} (#{current[0, 12]}) is not an ancestor of #{tag}; refusing a non-fast-forward move" if current && !ancestor?(current, target)

    from = current ? current[0, 12] : "absent"
    if options[:dry_run]
      puts "would move origin #{BRANCH} #{from} -> #{target[0, 12]} (#{tag}, Latest)"
      return 0
    end

    run_command("git", "push", "origin", "#{target}:refs/heads/#{BRANCH}")
    moved = remote_sha("refs/heads/#{BRANCH}")
    raise "origin #{BRANCH} is #{moved.to_s[0, 12]} after the push, not #{target[0, 12]}" unless moved == target

    puts "moved origin #{BRANCH} #{from} -> #{target[0, 12]} (#{tag}, Latest)"
    0
  rescue RuntimeError, OptionParser::ParseError, SystemCallError => e
    warn e.message
    1
  end
end

exit ReleaseStable.run(ARGV) if $PROGRAM_NAME == __FILE__
