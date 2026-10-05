require "json"
require "open3"
require "timeout"
require "fileutils"
require "time"

module Reach
  module HarnessSource
    CONFLICT = "already added from a different source".freeze
    CLAUDE_CONFLICT = "doesn't match its extraKnownMarketplaces entry".freeze
    MARKETPLACE = "reach".freeze
    PLUGIN = "reach@reach".freeze
    STABLE_REF = "stable".freeze
    UNPINNED_REFS = [nil, "", "main"].freeze
    HARNESSES = %w[claude-code codex].freeze

    module_function

    def repoint(source)
      { "claude-code" => claude(source), "codex" => codex(source) }
    end

    def slug
      owner, repo, host = Reach::Update.owner_repo
      host == "github.com" ? "#{owner}/#{repo}" : nil
    rescue StandardError
      nil
    end

    def repository_source?(text)
      name = slug
      return false unless name

      candidate = text.to_s.strip.sub(%r{/+\z}, "").sub(/\.git\z/, "")
      candidate = candidate.sub(%r{\Ahttps://github\.com/}i, "")
      candidate.casecmp?(name)
    end

    def stable_spec(harness)
      name = slug
      return nil unless name

      harness.to_s == "codex" ? "#{name}@#{STABLE_REF}" : "#{name}##{STABLE_REF}"
    end

    def pin(source, harness)
      return source unless repository_source?(source)

      stable_spec(harness) || source
    end

    def codex_bin
      return "codex" if on_path?("codex")

      path = ENV["CODEX_CLI_PATH"].to_s
      path.empty? || !File.file?(path) ? nil : path
    end

    def claude_bin
      on_path?("claude") ? "claude" : nil
    end

    def codex_command(*arguments)
      [codex_bin || "codex", *arguments]
    end

    def claude(source)
      return "absent" unless claude_bin

      claude_add(source)
    end

    def claude_add(source)
      _out, err, ok = capture(["claude", "plugin", "marketplace", "add", source])
      return "ok" if ok
      return "failed: #{first_line(err)}" unless err.to_s.include?(CLAUDE_CONFLICT)

      replace_claude_source(source)
    end

    def replace_claude_source(source)
      old_source = claude_old_source
      _out, err, ok = capture(%w[claude plugin marketplace remove reach])
      return "failed: #{first_line(err)}" unless ok

      _out, err, ok = capture(["claude", "plugin", "marketplace", "add", source])
      unless ok
        reason = first_line(err)
        if old_source
          _out, _err, restored = capture(["claude", "plugin", "marketplace", "add", old_source])
          capture(["claude", "plugin", "install", PLUGIN, "--scope", "user"]) if restored
          return "failed: #{reason} (previous source #{restored ? 'restored' : 'could not be restored'})"
        end
        return "failed: #{reason}"
      end

      _out, err, ok = capture(["claude", "plugin", "install", PLUGIN, "--scope", "user"])
      ok ? "ok" : "failed: #{first_line(err)}"
    end

    def codex(source)
      return "absent" unless codex_bin

      out, err, ok = capture(codex_command("plugin", "marketplace", "add", source))
      return "ok" if ok

      combined = "#{out}#{err}"
      return "failed: #{first_line(combined)}" unless combined.include?(CONFLICT)

      replace_codex_source(source)
    end

    def replace_codex_source(source)
      old_add = codex_old_add
      _out, err, ok = capture(codex_command("plugin", "marketplace", "remove", MARKETPLACE))
      return "failed: #{first_line(err)}" unless ok

      _out, err, ok = capture(codex_command("plugin", "marketplace", "add", source))
      return "ok" if ok

      reason = first_line(err)
      if old_add
        _out, _err, restored = capture(codex_command("plugin", "marketplace", "add", *old_add))
        return "failed: #{reason} (previous source #{restored ? 'restored' : 'could not be restored'})"
      end
      "failed: #{reason}"
    end

    def codex_source
      from_config || from_list
    end

    def codex_table
      config = File.join(codex_home, "config.toml")
      return nil unless File.file?(config)

      inside = false
      table = {}
      File.foreach(config) do |line|
        stripped = line.strip
        if stripped.start_with?("[")
          break if inside

          inside = stripped == "[marketplaces.reach]"
          next
        end
        next unless inside

        match = stripped.match(/\A(\w+)\s*=\s*"(.*)"\z/)
        table[match[1]] = match[2].gsub('\\"', '"').gsub("\\\\", "\\") if match
      end
      table.empty? ? nil : table
    rescue StandardError
      nil
    end

    def from_config
      table = codex_table
      table && table["source"]
    end

    def from_list
      out, _err, ok = capture(codex_command("plugin", "marketplace", "list"))
      return nil unless ok

      out.each_line do |line|
        next unless line =~ /\breach\b/

        found = line.scan(%r{(?:[A-Za-z]:)?[/\\][^\s"']+}).first
        return found if found
      end
      nil
    end

    def codex_entry
      table = codex_table
      return nil unless table

      git = table["source_type"].to_s == "git"
      { "kind" => git ? "git" : "local", "location" => table["source"].to_s, "ref" => table["ref"] }
    end

    def codex_old_add
      entry = codex_entry
      return nil unless entry && entry["location"] != ""

      if entry["kind"] == "git"
        entry["ref"].to_s.empty? ? [entry["location"]] : [entry["location"], "--ref", entry["ref"]]
      elsif File.directory?(entry["location"])
        [entry["location"]]
      end
    end

    def claude_source_hash
      file = File.join(Reach::Paths.claude_config_dir, "plugins", "known_marketplaces.json")
      data = JSON.parse(File.read(file))
      entry = data.is_a?(Hash) ? data[MARKETPLACE] : nil
      source = entry.is_a?(Hash) ? entry["source"] : nil
      source.is_a?(Hash) ? source : nil
    rescue StandardError
      nil
    end

    def claude_entry
      source = claude_source_hash
      return nil unless source

      case source["source"]
      when "github"
        { "kind" => "git", "location" => source["repo"].to_s, "ref" => source["ref"] }
      when "git"
        { "kind" => "git", "location" => source["url"].to_s, "ref" => source["ref"] }
      else
        { "kind" => "local", "location" => (source["path"] || source["url"]).to_s, "ref" => nil }
      end
    end

    def claude_old_source
      source = claude_source_hash
      return nil unless source

      case source["source"]
      when "github", "git"
        base = (source["repo"] || source["url"]).to_s
        source["ref"].to_s.empty? ? base : "#{base}##{source['ref']}"
      when "directory", "file"
        source["path"].to_s.empty? ? nil : source["path"].to_s
      end
    end

    def pending_entry(harness)
      entry = harness == "codex" ? codex_entry : claude_entry
      return nil unless entry && entry["kind"] == "git"
      return nil unless repository_source?(entry["location"]) && UNPINNED_REFS.include?(entry["ref"])

      entry
    end

    def state_file
      File.join(Reach::Paths.root_state_dir, "harness-source.json")
    end

    def load_state
      parsed = JSON.parse(File.read(state_file))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    def save_state(state)
      FileUtils.mkdir_p(File.dirname(state_file))
      temp = "#{state_file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(temp, "w", 0o600) { |handle| handle.write(JSON.pretty_generate(state)) }
      File.rename(temp, state_file)
    end

    def cli_present?(harness)
      harness == "codex" ? !codex_bin.nil? : !claude_bin.nil?
    end

    def due?(harness)
      return false if load_state.key?(harness)
      return false unless cli_present?(harness)

      !pending_entry(harness).nil?
    rescue StandardError
      false
    end

    def pending?
      return false if Reach::Sandbox.blocked?

      HARNESSES.any? { |harness| due?(harness) }
    rescue StandardError
      false
    end

    def ensure_stable!
      return {} if Reach::Sandbox.blocked?

      FileUtils.mkdir_p(Reach::Paths.root_state_dir)
      File.open("#{state_file}.lock", File::RDWR | File::CREAT, 0o600) do |handle|
        return {} unless handle.flock(File::LOCK_EX | File::LOCK_NB)

        begin
          results = {}
          HARNESSES.each do |harness|
            results[harness] = repoint_to_stable(harness) if due?(harness)
          end
          results
        ensure
          handle.flock(File::LOCK_UN)
        end
      end
    rescue StandardError
      {}
    end

    def repoint_to_stable(harness)
      entry = pending_entry(harness)
      spec = stable_spec(harness)
      from = entry["ref"].to_s.empty? ? entry["location"] : "#{entry['location']}@#{entry['ref']}"
      state = load_state
      state[harness] = { "at" => Time.now.utc.iso8601, "from" => from, "to" => spec, "result" => "started" }
      save_state(state)
      result = begin
        harness == "codex" ? repoint_codex_to_stable(spec) : repoint_claude_to_stable(spec)
      rescue StandardError => e
        "failed: #{e.message}"
      end
      state = load_state
      state[harness]["result"] = result
      save_state(state)
      Reach::Update.log("harness_source", "harness" => harness, "from" => from, "to" => spec, "result" => result)
      result
    end

    def repoint_claude_to_stable(spec)
      result = claude_add(spec)
      return result unless result == "ok"

      _out, err, ok = capture(%w[claude plugin update reach@reach --scope user])
      ok ? "ok" : "failed: #{first_line(err)}"
    end

    def repoint_codex_to_stable(spec)
      result = codex(spec)
      return result unless result == "ok"

      _out, err, ok = capture(codex_command("plugin", "add", PLUGIN))
      return "failed: #{first_line(err)}" unless ok

      Reach::CodexCache.repair
      "ok"
    end

    def codex_home
      Reach::Paths.codex_home
    end

    def first_line(text)
      lines = text.to_s.lines.map(&:strip).reject(&:empty?)
      lines.reject { |line| line.start_with?("WARNING") }.first || lines.first || "no output"
    end

    def on_path?(executable)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, executable)) && !File.directory?(File.join(dir, executable))
      end
    end

    def capture(args)
      out, err, status = Timeout.timeout(120) { Open3.capture3(*args) }
      [out, err, status.success?]
    rescue StandardError => e
      ["", e.message, false]
    end
  end
end
