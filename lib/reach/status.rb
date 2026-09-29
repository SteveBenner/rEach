module Reach
  module Status
    class << self
      def summary
        lines = []
        lines << header_line
        lines << assignment_line
        lines << "Your slices:"
        slice_lines.each { |line| lines << "  #{line}" }
        lines << receipts_line
        lines << hands_line
        lines << rules_line
        line = transcript_line
        lines << line if line
        lines.join("\n")
      end

      def transcript_line
        counts = Reach::Transcript.counts
        sent = counts["sent"].to_i
        waiting = counts["waiting"].to_i
        return nil if sent.zero? && waiting.zero? && !Dir.exist?(Reach::Paths.transcripts_dir)

        return "Transcript: #{Reach::Transcript.prompts(sent)} sent" if waiting.zero?

        "Transcript: #{Reach::Transcript.prompts(sent)} sent, #{waiting} waiting to send"
      rescue StandardError
        nil
      end

      private

      def install
        Reach::Enrol.current
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
        return "rEach #{Reach::VERSION} · not connected to a course yet (run reach enrol <code>)" unless data

        course = data["course"] || {}
        status = cached_status || {}
        student = status["student"] || {}

        course_part = course["title"]
        course_part = "#{course_part} (#{course['term']})" if course["term"]

        student_part = student["display_name"] || data["student_id"] || "unknown student"
        student_part = "#{student_part} (#{student['group']})" if student["group"]

        "rEach #{Reach::VERSION} · #{course_part} · enrolled as #{student_part}"
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
        tips = tips_summary
        "#{cutout_id}  #{slice}  #{state}   shape: #{shape}   tips: #{tips}"
      end

      def shape_summary(workspace_path)
        return "none" unless File.file?(Reach::Shape.shape_path(workspace_path))

        findings = Reach::Shape.check(workspace_path: workspace_path, format: :agent)
        findings.empty? ? "ok" : "#{findings.size} open"
      rescue StandardError
        "cannot run"
      end

      def tips_summary
        recent = Reach::Corpus.new(Reach.ports).recent("tip", limit: 1)
        recent.empty? ? "not run" : "last recorded"
      rescue StandardError
        "not run"
      end

      def receipts_line
        receipts = Reach::Receipts.list
        return "Receipts: 0" if receipts.nil? || receipts.empty?

        "Receipts: #{receipts.size} (latest #{receipts.first['receipt_id']})"
      rescue StandardError
        "Receipts: 0"
      end

      def hands_line
        hands = Reach::Hands.list
        return "Open hands: none" if hands.nil? || hands.empty?

        "Open hands: #{hands.size}"
      rescue StandardError
        "Open hands: none"
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
