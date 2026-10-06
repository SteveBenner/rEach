require "json"
require "fileutils"
require "rbconfig"
require "stringio"
require "time"

module Reach
  module SdkAuto
    STATE_FILE = "sdk-auto.json".freeze
    LOCK_FILE = "sdk-install.lock".freeze
    DEFAULT_INTERVAL_S = 3600
    DEFAULT_JITTER_S = 600
    DEFAULT_MAX_ATTEMPTS = 5
    BUSY = "reach: the SDK is already being installed in the background; check again in a few minutes with reach sdk status".freeze

    module_function

    def config
      section = Reach::Runtime.load_config["sdk"]
      section = {} unless section.is_a?(Hash)
      {
        "auto_install" => section["auto_install"] != false,
        "interval_s" => Reach::Update.setting_int(section["interval_s"], DEFAULT_INTERVAL_S),
        "jitter_s" => Reach::Update.setting_int(section["jitter_s"], DEFAULT_JITTER_S),
        "max_attempts" => Reach::Update.setting_int(section["max_attempts"], DEFAULT_MAX_ATTEMPTS)
      }
    end

    def state_path
      File.join(Reach::Paths.root_state_dir, STATE_FILE)
    end

    def lock_path
      File.join(Reach::Paths.root_state_dir, LOCK_FILE)
    end

    def load_state
      return {} unless File.file?(state_path)

      data = JSON.parse(File.read(state_path))
      return {} unless data.is_a?(Hash)

      data["sdk_id"] == Reach::SdkKit::SDK_ID ? data : {}
    rescue StandardError
      {}
    end

    def save_state(data)
      FileUtils.mkdir_p(File.dirname(state_path))
      tmp = "#{state_path}.tmp-#{Process.pid}"
      File.write(tmp, JSON.generate(data.merge("sdk_id" => Reach::SdkKit::SDK_ID)))
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

    def runtime_ruby?
      runtime = Reach::RuntimeKit.active
      !(runtime.nil? || runtime["ruby_exe"].nil?)
    rescue StandardError
      false
    end

    def current?
      sdk = Reach::SdkKit.active
      !sdk.nil? && sdk["sdk_id"] == Reach::SdkKit::SDK_ID
    end

    def enabled?
      config["auto_install"] && Reach::BrainPlanes.enabled? && Reach::SdkKit.pinned? && !Reach::SdkKit.disabled?
    end

    def due?(now = Time.now)
      return false unless enabled?
      return false unless runtime_ruby?
      return false if current?
      return false if installing?

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

      Reach::Download.log("event" => "sdk.auto.start", "sdk_id" => Reach::SdkKit::SDK_ID, "attempt" => attempt)
      spawn_install
    rescue StandardError
      nil
    end

    def spawn_install
      exe = File.join(Reach::Runtime.root, "exe", "reach")
      options = { in: File::NULL, out: File::NULL, err: File::NULL }.merge(Reach::Runtime.detach_group)
      pid = Process.spawn(RbConfig.ruby, exe, "sdk", "install", "--auto", options)
      Process.detach(pid)
      pid
    end

    def run
      result = with_lock { Reach::SdkKit.install!(out: StringIO.new) }
      if result == :busy
        Reach::Download.log("event" => "sdk.auto.skip", "reason" => "busy")
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
