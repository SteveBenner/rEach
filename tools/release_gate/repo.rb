require "open3"
require "yaml"
require "json"
require "fileutils"

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
    GH_TIMEOUT = 5
    VISIBILITY_TTL = 3600
    VISIBILITY_KEYS = %w[private_remotes public_remotes].freeze

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

    def normalized_remote
      url = self.class.origin_url(root).to_s.strip
      return "" if url.empty?

      url = url.sub(%r{\A[A-Za-z][A-Za-z0-9+.\-]*://}, "").sub(/\A[^@\/]+@/, "")
      url = url.sub(%r{\A([^/:]+):\d+/}, '\\1/').sub(%r{\A([^/:]+):}, '\\1/')
      url.sub(%r{/+\z}, "").sub(/\.git\z/, "")
    end

    def visibility_file
      given = ENV["RELEASE_GATE_VISIBILITY_FILE"].to_s
      File.expand_path(given.empty? ? "~/.config/release-gate/visibility.yml" : given)
    end

    def visibility_lists
      data = YAML.safe_load(File.read(visibility_file), permitted_classes: [], aliases: false)
      return {} unless data.is_a?(Hash)

      VISIBILITY_KEYS.to_h { |key| [key, Array(data[key]).map(&:to_s).reject(&:empty?)] }
    rescue Errno::ENOENT, Errno::EACCES, Psych::Exception
      {}
    end

    def visibility
      remote = normalized_remote
      lists = visibility_lists
      return :public if Array(lists["public_remotes"]).any? { |glob| File.fnmatch(glob, remote, File::FNM_CASEFOLD) }
      return :private if Array(lists["private_remotes"]).any? { |glob| File.fnmatch(glob, remote, File::FNM_CASEFOLD) }
      return :public if @facts[:remote].nil?

      match = remote.match(%r{\Agithub\.com/([^/]+/[^/]+)\z})
      match ? github_visibility(match[1]) : :public
    end

    def github_visibility(slug)
      cache = File.join(state_dir, "visibility.json")
      known = read_visibility_cache(cache)
      hit = known[slug]
      return hit["value"] == "private" ? :private : :public if hit.is_a?(Hash) && hit["at"].is_a?(Numeric) && Time.now.to_i - hit["at"] < VISIBILITY_TTL

      answer = ask_github(slug)
      return :public unless %w[PUBLIC INTERNAL PRIVATE].include?(answer)

      value = answer == "PRIVATE" ? "private" : "public"
      write_visibility_cache(cache, known.merge(slug => { "value" => value, "at" => Time.now.to_i }))
      value.to_sym
    end

    def ask_github(slug)
      binary = ENV["RELEASE_GATE_GH"].to_s.empty? ? "gh" : ENV["RELEASE_GATE_GH"]
      stdin, stdout, _stderr, thread = Open3.popen3(binary, "repo", "view", slug, "--json", "visibility", "--jq", ".visibility", chdir: root)
      stdin.close
      reader = Thread.new { stdout.read }
      unless thread.join(GH_TIMEOUT)
        begin
          Process.kill("KILL", thread.pid)
        rescue Errno::ESRCH
          nil
        end
        thread.join
        reader.kill
        return nil
      end
      thread.value.success? ? reader.value.to_s.strip : nil
    rescue Errno::ENOENT, Errno::EACCES, IOError
      nil
    end

    def read_visibility_cache(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      {}
    end

    def write_visibility_cache(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.chmod(0o700, File.dirname(path))
      temp = "#{path}.#{Process.pid}.tmp"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      File.rename(temp, path)
    rescue SystemCallError
      nil
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
        data = YAML.safe_load(File.read(File.join(root, "config.yml")), permitted_classes: [Date], aliases: false)
        teach = data.is_a?(Hash) ? data["teach"] : nil
        teach.is_a?(Hash) ? teach["url"].to_s.strip : ""
      else
        port = ENV["TEACH_PORT"].to_s.strip
        "http://127.0.0.1:#{port.empty? ? '7400' : port}"
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
