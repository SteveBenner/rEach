require "json"
require "time"
require "fileutils"

module Reach
  module Link
    DEFAULTS = { "hiccup_quiet_minutes" => 15, "fault_max_per_hour" => 60 }.freeze
    CLIENT_FAULT_CODES = %w[invalid_request too_large empty].freeze
    HICCUP_IDS = { cli: "M-REACH-HICCUP-CLI", tool: "M-REACH-HICCUP-TOOL", hook: "M-REACH-HICCUP" }.freeze

    module_function

    def config
      section = Reach::Runtime.load_config["link"]
      section = {} unless section.is_a?(Hash)
      DEFAULTS.merge(section.select { |key, value| DEFAULTS.key?(key) && value.is_a?(Numeric) })
    rescue StandardError
      DEFAULTS.dup
    end

    def state_file
      File.join(Reach::Paths.home, "link.json")
    end

    def lock_file
      File.join(Reach::Paths.home, "link.lock")
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def read_state
      return {} unless File.file?(state_file)

      parsed = JSON.parse(File.read(state_file))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    def write_state(state)
      tmp = "#{state_file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(state)) }
      Reach::StateFile.rename_into_place(tmp, state_file)
      File.chmod(0o600, state_file)
    end

    def locked
      FileUtils.mkdir_p(Reach::Paths.home)
      Reach::Locks.exclusive(lock_file) { yield }
    end

    def lost!(cause)
      event = nil
      locked do
        state = read_state
        next if state["state"] == "lost"

        write_state(
          "state" => "lost", "since" => now_s, "cause" => cause.to_s, "lost_shown" => false,
          "back_pending" => false, "hiccup_shown_at" => state["hiccup_shown_at"]
        )
        event = ["lost", cause.to_s, nil]
      end
      Reach::Debug.link(*event) if event
      nil
    rescue StandardError
      nil
    end

    def restored!
      return nil unless File.file?(state_file)
      return nil if read_state["state"] != "lost"

      event = nil
      locked do
        state = read_state
        next unless state["state"] == "lost"

        since = begin
          Time.parse(state["since"].to_s)
        rescue StandardError
          nil
        end
        outage = since ? [(Time.now - since).round, 0].max : nil
        write_state(state.merge("state" => "up", "back_pending" => state["lost_shown"] == true))
        event = ["back", state["cause"], outage]
      end
      Reach::Debug.link(*event) if event
      nil
    rescue StandardError
      nil
    end

    def notice!
      text = nil
      return nil unless File.file?(state_file)

      locked do
        state = read_state
        if state["state"] == "lost" && state["lost_shown"] != true
          write_state(state.merge("lost_shown" => true))
          text = Reach::Messages.text("M-TEACH-LINK-LOST")
        elsif state["state"] == "up" && state["back_pending"] == true
          write_state(state.merge("back_pending" => false))
          text = Reach::Messages.text("M-TEACH-LINK-BACK")
        end
      end
      text
    rescue StandardError
      nil
    end

    def hiccup!(id = "M-REACH-HICCUP")
      text = nil
      locked do
        state = read_state
        quiet = config["hiccup_quiet_minutes"].to_f * 60
        shown = state["hiccup_shown_at"].to_f
        if shown <= 0 || Time.now.to_f - shown >= quiet
          write_state(state.merge("hiccup_shown_at" => Time.now.to_f))
          text = Reach::Messages.text(id)
        end
      end
      text
    rescue StandardError
      nil
    end

    def masked?(error)
      return error.cause_name.to_s.empty? if error.is_a?(Reach::NetworkError)
      return true if error.is_a?(Reach::RemoteRefused) && (error.code.to_s.empty? || CLIENT_FAULT_CODES.include?(error.code.to_s))

      !error.is_a?(Reach::Error)
    rescue StandardError
      true
    end

    def reason(error, where)
      return Reach::Messages.text("M-REACH-REASON-OFFLINE") if error.is_a?(Reach::NetworkError) && !masked?(error)
      return error.message unless masked?(error)

      Reach::Debug.fault(error, where, "M-REACH-REASON-SNAG")
      Reach::Messages.text("M-REACH-REASON-SNAG")
    rescue StandardError
      ""
    end

    def student_text(error, surface)
      return error.message if !masked?(error)

      Reach::Messages.text(HICCUP_IDS.fetch(surface, "M-REACH-HICCUP"))
    rescue StandardError
      ""
    end
  end
end
