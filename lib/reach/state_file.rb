require "json"
require "fileutils"

module Reach
  module StateFile
    RENAME_RETRIES = 5
    RENAME_RETRY_S = 0.05

    module_function

    def path(name)
      File.join(Reach::Paths.state_dir, name)
    end

    def read(name)
      file = path(name)
      return {} unless File.file?(file)

      data = JSON.parse(File.read(file))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write(name, data)
      write_atomic(path(name), JSON.generate(data))
    end

    def write_atomic(file, content, mode: 0o600)
      FileUtils.mkdir_p(File.dirname(file))
      tmp = "#{file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, mode) do |handle|
        handle.write(content)
        handle.flush
        handle.fsync
      end
      rename_into_place(tmp, file)
      file
    rescue StandardError
      FileUtils.rm_f(tmp) if tmp
      raise
    end

    def rename_into_place(tmp, file)
      attempts = 0
      begin
        File.rename(tmp, file)
      rescue Errno::EACCES, Errno::EBUSY
        attempts += 1
        raise if attempts >= RENAME_RETRIES

        sleep(RENAME_RETRY_S * attempts)
        retry
      end
    end

    def update(name)
      FileUtils.mkdir_p(Reach::Paths.state_dir)
      Reach::Locks.exclusive("#{path(name)}.lock") do |_lock|
        state = read(name)
        before = JSON.generate(state)
        result = yield(state)
        write(name, state) unless JSON.generate(state) == before
        result
      end
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
