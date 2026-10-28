require "digest"

module Reach
  module AssignmentContext
    PHASE_OF = {
      "M-NEXT-START" => "start", "M-NEXT-PLAN" => "plan", "M-NEXT-PART" => "part", "M-NEXT-BUILD" => "build",
      "M-NEXT-SUBMIT" => "submit", "M-NEXT-WAIT-GRADE" => "wait", "M-NEXT-REVIEW" => "review", "M-NEXT-DONE" => "done",
      "M-NEXT-DOC-START" => "doc-start", "M-NEXT-DOC-WORK" => "doc-work", "M-NEXT-DOC-SUBMIT" => "doc-submit",
      "M-NEXT-DOC-WAIT" => "doc-wait", "M-NEXT-DOC-REVIEW" => "doc-review", "M-NEXT-ELSEWHERE" => "doc-elsewhere"
    }.freeze
    MAX_PATH = 200
    MAX_TITLE = 120
    UNSAFE_CHARS = /[`\x00-\x1f\x7f]/.freeze
    STATE_PHASE = { "graded" => "review", "submitted" => "wait", "in progress" => "build", "not started yet" => "start" }.freeze
    DEFAULTS = {
      "max_threads" => 64,
      "max_reads" => 12,
      "phases" => {
        "start" => %w[RESUME LEAN], "plan" => %w[RESUME PLAN1ST], "part" => %w[RESUME],
        "build" => %w[RESUME PLAN1ST FLOW CODEFILE QUALIFY CHECKPOINT], "submit" => %w[QUALIFY VERIFY],
        "wait" => %w[RESUME], "review" => %w[FLOW TOZERO CHECKPOINT], "done" => [],
        "doc-start" => %w[RESUMEDOC], "doc-work" => %w[RESUMEDOC FLOWDOC], "doc-submit" => %w[FLOWDOC],
        "doc-wait" => %w[RESUMEDOC], "doc-review" => %w[FLOWDOC RESUMEDOC], "doc-elsewhere" => []
      }
    }.freeze

    module_function

    def enabled?
      ENV["REACH_ASSIGNMENT_CONTEXT"] != "0" && Reach::Enroll.current ? true : false
    rescue StandardError
      false
    end

    def settings
      Reach::BehaviorPolicy.parameters("assignment_context")
    rescue StandardError
      DEFAULTS
    end

    def locate(workspace)
      assignment = nil
      assignment = Reach::Workspace.metadata(workspace)["assignment"].to_s if workspace
      if assignment.to_s.empty?
        current = (Reach::Sync.cached_status || {})["current_assignment"]
        assignment = current.is_a?(Hash) ? current["id"].to_s : ""
      end
      return nil if assignment.empty?

      step = Reach::Next.compute(consent: false)
      phase = step["assignment"].to_s == assignment ? PHASE_OF[step["id"]] : nil
      unless phase
        owned = Reach::Workspace.current_slices.find { |path| Reach::Workspace.metadata(path)["assignment"].to_s == assignment }
        phase = owned ? STATE_PHASE[Reach::Workspace.state_word(owned)] : nil
      end
      { "assignment" => assignment, "phase" => phase || "start" }
    rescue StandardError
      nil
    end

    def reference_files
      Reach::Reference.documents.flat_map { |document| document["files"] }
    rescue Reach::Refused, Reach::VerificationFailed
      []
    end

    def required(assignment, phase)
      files = reference_files
      wanted = assignment.to_s.downcase
      tagged = files.select { |file| Array(file["assignments"]).any? { |tag| tag.to_s.downcase == wanted } }
      chosen = if tagged.empty?
                 number = assignment.to_s[/\d+/]
                 if number
                   pattern = /assignment[\s_-]*0*#{number}(?!\d)/i
                   files.select do |file|
                     (file["title"].to_s =~ pattern || file["path"].to_s =~ pattern) && (file["kind"].nil? || file["kind"] == "assignment-prompt")
                   end
                 else
                   []
                 end
               else
                 tagged.select { |file| Array(file["phases"]).empty? || Array(file["phases"]).include?(phase) }
               end
      chosen.select { |file| safe_path?(file["path"]) }
            .map { |file| { "path" => file["path"], "title" => clean_title(file["title"]) } }
            .uniq { |entry| entry["path"] }
            .sort_by { |entry| entry["path"] }
            .first(settings["max_reads"].to_i)
    rescue StandardError
      []
    end

    def safe_path?(path)
      text = path.to_s
      !text.empty? && text.length <= MAX_PATH && text.valid_encoding? && !text.match?(UNSAFE_CHARS)
    end

    def clean_title(title)
      text = title.to_s.scrub("").gsub(UNSAFE_CHARS, " ").gsub(/\s+/, " ").strip
      text[0, MAX_TITLE]
    end

    def material_digest
      Digest::SHA256.hexdigest(Reach::Reference.blob_paths.map { |path| Digest::SHA256.file(path).hexdigest }.join)[0, 16]
    rescue StandardError
      nil
    end

    def result_count(since)
      Reach::Receipts.list.count do |receipt|
        %w[grade ingest].include?(receipt["kind"]) && receipt["issued_at"].to_s > since.to_s
      end
    rescue StandardError
      0
    end

    def changes_text(previous, spot, digest)
      parts = []
      before = previous["assignment"]
      if spot && before && before != spot["assignment"]
        parts << Reach::Messages.text("M-CTX-CHANGE-ASSIGNMENT", from: before, to: spot["assignment"])
      elsif spot && before && previous["phase"] != spot["phase"]
        parts << Reach::Messages.text("M-CTX-CHANGE-PHASE", from: previous["phase"].to_s, to: spot["phase"])
      end
      count = result_count(previous["last_seen_at"])
      parts << Reach::Messages.text("M-CTX-CHANGE-RESULTS", count: count) if count.positive?
      parts << Reach::Messages.text("M-CTX-CHANGE-MATERIAL") if previous["material"] && digest && previous["material"] != digest
      parts << Reach::Messages.text("M-CTX-CHANGE-NONE") if parts.empty?
      parts.join(", ")
    end

    def hello_entries(session:, harness:, source:, workspace:)
      return [] unless session && enabled?

      spot = locate(workspace)
      _thread, previous = Reach::Threads.start(session, harness, source)
      need = spot ? required(spot["assignment"], spot["phase"]) : []
      digest = material_digest
      Reach::Threads.update(session) do |stored|
        stored["assignment"] = spot && spot["assignment"]
        stored["phase"] = spot && spot["phase"]
        stored["material"] = digest
        stored["required"] = need.map { |entry| entry["path"] }
      end
      entries = []
      entries << ["hello.course", "- #{Reach::Messages.text('M-CTX-WHERE', assignment: spot['assignment'], phase: spot['phase'])}"] if spot
      if previous
        entries << ["hello.course", "- #{Reach::Messages.text('M-CTX-LAST', harness: Reach::Fingerprint.harness_label(previous['harness']), time: Reach::Messages.course_time(previous['last_seen_at']), assignment: previous['assignment'] || 'no assignment', phase: previous['phase'] || '-', changes: changes_text(previous, spot, digest))}"]
      else
        entries << ["hello.course", "- #{Reach::Messages.text('M-CTX-FIRST')}"]
      end
      unless need.empty?
        files = need.map { |entry| entry["title"].empty? ? "`#{entry['path']}`" : "`#{entry['path']}` (#{entry['title']})" }.join("; ")
        entries << ["hello.session", "- #{Reach::Messages.text('M-CTX-READ', assignment: spot['assignment'], files: files)}"]
      end
      entries << ["hello.session", "- #{Reach::Messages.text('M-CTX-READ-NONE', assignment: spot['assignment'])}"] if spot && need.empty?
      if spot
        present = Reach::Directives.rows.map { |row| row["opcode"] }
        opcodes = Array(settings["phases"][spot["phase"]]).select { |opcode| present.include?(opcode) }
        unless opcodes.empty?
          listed = opcodes.map { |opcode| "`reach directive #{opcode}`" }.join(", ")
          entries << ["hello.session", "- #{Reach::Messages.text('M-CTX-DIRECTIVES', phase: spot['phase'], directives: listed)}"]
        end
      end
      entries
    rescue StandardError
      []
    end

    def prompt_reminder(session, harness)
      return nil unless session && enabled?

      thread = Reach::Threads.touch(session, harness)
      hello_entries(session: session, harness: harness, source: "startup", workspace: nil) if thread.nil?
      missing = Reach::Threads.missing(session)
      return nil if missing.empty?

      files = missing.map { |path| "`reach reference show #{path}`" }.join(", ")
      Reach::Messages.text("M-CTX-REMIND", files: files)
    rescue StandardError
      nil
    end

    def note_read(path)
      return nil unless enabled?

      Reach::Threads.record_read(path, Reach::Session.detect_harness)
    rescue StandardError
      nil
    end
  end
end
