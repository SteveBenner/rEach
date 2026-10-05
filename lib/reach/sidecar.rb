require "json"
require "fileutils"
require "securerandom"
require "rbconfig"
require "time"

module Reach
  module Sidecar
    SCHEMA = "reach.sidecar/v1".freeze

    module_function

    def path
      override = ENV["REACH_SIDECAR"].to_s
      return File.expand_path(override) unless override.empty?
      return File.join(Reach::Paths.home, "seal.json") if Reach::Paths.persona_id

      host_os = RbConfig::CONFIG["host_os"].to_s
      base = if host_os =~ /darwin/
               File.join(Reach::Paths.user_home, "Library", "Application Support")
             elsif host_os =~ /mswin|mingw|cygwin/
               ENV["LOCALAPPDATA"].to_s.empty? ? File.join(Reach::Paths.user_home, "AppData", "Local") : ENV["LOCALAPPDATA"]
             else
               ENV["XDG_STATE_HOME"].to_s.empty? ? File.join(Reach::Paths.user_home, ".local", "state") : ENV["XDG_STATE_HOME"]
             end
      File.join(base, "reach", "seal.json")
    end

    def read
      return default unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) && parsed["sidecar_id"] ? parsed : default
    rescue StandardError
      default
    end

    def default
      { "schema" => SCHEMA, "sidecar_id" => SecureRandom.hex(16), "installs" => [], "heads" => {}, "updated_at" => nil }
    end

    def id
      ensure_written["sidecar_id"]
    end

    def ensure_written
      data = read
      write(data) unless File.file?(path)
      data
    end

    def record_install(install)
      data = read
      installs = Array(data["installs"])
      unless installs.any? { |entry| entry["install_id"] == install["install_id"] }
        installs << {
          "install_id" => install["install_id"],
          "student_id" => install["student_id"],
          "teach_url" => install["teach_url"],
          "enrolled_at" => install["enrolled_at"] || Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
      end
      data["installs"] = installs
      write(data)
      data
    end

    def prior_install_ids(current_install_id)
      Array(read["installs"]).map { |entry| entry["install_id"] }.compact.reject { |id| id == current_install_id }
    end

    def update_head(root, tag, n)
      data = read
      heads = data["heads"].is_a?(Hash) ? data["heads"] : {}
      heads[root.to_s] = { "head" => tag, "n" => n, "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
      data["heads"] = heads
      write(data)
    rescue StandardError
      nil
    end

    def head_for(root)
      heads = read["heads"]
      heads.is_a?(Hash) ? heads[root.to_s] : nil
    end

    def write(data)
      data["updated_at"] = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(data), perm: 0o600)
      data
    rescue StandardError
      data
    end
  end
end
