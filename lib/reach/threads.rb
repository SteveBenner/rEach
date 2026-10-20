require "json"
require "fileutils"

module Reach
  module Threads
    TIME_FMT = "%Y-%m-%dT%H:%M:%SZ".freeze
    DEFAULT_MAX_THREADS = 64

    module_function

    def file
      File.join(Reach::Paths.state_dir, "threads.json")
    end

    def lock_file
      "#{file}.lock"
    end

    def blank
      { "threads" => {}, "active" => {} }
    end

    def now
      Time.now.utc.strftime(TIME_FMT)
    end

    def max_threads
      value = Reach::BehaviorPolicy.parameters("assignment_context")["max_threads"]
      value.is_a?(Integer) && value.positive? ? value : DEFAULT_MAX_THREADS
    rescue StandardError
      DEFAULT_MAX_THREADS
    end

    def read
      return blank unless File.file?(file)

      parsed = JSON.parse(File.read(file))
      return blank unless parsed.is_a?(Hash) && parsed["threads"].is_a?(Hash)

      { "threads" => parsed["threads"], "active" => parsed["active"].is_a?(Hash) ? parsed["active"] : {} }
    rescue StandardError
      blank
    end

    def write(data)
      FileUtils.mkdir_p(File.dirname(file))
      temp = "#{file}.#{Process.pid}.tmp"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |handle| handle.write(JSON.generate(data)) }
      File.rename(temp, file)
    end

    def locked
      FileUtils.mkdir_p(File.dirname(file))
      File.open(lock_file, File::RDWR | File::CREAT, 0o600) do |handle|
        handle.flock(File::LOCK_EX)
        yield
      end
    end

    def prune(data)
      limit = max_threads
      threads = data["threads"]
      return data if threads.size <= limit

      keep = threads.sort_by { |_id, thread| thread["last_seen_at"].to_s }.last(limit).map(&:first)
      data["threads"] = threads.select { |id, _thread| keep.include?(id) }
      data["active"] = data["active"].select { |_harness, id| data["threads"].key?(id) }
      data
    end

    def start(id, harness, source)
      id = id.to_s
      locked do
        data = read
        others = data["threads"].reject { |key, _thread| key == id }
        latest = others.values.max_by { |thread| thread["last_seen_at"].to_s }
        previous = latest ? Marshal.load(Marshal.dump(latest)) : nil
        stamp = now
        thread = data["threads"][id]
        unless thread
          thread = { "harness" => harness.to_s, "started_at" => stamp, "reads" => {}, "required" => [] }
          data["threads"][id] = thread
        end
        if source == "compact"
          thread["reads"] = {}
          thread["compacted_at"] = stamp
        end
        thread["last_seen_at"] = stamp
        data["active"][harness.to_s] = id
        write(prune(data))
        [thread, previous]
      end
    end

    def update(id)
      id = id.to_s
      locked do
        data = read
        thread = data["threads"][id]
        next nil unless thread

        yield thread
        write(data)
        thread
      end
    end

    def touch(id, harness)
      id = id.to_s
      locked do
        data = read
        thread = data["threads"][id]
        next nil unless thread

        thread["last_seen_at"] = now
        data["active"][harness.to_s] = id
        write(data)
        thread
      end
    end

    def env_session_id
      raw = [ENV["CLAUDE_CODE_SESSION_ID"], ENV["CODEX_THREAD_ID"], ENV["CODEX_SESSION_ID"]].map(&:to_s).find { |value| !value.empty? }
      return nil unless raw

      raw.gsub(/[^A-Za-z0-9._:-]/, "_")[0, 128]
    end

    def resolve_in(data, harness)
      from_env = env_session_id
      return from_env if from_env && data["threads"].key?(from_env)

      active = data["active"][harness.to_s]
      return active if active && data["threads"].key?(active)

      latest = data["threads"].max_by { |_id, thread| thread["last_seen_at"].to_s }
      latest && latest.first
    end

    def resolve(harness)
      resolve_in(read, harness)
    end

    def record_read(path, harness)
      locked do
        data = read
        id = resolve_in(data, harness)
        next nil unless id

        data["threads"][id]["reads"][path.to_s] = now
        write(data)
        id
      end
    end

    def missing(id)
      thread = read["threads"][id.to_s]
      return [] unless thread

      Array(thread["required"]) - thread["reads"].to_h.keys
    end
  end
end
