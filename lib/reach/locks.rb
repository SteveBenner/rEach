module Reach
  module Locks
    class Busy < StandardError; end

    POLL_S = 0.02
    DEFAULT_WAIT_S = 2.0

    @bounded = false
    @spent = 0.0
    @configured = nil

    module_function

    def bounded?
      @bounded == true
    end

    def bound!(value = true)
      @bounded = value ? true : false
    end

    def refill!
      @spent = 0.0
    end

    def configured_wait_s
      return @configured if @configured

      section = Reach::Runtime.load_config["hooks"]
      given = section.is_a?(Hash) ? section["lock_wait_s"] : nil
      @configured = given.is_a?(Numeric) && given >= 0 ? given.to_f : DEFAULT_WAIT_S
    rescue StandardError
      DEFAULT_WAIT_S
    end

    def effective_wait_s(wait_s)
      return wait_s.to_f unless wait_s.nil?
      return nil unless bounded?

      [configured_wait_s - @spent, 0.0].max
    end

    def acquire(file, _path = nil, wait_s = nil)
      limit = effective_wait_s(wait_s)
      if limit.nil?
        file.flock(File::LOCK_EX)
        return true
      end

      return true if file.flock(File::LOCK_EX | File::LOCK_NB)

      began = clock
      deadline = began + limit
      while clock < deadline
        sleep([POLL_S, deadline - clock].min.clamp(0.001, POLL_S))
        if file.flock(File::LOCK_EX | File::LOCK_NB)
          spend(began, wait_s)
          return true
        end
      end
      spend(began, wait_s)
      false
    end

    def spend(began, wait_s)
      @spent += clock - began if wait_s.nil?
    end

    def exclusive(path, wait_s: nil, mode: File::RDWR | File::CREAT, perm: 0o600)
      File.open(path, mode, perm) do |file|
        return :busy unless acquire(file, path, wait_s)

        yield file
      end
    end

    def free?(path)
      return true unless File.exist?(path)

      File.open(path, File::RDWR) do |file|
        return false unless file.flock(File::LOCK_EX | File::LOCK_NB)

        file.flock(File::LOCK_UN)
      end
      true
    rescue StandardError
      true
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
