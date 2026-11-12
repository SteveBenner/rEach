# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module Reach
  module SessionRecall
    DEFAULTS = {
      "enabled" => true,
      "mode" => "hybrid",
      "resume" => true,
      "resume_gap_hours" => 6,
      "recurrence" => true,
      "cue" => true,
      "tool" => true,
      "budget_bytes" => 700,
      "per_hour" => 3,
      "max_episodes" => 400,
      "max_index_bytes" => 4_194_304,
      "cue_min_share" => 0.25,
      "cue_inject_share" => 0.45,
      "episode_gap_minutes" => 45,
      "refresh_budget_s" => 3
    }.freeze
    MODES = %w[hybrid inject offer].freeze
    FLOAT_KEYS = %w[cue_min_share cue_inject_share].freeze
    LINE_CHARS = 200
    SHOW_BYTES = 4000
    STATE_SESSIONS = 32
    LEDGER_KEEP = 400
    MIN_PROMPT_CHARS = 12
    RECUR_WINDOW_S = 86_400
    RECUR_LEAD_S = 600
    PROMPT_LOCK_WAIT_S = 0.25
    CUE_HITS = 8
    READ_CAP_BYTES = 16_777_216
    ELLIPSIS = "\u2026"
    CUE_PATTERN = /\b(?:last time|last session|last week|last night|yesterday|earlier today|the other day|(?:did|had|tried|like|as|same as) before|remember (?:when|how|what|that|the|we|I)|(?:like|as|what|the way) (?:we|I) did|previously|how did (?:we|I)|what did (?:we|I)|where (?:were|was) (?:we|I)|(?:we|I) left off|pick up where|(?:fail(?:ed|ing|s)?|broke|broken|happen(?:ed|ing|s)?|again and) again)\b/i.freeze

    module_function

    def fault(error, where)
      Reach::Debug.fault(error, "session_recall:#{where}")
      nil
    end

    def log(event, fields = {})
      Reach::Debug.emit("recall", fields.merge("event" => event))
      nil
    rescue StandardError => e
      fault(e, "log")
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def settings
      section = Reach::Runtime.load_config["recall"]
      section = {} unless section.is_a?(Hash)
      DEFAULTS.each_with_object({}) do |(key, default), memo|
        given = section[key]
        memo[key] = if default == true
                      given == false ? false : true
                    elsif key == "mode"
                      MODES.include?(given) ? given : default
                    elsif FLOAT_KEYS.include?(key)
                      given.is_a?(Numeric) && given.positive? ? given.to_f : default
                    elsif key == "max_index_bytes"
                      given.is_a?(Integer) && given.positive? ? [given, READ_CAP_BYTES].min : default
                    else
                      given.is_a?(Integer) && given.positive? ? given : default
                    end
      end
    rescue StandardError => e
      fault(e, "settings")
      DEFAULTS.merge("enabled" => false)
    end

    def dir
      File.join(Reach::Paths.brain_home, "recall")
    end

    def state_path
      File.join(dir, "state.json")
    end

    def ledger_path
      File.join(dir, "qualify.json")
    end

    def state_lock_path
      File.join(dir, "state.lock")
    end

    def ensure_dir!
      parent = Reach::Paths.brain_home
      fresh = !File.directory?(parent)
      FileUtils.mkdir_p(dir)
      File.chmod(0o700, parent) if fresh
      File.chmod(0o700, dir)
      nil
    end

    def read_json(path)
      return nil unless File.file?(path)

      size = File.size(path)
      if size > READ_CAP_BYTES
        log("recall.oversized", "file" => File.basename(path), "bytes" => size)
        return nil
      end
      JSON.parse(File.read(path))
    rescue StandardError => e
      fault(e, "read_json")
    end

    def read_state
      data = read_json(state_path)
      data.is_a?(Hash) ? data : {}
    end

    def read_ledger
      data = read_json(ledger_path)
      data.is_a?(Array) ? data.select { |row| row.is_a?(Hash) } : []
    end

    def update_state
      ensure_dir!
      outcome = Reach::Locks.exclusive(state_lock_path, wait_s: nil) do
        state = read_state
        yield(state)
        Reach::Brain.write_json(state_path, state)
        state
      end
      outcome == :busy ? nil : outcome
    end

    def student_id
      Reach::Brain.student_id.to_s
    end

    def available?
      return false unless settings["enabled"]
      return false unless Reach::Brain.enabled?
      return false if Reach::Instructor.mode? || Reach::Persona.active? || Reach::ExamMode.active?

      read_state["off"] != true
    rescue StandardError => e
      fault(e, "available")
      false
    end

    def parse_time(value)
      text = value.to_s
      return nil unless text.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/)

      Time.iso8601(text)
    rescue ArgumentError => e
      fault(e, "parse_time")
    end

    def iso(time)
      time.utc.iso8601
    end

    def clip_chars(text, limit)
      text = text.to_s
      return text if text.length <= limit

      "#{text[0, limit - 1]}#{ELLIPSIS}"
    end

    def refresh!(budget_s: settings["refresh_budget_s"])
      return nil unless available?

      Reach::SessionIndex.refresh!(budget_s)
    rescue StandardError => e
      fault(e, "refresh")
    end

    def prune_missing!
      Reach::SessionIndex.prune_missing!
    end

    def forget_paths
      Reach::SessionIndex.forget_paths
    end

    def slice_key_of(meta)
      cutout = meta.is_a?(Hash) ? meta["cutout_id"].to_s : ""
      slice = meta.is_a?(Hash) ? meta["slice"].to_s : ""
      cutout.empty? || slice.empty? ? "root" : "#{cutout}.#{slice}"
    end

    def note_qualify(workspace, record)
      return nil unless available?

      meta = Reach::Workspace.metadata(workspace)
      return nil if meta["cutout_id"].to_s.empty? || meta["slice"].to_s.empty?

      row = {
        "slice_key" => slice_key_of(meta), "at" => record["at"] || iso(Time.now), "passed" => record["passed"] == true,
        "steps" => Reach::Ladder.failed_steps(record)
      }
      ensure_dir!
      outcome = Reach::Locks.exclusive(state_lock_path, wait_s: nil) do
        rows = read_ledger
        rows << row
        Reach::Brain.write_json(ledger_path, rows.last(LEDGER_KEEP))
        rows.length
      end
      outcome == :busy ? nil : outcome
    rescue StandardError => e
      fault(e, "note_qualify")
    end

    def minutes(episode)
      started = parse_time(episode["started_at"])
      ended = parse_time(episode["ended_at"])
      return 0 unless started && ended

      [((ended - started) / 60.0).ceil, 1].max
    end

    def passage_line(passage)
      text = clip_chars(passage["x"], LINE_CHARS)
      date = Reach::Messages.course_time(passage["at"])
      if passage["k"] == "p"
        Reach::Messages.text("M-RECALL-LINE-STUDENT", date: date, text: text)
      else
        Reach::Messages.text("M-RECALL-LINE-AGENT", date: date, text: text)
      end
    end

    def outcome_line(episode, ledger)
      started = parse_time(episode["started_at"])
      ended = parse_time(episode["ended_at"])
      return nil unless started && ended

      rows = ledger.select do |row|
        at = parse_time(row["at"])
        row["slice_key"] == episode["slice_key"] && at && at >= started && at <= ended
      end
      newest = rows.max_by { |row| parse_time(row["at"]) }
      return nil unless newest
      return Reach::Messages.text("M-RECALL-OUTCOME-PASSED") if newest["passed"] == true

      Reach::Messages.text("M-RECALL-OUTCOME-FAILED", steps: Array(newest["steps"]).join(", "))
    end

    def recurrence_target(ledger, key, entry, now)
      rows = ledger.map { |row| [row, parse_time(row["at"])] }.select { |_row, at| at }
      newest = rows.select { |row, _at| row["slice_key"] == key }.max_by { |_row, at| at }
      return nil unless newest && newest[0]["passed"] != true && (now - newest[1]) <= RECUR_WINDOW_S

      failed = Array(newest[0]["steps"]).map(&:to_s)
      return nil if failed.empty?

      recur_key = "#{key}:#{failed.sort.join(',')}"
      return nil if Array(entry["steps"]).include?(recur_key)

      first_at = parse_time(entry["first_at"])
      return nil unless first_at

      earlier = rows.select { |row, at| row["passed"] != true && at < newest[1] && !(Array(row["steps"]).map(&:to_s) & failed).empty? }
      earlier.sort_by { |row, at| [row["slice_key"] == key ? 0 : 1, -at.to_f] }.each do |row, at|
        passes = rows.select { |other, other_at| other["slice_key"] == row["slice_key"] && other["passed"] == true && other_at > at && other_at < first_at }
        pass = passes.min_by { |_other, other_at| other_at }
        next unless pass

        return { failure: row, failure_at: at, pass: pass[0], pass_at: pass[1], steps: failed, key: recur_key }
      end
      nil
    end

    def recurrence_moment(target, episodes, sid)
      from = target[:failure_at] - RECUR_LEAD_S
      to = target[:pass_at]
      spanning = episodes.select do |episode|
        started = parse_time(episode["started_at"])
        ended = parse_time(episode["ended_at"])
        episode["session"] != sid && started && ended && started <= to && ended >= from
      end
      return nil if spanning.empty?

      own = spanning.select { |episode| episode["slice_key"] == target[:failure]["slice_key"] }
      ordered = own.sort_by { |episode| episode["ended_at"].to_s }.reverse + (spanning - own).sort_by { |episode| episode["ended_at"].to_s }.reverse
      { name: :recurrence, episodes: ordered, target: target, from: from, to: to }
    end

    def resume_moment(episodes, sid, key, now)
      found = episodes.select do |episode|
        ended = parse_time(episode["ended_at"])
        episode["session"] != sid && episode["slice_key"] == key && ended && ended < now
      end
      return nil if found.empty?

      { name: :resume, episodes: found.sort_by { |episode| episode["ended_at"].to_s }.reverse }
    end

    def cue_moment(episodes, sid, key, prompt, config)
      others = episodes.select { |episode| episode["session"] != sid }
      topic = prompt.gsub(CUE_PATTERN, " ")
      hits = Reach::SessionIndex.search(topic, others, k: CUE_HITS, boost_slice: key).select { |hit| hit["share"] >= config["cue_min_share"] }
      return nil if hits.empty?

      { name: :cue, hits: hits, episodes: hits.map { |hit| hit["episode"] }.uniq, best: hits.map { |hit| hit["share"] }.max }
    end

    def render_resume(episode, ledger)
      passages = episode["passages"]
      students = passages.each_index.select { |position| passages[position]["k"] == "p" }.last(2)
      agents = passages.each_index.select { |position| passages[position]["k"] == "r" }.last(1)
      lines = (students + agents).sort.map { |position| passage_line(passages[position]) }
      outcome = outcome_line(episode, ledger)
      lines << outcome if outcome
      header = Reach::Messages.text("M-RECALL-RESUME", date: Reach::Messages.course_time(episode["ended_at"]), minutes: minutes(episode), turns: episode["turns"])
      { header: header, lines: lines, shown: [episode["id"]] }
    end

    def render_recurrence(moment, usable, prompt)
      target = moment[:target]
      windowed = usable.map do |episode|
        inside = episode["passages"].select do |passage|
          at = parse_time(passage["at"])
          at && at >= moment[:from] && at <= moment[:to]
        end
        episode.merge("passages" => inside)
      end
      query = "#{target[:steps].join(' ')} #{prompt}"
      hits = Reach::SessionIndex.search(query, windowed, k: 4).sort_by { |hit| hit["passage"]["at"].to_s }
      return nil if hits.empty?

      header = Reach::Messages.text("M-RECALL-RECUR", steps: target[:steps].join(", "), date: Reach::Messages.course_time(target[:pass]["at"]))
      { header: header, lines: hits.map { |hit| passage_line(hit["passage"]) }, shown: hits.map { |hit| hit["episode"]["id"] }.uniq }
    end

    def render_cue(moment, recalled)
      hits = moment[:hits].reject { |hit| recalled.include?(hit["episode"]["id"]) }.first(3).sort_by { |hit| hit["passage"]["at"].to_s }
      return nil if hits.empty?

      { header: Reach::Messages.text("M-RECALL-CUE"), lines: hits.map { |hit| passage_line(hit["passage"]) }, shown: hits.map { |hit| hit["episode"]["id"] }.uniq }
    end

    def fit(rendered, budget)
      return nil unless rendered

      used = rendered[:header].bytesize
      kept = []
      rendered[:lines].each do |line|
        break if used + 1 + line.bytesize > budget

        used += 1 + line.bytesize
        kept << line
      end
      return nil if kept.empty?

      { text: [Reach::Messages.text("M-RECALL-HEAD"), rendered[:header], *kept].join("\n"), shown: rendered[:shown], lines: kept.length }
    end

    def pointer_text(moment)
      episodes = moment[:episodes]
      newest = episodes.map { |episode| episode["ended_at"].to_s }.max
      Reach::Messages.text("M-RECALL-POINTER", count: episodes.length, date: Reach::Messages.course_time(newest))
    end

    def hour_count(entry, now)
      hour = entry["hour"].is_a?(Hash) ? entry["hour"] : {}
      hour["bucket"] == Reach::Brain.hour_bucket(now) ? hour["count"].to_i : 0
    end

    def deliver(moment, context)
      config = context[:config]
      entry = context[:entry]
      recalled = Array(entry["recalled"])
      mode = config["mode"]
      content = mode == "inject" || (mode == "hybrid" && (moment[:name] != :cue || moment[:best] >= config["cue_inject_share"]))
      content = false if content && hour_count(entry, context[:now]) >= config["per_hour"]
      if content
        usable = moment[:episodes].reject { |episode| recalled.include?(episode["id"]) }
        return nil if usable.empty?

        rendered = case moment[:name]
                   when :resume then render_resume(usable.first, context[:ledger])
                   when :recurrence then render_recurrence(moment, usable, context[:prompt])
                   else render_cue(moment, recalled)
                   end
        block = fit(rendered, config["budget_bytes"])
        return nil unless block

        return { text: block[:text], shown: block[:shown], mode: "content", hits: block[:lines] }
      end
      return nil unless config["tool"]
      return nil if Array(entry["pointed"]).include?(moment[:name].to_s)

      { text: pointer_text(moment), shown: [], mode: "pointer", hits: moment[:episodes].length }
    end

    def activity(entry)
      slices = entry["slices"].is_a?(Hash) ? entry["slices"].values : []
      (slices + [entry["first_at"]]).map(&:to_s).max.to_s
    end

    def pick(context, sid, key, flags)
      episodes = flags.values.any? ? Reach::SessionIndex.load["episodes"] : []
      %i[recurrence resume cue].each do |name|
        moment = case name
                 when :recurrence then flags[:target] ? recurrence_moment(flags[:target], episodes, sid) : nil
                 when :resume then flags[:resume] ? resume_moment(episodes, sid, key, context[:now]) : nil
                 else flags[:cue] ? cue_moment(episodes, sid, key, context[:prompt], context[:config]) : nil
                 end
        next unless moment

        delivered = deliver(moment, context)
        return [moment, delivered] if delivered
      end
      [nil, nil]
    end

    def remember_delivery(state, entry, moment, delivered, now)
      entry["recalled"] = (entry["recalled"] + delivered[:shown]).uniq
      entry["steps"] = (entry["steps"] + [moment[:target][:key]]).uniq if moment[:name] == :recurrence
      return delivered[:text] unless delivered[:mode] == "content"

      entry["hour"] = { "bucket" => Reach::Brain.hour_bucket(now), "count" => hour_count(entry, now) + 1 }
      return delivered[:text] if state["notice_shown"] == true

      state["notice_shown"] = true
      "#{Reach::Messages.text('M-RECALL-NOTICE')}\n\n#{delivered[:text]}"
    end

    def recall_locked(sid, key, workspace, prompt, now)
      config = settings
      state = read_state
      sessions = state["sessions"].is_a?(Hash) ? state["sessions"] : {}
      entry = sessions[sid].is_a?(Hash) ? sessions[sid] : {}
      %w[recalled steps pointed].each { |name| entry[name] = [] unless entry[name].is_a?(Array) }
      entry["slices"] = {} unless entry["slices"].is_a?(Hash)
      previous = parse_time(entry["slices"][key])
      entry["first_at"] = iso(now) if entry["first_at"].to_s.empty?
      entry["slices"][key] = iso(now)
      sessions[sid] = entry
      ledger = read_ledger
      flags = {
        target: config["recurrence"] && workspace ? recurrence_target(ledger, key, entry, now) : nil,
        resume: config["resume"] && (previous.nil? || (now - previous) >= config["resume_gap_hours"] * 3600),
        cue: config["cue"] && prompt.gsub(/\s+/, "").length >= MIN_PROMPT_CHARS && prompt.match?(CUE_PATTERN)
      }
      context = { config: config, entry: entry, now: now, ledger: ledger, prompt: prompt }
      moment, delivered = pick(context, sid, key, flags)
      text = nil
      if delivered
        entry["pointed"] = (entry["pointed"] + [moment[:name].to_s]).uniq if delivered[:mode] == "pointer"
        text = remember_delivery(state, entry, moment, delivered, now)
      end
      state["sessions"] = sessions.sort_by { |_id, item| activity(item) }.last(STATE_SESSIONS).to_h
      Reach::Brain.write_json(state_path, state)
      log("recall.injected", "moment" => moment[:name].to_s, "mode" => delivered[:mode], "hits" => delivered[:hits], "bytes" => text.bytesize) if delivered
      text
    end

    def for_prompt(space:, session:, prompt:)
      return nil unless available?
      return nil unless space.is_a?(Hash) && %w[slice root].include?(space["kind"].to_s)

      workspace = Reach::TurnBrief.resolve(space)
      key = slice_key_of(workspace ? Reach::Workspace.metadata(workspace) : {})
      sid = session.to_s.empty? ? "none" : session.to_s
      ensure_dir!
      outcome = Reach::Locks.exclusive(state_lock_path, wait_s: Reach::Locks.bounded? ? PROMPT_LOCK_WAIT_S : nil) do
        recall_locked(sid, key, !workspace.nil?, prompt.to_s, Time.now.utc)
      end
      outcome == :busy ? nil : outcome
    rescue StandardError => e
      fault(e, "for_prompt")
    end

    def tool_arguments(arguments)
      return {} unless arguments.is_a?(Hash)

      arguments.each_with_object({}) { |(name, value), memo| memo[name.to_s] = value }
    end

    def bounded_int(value, default, low, high)
      number = Integer(value, exception: false)
      return default unless number

      [[number, low].max, high].min
    end

    def search_line(hit)
      fields = {
        id: hit["episode"]["id"], date: Reach::Messages.course_time(hit["passage"]["at"]), slice: hit["episode"]["slice_key"], text: hit["passage"]["x"]
      }
      if hit["passage"]["k"] == "p"
        Reach::Messages.text("M-RECALL-SEARCH-STUDENT", **fields)
      else
        Reach::Messages.text("M-RECALL-SEARCH-AGENT", **fields)
      end
    end

    def tool_search(args)
      query = args["query"].to_s.strip
      return { "text" => Reach::Messages.text("M-RECALL-USAGE") } if query.empty?

      hits = Reach::SessionIndex.search(query, Reach::SessionIndex.load["episodes"], k: bounded_int(args["k"], 3, 1, 8))
      return { "text" => Reach::Messages.text("M-RECALL-NONE") } if hits.empty?

      { "text" => [Reach::Messages.text("M-RECALL-TOOL-HEAD"), *hits.map { |hit| search_line(hit) }].join("\n"), "hits" => hits.length }
    end

    def tool_list(args)
      prefix = args["slice"].to_s
      limit = bounded_int(args["limit"], 10, 1, 30)
      episodes = Reach::SessionIndex.load["episodes"]
      episodes = episodes.select { |episode| episode["slice_key"].to_s.start_with?(prefix) } unless prefix.empty?
      return { "text" => Reach::Messages.text("M-RECALL-NONE") } if episodes.empty?

      rows = episodes.sort_by { |episode| episode["ended_at"].to_s }.reverse.first(limit)
      lines = rows.map do |episode|
        first = episode["passages"].find { |passage| passage["k"] == "p" }
        Reach::Messages.text(
          "M-RECALL-LIST-LINE", id: episode["id"], date: Reach::Messages.course_time(episode["started_at"]), minutes: minutes(episode),
          turns: episode["turns"], slice: episode["slice_key"], first: clip_chars(first ? first["x"] : "", 120)
        )
      end
      { "text" => lines.join("\n"), "hits" => rows.length }
    end

    def tool_show(args)
      wanted = args["id"].to_s.strip
      episodes = Reach::SessionIndex.load["episodes"]
      found = episodes.find { |episode| episode["id"] == wanted }
      unless found
        matches = wanted.empty? ? [] : episodes.select { |episode| episode["id"].start_with?(wanted) }
        found = matches.first if matches.length == 1
      end
      return { "text" => Reach::Messages.text("M-RECALL-NOT-FOUND", id: wanted) } unless found

      lines = [Reach::Messages.text("M-RECALL-TOOL-HEAD")]
      used = lines.first.bytesize
      found["passages"].each do |passage|
        line = passage_line(passage)
        break if used + 1 + line.bytesize > SHOW_BYTES

        used += 1 + line.bytesize
        lines << line
      end
      { "text" => lines.join("\n"), "hits" => lines.length - 1 }
    end

    def tool_switch(off)
      return { "text" => Reach::Messages.text("M-RECALL-DISABLED") } if !off && !settings["enabled"]

      outcome = update_state { |state| state["off"] = off }
      return { "text" => Reach::Messages.text("M-RECALL-UNAVAILABLE") } unless outcome

      off ? { "text" => Reach::Messages.text("M-RECALL-OFF-DONE") } : { "text" => Reach::Messages.text("M-RECALL-ON-DONE") }
    end

    def tool(arguments)
      args = tool_arguments(arguments)
      action = args["action"].to_s
      return tool_switch(true) if action == "off"
      return tool_switch(false) if action == "on"
      return { "text" => Reach::Messages.text("M-RECALL-USAGE") } unless %w[search list show].include?(action)
      return { "text" => Reach::Messages.text("M-RECALL-TOOL-OFF") } unless settings["tool"]
      return { "text" => Reach::Messages.text("M-RECALL-UNAVAILABLE") } unless available?

      case action
      when "search" then tool_search(args)
      when "list" then tool_list(args)
      else tool_show(args)
      end
    rescue StandardError => e
      fault(e, "tool")
      { "text" => Reach::Messages.text("M-RECALL-UNAVAILABLE") }
    end
  end
end
