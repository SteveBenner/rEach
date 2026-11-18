# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "state_file"

module Reach
  module Signals
    KINDS = %w[gate command brain hook check qualify].freeze
    MAX = 24
    MAX_AGE_S = 86_400
    DEDUP_S = 60
    READ_MAX = 65_536
    LOCK_WAIT_S = 0.2
    QUIET_OUTCOMES = %w[ok allow context started].freeze
    CHECK_FORMAT = /\A[a-z0-9_.: -]{1,48}\z/.freeze
    OUTCOME_FORMAT = /\A[a-z_]{1,24}\z/.freeze
    CODE_FORMAT = /\A[A-Z]{1,4}-[A-Z0-9-]{2,48}\z/.freeze
    SAFE = [SystemCallError, IOError, JSON::ParserError, ArgumentError, TypeError, NoMethodError, EncodingError, Reach::StateFile::Held].freeze

    module_function

    def disabled?
      ENV["REACH_SIGNALS_DISABLE"] == "1"
    end

    def file
      File.join(Reach::Paths.state_dir, "signals.json")
    end

    def lock_file
      File.join(Reach::Paths.state_dir, "signals.lock")
    end

    def record!(kind, fields)
      return nil if disabled?

      kind = kind.to_s
      return nil unless KINDS.include?(kind) && fields.is_a?(Hash)

      entry = build(kind, fields)
      return nil if entry["check"].nil? && entry["outcome"].nil? && entry["code"].nil?
      return nil if entry["code"].nil? && QUIET_OUTCOMES.include?(entry["outcome"])

      FileUtils.mkdir_p(Reach::Paths.state_dir)
      Reach::Locks.exclusive(lock_file, wait_s: LOCK_WAIT_S) { store(entry) }
      nil
    rescue *SAFE, Reach::Locks::Busy
      nil
    end

    def recent
      return [] if disabled?

      read_rows.select { |row| row.is_a?(Hash) }
    rescue *SAFE
      []
    end

    def build(kind, fields)
      outcome = fields["outcome"]
      outcome = (fields["ok"] == false ? "fail" : (fields["ok"] == true ? "ok" : nil)) if outcome.nil?
      {
        "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kind" => kind,
        "check" => shaped(fields["check"] || fields["command"] || fields["event"], CHECK_FORMAT),
        "outcome" => shaped(outcome, OUTCOME_FORMAT),
        "code" => shaped(fields["message_id"] || fields["code"], CODE_FORMAT)
      }
    end

    def shaped(value, format)
      return nil unless value.is_a?(String)

      value.match?(format) ? value : nil
    end

    def store(entry)
      cutoff = Time.now.utc - MAX_AGE_S
      rows = read_rows.select { |row| row.is_a?(Hash) && fresh?(row, cutoff) }
      newest = rows.last
      if newest && same?(newest, entry) && within_dedup?(newest, entry)
        newest["at"] = entry["at"]
      else
        rows << entry
      end
      Reach::StateFile.write_atomic(file, JSON.generate(rows.last(MAX)))
    end

    def read_rows
      path = file
      return [] unless File.file?(path)

      parsed = JSON.parse(File.read(path, READ_MAX))
      parsed.is_a?(Array) ? parsed : []
    rescue *SAFE
      []
    end

    def fresh?(row, cutoff)
      Time.iso8601(row["at"].to_s) >= cutoff
    rescue ArgumentError
      false
    end

    def same?(left, right)
      %w[kind check outcome code].all? { |key| left[key] == right[key] }
    end

    def within_dedup?(left, right)
      Time.iso8601(right["at"]) - Time.iso8601(left["at"].to_s) <= DEDUP_S
    rescue ArgumentError
      false
    end
  end
end
