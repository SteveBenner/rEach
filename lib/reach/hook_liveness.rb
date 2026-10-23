require "json"
require "time"
require "fileutils"
require "rbconfig"

module Reach
  module HookLiveness
    HOOKS_QUIET_S = 900
    PROMPT_WITHOUT_WORK_S = 600
    WORK_KEYS = %w[work_at prompt_at session_at session_label].freeze
    SESSION_SOURCES = %w[startup resume clear].freeze
    FAMILIES = %w[claude codex].freeze
    PROCESS_FAMILIES = { "codex" => "codex", "claude" => "claude" }.freeze

    module_function

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

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
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
      return @parent_harness if defined?(@parent_harness)

      @parent_harness = lookup_parent_harness
    end

    def lookup_parent_harness
      return nil if Reach::Runtime.windows?

      pid = Process.ppid
      return nil unless pid.to_i > 1

      name = IO.popen(["ps", "-o", "comm=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
      PROCESS_FAMILIES[File.basename(name).downcase.sub(/\.exe\z/, "")]
    rescue StandardError
      nil
    end

    def enroll_seen_file
      File.join(Reach::Paths.root_state_dir, "hooks_enroll_seen.json")
    end

    def recorded_harness
      latest = [read_json(hooks_seen_file), read_json(enroll_seen_file)].compact.max_by { |seen| seen["at"].to_s }
      label = latest ? latest["label"].to_s : ""
      label.empty? ? nil : label
    end

    def harness
      found = Reach::HarnessIdentity.detect["label"].to_s
      found.empty? || %w[terminal unknown].include?(found) ? nil : found
    end

    def environment
      { "os" => os_name, "harness" => harness, "reach_version" => Reach::VERSION }
    end

    def family_of(label)
      label.to_s.split("-").first
    end

    def hook_quiet?(key, limit, file = hooks_seen_file)
      seen = read_json(file)
      value = seen ? seen[key].to_s : ""
      return true if value.empty?

      Time.now - Time.parse(value) > limit
    rescue StandardError
      true
    end

    def hooks_stale?
      seen = read_json(hooks_seen_file) || {}
      work = stamp_time(seen["work_at"])
      prompted = stamp_time(seen["prompt_at"])
      return Time.now - prompted >= PROMPT_WITHOUT_WORK_S if prompted && (work.nil? || prompted > work)
      return true if work.nil?

      Time.now - work > HOOKS_QUIET_S
    rescue StandardError
      true
    end

    def stamp_time(value)
      text = value.to_s
      text.empty? ? nil : Time.parse(text)
    rescue ArgumentError
      nil
    end

    def prompt_hook_quiet?(limit)
      hook_quiet?("prompt_at", limit)
    end

    def enroll_hook_quiet?(limit)
      hook_quiet?("at", limit, enroll_seen_file)
    end

    def record_enroll_hook!(harness_label)
      write_json(enroll_seen_file, "at" => now_s, "label" => harness_label.to_s)
      nil
    rescue StandardError
      nil
    end

    def session_started!(harness_label, source)
      return nil unless SESSION_SOURCES.include?(source.to_s)

      seen = read_json(hooks_seen_file) || {}
      write_json(hooks_seen_file, seen.merge("session_at" => now_s, "session_label" => harness_label.to_s))
      nil
    rescue StandardError
      nil
    end

    def guard_enabled?
      section = Reach::Runtime.load_config["hooks"]
      ENV["REACH_HOOK_GUARD_DISABLE"].to_s != "1" && !(section.is_a?(Hash) && section["require"] == false)
    rescue StandardError
      true
    end

    def prompt_hook_dead?(env = environment)
      return false unless family_of(env["harness"]) == "codex"

      seen = read_json(hooks_seen_file) || {}
      started = seen["session_at"].to_s
      if !started.empty? && family_of(seen["session_label"]) == "codex"
        prompted = seen["prompt_at"].to_s
        return true if prompted.empty? || Time.parse(prompted) < Time.parse(started)
      end
      hooks_stale?
    rescue StandardError
      false
    end

    def signin_hook_dead?(env = environment)
      return false unless family_of(env["harness"]) == "codex"

      seen = read_json(hooks_seen_file) || {}
      stamps = [(read_json(enroll_seen_file) || {})["at"], seen["prompt_at"]].map(&:to_s).reject(&:empty?)
      return true if stamps.empty?

      ran = stamps.map { |stamp| Time.parse(stamp) }.max
      started = seen["session_at"].to_s
      if !started.empty? && family_of(seen["session_label"]) == "codex"
        return ran < Time.parse(started)
      end
      Time.now - ran > HOOKS_QUIET_S
    rescue StandardError
      false
    end

    def signin_pending?
      Reach::Login.required? && !Reach::Login.any_active?
    rescue StandardError
      false
    end

    def course_hook_files
      space = Reach::Workspace.space_for(Reach::Paths.cwd)
      files = Reach::CodexSetup.managed_hook_files
      return files unless space

      wanted = File.join(File.expand_path(space["path"]), ".codex", "hooks.json")
      files.select { |path, _kind| File.expand_path(path) == wanted }
    end

    def course_hooks_untrusted?(env = environment)
      return false unless family_of(env["harness"]) == "codex"
      return true if signin_hook_dead?(env) && Reach::CodexSetup.plugin_hooks_untrusted?
      return false if signin_pending?

      course_hook_files.any? do |path, kind|
        content = Reach::CodexSetup.managed_content(path, kind)
        content && Reach::CodexHookTrust.stale?(Reach::CodexHookTrust.status(path, content))
      end
    rescue StandardError
      false
    end

    def untrusted_or(message_id)
      course_hooks_untrusted? ? "M-HOOKS-UNTRUSTED" : message_id
    rescue StandardError
      message_id
    end

    def require_hooks!
      return nil unless guard_enabled?
      raise Reach::Refused, Reach::Messages.text("M-HOOKS-UNTRUSTED") if course_hooks_untrusted?
      return nil unless prompt_hook_dead?

      raise Reach::Refused, Reach::Messages.text("M-HOOKS-REQUIRED")
    end

    def record_hook!(harness_label, kind = "work")
      seen = read_json(hooks_seen_file) || {}
      data = { "at" => now_s, "label" => harness_label.to_s }
      WORK_KEYS.each { |key| data[key] = seen[key] if seen[key].is_a?(String) }
      data["work_at"] = data["at"] if kind == "work"
      data["prompt_at"] = data["at"] if kind == "prompt"
      write_json(hooks_seen_file, data)
      nil
    rescue StandardError
      nil
    end
  end
end
