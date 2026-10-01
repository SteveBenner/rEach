require "json"
require "fileutils"
require "rbconfig"
require "stringio"
require "time"

module Reach
  module RuntimeAuto
    STATE_FILE = "runtime-auto.json".freeze
    LOCK_FILE = "runtime-install.lock".freeze
    DEFAULT_INTERVAL_S = 3600
    DEFAULT_JITTER_S = 600
    DEFAULT_MAX_ATTEMPTS = 5
    BUSY = "reach: the runtime is already being installed in the background; check again in a few minutes with reach runtime status".freeze
    SETUP_NOTE = "Reach's checking tools (Ruby 4.0.7, prebuilt gems and Chrome for Testing, about 250 MB) install themselves in the background when the next session starts. Nothing to ask the student.".freeze
    STILL_INSTALLING = " (the course's checking tools are still installing in the background; try again in a few minutes)".freeze

    module_function

    def config
      section = Reach::Runtime.load_config["runtime"]
      section = {} unless section.is_a?(Hash)
      {
        "auto_install" => section["auto_install"] != false,
        "interval_s" => Reach::Update.setting_int(section["interval_s"], DEFAULT_INTERVAL_S),
        "jitter_s" => Reach::Update.setting_int(section["jitter_s"], DEFAULT_JITTER_S),
        "max_attempts" => Reach::Update.setting_int(section["max_attempts"], DEFAULT_MAX_ATTEMPTS)
      }
    end

    def enabled?
      config["auto_install"] && !Reach::RuntimeKit.network_disabled? && Reach::RuntimeKit.supported? && Reach::RuntimeKit.pinned?
    end

    def state_path
      File.join(Reach::Paths.state_dir, STATE_FILE)
    end

    def lock_path
      File.join(Reach::Paths.state_dir, LOCK_FILE)
    end

    def load_state
      return {} unless File.file?(state_path)

      data = JSON.parse(File.read(state_path))
      return {} unless data.is_a?(Hash)

      data["runtime_id"] == Reach::RuntimeKit::RUNTIME_ID ? data : {}
    rescue StandardError
      {}
    end

    def save_state(data)
      FileUtils.mkdir_p(File.dirname(state_path))
      tmp = "#{state_path}.tmp-#{Process.pid}"
      File.write(tmp, JSON.generate(data.merge("runtime_id" => Reach::RuntimeKit::RUNTIME_ID)))
      File.rename(tmp, state_path)
      true
    rescue StandardError
      false
    end

    def with_lock
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |file|
        return :busy unless file.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def installing?
      return false unless File.file?(lock_path)

      File.open(lock_path, File::RDWR) do |file|
        free = file.flock(File::LOCK_EX | File::LOCK_NB)
        file.flock(File::LOCK_UN) if free
        !free
      end
    rescue StandardError
      false
    end

    def due?(now = Time.now)
      return false unless enabled?
      return false if Reach::RuntimeKit.active || installing?

      state = load_state
      return false if state["attempts"].to_i >= config["max_attempts"]

      next_at = begin
        Time.parse(state["next_at"].to_s)
      rescue ArgumentError
        nil
      end
      next_at.nil? || now >= next_at
    end

    def start(now = Time.now)
      return nil unless due?(now)

      settings = config
      state = load_state
      attempt = state["attempts"].to_i + 1
      state["attempts"] = attempt
      state["started_at"] = now.utc.iso8601
      state["next_at"] = (now + settings["interval_s"] + rand(settings["jitter_s"] + 1)).utc.iso8601
      return nil unless save_state(state)

      Reach::Download.log("event" => "runtime.auto.start", "runtime_id" => Reach::RuntimeKit::RUNTIME_ID, "attempt" => attempt)
      spawn_install
    rescue StandardError
      nil
    end

    def spawn_install
      exe = File.join(Reach::Runtime.root, "exe", "reach")
      options = { in: File::NULL, out: File::NULL, err: File::NULL }
      if Reach::Runtime.windows?
        options[:new_pgroup] = true
      else
        options[:pgroup] = true
      end
      pid = Process.spawn(RbConfig.ruby, exe, "runtime", "install", "--auto", options)
      Process.detach(pid)
      pid
    end

    def run
      result = with_lock { Reach::RuntimeKit.install!(out: StringIO.new) }
      if result == :busy
        Reach::Download.log("event" => "runtime.auto.skip", "reason" => "busy")
        return 0
      end

      state = load_state
      state["attempts"] = 0
      state["installed_at"] = Time.now.utc.iso8601
      state.delete("last_error")
      save_state(state)
      0
    rescue Reach::Error, SystemCallError => e
      state = load_state
      state["last_error"] = e.message
      save_state(state)
      1
    end
  end
end
