#!/usr/bin/env ruby

require "json"
require "optparse"
require_relative "../lib/reach"

module RuntimePins
  PINS_PATH = File.expand_path("../exe/runtime-pins", __dir__)
  SAFE_VALUE = %r{\A[A-Za-z0-9._/:+-]+\z}.freeze

  module_function

  def load_manifest(file)
    return Reach::RuntimeKit.manifest unless file

    bytes = File.binread(file)
    Reach::RuntimeKit.verify_manifest_bytes!(bytes, file)
    data = JSON.parse(bytes)
    raise Reach::Error, "reach: #{file} is not a runtime manifest" unless data.is_a?(Hash) && data["schema"] == Reach::RuntimeKit::MANIFEST_SCHEMA

    data
  end

  def safe(key, value)
    text = value.to_s
    raise Reach::Error, "reach: #{key} has a value that is not safe for a shell pin: #{text.inspect}" unless text =~ SAFE_VALUE

    text
  end

  def expected(data)
    runtime_id = safe("runtime_id", data["runtime_id"])
    unless runtime_id == Reach::RuntimeKit::RUNTIME_ID
      raise Reach::Error, "reach: the manifest is for runtime #{runtime_id} but RuntimeKit pins #{Reach::RuntimeKit::RUNTIME_ID}"
    end

    pairs = []
    pairs << ["RUNTIME_TAG", safe("RUNTIME_TAG", Reach::RuntimeKit::RUNTIME_TAG)]
    pairs << ["RUNTIME_ID", runtime_id]
    pairs << ["RELEASE_BASE", safe("RELEASE_BASE", Reach::RuntimeKit::RELEASE_BASE)]
    pairs << ["RUBY_VERSION", safe("ruby_version", data["ruby_version"])]
    pairs << ["BUNDLER_VERSION", safe("bundler_version", data["bundler_version"])]
    profiles = Array(data["profiles"]).map do |profile|
      { "name" => safe("profile name", profile["name"]), "lock_sha256" => safe("lock_sha256", profile["lock_sha256"]),
        "gemfile_sha256" => safe("gemfile_sha256", profile["gemfile_sha256"]) }
    end
    pairs << ["PROFILES_JSON", "'#{JSON.generate(profiles)}'"]
    Reach::RuntimeKit::PLATFORMS.each do |platform|
      entry = data.fetch("platforms", {})[platform]
      next unless entry && entry["bundle"]

      suffix = platform.tr("-", "_")
      bundle = entry["bundle"]
      pairs << ["ASSET_#{suffix}", safe("asset", bundle["asset"])]
      pairs << ["SHA256_#{suffix}", safe("sha256", bundle["sha256"])]
      pairs << ["SIZE_#{suffix}", safe("size", bundle["size"])]
      pairs << ["RUBY_EXE_#{suffix}", safe("ruby_exe", bundle["ruby_exe"])]
    end
    pairs
  end

  def render(pairs)
    pairs.map { |key, value| "#{key}=#{value}\n" }.join
  end

  def parse(text)
    text.each_line.map do |line|
      key, value = line.chomp.split("=", 2)
      [key, value]
    end
  end

  def differences(pairs, committed)
    want = Hash[pairs]
    have = Hash[committed]
    problems = []
    want.each do |key, value|
      if !have.key?(key)
        problems << "#{key}: missing from exe/runtime-pins (manifest says #{value})"
      elsif have[key] != value
        problems << "#{key}: exe/runtime-pins has #{have[key]} but the manifest says #{value}"
      end
    end
    (have.keys - want.keys).each { |key| problems << "#{key}: in exe/runtime-pins but not in the manifest" }
    if problems.empty? && committed.map(&:first) != pairs.map(&:first)
      problems << "line order in exe/runtime-pins differs from the generated order"
    end
    problems
  end

  def run(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = "usage: ruby tools/runtime_pins.rb (--write | --check) [--manifest FILE]"
      opts.on("--write") { options[:mode] = :write }
      opts.on("--check") { options[:mode] = :check }
      opts.on("--manifest FILE") { |value| options[:manifest] = File.expand_path(value) }
    end
    parser.parse!(argv)
    unless options[:mode]
      warn parser.banner
      return 2
    end

    pairs = expected(load_manifest(options[:manifest]))
    if options[:mode] == :write
      File.write(PINS_PATH, render(pairs))
      puts "wrote #{PINS_PATH} (#{pairs.length} lines)"
      return 0
    end

    unless File.file?(PINS_PATH)
      warn "exe/runtime-pins does not exist"
      return 1
    end
    problems = differences(pairs, parse(File.read(PINS_PATH)))
    if problems.empty?
      puts "exe/runtime-pins matches the manifest"
      return 0
    end
    problems.each { |problem| warn problem }
    1
  rescue Reach::Error, OptionParser::ParseError, SystemCallError, JSON::ParserError => e
    warn e.message
    1
  end
end

exit RuntimePins.run(ARGV) if $PROGRAM_NAME == __FILE__
