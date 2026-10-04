require "json"
require "fileutils"

module Reach
  module StateFile
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
      file = path(name)
      FileUtils.mkdir_p(File.dirname(file))
      tmp = "#{file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |handle|
        handle.write(JSON.generate(data))
        handle.flush
        handle.fsync
      end
      File.rename(tmp, file)
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
