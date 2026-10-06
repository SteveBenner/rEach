require "open3"
require "yaml"

module ReleaseGate
  class Repo
    KNOWN = {
      "reach" => { remote: %r{github\.com[:/]SteveBenner/rEach(?:\.git)?}, releases: "github", component: "reach",
                   owner_git: "https://github.com/SteveBenner/rEach.git", raw_base: "https://raw.githubusercontent.com/SteveBenner/rEach" },
      "teach" => { remote: nil, releases: "none", component: "teach",
                   owner_git: "https://github.com/SteveBenner/rEach.git", raw_base: "https://raw.githubusercontent.com/SteveBenner/rEach" }
    }.freeze
    TEACH_PARAGRAPH = "This repository is Teach, the private instructor course server. It is pushed to a private repository host and is not " \
                      "published, but the push still leaves this computer: student data, credentials, keys and anything that would let a " \
                      "third party reach the course server must not be in it. Read the audit below with that in mind.\n\n".freeze
    HTTP_PATTERN = %r{\Ahttps?://}.freeze

    attr_reader :name, :root

    def self.git_root(from = Dir.pwd)
      out, status = Open3.capture2("git", "-C", from, "rev-parse", "--show-toplevel", err: File::NULL)
      status.success? && !out.strip.empty? ? out.strip : nil
    rescue StandardError
      nil
    end

    def self.origin_url(root)
      out, status = Open3.capture2("git", "-C", root, "remote", "get-url", "origin", err: File::NULL)
      status.success? ? out.strip : ""
    rescue StandardError
      ""
    end

    def self.detect(root: git_root)
      return nil if root.nil?

      forced = ENV["RELEASE_GATE_REPO"].to_s
      return new(forced, root) if KNOWN.key?(forced)

      return new("teach", root) if File.file?(File.join(root, "teach.spec.yml"))

      url = origin_url(root)
      name = KNOWN.keys.find { |key| KNOWN[key][:remote] && url =~ KNOWN[key][:remote] }
      name ? new(name, root) : nil
    end

    def initialize(name, root)
      @name = name
      @root = root
      @facts = KNOWN.fetch(name)
    end

    def component
      @facts[:component]
    end

    def github?
      @facts[:releases] == "github"
    end

    def owner_git
      ENV["RELEASE_GATE_OWNER_GIT"].to_s.empty? ? @facts[:owner_git] : ENV["RELEASE_GATE_OWNER_GIT"]
    end

    def raw_base
      (ENV["RELEASE_GATE_RAW_BASE"].to_s.empty? ? @facts[:raw_base] : ENV["RELEASE_GATE_RAW_BASE"]).sub(%r{/+\z}, "")
    end

    def slug
      url = self.class.origin_url(root)
      match = url.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/*\z})
      return "#{match[1]}/#{match[2]}" if match

      ENV["RELEASE_GATE_SLUG"].to_s.empty? ? "SteveBenner/rEach" : ENV["RELEASE_GATE_SLUG"]
    end

    def remote_matches?(url)
      return true if name == "teach"
      return true if @facts[:remote] && url.to_s =~ @facts[:remote]

      pattern = ENV["RELEASE_GATE_REMOTE"].to_s
      pattern = ENV["REACH_SECURITY_AUDIT_REMOTE"].to_s if pattern.empty? && name == "reach"
      return false if pattern.empty?

      !(url.to_s =~ Regexp.new(pattern)).nil?
    rescue RegexpError
      false
    end

    def state_dir
      given = ENV["RELEASE_GATE_STATE"].to_s
      given = ENV["REACH_SECURITY_AUDIT_STATE"].to_s if given.empty? && name == "reach"
      File.expand_path(given.empty? ? "~/.local/state/release-gate/#{name}" : given)
    end

    def token_paths
      paths = [File.expand_path("~/.config/release-gate/#{name}/token")]
      paths << File.expand_path("~/.config/reach-security-audit/token") if name == "reach"
      paths
    end

    def token
      env = ENV["RELEASE_GATE_TOKEN"].to_s.strip
      env = ENV["REACH_SECURITY_AUDIT_TOKEN"].to_s.strip if env.empty? && name == "reach"
      return env unless env.empty?

      token_paths.each do |path|
        next unless File.file?(path)

        if (File.stat(path).mode & 0o077) != 0
          $stderr.puts("release gate: token file #{path} must be mode 0600, ignoring it")
          next
        end
        value = File.read(path).strip
        return value unless value.empty?
      end
      nil
    end

    def teach_url
      given = ENV["TEACH_URL"].to_s
      given = configured_teach_url.to_s if given.empty?
      return nil if given.empty?

      given.sub(%r{/+\z}, "")
    end

    def configured_teach_url
      if name == "reach"
        text = File.read(File.join(root, "config.yml"))
        text[/^teach:\s*\n\s+url:\s*(\S+)/, 1].to_s
      else
        port = ENV["TEACH_PORT"].to_s
        return nil if port.empty?

        "http://127.0.0.1:#{port}"
      end
    rescue StandardError
      ""
    end

    def prompt_paragraph
      name == "teach" ? TEACH_PARAGRAPH : nil
    end

    def spec_path
      File.join(root, "specs", "release_gate.yml")
    end

    def spec
      @spec ||= YAML.safe_load(File.read(spec_path), permitted_classes: [Date], aliases: false)
    rescue StandardError
      nil
    end

    def version_homes
      homes = spec && spec["version_homes"].is_a?(Hash) ? spec["version_homes"][name] : nil
      Array(homes).map(&:to_s)
    end

    def pins
      list = spec && spec["pins"].is_a?(Hash) ? spec["pins"][name] : nil
      Array(list).select { |pin| pin.is_a?(Hash) && pin["path"] && pin["owner_path"] }
    end
  end
end
