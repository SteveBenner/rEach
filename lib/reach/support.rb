require "json"
require "time"
require "fileutils"
require "rbconfig"

module Reach
  module Support
    RECENT_S = 3600

    class << self
      def run!
        text = if Reach::Enroll.current
                 told = if recent?
                          :recent
                        else
                          state = begin
                            raise_hand(harness: harness_name, space: current_space, queue_only: false)
                          rescue StandardError
                            nil
                          end
                          remember(state) if state && state != :refused
                          state
                        end
                 message(told: told)
               else
                 message(told: nil)
               end
        puts text
        text
      end

      def queue_from_hook!(harness:, space:)
        return nil unless Reach::Enroll.current
        return nil if recent?

        state = raise_hand(harness: harness, space: space, queue_only: true)
        remember(state)
        spawn_flush
        state
      rescue StandardError
        nil
      end

      def flush_queued!(quick: true)
        install = Reach::Enroll.current
        return 0 unless install

        sent = 0
        Dir.glob(File.join(Reach::Paths.outbox_dir, "*.json")).sort.each do |path|
          entry = begin
            JSON.parse(File.read(path))
          rescue StandardError
            nil
          end
          next unless entry.is_a?(Hash) && entry["kind"] == "hand" && entry.dig("body", "trigger") == "wellbeing"

          begin
            response = Reach::Client.for_install(install, quick: quick).post_json(entry["route"], entry["body"], idempotency_key: entry["idempotency_key"])
            result = response.json || {}
            FileUtils.rm_f(path)
            Reach::Hands.track(result["hand_id"], slice: entry["slice"], hand_ref: entry["hand_ref"], originator: "agent") if result["hand_id"]
            sent += 1
          rescue Reach::RemoteRefused => e
            FileUtils.rm_f(path)
            Reach::Debug.fault(e, "support:flush")
          rescue Reach::Offline, Reach::NetworkError
            break
          end
        end
        remember(:told) if sent.positive?
        sent
      rescue StandardError
        0
      end

      def spawn_flush
        exe = File.expand_path("../../exe/reach", __dir__)
        pid = Process.spawn(RbConfig.ruby, exe, "support", "--flush", in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
        Process.detach(pid)
      rescue StandardError
        nil
      end

      def message(told:)
        own = Reach::CourseProfile.wellbeing_support_text
        base = own ? [own, support_text].reject(&:empty?).join(" ") : Reach::Messages.text("M-SUPPORT", support_text: support_text)
        base = base.gsub(/ {2,}/, " ").strip
        suffix = case told
                 when :told then Reach::Messages.text("M-SUPPORT-TOLD")
                 when :queued then Reach::Messages.text("M-SUPPORT-QUEUED")
                 when :recent then Reach::Messages.text("M-SUPPORT-RECENT")
                 end
        suffix ? "#{base} #{suffix}" : base
      end

      private

      def support_text
        section = Reach::Policy.support
        section.is_a?(Hash) ? section["text"].to_s.strip : ""
      rescue StandardError
        ""
      end

      def raise_hand(harness:, space:, queue_only:)
        outcome = Reach::Hands.raise_wellbeing(harness: harness, space: space, queue_only: queue_only)
        return :refused if outcome == :refused

        outcome == :sent ? :told : :queued
      end

      def harness_name
        Reach::Session.resolve_harness(ENV["REACH_HARNESS"])
      end

      def current_space
        Reach::Gate.current_space
      rescue StandardError
        nil
      end

      def state_file
        File.join(Reach::Paths.state_dir, "support.json")
      end

      def read_state
        return {} unless File.file?(state_file)

        parsed = JSON.parse(File.read(state_file))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def recent?
        raised = read_state["last_raised_at"]
        return false unless raised

        Time.now.utc - Time.parse(raised).utc < RECENT_S
      rescue ArgumentError
        false
      end

      def remember(state)
        FileUtils.mkdir_p(File.dirname(state_file))
        tmp = "#{state_file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        record = { "last_raised_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "last_state" => state == :told ? "told" : "queued" }
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(record)) }
        File.rename(tmp, state_file)
      end
    end
  end
end
