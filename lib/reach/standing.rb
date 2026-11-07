# frozen_string_literal: true

module Reach
  module Standing
    STALE_AFTER_S = 3600
    TIP_FILE = "standing-tip.json"

    class << self
      def answer
        step = next_text
        return { "summary" => Reach::Messages.text("M-STANDING-NEXT", step: step), "next" => step, "stale" => true, "age_minutes" => nil, "notices" => [] } unless enrolled

        age = age_s
        lines = course_lines + assignment_lines + open_lines + hand_lines + saved_lines + age_lines(age)
        lines << Reach::Messages.text("M-STANDING-NEXT", step: step) unless step.empty?
        {
          "summary" => lines.join("\n"),
          "next" => step,
          "stale" => age.nil? || age > STALE_AFTER_S,
          "age_minutes" => age && (age / 60).round,
          "notices" => notices
        }
      end

      def tip_due?
        Reach::StateFile.read(TIP_FILE)["shown"] != true
      rescue StandardError => e
        dropped(e, "tip", false)
      end

      def tip_shown!
        Reach::StateFile.write(TIP_FILE, "shown" => true)
        nil
      rescue StandardError => e
        dropped(e, "tip", nil)
      end

      private

      def enrolled
        Reach::Enroll.current
      rescue StandardError => e
        dropped(e, "enrolled", nil)
      end

      def next_text
        Reach::Next.compute["text"].to_s
      rescue StandardError => e
        dropped(e, "next", "")
      end

      def dropped(error, where, fallback)
        Reach::Debug.fault(error, "standing:#{where}")
        fallback
      end

      def age_s
        Reach::Sync.status_age_s
      rescue StandardError => e
        dropped(e, "age", nil)
      end

      def notices
        Reach::Checkpoint.status_notices
      rescue StandardError => e
        dropped(e, "notices", [])
      end

      def status
        Reach::Sync.cached_status || {}
      rescue StandardError => e
        dropped(e, "status", {})
      end

      def course_lines
        course = enrolled["course"] || {}
        title = course["title"].to_s
        return [] if title.empty?

        title = "#{title} (#{course['term']})" if course["term"]
        [Reach::Messages.text("M-STANDING-COURSE", course: title)]
      rescue StandardError => e
        dropped(e, "course", [])
      end

      def workspaces
        Reach::Workspace.current_slices.each_with_object({}) do |path, map|
          meta = Reach::Workspace.metadata(path)
          map[[meta["cutout_id"], meta["slice"]]] = path
        end
      rescue StandardError => e
        dropped(e, "workspaces", {})
      end

      def assignment_lines
        data = status
        found = workspaces
        current = data["current_assignment"].is_a?(Hash) ? data["current_assignment"] : nil
        ids = Array(data["slices"]).map { |slice| slice["assignment"].to_s }.uniq
        ids = ([current["id"].to_s] + ids).uniq if current
        ids.flat_map do |id|
          slices = Reach::Next.assignment_slices(data, id)
          is_current = current && current["id"].to_s == id
          next [] if slices.empty?
          next [] unless is_current || slices.any? { |slice| found[[slice["cutout_id"], slice["slice"]]] }

          [heading(id, is_current ? current : nil)] + slices.flat_map { |slice| slice_lines(slice, found[[slice["cutout_id"], slice["slice"]]]) }.map { |line| "  #{line}" }
        end
      rescue StandardError => e
        dropped(e, "assignments", [])
      end

      def heading(id, current)
        return Reach::Messages.text("M-STANDING-ASSIGNMENT-NODUE", assignment: id) unless current

        label = Reach::Status.assignment_label(current)
        due = Reach::Messages.course_time(current["due"]).to_s
        return Reach::Messages.text("M-STANDING-ASSIGNMENT-NODUE", assignment: label) if due.empty?

        Reach::Messages.text("M-STANDING-ASSIGNMENT", assignment: label, due: due)
      end

      def slice_lines(slice, workspace)
        return document_lines(slice, workspace) if Reach::Next.document_slice?(slice)

        module_id = Reach::Next.module_of(slice["cutout_id"])
        name = "#{Reach::Next.module_title(module_id)} #{slice['slice']}"
        [Reach::Messages.text("M-STANDING-SLICE", name: name, milestones: code_milestones(slice, workspace).join(", "))]
      end

      def code_milestones(slice, workspace)
        return [Reach::Messages.text("M-STANDING-NOT-STARTED")] unless workspace

        plan = Reach::Plan.load(workspace)
        word = Reach::Workspace.state_word(workspace)
        return [Reach::Messages.text("M-STANDING-NOT-STARTED")] if plan.nil? && word == "not started yet"

        list = [Reach::Messages.text(plan ? "M-STANDING-PLAN" : "M-STANDING-STARTED")]
        record = Reach::Qualify.read_record(workspace)
        qualification = Reach::Qualify.current?(workspace)
        list.concat(check_words(workspace, record, qualification))
        latest = Reach::Receipts.latest_for(cutout_id: slice["cutout_id"], slice: slice["slice"])
        list.concat(receipt_words(latest, record, qualification))
        list.concat(late_words(workspace))
        list
      end

      def check_words(workspace, record, qualification)
        return [] if record.nil?

        word = if qualification
                 "M-STANDING-CHECKS-PASS"
               elsif record["pending"]
                 "M-STANDING-CHECKS-WAIT"
               elsif record["passed"]
                 "M-STANDING-CHECKS-BEFORE"
               else
                 "M-STANDING-CHECKS-NOT-YET"
               end
        words = [Reach::Messages.text(word)]
        failed = Reach::Ladder.state(workspace)["failed"].to_i
        if failed.positive? && !qualification
          left = [Reach::Ladder::HARD_STOP - failed, 0].max
          words << Reach::Messages.text("M-STANDING-TRIES", left: left, limit: Reach::Ladder::HARD_STOP)
        end
        words
      end

      def receipt_words(latest, record, qualification)
        return [] unless latest && %w[ingest grade].include?(latest["kind"])

        words = [Reach::Messages.text("M-STANDING-HANDED-IN", time: Reach::Messages.course_time(latest["issued_at"]))]
        changed = qualification ? !Reach::Next.submitted_after?(latest, qualification) : !record.nil?
        words << Reach::Messages.text("M-STANDING-CHANGED") if changed
        if latest["kind"] == "grade"
          scenarios = Array(latest["scenarios"])
          unless scenarios.empty?
            failed = scenarios.count { |item| item["result"] == "failed" }
            words << Reach::Messages.text("M-STANDING-RESULT", passed: scenarios.size - failed, total: scenarios.size)
          end
        else
          words << Reach::Messages.text("M-STANDING-RESULT-WAIT")
        end
        words
      end

      def late_words(workspace)
        details = Reach::LateWork.info(workspace)
        return [] unless details["late"] && !details["on_record"]

        [Reach::Messages.text("M-STANDING-LATE", how_late: details["how_late"])]
      rescue StandardError => e
        dropped(e, "late", [])
      end

      def document_lines(slice, workspace)
        name = Reach::Messages.text("M-STANDING-WRITTEN")
        if slice["submit"].to_s == "elsewhere"
          note = slice["submit_note"].to_s.strip
          note = Reach::Messages.text("M-SUBMIT-ELSEWHERE-NONOTE") if note.empty?
          return [Reach::Messages.text("M-STANDING-SLICE", name: name, milestones: Reach::Messages.text("M-STATUS-ELSEWHERE", note: note).chomp("."))]
        end

        words = []
        count = workspace ? Reach::DocumentFiles.list(workspace).length : 0
        words << Reach::Messages.text(count.zero? ? "M-STANDING-NOT-STARTED" : "M-STANDING-FILES", count: count)
        latest = Reach::Receipts.latest_for(cutout_id: slice["cutout_id"], slice: slice["slice"])
        if latest && %w[ingest grade].include?(latest["kind"])
          words << Reach::Messages.text("M-STANDING-HANDED-IN", time: Reach::Messages.course_time(latest["issued_at"]))
          words << Reach::Messages.text("M-STANDING-RESULT-WAIT") unless latest["kind"] == "grade"
        end
        words.concat(late_words(workspace)) if workspace
        lines = [Reach::Messages.text("M-STANDING-SLICE", name: name, milestones: words.join(", "))]
        grade = Reach::Receipts.list.find { |receipt| Reach::Receipts.document_grade?(receipt) && receipt["cutout_id"] == slice["cutout_id"] }
        lines.concat(Reach::Receipts.grade_lines(grade).map { |line| "  #{line}" }) if grade
        lines
      end

      def open_lines
        Reach::Status.late_assignment_lines
      rescue StandardError => e
        dropped(e, "open", [])
      end

      def hand_lines
        hands = Array(Reach::Hands.list)
        answered = hands.count { |hand| hand[:reply] }
        waiting = hands.length - answered
        lines = []
        lines << Reach::Messages.text("M-STANDING-HANDS-ANSWERED", count: answered) if answered.positive?
        lines << Reach::Messages.text("M-STANDING-HANDS-WAITING", count: waiting) if waiting.positive?
        lines
      rescue StandardError => e
        dropped(e, "hands", [])
      end

      def saved_lines
        times = Reach::Workspace.current_slices.map { |path| Reach::Checkpoint.latest(path) }.compact.map { |entry| entry["at"].to_s }.reject(&:empty?)
        return [] if times.empty?

        [Reach::Messages.text("M-STANDING-SAVED", time: Reach::Messages.course_time(times.max))]
      rescue StandardError => e
        dropped(e, "saved", [])
      end

      def age_lines(age)
        return [Reach::Messages.text("M-STANDING-UNCHECKED")] if age.nil?
        return [Reach::Messages.text("M-STANDING-AGE", minutes: (age / 60).round)] if age <= STALE_AFTER_S

        [Reach::Messages.text("M-STANDING-STALE", hours: (age / 3600).round)]
      end
    end
  end
end
