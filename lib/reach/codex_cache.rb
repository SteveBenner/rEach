module Reach
  module CodexCache
    SET_ASIDE = "plugin.json.agent-plugins"

    class << self
      def codex_home
        Reach::Paths.codex_home
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

      def repaired?
        repair.positive?
      rescue StandardError
        false
      end
    end
  end
end
