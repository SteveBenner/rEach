#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "digest"
require "fileutils"
require "open3"
require "optparse"
require "rubygems/package"
require "stringio"
require "time"
require "zlib"

module SdkKitBuild
  RPLUGIN_PATHS = %w[lib bin/rplugin LICENSE VERSION].freeze
  RBRAIN_PATHS = %w[lib bin specs examples skills docs LICENSE VERSION].freeze
  RBRAIN_EXCLUDE = %r{\Aspecs/implementation(/|\z)}.freeze
  FORBIDDEN_NAMES = %w[TOKENS.jsonl DECISIONS.md].freeze
  PATTERNS = [
    [%r{/home/[a-z]}, "a /home/ path"],
    [%r{/Users/[a-z]}, "a /Users/ path"],
    [/[A-Za-z0-9._%+-]+@(gmail|icloud|outlook|yahoo)\./, "a personal e-mail address"],
    [/BEGIN [A-Z ]*PRIVATE KEY/, "a private key"]
  ].freeze

  class Refused < StandardError; end

  module_function

  def git(repo, *args)
    out, err, status = Open3.capture3("git", "-C", repo, *args)
    raise Refused, "git #{args.join(' ')} failed in #{repo}: #{err.strip}" unless status.success?

    out
  end

  def git_bytes(repo, *args)
    out, err, status = Open3.capture3("git", "-C", repo, *args, binmode: true)
    raise Refused, "git #{args.join(' ')} failed in #{repo}: #{err.strip}" unless status.success?

    out
  end

  def read_archive(repo, ref, paths)
    existing = paths.select { |path| !git(repo, "ls-tree", "--name-only", ref, "--", path).strip.empty? }
    bytes = git_bytes(repo, "archive", "--format=tar", ref, "--", *existing)
    files = {}
    Gem::Package::TarReader.new(StringIO.new(bytes)) do |tar|
      tar.each do |entry|
        next unless entry.file?

        files[entry.full_name] = entry.read.to_s.b
      end
    end
    files
  end

  def forbidden_name?(path)
    parts = path.split("/")
    FORBIDDEN_NAMES.include?(parts.last) || parts.include?(".specstory")
  end

  def gate!(entries)
    entries.each do |path, data|
      raise Refused, "refused: #{path} is a private file name" if forbidden_name?(path)

      text = data.dup.force_encoding(Encoding::BINARY)
      text.each_line.with_index(1) do |line, number|
        PATTERNS.each do |pattern, label|
          raise Refused, "refused: #{path}:#{number} holds #{label}" if line.match?(Regexp.new(pattern.source.b, Regexp::NOENCODING))
        end
      end
    end
  end

  def mode_for(path)
    path.start_with?("sdk/bin/", "sdk/rcorpus/bin/") ? 0o755 : 0o644
  end

  def write_archive(entries, target, mtime)
    ENV["SOURCE_DATE_EPOCH"] = mtime.to_s
    io = StringIO.new
    io.set_encoding(Encoding::BINARY)
    Gem::Package::TarWriter.new(io) do |tar|
      entries.keys.sort.each do |path|
        data = entries[path]
        tar.add_file_simple(path, mode_for(path), data.bytesize) { |file| file.write(data) }
      end
    end
    gz = StringIO.new
    gz.set_encoding(Encoding::BINARY)
    writer = Zlib::GzipWriter.new(gz, Zlib::BEST_COMPRESSION)
    writer.mtime = 0
    writer.write(io.string)
    writer.finish
    File.binwrite(target, gz.string)
  end

  def build(options)
    rplugin = File.expand_path(options.fetch(:rplugin))
    rbrain = File.expand_path(options.fetch(:rbrain))
    out = File.expand_path(options.fetch(:out))
    revision = options.fetch(:revision).to_s
    raise Refused, "refused: --revision must be a positive integer" unless revision.match?(/\A[1-9]\d*\z/)

    rplugin_commit = git(rplugin, "rev-parse", "#{options.fetch(:rplugin_ref)}^{commit}").strip
    rbrain_commit = git(rbrain, "rev-parse", "#{options.fetch(:rbrain_ref)}^{commit}").strip
    rplugin_version = git(rplugin, "show", "#{rplugin_commit}:VERSION").strip
    rbrain_version = git(rbrain, "show", "#{rbrain_commit}:VERSION").strip
    mtime = git(rbrain, "log", "-1", "--format=%ct", rbrain_commit).strip.to_i
    sdk_id = "#{rplugin_version}-#{rbrain_version}-r#{revision}"
    tag = "sdk-#{sdk_id}"

    entries = {}
    read_archive(rplugin, rplugin_commit, RPLUGIN_PATHS).each { |path, data| entries["sdk/#{path}"] = data }
    read_archive(rbrain, rbrain_commit, RBRAIN_PATHS).each do |path, data|
      next if path.match?(RBRAIN_EXCLUDE)

      entries["sdk/rcorpus/#{path}"] = data
    end
    entries["sdk/SDK.json"] = JSON.pretty_generate(
      "schema" => "reach.sdk/v1", "sdk_id" => sdk_id,
      "rplugin_version" => rplugin_version, "rplugin_commit" => rplugin_commit,
      "rbrain_version" => rbrain_version, "rbrain_commit" => rbrain_commit,
      "built_at" => Time.at(mtime).utc.iso8601
    ).b + "\n".b
    gate!(entries)

    FileUtils.mkdir_p(out)
    asset = "reach-sdk-#{sdk_id}.tar.gz"
    target = File.join(out, asset)
    write_archive(entries, target, mtime)
    manifest = {
      "schema" => "reach.sdk-manifest/v1", "sdk_id" => sdk_id, "tag" => tag,
      "rplugin_version" => rplugin_version, "rbrain_version" => rbrain_version,
      "asset" => asset, "sha256" => Digest::SHA256.file(target).hexdigest, "size" => File.size(target)
    }
    manifest_path = File.join(out, "sdk-manifest.json")
    File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
    puts "sdk_id: #{sdk_id}"
    puts "tag: #{tag}"
    puts "asset: #{target}"
    puts "asset sha256: #{manifest['sha256']}"
    puts "asset size: #{manifest['size']}"
    puts "files: #{entries.size}"
    puts "content bytes: #{entries.values.sum(&:bytesize)}"
    puts "manifest sha256: #{Digest::SHA256.file(manifest_path).hexdigest}"
    0
  rescue Refused => e
    warn e.message
    1
  end

  def main(argv)
    command = argv.shift
    unless command == "build"
      warn "usage: ruby tools/sdk_kit.rb build --rplugin PATH --rplugin-ref REF --rbrain PATH --rbrain-ref REF --revision N --out DIR"
      return 2
    end
    options = {}
    OptionParser.new do |parser|
      parser.on("--rplugin PATH") { |value| options[:rplugin] = value }
      parser.on("--rplugin-ref REF") { |value| options[:rplugin_ref] = value }
      parser.on("--rbrain PATH") { |value| options[:rbrain] = value }
      parser.on("--rbrain-ref REF") { |value| options[:rbrain_ref] = value }
      parser.on("--revision N") { |value| options[:revision] = value }
      parser.on("--out DIR") { |value| options[:out] = value }
    end.parse!(argv)
    missing = %i[rplugin rplugin_ref rbrain rbrain_ref revision out].reject { |key| options[key] }
    unless missing.empty?
      warn "missing: #{missing.join(', ')}"
      return 2
    end
    build(options)
  end
end

exit SdkKitBuild.main(ARGV) if $PROGRAM_NAME == __FILE__
