module Reach
  module OldCopy
    KEY = "old-copy".freeze
    VERSION_READ_BYTES = 64

    module_function

    def other_versions
      files = [File.join(Reach::Paths.managed_install_dir, "VERSION")]
      [Reach::Paths.codex_home, Reach::Paths.claude_config_dir].each do |base|
        files.concat(Dir.glob(File.join(base, "plugins", "cache", "*", "reach", "*", "VERSION")))
      end
      files.map { |file| read_version(file) }.compact
    end

    def read_version(file)
      return nil unless File.file?(file)

      text = File.read(file, VERSION_READ_BYTES).to_s.strip
      Gem::Version.correct?(text) ? Gem::Version.new(text) : nil
    rescue SystemCallError, IOError
      nil
    end

    def mismatch
      running = Gem::Version.new(Reach::VERSION)
      others = other_versions
      return nil if others.all? { |version| version == running }

      (others + [running]).max
    end

    def prompt_notices(session_id)
      newest = mismatch
      return [] unless newest
      return [] unless Reach::Update.announce!(KEY, session_id)

      [Reach::Update.notice_sentence("M-OLD-COPY-NOTICE", newest.to_s)]
    rescue StandardError
      []
    end
  end
end
