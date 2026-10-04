require "json"
require "time"
require "fileutils"
require "rbconfig"

module Reach
  module KnownIssues
    STALE_S = 3600
    HOOKS_QUIET_S = 900
    WORK_KEYS = %w[work_at prompt_at].freeze
    FAMILIES = %w[claude codex].freeze
    PROCESS_FAMILIES = { "codex" => "codex", "claude" => "claude" }.freeze
    REMEDIES = {
      "codex_configure" => ["reach_setup", { "action" => "configure" }],
      "sandbox_probe" => ["reach_setup", { "action" => "probe" }],
      "doctor" => ["reach_doctor", {}],
      "status" => ["reach_status", {}],
      "sync" => ["reach_sync", {}],
      "update_check" => ["reach_update", { "action" => "status" }],
      "update" => ["reach_update", { "action" => "run" }]
    }.freeze

    module_function

    def cache_file
      File.join(Reach::Paths.root_state_dir, "known_issues.json")
    end

    def hooks_seen_file
      File.join(Reach::Paths.root_state_dir, "hooks_seen.json")
    end

    def read_json(path)
      return nil unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError
      nil
    end

    def write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      File.rename(tmp, path)
      File.chmod(0o600, path)
    end

    def cache
      data = read_json(cache_file)
      data && data["issues"].is_a?(Array) ? data : nil
    end

    def stale?
      data = cache
      return true unless data

      fetched = Time.parse(data["fetched_at"].to_s)
      Time.now - fetched > STALE_S
    rescue StandardError
      true
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def fetch!(quick: true)
      base = Reach::Runtime.default_teach_url
      return nil if base.to_s.empty?

      current = cache
      headers = {}
      headers["If-None-Match"] = "\"#{current['revision']}\"" if current && current["revision"].to_s != ""
      client = Reach::Client.anonymous(base, quick: quick, link: false)
      response = client.get("/api/v1/known-issues", headers: headers)
      if response.status == 304
        write_json(cache_file, current.merge("fetched_at" => now_s)) if current
        return current
      end

      body = response.json
      return nil unless body.is_a?(Hash) && body["issues"].is_a?(Array)

      revision = body["revision"].to_s
      revision = response.headers["etag"].to_s.delete("\"") if revision.empty?
      data = { "revision" => revision, "fetched_at" => now_s, "issues" => body["issues"] }
      write_json(cache_file, data)
      data
    rescue StandardError
      nil
    end

    def refresh_if_stale!(quick: true)
      fetch!(quick: quick) if stale?
      nil
    rescue StandardError
      nil
    end

    def spawn_refresh!
      return nil unless stale?
      return nil if Reach::Runtime.default_teach_url.to_s.empty?

      exe = File.join(Reach::Runtime.root, "exe", "reach")
      options = { in: File::NULL, out: File::NULL, err: File::NULL }
      if Reach::Runtime.windows?
        options[:new_pgroup] = true
      else
        options[:pgroup] = true
      end
      pid = Process.spawn(RbConfig.ruby, exe, "known-issues", "--refresh", options)
      Process.detach(pid)
      pid
    rescue StandardError
      nil
    end

    def os_name
      case RbConfig::CONFIG["host_os"].to_s
      when /darwin|mac os/i then "macos"
      when /mswin|mingw|cygwin|windows/i then "windows"
      else "linux"
      end
    end

    def marker_harness
      codex = %w[CODEX_THREAD_ID CODEX_SANDBOX].any? { |key| ENV[key].to_s != "" } || Reach::Sandbox.active?
      claude = ENV["CLAUDE_CODE_ENTRYPOINT"].to_s != ""
      hermes = ENV["HERMES_HOME"].to_s != ""
      return nil unless codex || claude || hermes
      return Reach::Fingerprint.harness_label("codex") if codex

      Reach::Fingerprint.harness_label(nil)
    rescue StandardError
      nil
    end

    def parent_harness
      return nil if Reach::Runtime.windows?

      pid = Process.ppid
      return nil unless pid.to_i > 1

      name = IO.popen(["ps", "-o", "comm=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
      PROCESS_FAMILIES[File.basename(name).downcase.sub(/\.exe\z/, "")]
    rescue StandardError
      nil
    end

    def recorded_harness
      label = (read_json(hooks_seen_file) || {})["label"].to_s
      label.empty? ? nil : label
    end

    def harness
      label = marker_harness
      label = nil if label.to_s.empty? || label == Reach::Fingerprint::UNKNOWN
      label || parent_harness || recorded_harness
    end

    def environment
      { "os" => os_name, "harness" => harness, "reach_version" => Reach::VERSION }
    end

    def family_of(label)
      label.to_s.split("-").first
    end

    def harness_matches?(list, env_harness)
      list = Array(list)
      return true if list.empty?
      return false if env_harness.to_s.empty?

      if FAMILIES.include?(env_harness)
        list.any? { |item| item == env_harness || item.start_with?("#{env_harness}-") }
      else
        list.include?(env_harness) || list.include?(family_of(env_harness))
      end
    end

    def os_matches?(list, env_os)
      list = Array(list)
      list.empty? || list.include?(env_os)
    end

    def version_ok?(applies, version)
      current = Gem::Version.new(version.to_s)
      min = applies["reach_min"].to_s
      max = applies["reach_max"].to_s
      return false if min != "" && current < Gem::Version.new(min)
      return false if max != "" && current > Gem::Version.new(max)

      true
    rescue StandardError
      false
    end

    def matches?(entry, env)
      applies = entry["applies"].is_a?(Hash) ? entry["applies"] : {}
      os_matches?(applies["os"], env["os"]) &&
        harness_matches?(applies["harness"], env["harness"]) &&
        version_ok?(applies, env["reach_version"])
    end

    def steps_for(entry, env)
      step = Array(entry["steps"]).find do |candidate|
        candidate.is_a?(Hash) && os_matches?(candidate["os"], env["os"]) && harness_matches?(candidate["harness"], env["harness"])
      end
      step && step["text"]
    end

    def hook_quiet?(key, limit)
      seen = read_json(hooks_seen_file)
      value = seen ? seen[key].to_s : ""
      return true if value.empty?

      Time.now - Time.parse(value) > limit
    rescue StandardError
      true
    end

    def hooks_stale?
      hook_quiet?("work_at", HOOKS_QUIET_S)
    end

    def prompt_hook_quiet?(limit)
      hook_quiet?("prompt_at", limit)
    end

    def detected?(entry, env = environment, mcp: false)
      case entry["detector"]
      when "codex_sandbox"
        Reach::Sandbox.blocked?
      when "hooks_not_running"
        mcp && env["harness"].to_s != "" && family_of(env["harness"]) == "codex" && hooks_stale?
      else
        false
      end
    rescue StandardError
      false
    end

    def matching(mcp: false)
      data = cache
      return [] unless data

      env = environment
      data["issues"].select { |entry| entry.is_a?(Hash) && matches?(entry, env) }.map do |entry|
        {
          "id" => entry["id"],
          "title" => entry["title"],
          "symptom" => entry["symptom"],
          "detected" => detected?(entry, env, mcp: mcp),
          "remedy" => remedy_for(entry["remedy"]),
          "steps" => steps_for(entry, env)
        }
      end
    end

    def remedy_for(name)
      found = REMEDIES[name.to_s]
      return nil unless found

      { "id" => name.to_s, "tool" => found[0], "arguments" => found[1].dup }
    end

    def remedy_call(remedy)
      arguments = remedy["arguments"].map { |key, value| "#{key} #{value}" }
      arguments.empty? ? remedy["tool"] : "#{remedy['tool']} with #{arguments.join(', ')}"
    end

    def remedy_lines(found)
      Array(found).select { |item| item.is_a?(Hash) && item["remedy"].is_a?(Hash) }.map do |item|
        Reach::Messages.text("M-KNOWN-ISSUE-REMEDY", title: item["title"], call: remedy_call(item["remedy"]))
      end
    rescue StandardError
      []
    end

    def context_lines(mcp: false)
      found = matching(mcp: mcp)
      return [] if found.empty?

      lines = [Reach::Messages.text("M-KNOWN-ISSUES-AGENT", titles: found.map { |item| item["title"] }.join("; "))]
      found.each do |item|
        lines << Reach::Messages.text("M-KNOWN-ISSUE-DETECTED", title: item["title"]) if item["detected"]
      end
      lines.concat(remedy_lines(found))
    rescue StandardError
      []
    end

    def record_hook!(harness_label, kind = "work")
      seen = read_json(hooks_seen_file) || {}
      data = { "at" => now_s, "label" => harness_label.to_s }
      WORK_KEYS.each { |key| data[key] = seen[key] if seen[key].is_a?(String) }
      data["work_at"] = data["at"] unless kind == "session"
      data["prompt_at"] = data["at"] if kind == "prompt"
      write_json(hooks_seen_file, data)
      nil
    rescue StandardError
      nil
    end
  end
end
