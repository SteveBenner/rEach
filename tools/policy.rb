require "json"
require "yaml"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "../lib/reach"

operation = ARGV.shift
root = File.expand_path("..", __dir__)
source = File.join(root, "specs", "polispec", "behavior.yml")

resolve = lambda do |compiler|
  if compiler == "polispec"
    [compiler]
  elsif File.executable?(compiler) && File.extname(compiler) != ".rb"
    [File.expand_path(compiler)]
  else
    [RbConfig.ruby, File.expand_path(compiler)]
  end
end

invoke = lambda do |compiler, *arguments|
  Open3.capture3(*resolve.call(compiler), "behavior", *arguments)
end

on_path = lambda do
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, "polispec")) }
end

case operation
when "build"
  compiler = ARGV.shift || "polispec"
  abort "usage: ruby tools/policy.rb build [POLISPEC_EXECUTABLE]" unless ARGV.empty?
  output, error, status = invoke.call(compiler, "compile", source, "--root", root)
  abort error unless status.success?
  artifact = JSON.parse(output)
  Reach::BehaviorPolicy.validate_bundle!(artifact)
  guided_output, guided_error, guided_status = invoke.call(compiler, "export-package", "guided-learner")
  abort guided_error unless guided_status.success?
  guided = JSON.parse(guided_output)
  Reach::GuidedLearner.validate_bundle!(guided)
  artifact.fetch("surfaces", {}).each_key do |surface|
    _out, err, state = invoke.call(compiler, "render", source, "--surface", surface, "--root", root, "--write")
    abort err unless state.success?
  end
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
    next if row["scope"] == "repo"

    path = File.join(root, "directives", "#{row.fetch('opcode').downcase}.md")
    File.write(path, Reach::BehaviorPolicy.projection(row))
  end
  puts "compiled #{artifact.fetch('digest')}"
when "check"
  explicit = ARGV.shift
  abort "usage: ruby tools/policy.rb check [POLISPEC_EXECUTABLE]" unless ARGV.empty?
  compiler = explicit || "polispec"
  problems = Reach::BehaviorPolicy.problems
  if explicit
    begin
      installed = JSON.parse(File.read(Reach::GuidedLearner.artifact_path))
      Reach::GuidedLearner.validate_bundle!(installed)
      output, error, status = invoke.call(compiler, "export-package", "guided-learner")
      raise Reach::GuidedLearner::Invalid, error unless status.success?
      exported = JSON.parse(output)
      Reach::GuidedLearner.validate_bundle!(exported)
      raise Reach::GuidedLearner::Invalid, "installed presentation policy differs from export" unless installed.fetch("digest") == exported.fetch("digest")
    rescue StandardError => e
      problems << "R-DOC-POLICY: learner presentation export check failed (#{e.message})"
    end
  end
  if explicit || on_path.call
    output, error, status = invoke.call(compiler, "compile", source, "--root", root)
    if status.success?
      fresh = JSON.parse(output)
      problems << "R-DOC-POLICY: policy/behavior.json differs from a fresh compile of specs/polispec/behavior.yml" unless fresh == JSON.parse(File.read(File.join(root, "policy", "behavior.json")))
    else
      problems << "R-DOC-POLICY: compile failed: #{error.strip}"
    end
    drift_out, drift_err, drift_state = invoke.call(compiler, "drift", source, "--root", root)
    problems.concat((drift_err + drift_out).lines.map { |line| "R-DOC-POLICY: #{line.strip}" }.reject { |line| line.end_with?(": ") }) unless drift_state.success?
    corpus = ["--corpus", File.join(root, "locales", "en-US.yml")]
    ENV.fetch("REACH_POLICY_CORPUS", "").split(File::PATH_SEPARATOR).each do |glob|
      Dir.glob(glob).sort.each { |file| corpus.push("--corpus", file) }
    end
    lint_out, lint_err, lint_state = invoke.call(compiler, "lint", source, "--root", root, *corpus)
    problems.concat((lint_out + lint_err).lines.map { |line| "R-DOC-POLICY: lint #{line.strip}" }.reject { |line| line.end_with?("lint ") }) unless lint_state.success?
  end
  puts JSON.pretty_generate("ok" => problems.empty?, "problems" => problems)
  exit(problems.empty? ? 0 : 1)
else
  abort "usage: ruby tools/policy.rb <build [POLISPEC_EXECUTABLE]|check [POLISPEC_EXECUTABLE]>"
end
