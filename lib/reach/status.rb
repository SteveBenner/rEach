module Reach
  module Status
    class << self
      def summary
        lines = []
        lines << header_line
        lines << folder_line
        lines << assignment_line
        lines << signed_in_line
        lines << modules_line
        transfer = transfer_line
        lines << transfer if transfer
        lines << "Your slices:"
        slice_lines.each { |line| lines << "  #{line}" }
        lines << receipts_line
        lines << hands_line
        lines << rules_line
        line = transcript_line
        lines << line if line
        line = part_line
        lines << line if line
        line = next_line
        lines << line if line
        lines.join("\n")
      end

      def transcript_line
        counts = Reach::Transcript.counts
        sent = counts["sent"].to_i
        waiting = counts["waiting"].to_i
        held = counts["held"].to_i
        return nil if sent.zero? && waiting.zero? && !Dir.exist?(Reach::Paths.transcripts_dir)

        line = waiting.zero? ? "Transcript: #{sent} entries sent" : "Transcript: #{sent} entries sent, #{waiting} waiting to send"
        line += " (#{held} held until the course server is updated)" if held.positive?
        line
      rescue StandardError
        nil
      end

      private

      def install
        Reach::Enroll.current
      rescue StandardError
        nil
      end

      def cached_status
        Reach::Sync.cached_status
      rescue StandardError
        nil
      end

      def header_line
        data = install
        return "rEach #{Reach::VERSION} · not connected to a course yet (run reach enroll <code>)" unless data

        course = data["course"] || {}
        status = cached_status || {}
        student = status["student"] || {}

        course_part = course["title"]
        course_part = "#{course_part} (#{course['term']})" if course["term"]

        student_part = student["display_name"] || data["display_name"] || data["student_id"] || "unknown student"
        student_part = "#{student_part} (#{student['group']})" if student["group"]

        "rEach #{Reach::VERSION} · #{course_part} · enrolled as #{student_part}"
      end

      def folder_line
        folder = Reach::Paths.workspace_root
        return "Your rEach folder: #{folder}" if folder == Reach::Paths.root || !Reach::Paths.legacy_active?

        state = Reach::Relocation.status
        if state[:state] == "failed"
          reason = Reach::Relocation::REASONS[state[:reason]] || state[:reason]
          return "Your rEach folder: #{folder} (rEach could not move your files into #{Reach::Paths.root} yet: #{reason}; nothing was changed)"
        end

        "Your rEach folder: #{folder} (rEach will move your files into #{Reach::Paths.root} soon)"
      rescue StandardError
        "Your rEach folder: unknown"
      end

      def assignment_line
        status = cached_status
        assignment = status && status["current_assignment"]
        return "Current assignment: none" unless assignment

        "Current assignment: #{assignment['id']}, due #{Reach::Messages.course_time(assignment['due'])}"
      end

      def slice_lines
        Reach::Workspace.current_slices.map { |workspace_path| slice_line(workspace_path) }
      rescue StandardError
        []
      end

      def slice_line(workspace_path)
        meta = Reach::Workspace.metadata(workspace_path)
        cutout_id = meta["cutout_id"]
        slice = meta["slice"]
        state = Reach::Workspace.state_word(workspace_path)
        shape = shape_summary(workspace_path)
        checks = qualify_summary(workspace_path)
        "#{cutout_id}  #{slice}  #{state}   shape: #{shape}   checks: #{checks}"
      end

      def shape_summary(workspace_path)
        return "none" unless File.file?(Reach::Shape.shape_path(workspace_path))

        findings = Reach::Shape.check(workspace_path: workspace_path, format: :agent)
        findings.empty? ? "ok" : "#{findings.size} open"
      rescue StandardError
        "cannot run"
      end

      def qualify_summary(workspace_path)
        record = Reach::Qualify.read_record(workspace_path)
        ladder = Reach::Ladder.state(workspace_path)
        base = if record.nil?
                 "not run"
               elsif Reach::Qualify.current?(workspace_path)
                 "passed"
               elsif record["pending"]
                 "waiting for the course server"
               elsif record["passed"]
                 "passed before the last change"
               else
                 "not passing yet"
               end
        failed = ladder["failed"].to_i
        failed.positive? ? "#{base} (#{failed} of #{Reach::Ladder::HARD_STOP} tries used)" : base
      rescue StandardError
        "not run"
      end

      def signed_in_line
        Reach::Login.any_active? ? "Signed in: yes" : "Signed in: no"
      rescue StandardError
        "Signed in: no"
      end

      def modules_line
        record = Reach::Modules.current
        if record
          how = { "student_choice" => "chosen", "transfer" => "moved" }[record["source"]] || "assigned"
          "Modules: #{Reach::Modules.names(record['modules'])} (#{how} #{Reach::Messages.course_time(record['issued_at'])})"
        else
          data = Reach::Modules.options_data
          if data && data["mode"] == "student_choice" && data["open"]
            closes = data["window"].is_a?(Hash) ? Reach::Messages.course_time(data["window"]["closes_at"]) : ""
            "Modules: choose #{data['count']} by #{closes}"
          else
            "Modules: not set yet"
          end
        end
      rescue StandardError
        "Modules: not set yet"
      end

      def transfer_line
        data = Reach::Transfer.stored
        return nil unless data

        case data["state"]
        when "pending"
          "Module move: waiting for your instructor since #{Reach::Messages.course_time(data['created_at'])}"
        when "approved"
          "Module move: approved"
        when "denied"
          "Module move: not approved"
        end
      rescue StandardError
        nil
      end

      def receipts_line
        receipts = Reach::Receipts.list
        return "Receipts: 0" if receipts.nil? || receipts.empty?

        line = "Receipts: #{receipts.size} (latest #{receipts.first['receipt_id']})"
        counts = ack_counts
        if counts["total"].positive?
          line += "; #{counts['linked']} confirmed with Teach"
          line += ", #{counts['pending']} waiting" if counts["pending"].positive?
          line += ", #{counts['mismatch']} mismatched" if counts["mismatch"].positive?
        end
        line
      rescue StandardError
        "Receipts: 0"
      end

      def ack_counts
        Reach::ReceiptAcks.counts
      rescue StandardError
        { "total" => 0 }
      end

      def hands_line
        hands = Reach::Hands.list
        return "Open hands: none" if hands.nil? || hands.empty?

        "Open hands: #{hands.size}"
      rescue StandardError
        "Open hands: none"
      end

      def part_line
        status = cached_status || {}
        current = status["current_assignment"]
        return nil unless current.is_a?(Hash)

        rows = Reach::Part.status(current["id"])
        return nil if rows.empty?

        "Your part: #{rows.count { |row| row['answered'] }} of #{rows.size} answered"
      rescue StandardError
        nil
      end

      def next_line
        step = Reach::Next.compute
        "Next: #{step['text']}"
      rescue StandardError
        nil
      end

      def rules_line
        version = Reach::Guardrails.version
        age_s = Reach::Sync.status_age_s
        online = ENV["REACH_OFFLINE"] == "1" ? "offline" : "online"
        checked = age_s ? "#{(age_s / 60).round} min ago" : "unknown"
        rules = version.nil? || version.to_s.empty? ? "not received yet" : "v#{version} (verified)"
        "Course rules: #{rules}   Connection: #{online} (last checked #{checked})"
      rescue StandardError
        "Course rules: unknown   Connection: unknown"
      end
    end
  end
end
