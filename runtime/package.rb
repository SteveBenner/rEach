require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "time"
require "tmpdir"

BUNDLER_VERSION = "4.0.19"
LOCKS_DIR = File.expand_path("locks", __dir__)
CLEAN_ENV_KEYS = %w[GEM_HOME GEM_PATH GEM_ROOT RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_FROZEN
                    BUNDLE_DEPLOYMENT BUNDLE_APP_CONFIG BUNDLE_WITHOUT BUNDLER_VERSION].freeze

def tar_command
  return "tar" unless RbConfig::CONFIG["host_os"] =~ /mswin|mingw/

  bsdtar = File.join(ENV.fetch("SystemRoot", "C:/Windows"), "System32", "tar.exe")
  File.file?(bsdtar) ? bsdtar : "tar"
end

def fail_with(message)
  warn("package: #{message}")
  exit(1)
end

def run!(env, *cmd)
  puts("+ #{cmd.join(' ')}")
  $stdout.flush
  status = system(env, *cmd)
  fail_with("command failed: #{cmd.join(' ')}") unless status
end

def capture!(env, *cmd)
  out, err, status = Open3.capture3(env, *cmd)
  fail_with("command failed: #{cmd.join(' ')}\n#{err}") unless status.success?
  out.strip
end

options = {}
OptionParser.new do |o|
  o.on("--platform P") { |v| options[:platform] = v }
  o.on("--runtime-id ID") { |v| options[:runtime_id] = v }
  o.on("--ruby-dir DIR") { |v| options[:ruby_dir] = v }
  o.on("--out DIR") { |v| options[:out] = v }
end.parse!

%i[platform runtime_id ruby_dir out].each do |key|
  fail_with("missing --#{key.to_s.tr('_', '-')}") unless options[key]
end

platform = options[:platform]
windows = platform.start_with?("windows")
linux = platform.start_with?("linux")
exe_suffix = windows ? ".exe" : ""
ruby_dir = File.expand_path(options[:ruby_dir])
out_dir = File.expand_path(options[:out])
fail_with("no ruby at #{ruby_dir}/bin/ruby#{exe_suffix}") unless File.file?(File.join(ruby_dir, "bin", "ruby#{exe_suffix}"))

profiles = Dir.children(LOCKS_DIR).sort.select { |name| File.file?(File.join(LOCKS_DIR, name, "Gemfile.lock")) }
fail_with("no lock profiles under #{LOCKS_DIR}") if profiles.empty?

FileUtils.mkdir_p(out_dir)
asset = "reach-runtime-#{options[:runtime_id]}-#{platform}.tar.gz"
asset_path = File.join(out_dir, asset)

Dir.mktmpdir("reach-runtime-stage") do |stage|
  runtime = File.join(stage, "runtime")
  staged_ruby = File.join(runtime, "ruby")
  FileUtils.mkdir_p(runtime)
  FileUtils.mkdir_p(staged_ruby)
  FileUtils.cp_r(File.join(ruby_dir, "."), staged_ruby)
  ruby = File.join(staged_ruby, "bin", "ruby#{exe_suffix}")
  bin = File.join(staged_ruby, "bin")

  base_env = CLEAN_ENV_KEYS.each_with_object({}) { |key, h| h[key] = nil }
  base_env["PATH"] = [bin, ENV["PATH"]].join(File::PATH_SEPARATOR)
  default_gem_dir = capture!(base_env, ruby, "-e", "print Gem.default_dir")
  base_env["GEM_HOME"] = default_gem_dir
  base_env["GEM_PATH"] = default_gem_dir

  ruby_version = capture!(base_env, ruby, "-e", "print RUBY_VERSION")
  local_platform = capture!(base_env, ruby, "-e", "print Gem::Platform.local.to_s")
  puts("ruby #{ruby_version} on #{local_platform}")

  run!(base_env, ruby, File.join(bin, "gem"), "install", "bundler", "-v", BUNDLER_VERSION, "--no-document", "--force")
  bundler_version = capture!(base_env, ruby, File.join(bin, "bundle"), "_#{BUNDLER_VERSION}_", "--version")
  fail_with("bundler #{bundler_version} is not #{BUNDLER_VERSION}") unless bundler_version.include?(BUNDLER_VERSION)

  entries = []
  profiles.each do |name|
    lock_bytes = File.binread(File.join(LOCKS_DIR, name, "Gemfile.lock")).gsub("\r\n".b, "\n".b)
    gemfile_bytes = File.binread(File.join(LOCKS_DIR, name, "Gemfile"))
    lock_sha = Digest::SHA256.hexdigest(lock_bytes)
    gemfile_sha = Digest::SHA256.hexdigest(gemfile_bytes)
    lock12 = lock_sha[0, 12]
    gems_dir = File.join(runtime, "gems", lock12)
    FileUtils.mkdir_p(gems_dir)
    gemfile = File.join(gems_dir, "Gemfile")
    File.binwrite(gemfile, gemfile_bytes)
    File.binwrite(File.join(gems_dir, "Gemfile.lock"), lock_bytes)

    env = base_env.merge("BUNDLE_PATH" => gems_dir, "BUNDLE_GEMFILE" => gemfile)
    bundle = [ruby, File.join(bin, "bundle")]

    covered = lock_bytes.scan(/^PLATFORMS\n((?:  .+\n)+)/).flatten.first.to_s.split("\n").map(&:strip).any? do |entry|
      entry != "ruby" && Gem::Platform.new(entry) === Gem::Platform.new(local_platform)
    end
    run!(env, *bundle, "lock", "--add-platform", local_platform) unless covered

    run!(env, *bundle, "config", "set", "--local", "force_ruby_platform", "true") if linux

    run!(env, *bundle, "install", "--jobs", "4")
    entries << { "name" => name, "lock12" => lock12, "lock_sha256" => lock_sha, "gemfile_sha256" => gemfile_sha,
                 "platform_added" => !covered }
  end

  build = {
    "runtime_id" => options[:runtime_id],
    "platform" => platform,
    "ruby_version" => ruby_version,
    "bundler_version" => BUNDLER_VERSION,
    "built_at" => Time.now.utc.iso8601,
    "profiles" => entries
  }
  File.write(File.join(runtime, "BUILD.json"), JSON.pretty_generate(build) + "\n")

  FileUtils.rm_f(asset_path)
  run!({}, tar_command, "-czf", asset_path, "-C", stage, "runtime")
end

sha = Digest::SHA256.file(asset_path).hexdigest
size = File.size(asset_path)
meta = { "asset" => asset, "sha256" => sha, "size" => size, "ruby_exe" => "runtime/ruby/bin/ruby#{exe_suffix}" }
File.write(File.join(out_dir, "#{asset}.json"), JSON.pretty_generate(meta) + "\n")
puts("wrote #{asset_path} #{size} bytes sha256 #{sha}")
