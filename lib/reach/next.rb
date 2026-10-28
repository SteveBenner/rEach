require "time"

module Reach
  module Next
    class << self
      def compute(mcp: false, consent: true)
        step = compute_step(mcp: mcp)
        return step unless consent

        open = Reach::Consent.open_notice
        return step unless open

        step.merge(
          "text" => "#{open['text']}\n\n#{step['text']}",
          "consent" => open.reject { |key, _| key == "text" }
        )
      end

      def compute_step(mcp: false)
        return result("M-NEXT-ENROLL") unless Reach::Enroll.current
        if Reach::Login.required? && !Reach::Login.any_active?
          return result(Reach::HookLiveness.untrusted_or("M-NEXT-LOGIN-NO-HOOK")) if mcp && Reach::HookLiveness.signin_hook_dead?

          return result("M-NEXT-LOGIN")
        end

        status = Reach::Sync.cached_status || {}
        selection = status["module_selection"].is_a?(Hash) ? status["module_selection"] : {}
        if status["modules"].nil? && !documents_only?(status)
          if selection["open"]
            closes = Reach::Messages.course_time(selection["closes_at"])
            return result("M-NEXT-CHOOSE-OPEN", count: selection_count) if closes.to_s.empty?

            return result("M-NEXT-CHOOSE", count: selection_count, closes: closes)
          elsif %w[student_choice instructor].include?(selection["mode"])
            return result("M-NEXT-WAIT-MODULES")
          end
        end

        current = status["current_assignment"]
        assignment = current.is_a?(Hash) ? current["id"] : nil
        slices = assignment ? assignment_slices(status, assignment) : []
        return result("M-NEXT-NO-ASSIGNMENT") if assignment.nil? || slices.empty?

        workspaces = Reach::Workspace.current_slices.each_with_object({}) do |path, map|
          meta = Reach::Workspace.metadata(path)
          map[[meta["cutout_id"], meta["slice"]]] = path
        end
        waiting = nil
        slices.each do |slice|
          step = slice_step(slice, assignment, workspaces[[slice["cutout_id"], slice["slice"]]])
          next unless step

          if %w[M-NEXT-WAIT-GRADE M-NEXT-DOC-WAIT].include?(step["id"])
            waiting ||= step
            next
          end
          return step
        end
        return waiting if waiting

        result("M-NEXT-DONE", assignment_id: assignment, assignment: assignment)
      end

      def anchor_text(space)
        kind = space.is_a?(Hash) ? space["kind"] : space
        return nil if kind.nil? || kind.to_s == "extracurricular"

        step = compute(consent: false)
        return nil if %w[M-NEXT-ENROLL M-NEXT-LOGIN M-NEXT-NO-ASSIGNMENT].include?(step["id"])

        status = Reach::Sync.cached_status || {}
        current = status["current_assignment"] || {}
        names = module_names(assignment_slices(status, current["id"]))
        label = names.to_s.strip.empty? ? current["id"].to_s : "#{current['id']} for #{names}"
        due = Reach::Messages.course_time(current["due"])
        label += ", due #{due}" unless due.to_s.empty?
        Reach::Messages.text("M-ANCHOR", step: label, next: step["text"])
      rescue StandardError
        nil
      end

      private

      def result(id, module_id: nil, assignment_id: nil, **fields)
        { "id" => id, "text" => Reach::Messages.text(id, **fields), "module" => module_id, "assignment" => assignment_id }
      end

      def selection_count
        section = Reach::Policy.module_selection
        count = section.is_a?(Hash) ? section["count"].to_i : 0
        count.positive? ? count : 2
      rescue StandardError
        2
      end

      def assignment_slices(status, assignment)
        Array(status["slices"]).select do |slice|
          slice["assignment"].to_s == assignment.to_s && (document_slice?(slice) || Reach::Modules.allows?(slice["cutout_id"]))
        end
      end

      def document_slice?(slice)
        slice.is_a?(Hash) && slice["slice"].to_s == Reach::DocumentFiles::SLICE
      end

      def documents_only?(status)
        current = status["current_assignment"]
        return false unless current.is_a?(Hash) && current["id"]

        slices = Array(status["slices"]).select { |slice| slice["assignment"].to_s == current["id"].to_s }
        !slices.empty? && slices.all? { |slice| document_slice?(slice) }
      end

      def module_of(cutout_id)
        return nil if Reach::Modules.document_cutout?(cutout_id)

        cutout_id.to_s.split(".").first
      end

      def module_title(module_id)
        options = Reach::Policy.module_selection
        options = options.is_a?(Hash) ? Array(options["options"]) : []
        match = options.find { |option| option.is_a?(Hash) && option["id"] == module_id }
        match && match["title"] ? match["title"] : module_id
      rescue StandardError
        module_id
      end

      def module_names(slices)
        names = slices.reject { |slice| document_slice?(slice) }.map { |slice| module_title(module_of(slice["cutout_id"])) }.uniq
        return names.first.to_s if names.size <= 1

        "#{names[0..-2].join(', ')} and #{names[-1]}"
      end

      def document_step(slice, assignment, workspace)
        if slice["submit"].to_s == "elsewhere"
          return result("M-NEXT-ELSEWHERE", assignment_id: assignment, assignment: assignment, note: elsewhere_note(slice))
        end
        return result("M-NEXT-DOC-START", assignment_id: assignment, assignment: assignment) unless workspace

        if Reach::Part.required?(assignment)
          open_question = Reach::Part.missing(assignment).first
          return result("M-NEXT-PART", assignment_id: assignment, question: open_question["question"]) if open_question
        end
        return result("M-NEXT-DOC-WORK", assignment_id: assignment, folder: File.basename(workspace)) if Reach::DocumentFiles.list(workspace).empty?

        latest = Reach::Receipts.latest_for(cutout_id: slice["cutout_id"], slice: slice["slice"])
        sent = latest && %w[ingest grade].include?(latest["kind"]) && !changed_since?(workspace, latest)
        return result("M-NEXT-DOC-SUBMIT", assignment_id: assignment, assignment: assignment) unless sent
        return result("M-NEXT-DOC-WAIT", assignment_id: assignment, assignment: assignment) unless latest["kind"] == "grade"

        percent = document_percent(latest)
        pass = Reach::Policy.pass_percent
        return nil unless latest["feedback"].to_s.strip != "" || (percent && pass && percent < pass)

        result("M-NEXT-DOC-REVIEW", assignment_id: assignment, assignment: assignment, percent: percent.nil? ? "" : percent)
      end

      def elsewhere_note(slice)
        note = slice["submit_note"].to_s.strip
        note.empty? ? Reach::Messages.text("M-SUBMIT-ELSEWHERE-NONOTE") : note
      end

      def document_percent(receipt)
        return nil unless receipt["graded_by"] && receipt["score"].is_a?(Numeric)

        (receipt["score"] * 100).round
      end

      def changed_since?(workspace, receipt)
        stamp = Time.parse(receipt["issued_at"].to_s)
        Reach::DocumentFiles.list(workspace).any? { |relative| File.mtime(File.join(workspace, relative)).to_i > stamp.to_i }
      rescue ArgumentError, SystemCallError
        false
      end

      def slice_step(slice, assignment, workspace)
        return document_step(slice, assignment, workspace) if document_slice?(slice)

        module_id = module_of(slice["cutout_id"])
        name = module_title(module_id)
        return result("M-NEXT-START", module_id: module_id, assignment_id: assignment, assignment: assignment, module: name) unless workspace

        return result("M-NEXT-PLAN", module_id: module_id, assignment_id: assignment, module: name) if Reach::Plan.load(workspace).nil?

        if Reach::Part.required?(assignment)
          open_question = Reach::Part.missing(assignment).first
          return result("M-NEXT-PART", module_id: module_id, assignment_id: assignment, question: open_question["question"]) if open_question
        end

        qualification = Reach::Qualify.current?(workspace)
        return result("M-NEXT-BUILD", module_id: module_id, assignment_id: assignment, module: name) unless qualification

        latest = Reach::Receipts.latest_for(cutout_id: slice["cutout_id"], slice: slice["slice"])
        return result("M-NEXT-SUBMIT", module_id: module_id, assignment_id: assignment, module: name, slice: slice["slice"]) unless submitted_after?(latest, qualification)
        return result("M-NEXT-WAIT-GRADE", module_id: module_id, assignment_id: assignment, module: name, slice: slice["slice"]) unless latest["kind"] == "grade"

        scenarios = Array(latest["scenarios"])
        failed = scenarios.count { |item| item["result"] == "failed" }
        return nil if failed.zero?

        result("M-NEXT-REVIEW", module_id: module_id, assignment_id: assignment, module: name, failed: failed, total: scenarios.size)
      end

      def submitted_after?(receipt, qualification)
        return false unless receipt && %w[ingest grade].include?(receipt["kind"])

        Time.parse(receipt["issued_at"].to_s) >= Time.parse(qualification["at"].to_s)
      rescue ArgumentError
        false
      end
    end
  end
end
