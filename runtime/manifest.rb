require "digest"
require "json"
require "optparse"

CHROME_VERSION = "154.0.8037.92"
BUNDLER_VERSION = "4.0.19"
LOCKS_DIR = File.expand_path("locks", __dir__)

PLATFORMS = {
  "macos-arm64" => { cft: "mac-arm64", exe: "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" },
  "macos-x86_64" => { cft: "mac-x64", exe: "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" },
  "linux-x86_64" => { cft: "linux64", exe: "chrome-linux64/chrome" },
  "linux-arm64" => { cft: nil, exe: nil },
  "windows-x86_64" => { cft: "win64", exe: "chrome-win64/chrome.exe" }
}.freeze

def fail_with(message)
  warn("manifest: #{message}")
  exit(1)
end

def sort_keys(value)
  case value
  when Hash then value.keys.sort.each_with_object({}) { |k, h| h[k] = sort_keys(value[k]) }
  when Array then value.map { |v| sort_keys(v) }
  else value
  end
end

options = {}
OptionParser.new do |o|
  o.on("--runtime-id ID") { |v| options[:runtime_id] = v }
  o.on("--ruby-version V") { |v| options[:ruby_version] = v }
  o.on("--asset-dir DIR") { |v| options[:asset_dir] = v }
  o.on("--cft-dir DIR") { |v| options[:cft_dir] = v }
  o.on("--out FILE") { |v| options[:out] = v }
end.parse!

%i[runtime_id ruby_version asset_dir cft_dir out].each do |key|
  fail_with("missing --#{key.to_s.tr('_', '-')}") unless options[key]
end

profiles = Dir.children(LOCKS_DIR).sort.select { |n| File.file?(File.join(LOCKS_DIR, n, "Gemfile.lock")) }.map do |name|
  {
    "name" => name,
    "lock_sha256" => Digest::SHA256.file(File.join(LOCKS_DIR, name, "Gemfile.lock")).hexdigest,
    "gemfile_sha256" => Digest::SHA256.file(File.join(LOCKS_DIR, name, "Gemfile")).hexdigest
  }
end

platforms = {}
PLATFORMS.each do |platform, info|
  meta_path = File.join(options[:asset_dir], "reach-runtime-#{options[:runtime_id]}-#{platform}.tar.gz.json")
  next unless File.file?(meta_path)

  meta = JSON.parse(File.read(meta_path))
  chrome = nil
  if info[:cft]
    zip = File.join(options[:cft_dir], "chrome-#{info[:cft]}.zip")
    fail_with("missing #{zip}") unless File.file?(zip)
    chrome = {
      "url" => "https://storage.googleapis.com/chrome-for-testing-public/#{CHROME_VERSION}/#{info[:cft]}/chrome-#{info[:cft]}.zip",
      "sha256" => Digest::SHA256.file(zip).hexdigest,
      "size" => File.size(zip),
      "exe" => info[:exe]
    }
  end
  platforms[platform] = {
    "bundle" => meta.slice("asset", "sha256", "size", "ruby_exe"),
    "chrome" => chrome
  }
end
fail_with("no platform assets found in #{options[:asset_dir]}") if platforms.empty?

manifest = {
  "schema" => "reach.runtime-manifest/v1",
  "runtime_id" => options[:runtime_id],
  "ruby_version" => options[:ruby_version],
  "bundler_version" => BUNDLER_VERSION,
  "chrome_version" => CHROME_VERSION,
  "profiles" => profiles,
  "platforms" => platforms
}
body = JSON.pretty_generate(sort_keys(manifest)) + "\n"
File.write(options[:out], body)
puts Digest::SHA256.hexdigest(body)
