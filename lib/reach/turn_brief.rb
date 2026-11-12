# frozen_string_literal: true

require "digest"
require "json"

module Reach
  module TurnBrief
    FILE = "turn-brief.json"
    MAX_SESSIONS = 32
    CODE_STAGES = %w[material plan plan_check part build qualify submit grade].freeze
    DOCUMENT_STAGES = %w[start work submit grade].freeze
    DEFAULTS = {
      "enabled" => true, "full_every" => 5, "gap_minutes" => 30, "max_full_chars" => 1100, "max_line_chars" => 220
    }.freeze
    PLAN_CLIPS = [[80, 60], [50, 30], [30, 0]].freeze
    ELLIPSIS = "..."

    module_function

    def settings
      DEFAULTS.merge(Reach::BehaviorPolicy.parameters("turn_brief"))
    rescue KeyError
      DEFAULTS
    rescue StandardError => e
      fault(e, "settings")
      DEFAULTS
    end

    def enabled?
      return false if ENV["REACH_TURN_BRIEF"] == "0"

      settings["enabled"] != false && Reach::Enroll.current ? true : false
    rescue StandardError => e
      fault(e, "enabled")
      false
    end

    def fault(error, where)
      Reach::Debug.fault(error, "turn_brief:#{where}")
      nil
    end

    def status
      Reach::Sync.cached_status || {}
    end

    def resolve(space)
      return nil unless space.is_a?(Hash)

      case space["kind"].to_s
      when "slice" then space["path"]
      when "root" then Reach::Gate.focus_workspace
      end
    rescue StandardError => e
      fault(e, "resolve")
      nil
    end

    def slice_of(meta)
      Reach::Next.assignment_slices(status, meta["assignment"]).find do |item|
        item["cutout_id"] == meta["cutout_id"] && item["slice"] == meta["slice"]
      end
    end

    def clip(text, limit)
      text = text.to_s.gsub(/\s+/, " ").strip
      return text if text.length <= limit
      return text[0, [limit, 0].max] if limit <= ELLIPSIS.length

      "#{text[0, limit - ELLIPSIS.length].rstrip}#{ELLIPSIS}"
    end

    def stage_word(id)
      Reach::Messages.text(["M-BRIEF-STAGE", id.to_s.upcase.tr("_", "-")].join("-"))
    end

    def stage_facts(slice, assignment, workspace, session)
      return document_facts(slice, workspace) if Reach::Next.document_slice?(slice)

      plan = Reach::Plan.load(workspace)
      audit = Reach::PlanAudit.current(workspace)
      record = Reach::Qualify.read_record(workspace)
      qualification = Reach::Qualify.current?(workspace)
      latest = Reach::Receipts.latest_for(cutout_id: slice["cutout_id"], slice: slice["slice"])
      facts = {
        "material" => !plan.nil? || session.to_s.empty? || Reach::Threads.missing(session).empty?,
        "plan" => !plan.nil?,
        "plan_check" => audit ? audit["verdict"] == "pass" : false,
        "part" => !Reach::Part.required?(assignment) || Reach::Part.missing(assignment).empty?,
        "build" => !Reach::Workspace.changed_owned_files(workspace).empty?,
        "qualify" => !qualification.nil?,
        "submit" => qualification ? Reach::Next.submitted_after?(latest, qualification) : false,
        "grade" => !latest.nil? && latest["kind"] == "grade"
      }
      waiting = record && record["pending"] && qualification.nil? ? "qualify" : nil
      order = Reach::PlanAudit.mode == "enforce" || facts["plan_check"] ? CODE_STAGES : CODE_STAGES - ["plan_check"]
      [order, facts, waiting]
    end

    def workspace_facts(workspace, session: nil)
      meta = Reach::Workspace.metadata(workspace)
      slice = { "cutout_id" => meta["cutout_id"], "slice" => meta["slice"] }
      _order, facts, _waiting = stage_facts(slice, meta["assignment"].to_s, workspace, session)
      facts
    end

    def document_facts(slice, workspace)
      latest = Reach::Receipts.latest_for(cutout_id: slice["cutout_id"], slice: slice["slice"])
      sent = !latest.nil? && %w[ingest grade].include?(latest["kind"]) && !Reach::Next.changed_since?(workspace, latest)
      facts = {
        "start" => true,
        "work" => !Reach::DocumentFiles.list(workspace).empty?,
        "submit" => sent,
        "grade" => !latest.nil? && latest["kind"] == "grade"
      }
      [DOCUMENT_STAGES, facts, nil]
    end

    def stages_for(order, facts, pending)
      current = order.find { |id| !facts[id] }
      index = current ? order.index(current) : order.length
      list = order.each_with_index.map do |id, position|
        state = if position < index
                  "done"
                elsif position == index
                  id == "grade" || id == pending ? "waiting" : "current"
                else
                  "todo"
                end
        { "id" => id, "state" => state }
      end
      [list, current]
    end

    def tally_for(assignment, found)
      counts = { "submitted" => 0, "graded" => 0, "not_started" => 0, "in_progress" => 0 }
      names = { "graded" => "graded", "submitted" => "submitted", "in progress" => "in_progress" }
      Reach::Next.assignment_slices(status, assignment).each do |slice|
        path = found[[slice["cutout_id"], slice["slice"]]]
        word = path ? Reach::Workspace.state_word(path) : "not started yet"
        counts[names.fetch(word, "not_started")] += 1
      end
      counts
    end

    def found_workspaces
      Reach::Workspace.current_slices.each_with_object({}) do |path, map|
        meta = Reach::Workspace.metadata(path)
        map[[meta["cutout_id"], meta["slice"]]] = path
      end
    end

    def module_name(slice)
      return Reach::Messages.text("M-BRIEF-WRITTEN") if Reach::Next.document_slice?(slice)

      Reach::Next.module_title(Reach::Next.module_of(slice["cutout_id"])).to_s
    end

    def snapshot(workspace, session: nil)
      meta = Reach::Workspace.metadata(workspace)
      assignment = meta["assignment"].to_s
      slice = slice_of(meta)
      return nil if assignment.empty? || slice.nil?

      order, facts, pending = stage_facts(slice, assignment, workspace, session)
      stages, current = stages_for(order, facts, pending)
      peers = Reach::Next.assignment_slices(status, assignment)
      open = status["current_assignment"]
      due = open.is_a?(Hash) && open["id"].to_s == assignment ? open["due"] : nil
      step = Reach::Next.step_for(slice, assignment, workspace)
      position = peers.index { |item| item["cutout_id"] == slice["cutout_id"] && item["slice"] == slice["slice"] }
      {
        "assignment" => assignment,
        "due" => Reach::Messages.course_time(due).to_s,
        "cutout_id" => slice["cutout_id"],
        "slice" => slice["slice"],
        "module" => module_name(slice),
        "index" => (position || 0) + 1,
        "count" => [peers.length, 1].max,
        "stages" => stages,
        "current" => current,
        "plan" => Reach::Plan.step_view(workspace),
        "checklist" => Reach::Checklist.view(workspace),
        "next" => step ? step["text"].to_s : Reach::Messages.text("M-BRIEF-NEXT-NONE"),
        "failed" => Reach::Ladder.state(workspace)["failed"].to_i,
        "tally" => tally_for(assignment, found_workspaces)
      }
    rescue StandardError => e
      fault(e, "snapshot")
      nil
    end

    def digest(snap)
      plan = snap["plan"] || {}
      source = [snap["cutout_id"], snap["slice"], snap["current"], plan["done"], plan["doing_number"], snap["tally"]]
      Digest::SHA256.hexdigest(JSON.generate(source))[0, 16]
    end

    def decide(session, snap)
      options = settings
      now = Time.now.to_i
      key = session.to_s.empty? ? "none" : session.to_s
      slice_key = "#{snap['cutout_id']}.#{snap['slice']}"
      stage = snap["current"].to_s
      full = false
      changed = false
      Reach::StateFile.update(FILE) do |state|
        sessions = state["sessions"].is_a?(Hash) ? state["sessions"] : {}
        entry = sessions[key]
        mark = digest(snap)
        full = entry.nil? ||
               entry["digest"] != mark ||
               now - entry["seen"].to_i >= options["gap_minutes"].to_i * 60 ||
               entry["since"].to_i + 1 >= options["full_every"].to_i
        changed = !entry.nil? && entry["slice"] == slice_key && entry["stage"] != stage
        since = full ? 1 : entry["since"].to_i + 1
        sessions[key] = { "digest" => mark, "stage" => stage, "slice" => slice_key, "seen" => now, "since" => since }
        state["sessions"] = sessions.sort_by { |_id, item| item["seen"].to_i }.last(MAX_SESSIONS).to_h
      end
      [full, changed]
    end

    def where_line(snap)
      due = snap["due"].to_s.empty? ? "" : Reach::Messages.text("M-BRIEF-DUE", due: snap["due"])
      Reach::Messages.text("M-BRIEF-WHERE", assignment: snap["assignment"], due: due, module: snap["module"], index: snap["index"], count: snap["count"])
    end

    def stage_list(snap, state)
      snap["stages"].select { |item| item["state"] == state }.map { |item| stage_word(item["id"]) }
    end

    def done_line(snap)
      words = stage_list(snap, "done")
      words.empty? ? nil : Reach::Messages.text("M-BRIEF-DONE", list: words.join(", "))
    end

    def now_line(snap)
      current = snap["stages"].find { |item| %w[current waiting].include?(item["state"]) }
      return Reach::Messages.text("M-BRIEF-NOW-ALL") unless current

      Reach::Messages.text(current["state"] == "waiting" ? "M-BRIEF-NOW-WAIT" : "M-BRIEF-NOW", stage: stage_word(current["id"]))
    end

    def left_line(snap)
      words = stage_list(snap, "todo")
      words.empty? ? nil : Reach::Messages.text("M-BRIEF-LEFT", list: words.join(", "))
    end

    def plan_line(snap, clip_to)
      plan = snap["plan"]
      return nil unless plan

      line = if plan["doing_number"]
               Reach::Messages.text("M-BRIEF-PLAN-DOING", done: plan["done"], total: plan["total"], number: plan["doing_number"], text: clip(plan["doing_text"], clip_to[0]))
             else
               Reach::Messages.text("M-BRIEF-PLAN-COUNT", done: plan["done"], total: plan["total"])
             end
      evidence = plan["last_done_evidence"].to_s
      return line if evidence.empty? || clip_to[1].zero?

      "#{line} #{Reach::Messages.text('M-BRIEF-PLAN-EVIDENCE', evidence: clip(evidence, clip_to[1]))}"
    end

    def checklist_line(snap)
      Reach::Checklist.line(snap["checklist"], stage: snap["current"])
    end

    def tally_line(snap)
      Reach::Messages.text("M-BRIEF-TALLY", **snap["tally"].transform_keys(&:to_sym))
    end

    def tries_line(snap)
      return nil unless snap["failed"].to_i.positive? && snap["current"] == "qualify"

      Reach::Messages.text("M-BRIEF-TRIES", failed: snap["failed"], limit: Reach::Ladder::HARD_STOP)
    end

    def full_text(snap, changed)
      limit = settings["max_full_chars"].to_i
      variants = PLAN_CLIPS.map { |pair| { plan: pair, tries: pair == PLAN_CLIPS.first, tally: true, left: true, done: true, check: true } }
      variants << { plan: nil, tries: false, tally: true, left: true, done: true, check: true }
      variants << { plan: nil, tries: false, tally: false, left: true, done: true, check: true }
      variants << { plan: nil, tries: false, tally: false, left: false, done: true, check: true }
      variants << { plan: nil, tries: false, tally: false, left: false, done: false, check: true }
      variants << { plan: nil, tries: false, tally: false, left: false, done: false, check: false }
      text = nil
      variants.each do |choice|
        text = assemble(snap, changed, choice)
        break if text.length <= limit
      end
      text
    end

    def assemble(snap, changed, choice)
      lines = [where_line(snap)]
      lines << done_line(snap) if choice[:done]
      lines << now_line(snap)
      lines << left_line(snap) if choice[:left]
      lines << plan_line(snap, choice[:plan]) if choice[:plan]
      lines << checklist_line(snap) if choice[:check]
      lines << tally_line(snap) if choice[:tally]
      lines << tries_line(snap) if choice[:tries]
      lines << Reach::Messages.text("M-BRIEF-NEXT", next: snap["next"])
      lines << Reach::Messages.text("M-BRIEF-CONFIRM")
      lines << Reach::Messages.text("M-BRIEF-CHANGED") if changed
      lines.compact.join(" ")
    end

    def line_text(snap)
      limit = settings["max_line_chars"].to_i
      current = snap["stages"].find { |item| %w[current waiting].include?(item["state"]) }
      stage = current ? stage_word(current["id"]) : Reach::Messages.text("M-BRIEF-STAGE-ALL")
      fields = { assignment: snap["assignment"], index: snap["index"], count: snap["count"], stage: stage }
      head = Reach::Messages.text("M-BRIEF-LINE", **fields, next: "")
      Reach::Messages.text("M-BRIEF-LINE", **fields, next: clip(snap["next"], [limit - head.length, 0].max))
    end

    def for_prompt(space, session, _harness)
      return nil unless enabled?

      workspace = resolve(space)
      return nil unless workspace

      snap = snapshot(workspace, session: session)
      return nil unless snap

      full, changed = decide(session, snap)
      full ? full_text(snap, changed) : line_text(snap)
    rescue StandardError => e
      fault(e, "for_prompt")
      nil
    end

    def overview
      data = status
      current = data["current_assignment"]
      return nil unless current.is_a?(Hash) && current["id"]

      found = found_workspaces
      rows = Reach::Next.assignment_slices(data, current["id"]).map do |slice|
        path = found[[slice["cutout_id"], slice["slice"]]]
        stage = path ? current_stage_word(slice, current["id"], path) : Reach::Messages.text("M-BRIEF-STAGE-NOT-STARTED")
        { "assignment" => current["id"], "module" => module_name(slice), "slice" => slice["slice"], "stage" => stage }
      end
      return nil if rows.empty?

      { "assignment" => current["id"], "rows" => rows, "tally" => tally_for(current["id"], found) }
    rescue StandardError => e
      fault(e, "overview")
      nil
    end

    def current_stage_word(slice, assignment, workspace)
      order, facts, pending = stage_facts(slice, assignment, workspace, nil)
      _list, current = stages_for(order, facts, pending)
      current ? stage_word(current) : Reach::Messages.text("M-BRIEF-STAGE-ALL")
    end
  end
end
