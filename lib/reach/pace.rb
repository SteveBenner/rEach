require "json"
require "time"

module Reach
  module Pace
    module_function

    def status_cache
      path = Reach::Paths.status_cache_file
      return nil unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError
      nil
    end

    def current_assignment
      assignment = status_cache && status_cache["current_assignment"]
      assignment.is_a?(Hash) ? assignment : nil
    end

    def server_now
      status = status_cache
      return Time.now.utc unless status && status["server_time"] && status["fetched_at"]

      Time.parse(status["server_time"]).utc + (Time.now.utc - Time.parse(status["fetched_at"]).utc)
    rescue StandardError
      Time.now.utc
    end

    def writable?(workspace)
      return true if workspace.nil?

      status = status_cache
      return true unless status

      meta = Reach::Workspace.metadata(workspace)
      current = current_assignment
      due = Reach::LateWork.due_for_meta(meta)
      if current && meta["assignment"].to_s == current["id"].to_s
        return true if due.nil?
        return true if server_now < due

        return Reach::LateWork.allow?
      end

      !due.nil? && server_now >= due && Reach::LateWork.allow?
    rescue StandardError
      true
    end
  end
end
