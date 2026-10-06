require "json"
require "time"
require "socket"
require "securerandom"
require "fileutils"

module ReleaseGate
  module Override
    class Refused < StandardError; end

    PHRASE = "override %s".freeze
    HOURS = (1..24).freeze
    REASON = (10..500).freeze

    module_function

    def dir(repo)
      File.join(repo.state_dir, "overrides")
    end

    def stamp(time = Time.now.utc)
      time.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def write(repo, record)
      FileUtils.mkdir_p(dir(repo))
      File.chmod(0o700, dir(repo))
      path = File.join(dir(repo), "#{record["id"]}.json")
      temp = "#{path}.#{Process.pid}.tmp"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.pretty_generate(record)) }
      File.rename(temp, path)
      path
    end

    def all(repo)
      Dir.glob(File.join(dir(repo), "ovr_*.json")).sort.map do |path|
        begin
          JSON.parse(File.read(path))
        rescue StandardError
          nil
        end
      end.compact
    end

    def active(repo, now: Time.now.utc)
      all(repo).select do |record|
        record["consumed_at"].nil? && (expires = Time.parse(record["expires_at"].to_s) rescue nil) && expires > now
      end
    end

    def covers?(record, ids)
      checks = Array(record["checks"]).map(&:to_s)
      return true if checks.include?("*")

      !ids.empty? && (ids - checks).empty?
    end

    def covering(repo, ids, now: Time.now.utc)
      active(repo, now: now).find { |record| covers?(record, ids) }
    end

    def consume!(repo, record, consumed_by)
      updated = record.merge("consumed_at" => stamp, "consumed_by" => consumed_by)
      write(repo, updated)
      updated
    end

    def by
      tty = begin
        File.readlink("/proc/self/fd/0")
      rescue StandardError
        nil
      end
      parent = begin
        File.read("/proc/#{Process.ppid}/comm").strip
      rescue StandardError
        nil
      end
      { "user" => ENV["USER"].to_s, "host" => Socket.gethostname, "tty" => tty, "parent" => parent }
    end

    def build(repo, reason:, hours:, checks:)
      now = Time.now.utc
      {
        "id" => "ovr_#{SecureRandom.hex(10)}", "repo" => repo.name, "created_at" => stamp(now),
        "expires_at" => stamp(now + hours * 3600), "reason" => reason, "checks" => checks, "by" => by,
        "scope" => "one_push", "consumed_at" => nil, "consumed_by" => nil
      }
    end

    def create!(repo, reason:, hours: 2, checks: ["*"], input: $stdin, output: $stdout)
      raise Refused, "an override is made at an interactive terminal by the instructor; this process has none" unless input.tty? && output.tty?
      raise Refused, "the reason must be #{REASON.min} to #{REASON.max} characters" unless REASON.cover?(reason.to_s.strip.length)
      raise Refused, "hours must be #{HOURS.min} to #{HOURS.max}" unless HOURS.cover?(hours)

      phrase = format(PHRASE, repo.name)
      output.puts("This lets exactly one #{repo.name} push through the release gate for #{hours} hour#{hours == 1 ? "" : "s"}.")
      output.puts("It is recorded on Teach with your user, host and terminal, and the desk raises an alarm until it is used or expires.")
      output.print("Type \"#{phrase}\" to confirm: ")
      output.flush
      typed = input.gets.to_s.strip
      raise Refused, "not confirmed" unless typed == phrase

      record = build(repo, reason: reason.to_s.strip, hours: hours, checks: checks)
      write(repo, record)
      record
    end
  end
end
