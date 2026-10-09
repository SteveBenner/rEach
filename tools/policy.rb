require "json"
require "yaml"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "../lib/reach"

operation = ARGV.shift
root = File.expand_path("..", __dir__)
case operation
when "build"
  compiler = ARGV.shift || "polispec"
  abort "usage: ruby tools/policy.rb build [POLISPEC_EXECUTABLE]" unless ARGV.empty?
  source = File.join(root, "specs", "polispec", "behavior.yml")
  invocation = compiler == "polispec" ? [compiler] : [RbConfig.ruby, File.expand_path(compiler)]
  output, error, status = Open3.capture3(*invocation, "behavior", "compile", source)
  abort error unless status.success?
  artifact = JSON.parse(output)
  Reach::BehaviorPolicy.validate_bundle!(artifact)
  directory = File.join(root, "policy")
  FileUtils.mkdir_p(directory)
  destination = File.join(directory, "behavior.json")
  temporary = "#{destination}.#{Process.pid}.tmp"
  File.write(temporary, JSON.pretty_generate(artifact) + "\n")
  File.rename(temporary, destination)
  artifact.fetch("policy").fetch("directives").each do |row|
    path = File.join(root, "directives", "#{row.fetch('opcode').downcase}.md")
    File.write(path, Reach::BehaviorPolicy.projection(row))
  end
  puts "compiled #{artifact.fetch('digest')}"
when "check"
  abort "usage: ruby tools/policy.rb check" unless ARGV.empty?
  problems = Reach::BehaviorPolicy.problems
  puts JSON.pretty_generate("ok" => problems.empty?, "problems" => problems)
  exit(problems.empty? ? 0 : 1)
else
  abort "usage: ruby tools/policy.rb <build [POLISPEC_EXECUTABLE]|check>"
end
