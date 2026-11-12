# frozen_string_literal: true

require "json"
require "yaml"
require "time"
require "fileutils"

module Reach
  module Checklist
    SCHEMA = "reach.checklist/v1"
    STATES = %w[todo doing done].freeze
    ITEM_LIMIT = 200
    DEFAULTS = { "enabled" => true, "max_items" => 30, "offer" => true, "open_listed" => 3, "line_chars" => 140 }.freeze
    ASK_PATTERN = /\b(check[ -]?list|to-?do list|task list|what (do i|should i|i need to|is left|is required|is expected|have i missed|am i missing)\b)/i.freeze
    OFFER_SESSIONS = 32
    OFFER_LOCK_WAIT_S = 0.25
    INTEGER_KEYS = %w[max_items open_listed line_chars].freeze

    module_function

    def fault(error, where)
      Reach::Debug.fault(error, "checklist:#{where}")
      nil
    end

    def settings
      given = DEFAULTS.merge(Reach::BehaviorPolicy.parameters("checklist"))
      DEFAULTS.each_with_object({}) do |(key, default), memo|
        value = given[key]
        memo[key] = if INTEGER_KEYS.include?(key)
                      value.is_a?(Integer) && value.positive? ? value : default
                    else
                      value == false ? false : true
                    end
      end
    rescue KeyError
      DEFAULTS
    rescue StandardError => e
      fault(e, "settings")
      DEFAULTS
    end

    def enabled?
      return false if ENV["REACH_CHECKLIST"] == "0"

      settings["enabled"] != false && Reach::Enroll.current ? true : false
    rescue StandardError => e
      fault(e, "enabled")
      false
    end

    def path(workspace)
      File.join(workspace, Reach::Workspace::MARKER_DIR, "checklist.yml")
    end

    def stamp
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def load(workspace)
      return nil unless File.file?(path(workspace))

      data = YAML.safe_load(File.read(path(workspace)), permitted_classes: [], aliases: false)
      return nil unless data.is_a?(Hash) && data["schema"] == SCHEMA
      return nil unless data["items"].is_a?(Array) && data["items"].all? { |item| item.is_a?(Hash) }

      data
    rescue StandardError => e
      fault(e, "load")
    end

    def required_files(workspace)
      assignment = Reach::Workspace.metadata(workspace)["assignment"].to_s
      return [] if assignment.empty? || !Reach::AssignmentContext.enabled?

      phase = (Reach::AssignmentContext.locate(workspace) || {})["phase"] || "start"
      Reach::AssignmentContext.required(assignment, phase)
    end

    def required_reads(workspace)
      required_files(workspace).map { |entry| entry["path"].to_s }.reject(&:empty?)
    rescue StandardError => e
      fault(e, "required_reads")
      []
    end

    def chat_id(session)
      given = session.to_s
      return given if !given.empty? && Reach::Threads.read["threads"].key?(given)

      Reach::Threads.resolve(Reach::Session.detect_harness)
    end

    def unread(workspace, session: nil)
      need = required_reads(workspace)
      return [] if need.empty?

      id = chat_id(session)
      return [] if id.to_s.empty?

      need - Reach::Threads.read_paths(id)
    rescue StandardError => e
      fault(e, "unread")
      []
    end

    def clean_items(items)
      list = items.is_a?(Array) ? items.map(&:to_s) : items.to_s.split("|")
      list.map { |item| item.gsub(/\s+/, " ").strip }.reject(&:empty?).uniq
    end

    def save(workspace, items:, session: nil)
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-DISABLED") unless enabled?

      missing = unread(workspace, session: session)
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-READ-FIRST", files: missing.join(", ")) unless missing.empty?

      list = clean_items(items)
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-EMPTY") if list.empty?

      limit = settings["max_items"]
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-TOO-LONG", field: "items", limit: limit) if list.length > limit
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-TOO-LONG", field: "item", limit: ITEM_LIMIT) if list.any? { |item| item.length > ITEM_LIMIT }

      earlier = load(workspace)
      before = earlier ? earlier["items"].to_h { |item| [item["text"].to_s, item] } : {}
      kept = 0
      rows = list.each_with_index.map do |text, index|
        old = before[text]
        if old && STATES.include?(old["state"].to_s)
          kept += 1
          { "number" => index + 1, "text" => text, "state" => old["state"].to_s, "evidence" => old["evidence"].to_s, "at" => old["at"].to_s }
        else
          { "number" => index + 1, "text" => text, "state" => "todo", "evidence" => "", "at" => "" }
        end
      end
      meta = Reach::Workspace.metadata(workspace)
      now = stamp
      data = {
        "schema" => SCHEMA,
        "assignment" => meta["assignment"].to_s,
        "cutout_id" => meta["cutout_id"],
        "slice" => meta["slice"],
        "sources" => required_reads(workspace),
        "material" => Reach::AssignmentContext.material_digest,
        "revision" => earlier ? earlier["revision"].to_i + 1 : 1,
        "created_at" => earlier && !earlier["created_at"].to_s.empty? ? earlier["created_at"].to_s : now,
        "updated_at" => now,
        "items" => rows
      }
      FileUtils.mkdir_p(File.dirname(path(workspace)))
      Reach::StateFile.write_atomic(path(workspace), YAML.dump(data))
      Reach::Ledger.append(workspace, "checklist", "action" => "save", "items" => rows.length)
      data.merge("kept" => kept)
    end

    def set_item(workspace, number, state, evidence: nil)
      data = load(workspace)
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-NONE") unless data

      items = data["items"]
      index = number.to_s.match?(/\A\d{1,4}\z/) ? number.to_s.to_i : 0
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-BAD-NUMBER", count: items.length) unless index.between?(1, items.length)

      state = state.to_s
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-BAD-STATE") unless STATES.include?(state)

      note = evidence.to_s.strip
      raise Reach::Error, Reach::Messages.text("M-CHECKLIST-NEEDS-EVIDENCE", limit: ITEM_LIMIT) if state == "done" && (note.empty? || note.length > ITEM_LIMIT)

      now = stamp
      items.each { |item| item["state"] = "todo" if state == "doing" && item["state"] == "doing" }
      target = items[index - 1]
      target["state"] = state
      target["evidence"] = state == "todo" ? "" : note[0, ITEM_LIMIT]
      target["at"] = now
      data["updated_at"] = now
      Reach::StateFile.write_atomic(path(workspace), YAML.dump(data))
      Reach::Ledger.append(workspace, "checklist", "action" => "item", "item" => index, "state" => state)
      data
    end

    def view(workspace)
      return nil unless enabled?

      data = load(workspace)
      return nil unless data && !data["items"].empty?

      items = data["items"].each_with_index.map do |item, index|
        {
          "number" => item["number"] || index + 1, "text" => item["text"].to_s,
          "state" => STATES.include?(item["state"].to_s) ? item["state"].to_s : "todo",
          "evidence" => item["evidence"].to_s, "at" => item["at"].to_s
        }
      end
      stored = data["material"]
      {
        "total" => items.length,
        "done" => items.count { |item| item["state"] == "done" },
        "open" => items.reject { |item| item["state"] == "done" },
        "doing" => items.find { |item| item["state"] == "doing" },
        "items" => items,
        "stale" => !stored.nil? && stored != Reach::AssignmentContext.material_digest
      }
    rescue StandardError => e
      fault(e, "view")
      nil
    end

    def open_list(view)
      options = settings
      listed = options["open_listed"]
      each = [options["line_chars"] / listed, 1].max
      view["open"].first(listed).map { |item| "#{item['number']}. #{Reach::TurnBrief.clip(item['text'], each)}" }.join("; ")
    end

    def line(view, stage: nil)
      return nil unless view

      open = view["open"]
      return Reach::Messages.text("M-CHECKLIST-ALL-DONE", total: view["total"]) if open.empty?
      return Reach::Messages.text("M-CHECKLIST-BEFORE", count: open.length, list: open_list(view)) if %w[qualify submit].include?(stage.to_s)

      [
        Reach::Messages.text("M-CHECKLIST-LINE", done: view["done"], total: view["total"]),
        Reach::Messages.text("M-CHECKLIST-OPEN", list: open_list(view))
      ].join(" ")
    rescue StandardError => e
      fault(e, "line")
      nil
    end

    def gate_note(workspace)
      return nil unless enabled?

      found = view(workspace)
      return nil unless found && !found["open"].empty?

      Reach::Messages.text("M-CHECKLIST-BEFORE", count: found["open"].length, list: open_list(found))
    rescue StandardError => e
      fault(e, "gate_note")
      nil
    end

    def step_note(workspace)
      return nil unless enabled?

      found = view(workspace)
      return nil unless found && !found["open"].empty?

      Reach::Messages.text("M-CHECKLIST-AFTER-STEP", count: found["open"].length)
    rescue StandardError => e
      fault(e, "step_note")
      nil
    end

    def render(workspace)
      data = load(workspace)
      return Reach::Messages.text("M-CHECKLIST-NONE") unless data

      lines = data["items"].each_with_index.map do |item, index|
        row = "#{item['number'] || index + 1}. [#{item['state']}] #{item['text']}"
        evidence = item["evidence"].to_s
        evidence.empty? ? row : "#{row} (#{evidence})"
      end
      lines << "Updated: #{data['updated_at']}"
      lines.join("\n")
    rescue StandardError => e
      fault(e, "render")
      Reach::Messages.text("M-CHECKLIST-NONE")
    end

    def files_text(workspace)
      files = required_reads(workspace)
      return Reach::Messages.text("M-CHECKLIST-NO-FILES") if files.empty?

      files.map { |file| "`#{file}`" }.join(", ")
    end

    def hello_entries(workspace:, session:)
      return [] unless enabled? && workspace

      found = view(workspace)
      return [] unless found

      entries = [
        ["hello.session", "- #{line(found)}"],
        ["hello.session", "- #{Reach::Messages.text('M-CHECKLIST-KEEP')}"]
      ]
      files = required_reads(workspace)
      entries << ["hello.session", "- #{Reach::Messages.text('M-CHECKLIST-STALE', files: files.join(', '))}"] if found["stale"] && !files.empty?
      entries
    rescue StandardError => e
      fault(e, "hello_entries")
      []
    end

    def offers_file
      File.join(Reach::Paths.state_dir, "checklist-offers.json")
    end

    def read_offers
      return { "sessions" => {} } unless File.file?(offers_file)

      data = JSON.parse(File.read(offers_file))
      raise TypeError, "offers state has the wrong shape" unless data.is_a?(Hash) && data["sessions"].is_a?(Hash)

      data
    end

    def offer_once(session, key)
      return false if session.to_s.empty?

      file = offers_file
      FileUtils.mkdir_p(File.dirname(file))
      outcome = Reach::Locks.exclusive("#{file}.lock", wait_s: OFFER_LOCK_WAIT_S) do
        data = read_offers
        entry = data["sessions"][session].is_a?(Hash) ? data["sessions"][session] : {}
        next false if entry.key?(key)

        entry[key] = stamp
        data["sessions"][session] = entry
        data["sessions"] = data["sessions"].sort_by { |_id, item| item.values.map(&:to_s).max.to_s }.last(OFFER_SESSIONS).to_h
        Reach::StateFile.write_atomic(file, JSON.generate(data), mode: 0o600)
        true
      end
      outcome == true
    rescue StandardError => e
      fault(e, "offer_once")
      false
    end

    def prompt_notice(space:, session:, prompt:)
      return nil unless enabled? && settings["offer"] != false
      return nil if Reach::Instructor.mode? || Reach::Persona.active? || Reach::ExamMode.active?

      workspace = Reach::TurnBrief.resolve(space)
      return nil unless workspace

      meta = Reach::Workspace.metadata(workspace)
      return nil if meta["assignment"].to_s.empty?

      files = files_text(workspace)
      return Reach::Messages.text("M-CHECKLIST-ASKED", files: files) if prompt.to_s.match?(ASK_PATTERN)

      key = "#{meta['cutout_id']}.#{meta['slice']}"
      found = view(workspace)
      if found
        return nil unless found["stale"]

        return offer_once(session, "#{key}#stale") ? Reach::Messages.text("M-CHECKLIST-STALE", files: files) : nil
      end
      return nil if load(workspace)

      offer_once(session, key) ? Reach::Messages.text("M-CHECKLIST-BEGIN", files: files) : nil
    rescue StandardError => e
      fault(e, "prompt_notice")
      nil
    end

    def tool(workspace, arguments)
      args = arguments.is_a?(Hash) ? arguments.each_with_object({}) { |(name, value), memo| memo[name.to_s] = value } : {}
      case args["action"].to_s
      when "save"
        data = save(workspace, items: args["items"])
        { "text" => Reach::Messages.text("M-CHECKLIST-SAVED", count: data["items"].length, kept: data["kept"]) }
      when "item"
        set_item(workspace, args["number"], args["state"], evidence: args["evidence"])
        { "text" => Reach::Messages.text("M-CHECKLIST-ITEM-SAVED", number: args["number"].to_s.to_i, state: args["state"].to_s) }
      when "show"
        { "text" => render(workspace), "checklist" => load(workspace) || {} }
      else
        { "text" => Reach::Messages.text("M-CHECKLIST-USAGE") }
      end
    end
  end
end
