require "fileutils"
require "json"
require "time"

module Reach
  module RetiredCapture
    MARKER = "transcripts-retired.json".freeze

    module_function

    def marker_path
      File.join(Reach::Paths.root_state_dir, MARKER)
    end

    def purge_once!
      return nil if File.exist?(marker_path)

      purge!
    rescue StandardError
      nil
    end

    def purge!
      homes = [Reach::Paths.root] + Dir.glob(File.join(Reach::Paths.root, "personas", "*")).select { |path| File.directory?(path) }
      removed = 0
      homes.each do |home|
        targets = [
          File.join(home, "transcripts"),
          File.join(home, "state", "transcript-flush.lock"),
          File.join(home, "state", "transcript-flush.json")
        ]
        targets.each do |target|
          next unless File.exist?(target) || File.symlink?(target)

          FileUtils.rm_rf(target, secure: true)
          removed += 1
        end
      end
      FileUtils.mkdir_p(File.dirname(marker_path))
      File.write(marker_path, JSON.generate("retired_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "removed" => removed))
      removed
    end
  end
end
