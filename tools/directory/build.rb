#!/usr/bin/env ruby

require "json"
require "zlib"
require "fileutils"

root = File.expand_path("../..", __dir__)
source = File.join(root, "directory")
version = File.read(File.join(root, "VERSION")).strip
out_dir = File.join(root, ".scratch", "directory")
out_path = File.join(out_dir, "reach-installer-#{version}.zip")

manifest = JSON.parse(File.read(File.join(source, "plugin.json")))
openai = manifest.fetch("extensions", {}).fetch("com.openai", {})
forbidden = %w[hooks apps mcpServers].select { |key| manifest.key?(key) || openai.key?(key) }
abort "directory/plugin.json declares #{forbidden.join(', ')}, which the OpenAI directory refuses" unless forbidden.empty?
banned = Dir.glob(File.join(source, "**", "{hooks,.app.json,mcp.json,.codex-plugin}"), File::FNM_DOTMATCH)
abort "directory/ holds #{banned.map { |p| p.sub("#{source}/", '') }.join(', ')}, which the OpenAI directory refuses" unless banned.empty?
manifest["version"] = version

files = Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH)
           .select { |path| File.file?(path) && File.basename(path) != "SUBMISSION.md" }
           .sort
entries = files.map do |path|
  name = path.sub("#{source}/", "")
  data = name == "plugin.json" ? "#{JSON.pretty_generate(manifest)}\n" : File.binread(path)
  [name, data.b]
end

FileUtils.mkdir_p(out_dir)
time = Time.now
dos_time = (time.hour << 11) | (time.min << 5) | (time.sec / 2)
dos_date = ((time.year - 1980) << 9) | (time.month << 5) | time.day
body = "".b
central = "".b
entries.each do |name, data|
  crc = Zlib.crc32(data)
  deflater = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS)
  packed = deflater.deflate(data, Zlib::FINISH)
  deflater.close
  offset = body.bytesize
  body << [0x04034b50, 20, 0x0800, 8, dos_time, dos_date, crc, packed.bytesize, data.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv")
  body << name.b << packed
  central << [0x02014b50, 20, 20, 0x0800, 8, dos_time, dos_date, crc, packed.bytesize, data.bytesize, name.bytesize, 0, 0, 0, 0, 0o100644 << 16, offset].pack("VvvvvvvVVVvvvvvVV")
  central << name.b
end
ending = [0x06054b50, 0, 0, entries.size, entries.size, central.bytesize, body.bytesize, 0].pack("VvvvvVVv")
File.binwrite(out_path, body + central + ending)
puts out_path
entries.each { |name, data| puts "  #{name} (#{data.bytesize} bytes)" }
