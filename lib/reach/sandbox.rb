require "fileutils"

module Reach
  module Sandbox
    WRITE_ERRORS = [Errno::EPERM, Errno::EACCES, Errno::EROFS].freeze

    module_function

    def active?
      !ENV["CODEX_SANDBOX"].to_s.empty? || ENV["CODEX_SANDBOX_NETWORK_DISABLED"].to_s == "1"
    end

    def network_blocked?
      ENV["CODEX_SANDBOX_NETWORK_DISABLED"].to_s == "1"
    end

    def home_writable?
      return @home_writable unless @home_writable.nil?

      @home_writable = probe_home
    end

    def blocked?
      active? && (network_blocked? || !home_writable?)
    end

    def blocking_error?(error)
      return false unless active?
      return true if error.is_a?(Reach::NetworkError) && error.cause_name == "codex_sandbox"

      write_error = [error, error.cause].any? { |candidate| WRITE_ERRORS.any? { |klass| candidate.is_a?(klass) } }
      write_error && !home_writable?
    end

    def agent_text
      Reach::Messages.text("M-SANDBOX-AGENT", student: Reach::Messages.text("M-SANDBOX-STUDENT", folder: course_folder))
    end

    def course_folder
      path = Reach::Paths.workspace_root
      File::ALT_SEPARATOR ? path.tr(File::SEPARATOR, File::ALT_SEPARATOR) : path
    end

    def reset!
      @home_writable = nil
    end

    def probe_home
      dir = Reach::Paths.root_state_dir
      FileUtils.mkdir_p(dir)
      probe = File.join(dir, ".sandbox-probe-#{Process.pid}")
      File.write(probe, "")
      File.delete(probe)
      true
    rescue *WRITE_ERRORS
      false
    rescue StandardError
      true
    end
  end
end
