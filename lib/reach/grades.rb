require "json"
require "time"
require "fileutils"

module Reach
  module Grades
    ROUTE = "/api/v1/grades".freeze
    STATE_NAME = "grades.json".freeze

    module_function

    def fetch
      install = Reach::Enroll.current
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

      begin
        response = Reach::Client.for_install(install).get(ROUTE)
        answer = normalize(response.json)
        save(answer)
        shown(answer)
      rescue Reach::RemoteRefused => e
        raise unless e.status == 404 || e.code.to_s == "grades_disabled"

        forget
        unavailable
      rescue Reach::NetworkError
        offline
      end
    end

    def normalize(body)
      body = {} unless body.is_a?(Hash)
      grades = Array(body["grades"]).select { |row| row.is_a?(Hash) }.map do |row|
        {
          "assignment" => row["assignment"].to_s, "points" => row["points"], "points_possible" => row["points_possible"],
          "recorded_at" => row["recorded_at"]
        }
      end
      total = body["total"].is_a?(Hash) ? { "points" => body["total"]["points"], "points_possible" => body["total"]["points_possible"] } : nil
      {
        "available" => body["available"] == true && !grades.empty?,
        "grades" => grades,
        "total" => total,
        "as_of" => body["as_of"].to_s.empty? ? Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") : body["as_of"].to_s
      }
    end

    def state_path
      File.join(Reach::Paths.state_dir, STATE_NAME)
    end

    def save(answer)
      FileUtils.mkdir_p(Reach::Paths.state_dir)
      tmp = "#{state_path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(answer))
        file.flush
        file.fsync
      end
      File.rename(tmp, state_path)
    end

    def forget
      FileUtils.rm_f(state_path)
    end

    def last
      return nil unless File.file?(state_path)

      data = JSON.parse(File.read(state_path))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def number(value)
      return value.to_s unless value.is_a?(Numeric)

      value == value.to_i ? value.to_i.to_s : value.to_s
    end

    def lines_for(answer)
      lines = answer["grades"].map do |row|
        if row["points_possible"].nil?
          Reach::Messages.text("M-GRADES-ROW-OPEN", assignment: row["assignment"], points: number(row["points"]))
        else
          Reach::Messages.text("M-GRADES-ROW", assignment: row["assignment"], points: number(row["points"]), possible: number(row["points_possible"]))
        end
      end
      total = answer["total"]
      if total.is_a?(Hash)
        lines << if total["points_possible"].nil?
                   Reach::Messages.text("M-GRADES-TOTAL-OPEN", points: number(total["points"]))
                 else
                   Reach::Messages.text("M-GRADES-TOTAL", points: number(total["points"]), possible: number(total["points_possible"]))
                 end
      end
      lines
    end

    def render(answer, header_id)
      lines = [Reach::Messages.text(header_id, as_of: Reach::Messages.course_time(answer["as_of"]))]
      lines.concat(lines_for(answer).map { |line| "  #{line}" })
      lines << Reach::Messages.text("M-GRADES-NOTE", record: Reach::Archive.grade_record)
      lines.join("\n")
    end

    def shown(answer)
      return unavailable if answer["available"] != true

      answer.merge("state" => "shown", "text" => render(answer, "M-GRADES-SHOWN"))
    end

    def unavailable
      {
        "state" => "unavailable", "available" => false, "grades" => [], "total" => nil, "as_of" => nil,
        "text" => Reach::Messages.text("M-GRADES-UNAVAILABLE", record: Reach::Archive.grade_record)
      }
    end

    def offline
      previous = last
      if previous && previous["available"] == true
        return previous.merge("state" => "offline", "text" => render(previous, "M-GRADES-OFFLINE-LAST"))
      end

      {
        "state" => "offline", "available" => false, "grades" => [], "total" => nil, "as_of" => previous && previous["as_of"],
        "text" => Reach::Messages.text("M-GRADES-OFFLINE")
      }
    end
  end
end
