#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "optparse"
require "tmpdir"
require "timeout"
require_relative "kit"

ROOT = File.expand_path("../..", __dir__)
opts = { out: File.join(ROOT, "docs", "assets", "figures"), png: false, only: nil, png_width: 3840, chrome: ENV["REACH_FIGURES_CHROME"] }
OptionParser.new do |o|
  o.banner = "ruby tools/figures/build.rb [--png] [--only SLUG] [--out DIR] [--png-width PX] [--chrome PATH]"
  o.on("--png") { opts[:png] = true }
  o.on("--only SLUG") { |v| opts[:only] = v }
  o.on("--out DIR") { |v| opts[:out] = File.expand_path(v) }
  o.on("--png-width PX", Integer) { |v| opts[:png_width] = v }
  o.on("--chrome PATH") { |v| opts[:chrome] = v }
end.parse!

Dir[File.join(__dir__, "figures", "*.rb")].sort.each { |f| require f }

def find_chrome(given)
  return given if given

  %w[google-chrome google-chrome-stable chromium chromium-browser chrome].each do |name|
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
      path = File.join(dir, name)
      return path if File.executable?(path)
    end
  end
  mac = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  File.executable?(mac) ? mac : nil
end

def render_png(chrome, svg_path, png_path, width, height, scale)
  Dir.mktmpdir("reach-fig") do |profile|
    cmd = [chrome, "--headless=new", "--disable-gpu", "--no-first-run", "--hide-scrollbars",
           "--user-data-dir=#{profile}", "--force-device-scale-factor=#{scale}",
           "--window-size=#{width},#{height}", "--screenshot=#{png_path}", "file://#{svg_path}"]
    pid = Process.spawn(*cmd, out: File::NULL, err: File::NULL)
    begin
      Timeout.timeout(90) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("KILL", pid)
      Process.wait(pid)
      return false
    end
  end
  File.file?(png_path) && File.size(png_path).positive?
end

figures = Figures::REGISTRY.select { |f| opts[:only].nil? || f[:slug].include?(opts[:only]) }
abort "no figure matches #{opts[:only]}" if figures.empty?

FileUtils.mkdir_p(opts[:out])
chrome = opts[:png] ? find_chrome(opts[:chrome]) : nil
abort "no Chrome found; pass --chrome PATH or set REACH_FIGURES_CHROME" if opts[:png] && chrome.nil?
png_dir = File.join(opts[:out], "png")
FileUtils.mkdir_p(png_dir) if opts[:png]

failed = 0
figures.each do |fig|
  Figures::THEMES.each_key do |theme|
    svg_path = File.join(opts[:out], "#{fig[:slug]}-#{theme}.svg")
    File.write(svg_path, Figures.render(fig, theme))
    line = "svg #{File.basename(svg_path)}"
    if opts[:png]
      png_path = File.join(png_dir, "#{fig[:slug]}-#{theme}.png")
      scale = (opts[:png_width].to_f / fig[:width]).round(4)
      if render_png(chrome, svg_path, png_path, fig[:width], fig[:height], scale)
        line += "  png #{File.basename(png_path)} #{File.size(png_path) / 1024} KiB"
      else
        line += "  png FAILED"
        failed += 1
      end
    end
    puts line
  end
end
exit(failed.zero? ? 0 : 1)
