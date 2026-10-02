module Reach
  module CodexCache
    SET_ASIDE = "plugin.json.agent-plugins"

    class << self
      def codex_home
        value = ENV["CODEX_HOME"].to_s
        File.expand_path(value.empty? ? "~/.codex" : value)
      end

      def repair
        Dir.glob(File.join(codex_home, "plugins", "cache", "*", "reach", "*", "plugin.json")).count do |manifest|
          dir = File.dirname(manifest)
          next false unless File.file?(File.join(dir, ".codex-plugin", "plugin.json"))

          File.rename(manifest, File.join(dir, SET_ASIDE))
          true
        rescue SystemCallError
          false
        end
      rescue StandardError
        0
      end
    end
  end
end
