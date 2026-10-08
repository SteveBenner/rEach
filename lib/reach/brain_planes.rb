require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "timeout"

module Reach
  module BrainPlanes
    LOG_FILE = "brain-planes.log".freeze
    PENDING_FILE = "pending-erase.jsonl".freeze
    PENDING_LOCK = "pending-erase.lock".freeze

    module_function

    def enabled?
      return false if ENV["REACH_BRAIN_PLANES_DISABLE"] == "1"
      return false if Reach::Paths.persona_id

      section = Reach::Runtime.load_config["brain"]
      !(section.is_a?(Hash) && section["planes"] == false)
    rescue StandardError
      false
    end

    def in_process?
      defined?(Rplugin::Ports) ? true : false
    end

    def child?
      ENV["REACH_BRAIN_PLANES_CHILD"] == "1"
    end

    def ruby
      return RbConfig.ruby if in_process?

      runtime = Reach::RuntimeKit.active
      exe = runtime && runtime["ruby_exe"]
      exe && File.file?(exe) ? exe : nil
    rescue StandardError
      nil
    end

    def sdk_home
      return nil if in_process?

      sdk = Reach::SdkKit.active
      sdk ? sdk["home"] : nil
    rescue StandardError
      nil
    end

    def available?
      return false unless enabled?

      in_process? || !(ruby.nil? || sdk_home.nil?)
    rescue StandardError
      false
    end

    def corpora_home
      File.join(Reach::Paths.home, "corpora")
    end

    def planes_dir
      File.join(corpora_home, "reach")
    end

    def pending_path
      File.join(Reach::Brain.dir, PENDING_FILE)
    end

    def pending_lock_path
      File.join(Reach::Brain.dir, PENDING_LOCK)
    end

    def state_base
      File.dirname(Reach::BrainSpool.state_home)
    end

    def env
      return Reach::RuntimeKit.clean_env("REACH_BRAIN_PLANES_CHILD" => "1") if in_process?

      Reach::RuntimeKit.clean_env(
        "RPLUGIN_HOME" => sdk_home,
        "RPLUGIN_CORPORA_HOME" => corpora_home,
        "RPLUGIN_REGISTRY_FILE_ONLY" => "1",
        "RPLUGIN_SCHEDULE_ADAPTER" => "none",
        "RLOGS_DISABLE" => "1",
        "RNOTIFY_DISABLE" => "1",
        "REACH_BRAIN_PLANES_CHILD" => "1",
        "XDG_STATE_HOME" => state_base
      )
    end

    def exe
      File.expand_path("../../exe/reach", __dir__)
    end

    def log_path
      File.join(Reach::Paths.logs_dir, LOG_FILE)
    end

    def spawn(args)
      return nil unless available?

      interpreter = ruby
      FileUtils.mkdir_p(Reach::Paths.logs_dir)
      Reach::Debug.rotate_log(log_path)
      pid = Process.spawn(env, interpreter, exe, *args.map(&:to_s), in: File::NULL, out: [log_path, "a", 0o600], err: [:child, :out], **Reach::Runtime.detach_group)
      Process.detach(pid)
      pid
    rescue StandardError
      nil
    end

    def run(args, timeout:)
      return nil unless available?

      interpreter = ruby
      options = Reach::Runtime.windows? ? { new_pgroup: true } : { pgroup: true }
      Open3.popen3(env, interpreter, exe, *args.map(&:to_s), **options) do |stdin, stdout, stderr, thread|
        stdin.close
        out_reader = Thread.new { stdout.read.to_s }
        err_reader = Thread.new { stderr.read.to_s }
        unless thread.join(timeout)
          kill_group(thread.pid)
          thread.join
          out_reader.join(2)
          err_reader.join(2)
          return nil
        end
        return [out_reader.value, thread.value]
      end
    rescue StandardError
      nil
    end

    def kill_group(pid)
      if Reach::Runtime.windows?
        Process.kill("KILL", pid)
      else
        Process.kill("KILL", -pid)
      end
    rescue SystemCallError
      begin
        Process.kill("KILL", pid)
      rescue SystemCallError
        nil
      end
    end

    def pending_count
      return 0 unless File.file?(pending_path)

      File.readlines(pending_path).count { |line| !line.strip.empty? }
    rescue StandardError
      0
    end

    def status_line
      line = describe
      count = pending_count
      count.positive? ? "#{line}; pending erases: #{count}" : line
    rescue StandardError
      "planes: spool mode (could not be checked)"
    end

    def describe
      return "planes: spool mode (disabled)" if ENV["REACH_BRAIN_PLANES_DISABLE"] == "1" || planes_off_in_config?
      return "planes: spool mode (persona)" if Reach::Paths.persona_id
      return "planes: in-process" if in_process?
      return "planes: spool mode (no runtime kit)" if ruby.nil?

      sdk = Reach::SdkKit.active
      unless sdk
        return Reach::SdkKit.pinned? ? "planes: spool mode (SDK not installed)" : "planes: spool mode (SDK not pinned in this build)"
      end

      info = sdk["info"]
      "planes: kit SDK #{sdk['sdk_id']} (rplugin #{info['rplugin_version']}, rBrain #{info['rbrain_version']}), corpus #{planes_dir}"
    end

    def planes_off_in_config?
      section = Reach::Runtime.load_config["brain"]
      section.is_a?(Hash) && section["planes"] == false
    rescue StandardError
      false
    end
  end
end
