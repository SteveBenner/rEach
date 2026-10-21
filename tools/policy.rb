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
  invocation = if compiler == "polispec"
    [compiler]
  elsif File.executable?(compiler) && File.extname(compiler) != ".rb"
    [File.expand_path(compiler)]
  else
    [RbConfig.ruby, File.expand_path(compiler)]
  end
  output, error, status = Open3.capture3(*invocation, "behavior", "compile", source)
  abort error unless status.success?
  artifact = JSON.parse(output)
  Reach::BehaviorPolicy.validate_bundle!(artifact)
  guided_output, guided_error, guided_status = Open3.capture3(*invocation, "behavior", "export-package", "guided-learner")
  abort guided_error unless guided_status.success?
  guided = JSON.parse(guided_output)
  Reach::GuidedLearner.validate_bundle!(guided)
  directory = File.join(root, "policy")
  FileUtils.mkdir_p(directory)
  destination = File.join(directory, "behavior.json")
  temporary = "#{destination}.#{Process.pid}.tmp"
  File.write(temporary, JSON.pretty_generate(artifact) + "\n")
  File.rename(temporary, destination)
  guided_destination = File.join(directory, "guided-learner.json")
  guided_temporary = "#{guided_destination}.#{Process.pid}.tmp"
  File.write(guided_temporary, JSON.pretty_generate(guided) + "\n")
  File.rename(guided_temporary, guided_destination)
  artifact.fetch("policy").fetch("directives").each do |row|
    path = File.join(root, "directives", "#{row.fetch('opcode').downcase}.md")
    File.write(path, Reach::BehaviorPolicy.projection(row))
  end
  puts "compiled #{artifact.fetch('digest')}"
when "check"
  compiler = ARGV.shift
  abort "usage: ruby tools/policy.rb check [POLISPEC_EXECUTABLE]" unless ARGV.empty?
  problems = Reach::BehaviorPolicy.problems
  if compiler
    begin
    installed = JSON.parse(File.read(Reach::GuidedLearner.artifact_path))
    Reach::GuidedLearner.validate_bundle!(installed)
      invocation = if compiler == "polispec"
        [compiler]
      elsif File.executable?(compiler) && File.extname(compiler) != ".rb"
        [File.expand_path(compiler)]
      else
        [RbConfig.ruby, File.expand_path(compiler)]
      end
      output, error, status = Open3.capture3(*invocation, "behavior", "export-package", "guided-learner")
      raise Reach::GuidedLearner::Invalid, error unless status.success?
      exported = JSON.parse(output)
      Reach::GuidedLearner.validate_bundle!(exported)
      raise Reach::GuidedLearner::Invalid, "installed presentation policy differs from export" unless installed.fetch("digest") == exported.fetch("digest")
    rescue StandardError => e
      problems << "R-DOC-POLICY: learner presentation export check failed (#{e.message})"
    end
  end
  puts JSON.pretty_generate("ok" => problems.empty?, "problems" => problems)
  exit(problems.empty? ? 0 : 1)
else
  abort "usage: ruby tools/policy.rb <build [POLISPEC_EXECUTABLE]|check>"
end
