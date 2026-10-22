require "json"
require "securerandom"
require "net/http"
require "open3"
require "socket"
require "time"
require "fileutils"
require "timeout"

module Reach
  module Preview
    IDLE_S = 1800
    START_WAIT_S = 20
    SHOT_WAIT_S = 60
    STATE_NAME = "preview.json".freeze
    SERVER = File.expand_path("kit/preview_server.rb", __dir__).freeze
    SHOT = File.expand_path("kit/preview_shot.rb", __dir__).freeze

    module_function

    def start(workspace, open: true)
      Reach::BehaviorPolicy.ensure!
      Reach::Login.require_active!
      Reach::KnownIssues.require_hooks!
      launch(workspace, open: open)
    end

    def launch(workspace, open: true)
      meta = Reach::Workspace.metadata(workspace)
      raise Reach::Refused, Reach::Messages.text("M-PREVIEW-NOT-PANEL") unless meta["slice"] == "panel"
      raise Reach::Refused, Reach::Messages.text("M-PREVIEW-NO-PRACTICE") unless File.file?(File.join(workspace, Reach::Qualify::KIT_DIR, "app", "index.html"))

      current = live_state
      if current && File.expand_path(current["workspace"].to_s) == File.expand_path(workspace)
        opened = open && Reach::Desktop.open_url(current["url"])
        return running_result(current, opened)
      end
      stop if current

      run_dir = Reach::Qualify.assemble_local(workspace, meta, stub: false, name: "preview")
      gems = prepare_kit(run_dir)
      module_id = meta["cutout_id"].to_s.split(".").first.to_s
      port = free_port
      key = SecureRandom.hex(16)
      qualify = meta["qualify"].is_a?(Hash) ? meta["qualify"] : {}
      env, _dropped = Reach::Qualify.sanitize_env(qualify["env"])
      env = env.merge(
        "REACH_PREVIEW_PORT" => port.to_s,
        "REACH_PREVIEW_WORKSPACE" => File.expand_path(workspace),
        "REACH_PREVIEW_OWNED" => JSON.generate(Array(meta["owned_files"]).map(&:to_s)),
        "REACH_PREVIEW_IDLE_S" => IDLE_S.to_s,
        "REACH_PREVIEW_KEY" => key
      )
      env, prefix = Reach::Suite.kit_launch(gems, env)
      log = "#{run_dir}.log"
      pid = spawn_server(env, prefix, run_dir, log)
      url = "http://127.0.0.1:#{port}/#{module_id.tr('_', '-')}?reach_key=#{key}"
      wait_for_server(pid, port, log)
      state = {
        "pid" => pid, "port" => port, "url" => url, "workspace" => File.expand_path(workspace), "run_dir" => run_dir,
        "module_id" => module_id, "started_at" => Time.now.utc.iso8601, "log" => log
      }
      write_state(state)
      opened = open && Reach::Desktop.open_url(url)
      Reach::Debug.emit("command", "command" => "preview", "action" => "start", "ok" => true, "opened" => opened ? true : false)
      running_result(state, opened)
    end

    def stop
      state = read_state
      return { "state" => "none", "message" => Reach::Messages.text("M-PREVIEW-NONE") } if state.empty?

      Reach::Suite.kill_tree(state["pid"].to_i) if ours?(state)
      FileUtils.rm_f(state_path)
      { "state" => "stopped", "message" => Reach::Messages.text("M-PREVIEW-STOPPED") }
    end

    def status
      state = live_state
      return { "state" => "none", "message" => Reach::Messages.text("M-PREVIEW-NONE") } unless state

      { "state" => "running", "url" => state["url"], "workspace" => state["workspace"] }
    end

    def screenshot(workspace)
      state = launch(workspace, open: false)
      current = read_state
      chrome = Reach::Suite.chromium_binary
      raise Reach::Refused, Reach::Messages.text("M-PREVIEW-NOBROWSER") unless chrome

      run_dir = current["run_dir"].to_s
      gems = prepare_kit(run_dir)
      env, prefix = Reach::Suite.kit_launch(gems)
      dir = File.join(Reach::Paths.home, "previews")
      FileUtils.mkdir_p(dir, mode: 0o700)
      out = File.join(dir, "#{File.basename(workspace)}-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.png")
      result = run_shot(env, prefix + ["ruby", SHOT, state["url"], out, current["module_id"].to_s], run_dir)
      result.merge(
        "url" => state["url"],
        "message" => Reach::Messages.text("M-PREVIEW-SHOT", path: result["png"] || out, errors: Array(result["console_errors"]).length)
      )
    rescue Reach::Error
      raise
    rescue StandardError => e
      raise Reach::Refused, Reach::Messages.text("M-PREVIEW-FAILED", reason: e.message.to_s.lines.first.to_s.strip[0, 300])
    end

    def prepare_kit(run_dir)
      Reach::Suite.select_lock!(run_dir)
      Reach::Suite.install_gems(run_dir)
    rescue Reach::Error => e
      raise Reach::Refused, Reach::Messages.text("M-PREVIEW-FAILED", reason: e.message.to_s.lines.first.to_s.strip[0, 300])
    end

    def run_shot(env, argv, run_dir)
      stdout = +""
      stderr = +""
      timed_out = false
      group = Reach::Untar.windows? ? { new_pgroup: true } : { pgroup: true }
      Open3.popen3(env, *argv, chdir: run_dir, **group) do |stdin, out, err, wait_thr|
        stdin.close
        out_buffer = String.new
        err_buffer = String.new
        readers = [Thread.new { Reach::Suite.pump(out, out_buffer) }, Thread.new { Reach::Suite.pump(err, err_buffer) }]
        unless wait_thr.join(SHOT_WAIT_S)
          timed_out = true
          Reach::Suite.kill_tree(wait_thr.pid)
          wait_thr.join
        end
        readers.each { |reader| reader.join(Reach::Suite::PIPE_GRACE_S) || reader.kill }
        stdout = out_buffer.dup.force_encoding(Encoding::UTF_8).scrub
        stderr = err_buffer.dup.force_encoding(Encoding::UTF_8).scrub
      end
      raise Reach::Refused, Reach::Messages.text("M-PREVIEW-FAILED", reason: "the screenshot took too long") if timed_out

      line = stdout.lines.map(&:strip).reject(&:empty?).last
      parsed = line ? (JSON.parse(line) rescue nil) : nil
      unless parsed.is_a?(Hash)
        reason = stderr.lines.map(&:strip).reject(&:empty?).last.to_s[0, 300]
        raise Reach::Refused, Reach::Messages.text("M-PREVIEW-FAILED", reason: reason.empty? ? "the screenshot could not be taken" : reason)
      end
      parsed
    end

    def spawn_server(env, prefix, run_dir, log)
      group = Reach::Untar.windows? ? { new_pgroup: true } : { pgroup: true }
      sink = File.open(log, File::WRONLY | File::APPEND | File::CREAT, 0o600)
      sink.chmod(0o600)
      pid = Process.spawn(env, *prefix, "ruby", SERVER, chdir: run_dir, in: File::NULL, out: sink, err: sink, **group)
      sink.close
      Process.detach(pid)
      pid
    rescue SystemCallError => e
      raise Reach::Refused, Reach::Messages.text("M-PREVIEW-FAILED", reason: e.message.to_s[0, 300])
    end

    def wait_for_server(pid, port, log)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_WAIT_S
      loop do
        return true if answers?(port)

        died = !alive?(pid)
        if died || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Reach::Suite.kill_tree(pid) unless died
          raise Reach::Refused, Reach::Messages.text("M-PREVIEW-FAILED", reason: last_log_line(log))
        end
        sleep 0.25
      end
    end

    def last_log_line(log)
      line = File.file?(log) ? File.read(log).to_s.lines.map(&:strip).reject(&:empty?).last : nil
      line ? line[0, 300] : "the preview did not answer in time"
    rescue SystemCallError
      "the preview did not answer in time"
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def answers?(port)
      http = Net::HTTP.new("127.0.0.1", port)
      http.open_timeout = 1
      http.read_timeout = 1
      request = Net::HTTP::Get.new("/")
      request["Host"] = "127.0.0.1:#{port}"
      http.request(request)
      true
    rescue StandardError, Timeout::Error
      false
    end

    def alive?(pid)
      return false unless pid.to_i.positive?

      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def live_state
      state = read_state
      return nil if state.empty?
      return state if ours?(state)

      FileUtils.rm_f(state_path)
      nil
    end

    def ours?(state)
      alive?(state["pid"]) && answers?(state["port"].to_i)
    end

    def running_result(state, opened)
      {
        "state" => "running", "url" => state["url"], "opened" => opened ? true : false, "idle_minutes" => IDLE_S / 60,
        "message" => Reach::Messages.text("M-PREVIEW-READY", url: state["url"])
      }
    end

    def state_path
      File.join(Reach::Paths.state_dir, STATE_NAME)
    end

    def read_state
      data = JSON.parse(File.read(state_path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write_state(state)
      Reach::StateFile.write_atomic(state_path, JSON.generate(state), mode: 0o600)
    end
  end
end
