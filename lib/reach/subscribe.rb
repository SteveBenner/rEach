require "json"
require "fileutils"
require "digest"
require "time"
require "rbconfig"
require "etc"

module Reach
  module Subscribe
    ROUTE = "/api/v1/revision".freeze
    MIN_GAP_S = 50
    UNSUPPORTED_WAIT_S = 21_600
    BACKOFF_BASE_S = 60
    BACKOFF_CAP_S = 3600
    NOTICE_TTL_S = 604_800
    NOTICE_KEEP = 20
    OS_TIMEOUT_S = 10
    SESSION_JITTER_S = 15
    DEFAULT_SETTINGS = { "background" => true, "session_interval_s" => 60, "background_interval_s" => 900 }.freeze
    MIN_SESSION_INTERVAL_S = 1
    MIN_BACKGROUND_INTERVAL_S = 60
    SOURCES = %w[session background].freeze
    NOTICE_KINDS = {
      "status" => "course_update",
      "grades" => "grade",
      "hands" => "hand_reply",
      "extra_credit" => "extra_credit",
      "receipts" => "receipt"
    }.freeze
    NOTICE_WORDS = {
      "course_update" => "your course has new materials or settings",
      "grade" => "a grade was posted",
      "hand_reply" => "an instructor answered your raised hand",
      "extra_credit" => "your extra credit changed",
      "receipt" => "a receipt arrived"
    }.freeze
    SERVICE_NAME = "reach-subscribe.service".freeze
    TIMER_NAME = "reach-subscribe.timer".freeze
    LAUNCH_LABEL = "reach.subscribe".freeze
    TASK_NAME = "rEach\\Update check".freeze

    module_function

    def now
      Time.now.to_i
    end

    def iso(epoch)
      epoch ? Time.at(epoch).utc.strftime("%Y-%m-%dT%H:%M:%SZ") : nil
    end

    def state_file
      File.join(Reach::Paths.state_dir, "subscribe.json")
    end

    def state_lock_file
      File.join(Reach::Paths.state_dir, "subscribe.state.lock")
    end

    def tick_lock_file
      File.join(Reach::Paths.state_dir, "subscribe.lock")
    end

    def settings
      section = Reach::Runtime.load_config["subscribe"]
      section = {} unless section.is_a?(Hash)
      background = section.key?("background") ? section["background"] != false : DEFAULT_SETTINGS["background"]
      {
        "background" => background,
        "session_interval_s" => [positive(section["session_interval_s"], DEFAULT_SETTINGS["session_interval_s"]), MIN_SESSION_INTERVAL_S].max,
        "background_interval_s" => [positive(section["background_interval_s"], DEFAULT_SETTINGS["background_interval_s"]), MIN_BACKGROUND_INTERVAL_S].max
      }
    rescue StandardError
      DEFAULT_SETTINGS.dup
    end

    def positive(value, default)
      number = Integer(value)
      number.positive? ? number : default
    rescue ArgumentError, TypeError
      default
    end

    def disabled?
      ENV["REACH_OFFLINE"] == "1" || ENV["REACH_SUBSCRIBE"] == "0"
    end

    def defaults
      {
        "revision" => nil, "parts" => {}, "checked_at" => nil, "next_due_at" => nil, "failures" => 0,
        "unsupported_until" => nil, "last_sync_at" => nil, "notices" => [], "job" => nil
      }
    end

    def read_state
      parsed = JSON.parse(File.read(state_file))
      parsed.is_a?(Hash) ? defaults.merge(parsed) : defaults
    rescue StandardError
      defaults
    end

    def write_state(state)
      FileUtils.mkdir_p(File.dirname(state_file))
      temp = "#{state_file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(state)) }
      File.rename(temp, state_file)
      File.chmod(0o600, state_file)
      state
    end

    def update_state(wait_s: nil)
      FileUtils.mkdir_p(File.dirname(state_file))
      outcome = Reach::Locks.exclusive(state_lock_file, wait_s: wait_s) do
        state = read_state
        result = yield state
        write_state(state)
        result
      end
      outcome == :busy ? nil : outcome
    rescue StandardError => e
      Reach::Debug.fault(e, "subscribe:state")
      nil
    end

    def enrolled_install
      install = Reach::Enroll.current
      install.is_a?(Hash) && !install["revoked"] ? install : nil
    rescue StandardError
      nil
    end

    def due?(state = read_state, at: now)
      return false if disabled?
      return false unless enrolled_install
      return false if state["checked_at"] && at - state["checked_at"].to_i < MIN_GAP_S
      return false if state["next_due_at"] && at < state["next_due_at"].to_i
      return false if state["unsupported_until"] && at < state["unsupported_until"].to_i

      true
    rescue StandardError
      false
    end

    def tick(source: "background")
      return { "skipped" => "disabled" } if disabled?

      install = Reach::Enroll.current
      return { "skipped" => "not_enrolled" } unless install.is_a?(Hash)
      return { "skipped" => "revoked" } if install["revoked"]

      FileUtils.mkdir_p(Reach::Paths.state_dir)
      outcome = Reach::Locks.exclusive(tick_lock_file, wait_s: 0) do
        state = read_state
        at = now
        next { "skipped" => "recent" } if state["checked_at"] && at - state["checked_at"].to_i < MIN_GAP_S
        next { "skipped" => "backoff" } if state["next_due_at"] && at < state["next_due_at"].to_i
        next { "skipped" => "unsupported" } if state["unsupported_until"] && at < state["unsupported_until"].to_i

        check(install, state, source)
      end
      outcome == :busy ? { "skipped" => "busy" } : outcome
    rescue StandardError => e
      Reach::Debug.fault(e, "subscribe:tick")
      { "error" => e.class.name }
    end

    def check(install, state, source)
      response = fetch_revision(install, state)
      at = now
      state["checked_at"] = at
      body = response.status == 200 ? response.json : nil
      if response.status == 304
        state["failures"] = 0
        state["next_due_at"] = nil
        write_state_locked(state)
        return { "result" => "unchanged", "source" => source }
      end
      unless body.is_a?(Hash) && body["revision"].to_s != "" && body["parts"].is_a?(Hash)
        raise Reach::Error, "revision answer was malformed"
      end

      revision = body["revision"].to_s
      parts = body["parts"]
      if revision == state["revision"]
        state["failures"] = 0
        state["next_due_at"] = nil
        write_state_locked(state)
        return { "result" => "unchanged", "source" => source }
      end

      write_state_locked(state)
      sync_and_store(revision, parts, source)
    rescue Reach::RemoteRefused => e
      handle_refusal(e, state)
    rescue StandardError => e
      record_failure(state, e)
    end

    def fetch_revision(install, state)
      key = Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
      client = Reach::Client.new(
        base_url: install.fetch("teach_url"), install_id: install["install_id"], install_private_key: key,
        max_retries: 0, link: false
      )
      headers = {}
      headers["If-None-Match"] = "\"#{state['revision']}\"" if state["revision"].to_s != ""
      client.get(ROUTE, headers: headers)
    end

    def write_state_locked(state)
      update_state do |disk|
        %w[revision parts checked_at next_due_at failures unsupported_until last_sync_at].each { |key| disk[key] = state[key] }
        disk
      end
    end

    def sync_and_store(revision, parts, source)
      summary = Reach::Sync.run(wait_s: 0)
      at = now
      if summary.is_a?(Hash) && summary["state"] == "revoked"
        uninstall!
        return { "result" => "revoked", "source" => source }
      end
      if summary.is_a?(Hash) && summary["state"] == "offline"
        update_state { |state| register_failure(state) }
        return { "result" => "offline", "source" => source }
      end

      update_state do |state|
        previous = state["revision"] ? state["parts"] : nil
        add_notices(state, previous, parts, at) if previous
        state["revision"] = revision
        state["parts"] = parts
        state["last_sync_at"] = at
        state["failures"] = 0
        state["next_due_at"] = nil
        prune_notices(state, at)
      end
      { "result" => "synced", "source" => source }
    rescue Reach::Sync::Busy
      { "result" => "busy", "source" => source }
    rescue Reach::RemoteRefused => e
      refusal_result(e)
    rescue StandardError => e
      Reach::Debug.fault(e, "subscribe:sync")
      update_state { |state| register_failure(state) }
      { "result" => "failed", "source" => source }
    end

    def add_notices(state, previous, parts, at)
      changed = NOTICE_KINDS.keys.select { |part| previous[part] != parts[part] }
      notices = Array(state["notices"])
      changed.each do |part|
        kind = NOTICE_KINDS[part]
        existing = notices.find { |notice| notice["kind"] == kind && !notice["announced"] }
        if existing
          existing["at"] = at
        else
          notices << { "kind" => kind, "at" => at, "announced" => false }
        end
      end
      state["notices"] = notices
    end

    def prune_notices(state, at)
      kept = Array(state["notices"]).select { |notice| at - notice["at"].to_i <= NOTICE_TTL_S }
      state["notices"] = kept.last(NOTICE_KEEP)
    end

    def register_failure(state)
      state["failures"] = state["failures"].to_i + 1
      wait = [BACKOFF_BASE_S * (2**(state["failures"] - 1)), BACKOFF_CAP_S].min
      state["next_due_at"] = now + wait
      state
    end

    def record_failure(state, error)
      Reach::Debug.fault(error, "subscribe:check")
      update_state do |disk|
        disk["checked_at"] = state["checked_at"] || now
        register_failure(disk)
      end
      { "result" => "failed" }
    end

    def handle_refusal(error, state)
      result = refusal_result(error)
      return result if result

      record_failure(state, error)
    end

    def refusal_result(error)
      if error.status.to_i == 404
        update_state do |state|
          state["checked_at"] = now
          state["unsupported_until"] = now + UNSUPPORTED_WAIT_S
        end
        return { "result" => "unsupported" }
      end
      if %w[revoked not_enrolled].include?(error.code)
        Reach::Enroll.mark_revoked!
        uninstall!
        return { "result" => "revoked" }
      end
      nil
    end

    def prompt_notice
      state = read_state
      kinds = Array(state["notices"]).select { |notice| !notice["announced"] && now - notice["at"].to_i <= NOTICE_TTL_S }
      return nil if kinds.empty?

      names = kinds.map { |notice| notice["kind"] }.uniq
      line = nil
      update_state do |disk|
        pending = Array(disk["notices"]).select { |notice| !notice["announced"] && names.include?(notice["kind"]) }
        next if pending.empty?

        line = Reach::Messages.text("M-SUBSCRIBE-UPDATES", updates: join_words(names.map { |kind| NOTICE_WORDS[kind] || kind }))
        pending.each { |notice| notice["announced"] = true }
        prune_notices(disk, now)
      end
      line
    rescue StandardError => e
      Reach::Debug.fault(e, "subscribe:notice")
      nil
    end

    def join_words(words)
      return words.first.to_s if words.length <= 1
      return words.join(" and ") if words.length == 2

      "#{words[0...-1].join(', ')}, and #{words.last}"
    end

    def start_session_thread
      return nil if disabled?

      Thread.new do
        Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)
        loop do
          begin
            sleep(settings["session_interval_s"] + rand(0..SESSION_JITTER_S))
            Reach::Storage.spawn_detached(%w[subscribe tick --source session]) if due?
          rescue StandardError => e
            Reach::Debug.fault(e, "subscribe:thread")
          end
        end
      end
    rescue StandardError
      nil
    end

    def spawn_ensure
      return nil if disabled?

      Reach::Storage.spawn_detached(%w[subscribe ensure])
    rescue StandardError
      nil
    end

    def ensure!
      return nil if Reach::Paths.persona_id
      return nil if disabled?

      wanted = !enrolled_install.nil? && settings["background"]
      wanted ? install! : uninstall!
    rescue StandardError => e
      Reach::Debug.fault(e, "subscribe:ensure")
      nil
    end

    def tick_command
      [Reach::Runtime.ruby_path, Reach::Runtime.shim_path, "subscribe", "tick", "--source", "background"]
    end

    def platform
      if Reach::Runtime.windows?
        "windows"
      elsif RbConfig::CONFIG["host_os"].to_s =~ /darwin/
        "macos"
      else
        "linux"
      end
    end

    def systemd_override?
      !ENV["REACH_SYSTEMD_USER_DIR"].to_s.empty?
    end

    def systemd_dir
      override = ENV["REACH_SYSTEMD_USER_DIR"].to_s
      File.expand_path(override.empty? ? "~/.config/systemd/user" : override)
    end

    def launch_agents_dir
      File.expand_path("~/Library/LaunchAgents")
    end

    def plist_path
      File.join(launch_agents_dir, "#{LAUNCH_LABEL}.plist")
    end

    def vbs_path
      File.join(Reach::Paths.root, "bin", "reach-subscribe.vbs")
    end

    def unit_quote(value)
      "\"#{value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub('%', '%%')}\""
    end

    def service_unit(command = tick_command)
      [
        "[Unit]",
        "Description=rEach course update check",
        "",
        "[Service]",
        "Type=oneshot",
        "Nice=10",
        "ExecStart=#{command.map { |part| unit_quote(part) }.join(' ')}",
        ""
      ].join("\n")
    end

    def timer_unit(interval = settings["background_interval_s"])
      [
        "[Unit]",
        "Description=rEach course update timer",
        "",
        "[Timer]",
        "OnBootSec=2min",
        "OnActiveSec=2min",
        "OnUnitActiveSec=#{interval}s",
        "RandomizedDelaySec=120",
        "",
        "[Install]",
        "WantedBy=timers.target",
        ""
      ].join("\n")
    end

    def xml_escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def plist_content(command = tick_command, interval = settings["background_interval_s"])
      arguments = command.map { |part| "    <string>#{xml_escape(part)}</string>" }.join("\n")
      [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "  <key>Label</key>",
        "  <string>#{LAUNCH_LABEL}</string>",
        "  <key>ProgramArguments</key>",
        "  <array>",
        arguments,
        "  </array>",
        "  <key>StartInterval</key>",
        "  <integer>#{interval}</integer>",
        "  <key>RunAtLoad</key>",
        "  <false/>",
        "  <key>ProcessType</key>",
        "  <string>Background</string>",
        "  <key>LowPriorityIO</key>",
        "  <true/>",
        "  <key>StandardOutPath</key>",
        "  <string>/dev/null</string>",
        "  <key>StandardErrorPath</key>",
        "  <string>/dev/null</string>",
        "</dict>",
        "</plist>",
        ""
      ].join("\n")
    end

    def windowed_ruby
      ruby = Reach::Runtime.ruby_path
      candidate = File.join(File.dirname(ruby), "rubyw.exe")
      File.file?(candidate) ? candidate : nil
    end

    def vbs_content(command = tick_command)
      line = command.map { |part| "\"\"#{part}\"\"" }.join(" ")
      [
        'Set shell = CreateObject("WScript.Shell")',
        "shell.Run \"#{line}\", 0, False",
        ""
      ].join("\r\n")
    end

    def windows_quote(value)
      "\"#{value}\""
    end

    def schtasks_create(interval = settings["background_interval_s"], windowless: windowed_ruby, launcher: vbs_path)
      minutes = [interval / 60, 1].max
      action = if windowless
                 [windows_quote(windowless), windows_quote(tick_command[1]), *tick_command[2..-1]].join(" ")
               else
                 "wscript.exe //B //Nologo #{windows_quote(launcher)}"
               end
      ["schtasks", "/Create", "/F", "/SC", "MINUTE", "/MO", minutes.to_s, "/TN", TASK_NAME, "/TR", action]
    end

    def schtasks_delete
      ["schtasks", "/Delete", "/F", "/TN", TASK_NAME]
    end

    def job_plan
      interval = settings["background_interval_s"]
      case platform
      when "windows"
        windowless = windowed_ruby
        files = windowless ? {} : { vbs_path => vbs_content }
        {
          "files" => files,
          "install" => [schtasks_create(interval, windowless: windowless)],
          "uninstall" => [schtasks_delete],
          "remove" => [vbs_path],
          "location" => TASK_NAME
        }
      when "macos"
        uid = Process.uid.to_s
        {
          "files" => { plist_path => plist_content(tick_command, interval) },
          "install" => [["launchctl", "bootout", "gui/#{uid}/#{LAUNCH_LABEL}"], ["launchctl", "bootstrap", "gui/#{uid}", plist_path]],
          "fallback" => [["launchctl", "load", "-w", plist_path]],
          "uninstall" => [["launchctl", "bootout", "gui/#{uid}/#{LAUNCH_LABEL}"]],
          "uninstall_fallback" => [["launchctl", "unload", "-w", plist_path]],
          "remove" => [plist_path],
          "location" => plist_path
        }
      else
        dir = systemd_dir
        override = systemd_override?
        {
          "files" => {
            File.join(dir, SERVICE_NAME) => service_unit,
            File.join(dir, TIMER_NAME) => timer_unit(interval)
          },
          "install" => override ? [] : [%w[systemctl --user daemon-reload], ["systemctl", "--user", "enable", "--now", TIMER_NAME]],
          "uninstall" => override ? [] : [["systemctl", "--user", "disable", "--now", TIMER_NAME]],
          "after_remove" => override ? [] : [%w[systemctl --user daemon-reload]],
          "remove" => [File.join(dir, SERVICE_NAME), File.join(dir, TIMER_NAME)],
          "location" => dir,
          "needs_manager" => !override
        }
      end
    end

    def plan_signature(plan)
      Digest::SHA256.hexdigest(JSON.generate("files" => plan["files"], "install" => plan["install"]))
    end

    def installed?
      plan = job_plan
      job = read_state["job"]
      return false unless job.is_a?(Hash) && job["installed"] && job["signature"] == plan_signature(plan)

      plan["files"].all? { |path, content| File.file?(path) && File.read(path) == content }
    rescue StandardError
      false
    end

    def install!
      plan = job_plan
      signature = plan_signature(plan)
      if plan["needs_manager"] && !run_os(%w[systemctl --user show-environment]).first
        record_job("installed" => false, "platform" => platform, "error" => "systemd user manager unavailable")
        return :unsupported
      end

      changed = false
      plan["files"].each do |path, content|
        next if File.file?(path) && File.read(path) == content

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        changed = true
      end
      current = read_state["job"]
      known = current.is_a?(Hash) && current["installed"] && current["signature"] == signature
      return :unchanged if known && !changed

      ok = run_plan(plan["install"], plan["fallback"])
      unless ok
        record_job("installed" => false, "platform" => platform, "signature" => signature, "error" => "operating system call failed")
        return :failed
      end
      record_job("installed" => true, "platform" => platform, "signature" => signature, "location" => plan["location"], "error" => nil)
      :installed
    rescue StandardError => e
      Reach::Debug.fault(e, "subscribe:install")
      record_job("installed" => false, "platform" => platform, "error" => e.class.name)
      :failed
    end

    def uninstall!
      plan = job_plan
      present = plan["files"].keys.any? { |path| File.file?(path) } || (read_state["job"].is_a?(Hash) && read_state["job"]["installed"])
      return :unchanged unless present

      ok = run_plan(plan["uninstall"], plan["uninstall_fallback"])
      Array(plan["remove"]).each do |path|
        begin
          File.delete(path) if File.file?(path)
        rescue StandardError => e
          Reach::Debug.fault(e, "subscribe:uninstall")
        end
      end
      Array(plan["after_remove"]).each { |command| run_os(*command) }
      record_job("installed" => false, "platform" => platform, "error" => ok ? nil : "operating system call failed")
      ok ? :uninstalled : :failed
    rescue StandardError => e
      Reach::Debug.fault(e, "subscribe:uninstall")
      :failed
    end

    def run_plan(commands, fallback)
      commands = Array(commands)
      return true if commands.empty?

      results = commands.map { |command| run_os(*command).first }
      return true if results.all?
      return false if Array(fallback).empty?

      Array(fallback).map { |command| run_os(*command).first }.all?
    end

    def record_job(job)
      update_state { |state| state["job"] = job }
      nil
    end

    def run_os(*command)
      reader, writer = IO.pipe
      pid = Process.spawn(*command, in: File::NULL, out: writer, err: writer)
      writer.close
      collector = Thread.new { reader.read.to_s }
      waiter = Process.detach(pid)
      if waiter.join(OS_TIMEOUT_S)
        [waiter.value.success?, collector.value]
      else
        begin
          Process.kill("KILL", pid)
        rescue StandardError
          nil
        end
        Reach::Debug.fault(Reach::Error.new("operating system call timed out"), "subscribe:os")
        [false, "timeout"]
      end
    rescue StandardError => e
      Reach::Debug.fault(e, "subscribe:os")
      [false, e.message]
    ensure
      begin
        writer.close if writer && !writer.closed?
        reader.close if reader && !reader.closed?
      rescue StandardError
        nil
      end
    end

    def status
      state = read_state
      config = settings
      job = state["job"].is_a?(Hash) ? state["job"] : {}
      {
        "enabled" => !disabled?,
        "enrolled" => !enrolled_install.nil?,
        "settings" => config,
        "job" => {
          "installed" => installed?,
          "platform" => platform,
          "location" => job["location"] || job_plan["location"],
          "error" => job["error"]
        },
        "revision" => state["revision"],
        "checked_at" => iso(state["checked_at"]),
        "next_due_at" => iso([state["next_due_at"], state["unsupported_until"], state["checked_at"] && (state["checked_at"] + MIN_GAP_S)].compact.map(&:to_i).max),
        "last_sync_at" => iso(state["last_sync_at"]),
        "failures" => state["failures"].to_i,
        "unsupported_until" => iso(state["unsupported_until"]),
        "notices" => Array(state["notices"]).map { |notice| { "kind" => notice["kind"], "at" => iso(notice["at"]), "announced" => notice["announced"] ? true : false } }
      }
    end

    def status_lines(data = status)
      job = data["job"]
      lines = []
      lines << "background check: #{data['settings']['background'] ? 'on' : 'off'} (every #{data['settings']['background_interval_s']} s)"
      lines << "open-session check: every #{data['settings']['session_interval_s']} s"
      lines << "background job: #{job['installed'] ? "installed (#{job['location']})" : "not installed#{job['error'] ? " (#{job['error']})" : ''}"}"
      lines << "last check: #{data['checked_at'] || 'never'}"
      lines << "next check: #{data['next_due_at'] || 'any time'}"
      lines << "last sync: #{data['last_sync_at'] || 'never'}"
      lines << "failures: #{data['failures']}"
      lines << "unsupported until: #{data['unsupported_until']}" if data["unsupported_until"]
      lines << "switched off: REACH_OFFLINE or REACH_SUBSCRIBE" unless data["enabled"]
      lines
    end

    def doctor_line
      data = status
      job = data["job"]
      state = job["installed"] ? "background job installed" : "background job not installed#{job['error'] ? " (#{job['error']})" : ''}"
      "#{state}; last check #{data['checked_at'] || 'never'}"
    rescue StandardError
      "not checked"
    end
  end
end
