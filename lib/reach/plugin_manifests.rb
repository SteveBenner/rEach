# frozen_string_literal: true

require "json"
require "fileutils"

module Reach
  module PluginManifests
    FILES = %w[
      .claude-plugin/marketplace.json
      .agents/plugins/marketplace.json
      .antigravity-plugin/plugin.json
    ].freeze

    module_function

    def render(root)
      plugin = read_plugin(root)
      version = read_version(root)
      return nil unless plugin && version

      {
        FILES[0] => encode(claude_marketplace(plugin, version)),
        FILES[1] => encode(codex_marketplace(plugin)),
        FILES[2] => encode(antigravity_plugin(plugin, version))
      }
    end

    def write!(root)
      rendered = render(root)
      return [] unless rendered

      written = []
      rendered.each do |relative, content|
        target = File.join(root, relative)
        next if File.file?(target) && File.binread(target) == content.b

        FileUtils.mkdir_p(File.dirname(target))
        temp = "#{target}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        begin
          File.open(temp, "wb") { |handle| handle.write(content) }
          File.rename(temp, target)
        rescue SystemCallError
          File.delete(temp) if File.exist?(temp)
          raise
        end
        written << relative
      end
      written
    end

    def encode(data)
      "#{JSON.pretty_generate(data)}\n"
    end

    def read_plugin(root)
      file = File.join(root, ".claude-plugin", "plugin.json")
      return nil unless File.file?(file)

      parsed = JSON.parse(File.read(file, encoding: "UTF-8"))
      parsed.is_a?(Hash) && parsed["name"].to_s != "" ? parsed : nil
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def read_version(root)
      file = File.join(root, "VERSION")
      return nil unless File.file?(file)

      text = File.read(file, encoding: "UTF-8").strip
      text.empty? ? nil : text
    rescue SystemCallError
      nil
    end

    def claude_marketplace(plugin, version)
      {
        "name" => plugin["name"],
        "owner" => plugin["author"],
        "description" => plugin["description"],
        "plugins" => [
          {
            "name" => plugin["name"],
            "source" => "./",
            "description" => plugin["description"],
            "version" => version,
            "category" => "education"
          }
        ]
      }
    end

    def codex_marketplace(plugin)
      {
        "name" => plugin["name"],
        "interface" => { "displayName" => plugin["displayName"] },
        "plugins" => [
          {
            "name" => plugin["name"],
            "source" => { "source" => "local", "path" => "./" },
            "policy" => { "installation" => "AVAILABLE", "authentication" => "ON_INSTALL" },
            "category" => "Education"
          }
        ]
      }
    end

    def antigravity_plugin(plugin, version)
      {
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name" => plugin["name"],
        "version" => version,
        "description" => plugin["description"],
        "author" => plugin["author"],
        "repository" => plugin["repository"],
        "license" => plugin["license"],
        "keywords" => plugin["keywords"]
      }
    end
  end
end
