#!/usr/bin/env ruby

require "json"
require "optparse"
require "fileutils"
require "rbconfig"
require "securerandom"
require "open3"
require "timeout"
require "time"

HARNESS_TIMEOUT_S = 120

options = { resume: false }
OptionParser.new do |parser|
  parser.on("--staged DIR") { |value| options[:staged] = value }
  parser.on("--destination DIR") { |value| options[:destination] = value }
  parser.on("--manifest FILE") { |value| options[:manifest] = value }
  parser.on("--from VERSION") { |value| options[:from] = value }
  parser.on("--to VERSION") { |value| options[:to] = value }
  parser.on("--resume") { options[:resume] = true }
end.parse!(ARGV)

%i[destination manifest from to].each do |key|
  next unless options[key].to_s.empty?

  warn "apply: --#{key} is required"
  exit 2
end

destination = File.expand_path(options[:destination])
staged = options[:staged].to_s.empty? ? nil : File.expand_path(options[:staged])
manifest_file = File.expand_path(options[:manifest])
from = options[:from]
to = options[:to]

def read_manifest(file)
  parsed = JSON.parse(File.read(file))
  parsed.is_a?(Hash) ? parsed : {}
rescue StandardError
  {}
end

def save_manifest(file, manifest)
  manifest["updated_at"] = Time.now.utc.iso8601
  FileUtils.mkdir_p(File.dirname(file))
  temp = "#{file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
  File.open(temp, "w", 0o600) { |handle| handle.write(JSON.pretty_generate(manifest)) }
  File.rename(temp, file)
end

def on_path(name)
  extensions = RbConfig::CONFIG["host_os"].to_s =~ /mswin|mingw|cygwin/ ? ["", ".exe", ".cmd", ".bat"] : [""]
  ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
    next if dir.empty?

    extensions.each do |extension|
      candidate = File.join(dir, "#{name}#{extension}")
      return candidate if File.executable?(candidate) && !File.directory?(candidate)
    end
  end
  nil
end

def run_step(command)
  Timeout.timeout(HARNESS_TIMEOUT_S) do
    _out, err, status = Open3.capture3(*command)
    return nil if status.success?

    err.to_s.lines.map(&:strip).reject(&:empty?).first || "exit #{status.exitstatus}"
  end
rescue Timeout::Error
  "timed out"
rescue StandardError => e
  e.message
end

def refresh_harness(executable, steps)
  path = on_path(executable)
  return "absent" unless path

  steps.each do |step|
    failure = run_step([path] + step)
    return "failed: #{failure}" if failure
  end
  "ok"
end

manifest = read_manifest(manifest_file)
resuming = options[:resume] || %w[swapped refreshed].include?(manifest["phase"])

unless resuming
  unless staged && File.file?(File.join(staged, "VERSION")) && File.read(File.join(staged, "VERSION")).strip == to
    warn "apply: staged release does not carry VERSION #{to}"
    exit 1
  end
  backup = File.join(File.dirname(destination), ".backup", "plugin-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}")
  FileUtils.mkdir_p(File.dirname(backup))
  manifest["backup_path"] = backup
  save_manifest(manifest_file, manifest)
  begin
    File.rename(destination, backup) if File.exist?(destination)
    File.rename(staged, destination)
  rescue StandardError => e
    File.rename(backup, destination) if File.exist?(backup) && !File.exist?(destination)
    warn "apply: swap failed: #{e.message}"
    exit 1
  end
  manifest["phase"] = "swapped"
  save_manifest(manifest_file, manifest)
end

migrations_done = Array(manifest["migrations_done"])
pending = Dir[File.join(destination, "update", "migrations", "*.rb")].map do |path|
  name = File.basename(path, ".rb")
  version = begin
    Gem::Version.new(name)
  rescue ArgumentError
    nil
  end
  [version, name, path]
end
pending = pending.select { |version, _name, _path| version && Gem::Version.new(from) < version && version <= Gem::Version.new(to) }
pending.sort_by! { |version, _name, _path| version }
pending.each do |_version, name, path|
  next if migrations_done.include?(name)

  unless system(RbConfig.ruby, path, "--destination", destination, "--from", from, "--to", to)
    warn "apply: migration #{name} failed"
    exit 1
  end
  migrations_done << name
  manifest["migrations_done"] = migrations_done
  save_manifest(manifest_file, manifest)
end

home = File.dirname(destination)
bin = File.join(home, "bin")
File.write(File.join(bin, "root"), "#{destination}\n") if File.directory?(bin)

results = manifest["harness_results"]
results = {} unless results.is_a?(Hash)
results["claude-code"] = refresh_harness("claude", [%w[plugin marketplace update reach], %w[plugin update reach@reach --scope user]])
codex_path = on_path("codex")
run_step([codex_path, "plugin", "marketplace", "upgrade", "reach"]) if codex_path
results["codex"] = refresh_harness("codex", [%w[plugin add reach@reach]])
codex_home = ENV["CODEX_HOME"].to_s
Dir.glob(File.join(File.expand_path(codex_home.empty? ? "~/.codex" : codex_home), "plugins", "cache", "*", "reach", "*", "plugin.json")).each do |cached|
  next unless File.file?(File.join(File.dirname(cached), ".codex-plugin", "plugin.json"))

  begin
    File.rename(cached, File.join(File.dirname(cached), "plugin.json.agent-plugins"))
  rescue SystemCallError
    nil
  end
end
manifest["harness_results"] = results
manifest["phase"] = "refreshed"
save_manifest(manifest_file, manifest)

manifest["phase"] = "completed"
manifest["completed_version"] = to
manifest["completed_at"] = Time.now.utc.iso8601
save_manifest(manifest_file, manifest)
puts "rEach updated to #{to}"
exit 0
