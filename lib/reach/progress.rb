require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Progress
    ROUTE = "/api/v1/progress".freeze
    PRE_ENROLL = %w[enroll.code enroll.identity].freeze
    ASSIGNMENT_PATTERN = /\A[A-Za-z0-9_-]{1,32}\z/.freeze
    MAX_BATCH = 64
    TIME_FMT = "%Y-%m-%dT%H:%M:%SZ".freeze

    module_function

    def enabled?
      ENV["REACH_PROGRESS"] != "0"
    end

    def file
      File.join(Reach::Paths.state_dir, "progress.json")
    end

    def blank
      { "student_id" => nil, "reached" => {}, "sent" => [] }
    end

    def read
      return blank unless File.file?(file)

      parsed = JSON.parse(File.read(file))
      return blank unless parsed.is_a?(Hash) && parsed["reached"].is_a?(Hash)

      blank.merge(parsed).merge("sent" => Array(parsed["sent"]))
    rescue StandardError
      blank
    end

    def write(data)
      FileUtils.mkdir_p(File.dirname(file))
      temp = "#{file}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate(data))
      File.rename(temp, file)
    end

    def mark(id, at: Time.now.utc)
      return nil unless enabled?

      id = id.to_s
      data = read
      data = blank if PRE_ENROLL.include?(id) && data["student_id"]
      return nil if data["reached"].key?(id)

      data["reached"][id] = at.strftime(TIME_FMT)
      write(data)
      id
    rescue StandardError
      nil
    end

    def enrolled!(student_id)
      return nil unless enabled?

      data = read
      previous = data["student_id"]
      if previous && previous != student_id.to_s
        data = blank.merge("reached" => data["reached"].select { |id, _| PRE_ENROLL.include?(id) })
      end
      write(data.merge("student_id" => student_id.to_s))
      student_id.to_s
    rescue StandardError
      nil
    end

    def assignment_started(workspace)
      return nil if workspace.nil?

      assignment = Reach::Workspace.metadata(workspace)["assignment"].to_s
      return nil unless ASSIGNMENT_PATTERN.match?(assignment)

      mark("#{assignment}.started")
    rescue StandardError
      nil
    end

    def flush!(quick: false)
      return nil unless enabled?

      install = Reach::Enroll.current
      return nil unless install

      data = read
      pending = data["reached"].reject { |id, _| data["sent"].include?(id) }.first(MAX_BATCH)
      return nil if pending.empty?

      body = { "checkpoints" => pending.map { |id, at| { "id" => id, "at" => at } } }
      begin
        Reach::Client.for_install(install, quick: quick).post_json(ROUTE, body, idempotency_key: SecureRandom.uuid)
      rescue Reach::RemoteRefused
        nil
      end
      write(read.merge("sent" => (data["sent"] + pending.map(&:first)).uniq))
      pending.length
    rescue StandardError
      nil
    end
  end
end
