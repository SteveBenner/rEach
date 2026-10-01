require "fileutils"
require "json"
require "rbconfig"
require "optparse"
require "tmpdir"

CHROME_EXES = {
  "chrome-linux64.zip" => "chrome-linux64/chrome",
  "chrome-mac-arm64.zip" => "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
  "chrome-mac-x64.zip" => "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
  "chrome-win64.zip" => "chrome-win64/chrome.exe"
}.freeze

FERRUM_SCRIPT = <<~'RUBY'.freeze
  require "ferrum"
  options = { "no-sandbox" => nil } if RbConfig::CONFIG["host_os"] =~ /linux/
  browser = Ferrum::Browser.new(browser_path: ENV.fetch("RELOCATE_CHROME"), headless: true,
                                process_timeout: 30, browser_options: options || {})
  begin
    browser.go_to("data:text/html,<p id=x>hi</p>")
    text = browser.at_css("#x").text
    abort("ferrum page text was #{text.inspect}") unless text == "hi"
    puts text
  ensure
    browser.quit
  end
RUBY

def tar_command
  return "tar" unless RbConfig::CONFIG["host_os"] =~ /mswin|mingw/

  bsdtar = File.join(ENV.fetch("SystemRoot", "C:/Windows"), "System32", "tar.exe")
  File.file?(bsdtar) ? bsdtar : "tar"
end

def fail_with(message)
  warn("relocate_check: #{message}")
  exit(1)
end

GLIBC_CEILING = Gem::Version.new("2.28")

def elf?(path)
  File.file?(path) && !File.symlink?(path) && File.open(path, "rb") { |f| f.read(4) } == "\x7FELF".b
end

def glibc_ceiling(runtime)
  fail_with("objdump is required for the glibc check") unless system("objdump", "--version", out: File::NULL, err: File::NULL)
  worst = nil
  worst_file = nil
  Dir.glob(File.join(runtime, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
    next unless elf?(path)

    out = IO.popen(["objdump", "-T", path], err: File::NULL, &:read)
    out.scan(/GLIBC_(\d+(?:\.\d+)*)/).flatten.uniq.each do |text|
      version = Gem::Version.new(text)
      worst, worst_file = version, path if worst.nil? || version > worst
      fail_with("#{path.sub("#{runtime}/", '')} requires GLIBC_#{text}, above #{GLIBC_CEILING}") if version > GLIBC_CEILING
    end
  end
  [worst, worst_file]
end

def capture(env, *cmd)
  IO.popen(env, cmd, err: [:child, :out], &:read).tap do
    fail_with("command failed: #{cmd.join(' ')}\n#{$?.inspect}") unless $?.success?
  end
end

def remove_tree(dir)
  attempts = 0
  begin
    FileUtils.remove_entry(dir)
  rescue Errno::EACCES, Errno::EBUSY, Errno::ENOTEMPTY => e
    attempts += 1
    if attempts < 30
      sleep(2)
      retry
    end
    warn("relocate_check: left #{dir} behind: #{e.message}")
  end
end

chrome_zip = nil
parser = OptionParser.new { |o| o.on("--chrome-zip PATH") { |v| chrome_zip = File.expand_path(v) } }
args = parser.parse(ARGV)
fail_with("usage: relocate_check.rb TARBALL [--chrome-zip PATH]") unless args.length == 1
tarball = File.expand_path(args.first)
fail_with("no such file #{tarball}") unless File.file?(tarball)

dir = Dir.mktmpdir("relocated-")
begin
  target = File.join(dir, "elsewhere", "deep", "location")
  FileUtils.mkdir_p(target)
  fail_with("tar extraction failed") unless system(tar_command, "-xzf", tarball, "-C", target)

  runtime = File.join(target, "runtime")
  build = JSON.parse(File.read(File.join(runtime, "BUILD.json")))
  exe_suffix = build["platform"].start_with?("windows") ? ".exe" : ""
  ruby = File.join(runtime, "ruby", "bin", "ruby#{exe_suffix}")
  bundle = File.join(runtime, "ruby", "bin", "bundle")
  profile = build["profiles"].first
  gems_dir = File.join(runtime, "gems", profile["lock12"])

  clean = %w[GEM_HOME GEM_PATH RUBYOPT RUBYLIB BUNDLE_DEPLOYMENT BUNDLE_WITHOUT BUNDLER_VERSION].each_with_object({}) { |k, h| h[k] = nil }
  env = clean.merge(
    "PATH" => [File.join(runtime, "ruby", "bin"), ENV["PATH"]].join(File::PATH_SEPARATOR),
    "BUNDLE_GEMFILE" => File.join(gems_dir, "Gemfile"),
    "BUNDLE_PATH" => gems_dir,
    "BUNDLE_FROZEN" => "true"
  )

  if build["platform"].start_with?("linux")
    worst, worst_file = glibc_ceiling(runtime)
    puts("glibc ceiling GLIBC_#{worst} (#{worst_file&.sub("#{runtime}/", '')}), limit #{GLIBC_CEILING}")
  end

  version = capture(env, ruby, "-e", "puts RUBY_VERSION").strip
  puts(version)
  fail_with("ruby version is #{version}, expected #{build['ruby_version']}") unless version == build["ruby_version"]

  requires = 'require "nokogiri"; require "ffi"; require "bigdecimal"; require "racc/parser"; ' \
             'require "capybara"; require "capybara/cuprite"; puts :ok'
  ok = capture(env, ruby, bundle, "exec", "ruby", "-e", requires).strip.lines.last.to_s.strip
  puts(ok)
  fail_with("gem load printed #{ok.inspect}") unless ok == "ok"

  if chrome_zip
    exe_rel = CHROME_EXES.fetch(File.basename(chrome_zip)) { fail_with("unknown chrome zip #{File.basename(chrome_zip)}") }
    chrome_dir = File.join(dir, "chrome")
    FileUtils.mkdir_p(chrome_dir)
    extracted = system("unzip", "-q", chrome_zip, "-d", chrome_dir) || system(tar_command, "-xf", chrome_zip, "-C", chrome_dir)
    fail_with("could not extract #{chrome_zip}") unless extracted
    chrome = File.join(chrome_dir, exe_rel)
    fail_with("no chrome at #{chrome}") unless File.file?(chrome)
    File.chmod(0o755, chrome) unless chrome.end_with?(".exe")
    script = File.join(dir, "ferrum_check.rb")
    File.write(script, FERRUM_SCRIPT)
    text = capture(env.merge("RELOCATE_CHROME" => chrome), ruby, bundle, "exec", "ruby", script).strip.lines.last.to_s.strip
    puts(text)
    fail_with("ferrum text was #{text.inspect}") unless text == "hi"
  end
ensure
  remove_tree(dir)
end
puts "relocate_check passed"
