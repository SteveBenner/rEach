# frozen_string_literal: true

require "open3"
require "timeout"

module Reach
  module GitAuthor
    PLACEHOLDER_DOMAIN = "students.invalid"
    TIMEOUT_S = 10
    MESSAGE_LIMIT = 65_536
    IDENTITY_KEY = /\A(?:user|author|committer|include|includeif|core\.hookspath)(?:\.|\z)/i.freeze
    LOCAL_KEYS = '^(user\.(name|email)|author\.(name|email)|committer\.(name|email))$'
    LOCAL_UNSET = %w[author.name author.email committer.name committer.email].freeze
    NON_COMMIT = %w[status log diff show branch add rm mv checkout switch restore reset init clone fetch remote ls-files ls-tree rev-parse rev-list blame grep describe shortlog reflog clean help version var gc fsck worktree submodule push bisect apply diff-tree diff-index cat-file for-each-ref show-ref symbolic-ref name-rev whatchanged archive bundle count-objects maintenance sparse-checkout].freeze
    GLOBAL_VALUE_OPTIONS = %w[--namespace --exec-path --super-prefix --attr-source].freeze
    CONFIG_READ_FLAGS = %w[--get --get-all --get-regexp --get-urlmatch --get-color --get-colorbool --list -l --show-origin --show-scope --name-only get list].freeze
    CONFIG_WRITE_FLAGS = %w[--unset --unset-all --add --replace-all --rename-section --remove-section --edit -e set unset edit rename-section remove-section].freeze
    INTERNAL_NAMES = %w[config config.worktree hooks].freeze
    CO_AUTHOR = /^[ \t]*co-authored-by[ \t]*:/i.freeze
    GENERATED = /\b(?:generated|created|written|authored|assisted|made|built)\s+(?:with|by|using)\b/i.freeze
    AGENT_NAME = /\b(?:claude|codex|chatgpt|gpt|openai|anthropic|copilot|gemini|cursor|windsurf|llm|ai|assistant|agent)\b/i.freeze
    AUTHOR_OPTION = /\A--au(?:t(?:h(?:o(?:r)?)?)?)?(?:=|\z)/.freeze
    MESSAGE_CLUSTER = /\A-[A-Za-z]*m\z/.freeze
    MESSAGE_INLINE = /\A-m(.+)\z/m.freeze
    FILE_CLUSTER = /\A-[A-Za-z]*F\z/.freeze
    FILE_INLINE = /\A-F(.+)\z/m.freeze
    CRUDE = /\A[\s.,:;<>"'\\]+|[\s.,:;<>"'\\]+\z/.freeze

    module_function

    def name
      value = Reach::Login.display_name.to_s.gsub(/[<>\r\n]+/, " ").gsub(/\s+/, " ").strip
      value.empty? ? nil : value
    end

    def email
      id = Reach::Login.enrolled_id.to_s.gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/\A[-.]+|[-.]+\z/, "")
      "#{id.empty? ? "student" : id}@#{PLACEHOLDER_DOMAIN}"
    end

    def internal_path?(resolved)
      parts = resolved.to_s.downcase.split(%r{[\\/]})
      parts.each_with_index.any? { |part, index| part == ".git" && INTERNAL_NAMES.include?(parts[index + 1].to_s) }
    end

    def refusal(words, cwd)
      args = words[1..-1].to_a
      dir = cwd.to_s
      configs = []
      index = 0
      while index < args.length && args[index].text.start_with?("-")
        text = args[index].text
        value = args[index + 1]
        if %w[-C -c --config-env --git-dir --work-tree].include?(text) || GLOBAL_VALUE_OPTIONS.include?(text)
          return unmodeled if value.nil? || value.dynamic

          return author if text == "--git-dir" || text == "--work-tree"

          dir = File.expand_path(value.text, dir) if text == "-C"
          configs << value.text if text == "-c" || text == "--config-env"
          index += 2
        else
          return unmodeled if args[index].dynamic
          return author if text.start_with?("--git-dir", "--work-tree")

          configs << text.split("=", 2)[1].to_s if text.start_with?("--config-env=")
          configs << text[2..-1] if text.start_with?("-c") && text.length > 2
          index += 1
        end
      end
      return author if configs.any? { |entry| entry.split("=", 2).first.to_s.strip.match?(IDENTITY_KEY) }

      sub = args[index]
      return nil if sub.nil?
      return unmodeled if sub.dynamic

      rest = args[(index + 1)..-1].to_a
      return config_refusal(rest) if sub.text == "config"

      commit = !NON_COMMIT.include?(sub.text)
      found = commit ? commit_refusal(rest, dir) : nil
      return found if found

      ensure_identity(dir, verify: commit)
    end

    def author
      ["M-GATE-GIT-AUTHOR", {}]
    end

    def unmodeled
      ["M-SHELL-UNMODELED", {}]
    end

    def config_refusal(rest)
      texts = rest.map(&:text)
      flagged = texts.any? { |text| text.start_with?("-") || CONFIG_READ_FLAGS.include?(text) || CONFIG_WRITE_FLAGS.include?(text) }
      return unmodeled if rest.any?(&:dynamic) && flagged

      positional = texts.reject { |text| text.start_with?("-") }
      writes = texts.any? { |text| CONFIG_WRITE_FLAGS.include?(text) } || positional.length >= 2
      return nil if !writes || texts.any? { |text| CONFIG_READ_FLAGS.include?(text) }
      return author if texts.any? { |text| %w[--edit -e edit].include?(text) }

      positional.any? { |text| text.match?(IDENTITY_KEY) } ? author : nil
    end

    def commit_refusal(rest, dir)
      return author if rest.any? { |word| word.text.match?(AUTHOR_OPTION) }

      collected = []
      index = 0
      while index < rest.length
        word = rest[index]
        text = word.text
        break if text == "--"

        value = rest[index + 1]
        taken = 0
        if text == "--message" || text == "--trailer" || text.match?(MESSAGE_CLUSTER)
          return unmodeled if value.nil? || value.dynamic

          collected << value.text
          taken = 1
        elsif text.start_with?("--message=", "--trailer=")
          return unmodeled if word.dynamic

          collected << text.split("=", 2)[1].to_s
        elsif !text.start_with?("--") && (inline = text.match(MESSAGE_INLINE))
          return unmodeled if word.dynamic

          collected << inline[1]
        elsif text == "--file" || text.match?(FILE_CLUSTER)
          return unmodeled if value.nil? || value.dynamic

          loaded = file_text(value.text, dir)
          return unmodeled if loaded.nil?

          collected << loaded
          taken = 1
        elsif text.start_with?("--file=") || (!text.start_with?("--") && text.match?(FILE_INLINE))
          return unmodeled if word.dynamic

          loaded = file_text(text.start_with?("--file=") ? text.split("=", 2)[1].to_s : text.match(FILE_INLINE)[1], dir)
          return unmodeled if loaded.nil?

          collected << loaded
        end
        index += 1 + taken
      end
      attribution?(collected) ? ["M-GATE-GIT-ATTRIBUTION", {}] : nil
    end

    def file_text(path, dir)
      return nil if path == "-" || path.start_with?("/dev/")

      full = File.expand_path(path, dir)
      return nil unless File.file?(full)

      File.binread(full, MESSAGE_LIMIT).to_s.dup.force_encoding(Encoding::UTF_8).scrub
    rescue SystemCallError
      nil
    end

    def attribution?(messages)
      messages.any? do |message|
        message.to_s.each_line.any? { |line| line.match?(CO_AUTHOR) || (line.match?(GENERATED) && line.match?(AGENT_NAME)) }
      end
    end

    def ensure_identity(dir, verify:)
      want = name
      return ["M-GATE-GIT-NONAME", {}] if want.nil?

      mail = email
      listed, status = git(dir, "config", "--local", "--get-regexp", LOCAL_KEYS)
      return (verify ? author : nil) if status.nil?
      if status.exitstatus > 1
        _inside, probe = git(dir, "rev-parse", "--git-dir")
        return nil unless probe&.success?

        return verify ? author : nil
      end

      have = listed.to_s.lines.each_with_object({}) do |line, memo|
        key, value = line.chomp.split(" ", 2)
        memo[key] = value.to_s
      end
      git(dir, "config", "--local", "--replace-all", "user.name", want) unless have["user.name"] == want
      git(dir, "config", "--local", "--replace-all", "user.email", mail) unless have["user.email"] == mail
      LOCAL_UNSET.each { |key| git(dir, "config", "--local", "--unset-all", key) if have.key?(key) }
      return nil unless verify

      verified?(dir, want, mail) ? nil : author
    end

    def verified?(dir, want, mail)
      expected = "#{want.gsub(CRUDE, "")} <#{mail}> "
      %w[GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT].all? do |variable|
        out, status = git(dir, "var", variable)
        status&.success? && out.to_s.start_with?(expected)
      end
    end

    def git(dir, *args)
      Open3.popen3("git", "-C", dir.to_s, *args) do |stdin, stdout, stderr, waiter|
        stdin.close
        drain = Thread.new { stderr.read(MESSAGE_LIMIT) }
        begin
          Timeout.timeout(TIMEOUT_S) { [stdout.read(MESSAGE_LIMIT).to_s, waiter.value] }
        rescue Timeout::Error
          Process.kill("KILL", waiter.pid)
          [nil, nil]
        ensure
          drain.kill
        end
      end
    rescue SystemCallError
      [nil, nil]
    end
  end
end
