#!/usr/bin/env ruby

require "fileutils"
require "json"
require "optparse"
require "time"

module PlatformMatrix
  SCHEMA = "reach.compat-tested/v1".freeze
  SCOPE = "commands and hook command lines; no live agent session".freeze
  HARNESSES = %w[core claude-code codex].freeze
  GROUPS = {
    "claude-code" => %w[hook_session_start hook_prompt_locked hook_prompt_open],
    "codex" => %w[hook_codex codex_sandbox_decrypt]
  }.freeze

  class InputError < StandardError; end

  def self.group_of(step_name)
    GROUPS.each { |group, names| return group if names.include?(step_name) }
    "core"
  end

  def self.load_report(path)
    report = JSON.parse(File.read(path))
    raise InputError, "#{path}: not a platform smoke report" unless report.is_a?(Hash) && report["steps"].is_a?(Array)

    report
  rescue SystemCallError, JSON::ParserError => e
    raise InputError, "#{path}: #{e.message}"
  end

  def self.environment_of(report)
    env = report["environment"]
    platform = report["platform"].to_s.split(" ")
    if env.is_a?(Hash)
      {
        "os" => env["os"].to_s,
        "os_release" => env["os_release"].to_s,
        "arch" => env["arch"].to_s,
        "ruby" => env["ruby"].to_s
      }
    else
      {
        "os" => platform[0].to_s,
        "os_release" => (env.is_a?(String) ? env : report["os_version"]).to_s,
        "arch" => platform[1].to_s,
        "ruby" => report["ruby_version"].to_s
      }
    end
  end

  def self.verdicts(steps)
    grouped = Hash.new { |h, k| h[k] = [] }
    steps.each do |step|
      next unless step.is_a?(Hash)

      grouped[group_of(step["name"].to_s)] << step
    end
    results = {}
    HARNESSES.each do |group|
      list = grouped[group]
      failed = list.select { |s| s["result"] == "fail" }.map { |s| s["name"].to_s }
      passed = list.count { |s| s["result"] == "pass" }
      results[group] = { passed: passed, failed: failed, skipped: list.select { |s| s["result"] == "skip" }.map { |s| s["name"].to_s } }
    end
    core_ok = results["core"][:failed].empty? && results["core"][:passed].positive?
    HARNESSES.map do |group|
      data = results[group]
      ok = data[:failed].empty? && data[:passed].positive?
      ok &&= core_ok unless group == "core"
      names = data[:failed].dup
      names = data[:skipped].dup if names.empty? && !ok && data[:passed].zero?
      names = ["core"] if names.empty? && !ok && !core_ok && group != "core"
      [group, ok ? "pass" : "fail", ok ? [] : names]
    end
  end

  def self.cells(report)
    env = environment_of(report)
    verdicts(report["steps"]).map do |group, result, failed|
      {
        "leg" => report["leg"].to_s.empty? ? report["platform"].to_s : report["leg"].to_s,
        "os" => env["os"],
        "os_release" => env["os_release"],
        "arch" => env["arch"],
        "ruby" => env["ruby"],
        "harness" => group,
        "result" => result,
        "failed_steps" => failed
      }
    end
  end

  def self.markdown(doc)
    rows = doc["cells"].group_by { |c| [c["leg"], c["os_release"]] }
    lines = []
    lines << "# Tested compatibility matrix"
    lines << ""
    lines << "rEach #{doc['reach_version']} at #{doc['commit']}, generated #{doc['generated_at']}."
    lines << ""
    lines << "Scope: #{doc['scope']}."
    lines << ""
    lines << "| Leg | OS release | core | claude-code | codex |"
    lines << "| --- | --- | --- | --- | --- |"
    rows.each do |(leg, release), cells|
      columns = HARNESSES.map do |harness|
        cell = cells.find { |c| c["harness"] == harness }
        next "" unless cell

        text = cell["result"]
        text += " (#{cell['failed_steps'].join(', ')})" unless cell["failed_steps"].empty?
        text
      end
      lines << "| #{[leg, release, *columns].map { |v| v.to_s.gsub('|', '\\|') }.join(' | ')} |"
    end
    lines.join("\n") + "\n"
  end

  def self.build(reports)
    first = reports.first
    {
      "schema" => SCHEMA,
      "reach_version" => first["reach_version"].to_s.empty? ? "unknown" : first["reach_version"].to_s,
      "commit" => first["commit"].to_s.empty? ? "unknown" : first["commit"].to_s,
      "generated_at" => Time.now.utc.iso8601,
      "scope" => SCOPE,
      "cells" => reports.flat_map { |r| cells(r) }
    }
  end

  def self.main(argv)
    out = nil
    OptionParser.new { |parser| parser.on("--out DIR") { |value| out = value } }.parse!(argv)
    raise InputError, "usage: matrix.rb --out DIR REPORT.json..." if out.nil? || argv.empty?

    doc = build(argv.map { |path| load_report(path) })
    FileUtils.mkdir_p(out)
    File.write(File.join(out, "compat-tested.json"), JSON.pretty_generate(doc) + "\n")
    File.write(File.join(out, "compat-tested.md"), markdown(doc))
    0
  rescue InputError, OptionParser::ParseError, SystemCallError => e
    warn "matrix: #{e.message}"
    2
  end
end

exit PlatformMatrix.main(ARGV) if $PROGRAM_NAME == __FILE__
