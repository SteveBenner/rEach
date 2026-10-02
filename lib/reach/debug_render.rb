require "time"

module Reach
  module DebugRender
    MAX_WIDTH = 100
    TIME_WIDTH = 8
    KIND_CAP = 10
    RESULT_CAP = 30
    MS_CAP = 7
    GUI_ENTRYPOINT = /desktop|vscode|jetbrains|ide|local-agent|teams|remote|cowork|cursor|windsurf/i.freeze
    CODEX_GUI_ENV = /\ACODEX_(DESKTOP_APP|IDE)/.freeze
    QUIET_KEYS = %w[session_id quick].freeze

    module_function

    def detect(harness, payload = {})
      case harness.to_s
      when "codex"
        codex_gui? ? "gui" : "tui"
      when "hermes"
        "tui"
      else
        entry = ENV["CLAUDE_CODE_ENTRYPOINT"].to_s
        if !entry.empty? || ENV["CLAUDE_CODE_DESKTOP_APP_VERSION"].to_s != ""
          ENV["CLAUDE_CODE_DESKTOP_APP_VERSION"].to_s != "" || GUI_ENTRYPOINT.match?(entry) ? "gui" : "tui"
        else
          codex_gui? ? "gui" : "tui"
        end
      end
    end

    def codex_gui?
      ENV.any? { |name, value| CODEX_GUI_ENV.match?(name) && !value.to_s.empty? }
    end

    def surface(harness, payload = {})
      case Reach::Debug.config["render"].to_s
      when "ascii"
        "tui"
      when "markdown"
        "gui"
      else
        detect(harness, payload)
      end
    end

    def format_for(harness, payload)
      surface(harness, payload) == "gui" ? "markdown" : "ascii"
    end

    def block(entries, harness: nil, payload: {}, format: nil)
      chosen = format || format_for(harness, payload)
      chosen = "ascii" unless %w[ascii markdown].include?(chosen)
      table(entries, format: chosen)
    end

    def title(entries)
      reasons = entries.map { |entry| entry["reason"].to_s }.reject(&:empty?).uniq
      Reach::Messages.text("M-DEBUG-TITLE", reason: reasons.empty? ? Reach::Debug.reason.to_s : reasons.join("/"), count: entries.length)
    end

    def table(entries, format: "ascii", limit: nil)
      return Reach::Messages.text("M-DEBUG-NONE") if entries.empty?

      limit = [(limit || Reach::Debug.config["show_max_rows"]).to_i, 1].max
      shown = entries.first(limit)
      rows = shown.map { |entry| row_for(entry["event"]) }
      more = entries.length - shown.length
      head = [
        Reach::Messages.text("M-DEBUG-COL-TIME"), Reach::Messages.text("M-DEBUG-COL-KIND"), Reach::Messages.text("M-DEBUG-COL-WHAT"),
        Reach::Messages.text("M-DEBUG-COL-RESULT"), Reach::Messages.text("M-DEBUG-COL-MS")
      ]
      lines = format == "markdown" ? markdown(entries, head, rows) : ascii(entries, head, rows)
      lines << (format == "markdown" ? "*#{Reach::Messages.text('M-DEBUG-MORE', count: more)}*" : Reach::Messages.text("M-DEBUG-MORE", count: more)) if more.positive?
      lines.join("\n")
    end

    def ascii(entries, head, rows)
      widths = column_widths(head, rows)
      rule = "+" + widths.map { |width| "-" * (width + 2) }.join("+") + "+"
      out = [title(entries), rule, ascii_row(head, widths), rule]
      rows.each { |cells| out << ascii_row(cells, widths) }
      out << rule
      out
    end

    def ascii_row(cells, widths)
      "| " + cells.each_with_index.map { |cell, index| fit(cell, widths[index]).ljust(widths[index]) }.join(" | ") + " |"
    end

    def column_widths(head, rows)
      all = [head] + rows
      natural = (0..4).map { |index| all.map { |cells| clean(cells[index]).length }.max }
      time = [natural[0], TIME_WIDTH].min
      kind = [natural[1], KIND_CAP].min
      result = [natural[3], RESULT_CAP].min
      ms = [natural[4], MS_CAP].min
      what = [natural[2], MAX_WIDTH - 16 - (time + kind + result + ms)].min
      [time, kind, what, result, ms]
    end

    def markdown(entries, head, rows)
      out = ["**#{title(entries)}**", ""]
      out << "| #{head.map { |cell| md(cell) }.join(' | ')} |"
      out << "| --- | --- | --- | --- | ---: |"
      rows.each { |cells| out << "| #{cells.map { |cell| md(cell) }.join(' | ')} |" }
      out
    end

    def md(cell)
      clean(cell).gsub("\\", "\\\\\\\\").gsub("|", "\\|")
    end

    def clean(cell)
      cell.to_s.gsub(/[[:cntrl:]]+/, " ").strip
    end

    def fit(cell, width)
      text = clean(cell)
      return text if text.length <= width
      return text[0, width] if width <= 3

      "#{text[0, width - 3]}..."
    end

    def row_for(event)
      fields = event["fields"].is_a?(Hash) ? event["fields"] : {}
      what, result, ms = summary(event["kind"].to_s, fields)
      [clock(event["at"]), event["kind"].to_s, what, result, ms.nil? ? "" : ms.to_s]
    end

    def clock(at)
      instant = Time.parse(at.to_s).utc
      match = Reach::CourseTime.format(instant).match(/(\d{1,2}):(\d{2}) (am|pm)/)
      return instant.strftime("%H:%M:%S") unless match

      hour = (match[1].to_i % 12) + (match[3] == "pm" ? 12 : 0)
      format("%02d:%02d:%02d", hour, match[2].to_i, instant.sec)
    rescue StandardError
      "--:--:--"
    end

    def pairs(fields, skip = [])
      fields.reject { |name, value| skip.include?(name) || QUIET_KEYS.include?(name) || value.nil? || value.is_a?(Array) }
            .map { |name, value| "#{name}=#{value}" }.join(" ")
    end

    def join(*parts)
      parts.compact.map(&:to_s).reject(&:empty?).join(" ")
    end

    def summary(kind, f)
      case kind
      when "session"
        wire = f["wire_match"].nil? ? "?" : (f["wire_match"] ? "ok" : "differs")
        [join("reach", f["reach"], "ruby", f["ruby"], f["harness"], f["surface"]), "wire=#{wire}", nil]
      when "hook"
        [join(f["event"], f["space"]), join(f["decision"], f["rule"]), f["latency_ms"]]
      when "gate"
        [f["check"].to_s, join(f["outcome"], f["message_id"]), nil]
      when "command"
        [join(f["command"], f["sub"], Array(f["flags"]).join(" ")), join("exit=#{f['exit']}", f["error"]), f["duration_ms"]]
      when "request"
        retry_note = f["attempt"].to_i.positive? ? "retry #{f['attempt']}" : nil
        [join(f["method"], f["route"]), join(f["status"], f["error"], retry_note), f["latency_ms"]]
      when "lock"
        [join("lock", f["state"]), f["reason"] || "ok", nil]
      when "sync"
        [join("sync", Array(f["packages"]).join(",")), join(f["state"], f["warnings"].to_i.positive? ? "warnings=#{f['warnings']}" : nil), f["duration_ms"]]
      when "check"
        [join(f["files_checked"], "files"), join(f["findings"], "findings", Array(f["rules"]).join(",")), nil]
      when "qualify"
        outcome = f["passed"] ? "passed" : (f["pending"] ? "pending" : "failed=#{f['failed']}")
        [join("attempt", f["attempt"], f["mode"]), outcome, nil]
      when "submit"
        [join("submit", f["receipt_id"]), join(f["outcome"], f["late"] ? "late" : nil, f["attempt"] ? "attempt #{f['attempt']}" : nil, f["resubmit"], f["archive"] ? "copy #{f['archive']}" : nil), nil]
      when "transcript"
        [join("transcript", f["event"]), pairs(f, %w[event]), nil]
      when "brain"
        [join("brain", f["event"]), pairs(f, %w[event]), nil]
      when "update"
        [join("update", f["event"] || f["phase"]), pairs(f, %w[event phase]), nil]
      when "error"
        [join(f["exception"], f["where"]), f["message_id"] || f["message"], nil]
      else
        [pairs(f), "", nil]
      end
    end
  end
end
