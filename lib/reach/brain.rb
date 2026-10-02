require "json"
require "time"
require "digest"
require "securerandom"
require "fileutils"

module Reach
  module Brain
    CATEGORIES = %w[preference goal decision struggle skill project fact thought].freeze
    HIGH_SALIENCE = %w[preference goal decision].freeze
    DEFAULTS = {
      "enabled" => true,
      "capture_min_chars" => 40,
      "sources_per_hour" => 120,
      "duplicate" => 0.85,
      "related" => 0.5,
      "per_hour" => 30,
      "per_day" => 150,
      "max_record_bytes" => 4096,
      "nudge_every_turns" => 3,
      "nudge_max_turns" => 24,
      "session_budget_bytes" => 1500,
      "prompt_budget_bytes" => 800,
      "prompt_k" => 4,
      "prompt_min_score" => 0.2,
      "admit_interval_s" => 300,
      "admit_max_backoff_s" => 3600,
      "max_spool_bytes" => 20_971_520
    }.freeze
    FLOAT_KEYS = %w[duplicate related prompt_min_score].freeze
    SOURCE_MAX_BYTES = 16_384
    CUT_MARK = "\n[cut]".freeze
    CLAIM_MAX = 400
    EVIDENCE_MAX = 1200
    CLAIM_MIN = 8
    GROUND_WINDOW_S = 1800
    SPOOL_CHECK_S = 600
    PRUNE_TARGET = 0.8
    DIGEST_KEEP = 500
    INJECT_KEEP = 10
    MIN_PROMPT_CHARS = 12
    SECRET_PATTERN = /(password|passcode|passphrase|api[ _-]?key|secret|token)\s*[:=]/i.freeze

    module_function

    def settings
      section = Reach::Runtime.load_config["brain"]
      section = {} unless section.is_a?(Hash)
      DEFAULTS.each_with_object({}) do |(key, default), memo|
        given = section[key]
        memo[key] = if default == true
                      given == false ? false : true
                    elsif FLOAT_KEYS.include?(key)
                      given.is_a?(Numeric) && given.positive? ? given.to_f : default
                    else
                      given.is_a?(Integer) && given.positive? ? given : default
                    end
      end
    rescue StandardError
      DEFAULTS.dup
    end

    def enabled?
      return @enabled if defined?(@enabled) && !@enabled.nil?

      @enabled = settings["enabled"] && !Reach::Enroll.current.nil? && !Reach::EnrollmentLock.locked?
    rescue StandardError
      false
    end

    def dir
      File.join(Reach::Paths.home, "brain")
    end

    def sessions_dir
      File.join(dir, "sessions")
    end

    def state_path
      File.join(dir, "state.json")
    end

    def log(event, fields = {})
      Reach::BrainSpool.log(event, fields)
    end

    def ensure_dir!
      FileUtils.mkdir_p(sessions_dir)
      File.chmod(0o700, dir)
      File.chmod(0o700, sessions_dir)
    rescue NotImplementedError, Errno::ENOENT
      nil
    end

    def with_lock
      ensure_dir!
      File.open(File.join(dir, "brain.lock"), File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end

    def read_json(path)
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write_json(path, data)
      tmp = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(3)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      File.rename(tmp, path)
    end

    def read_state
      read_json(state_path)
    end

    def update_state
      with_lock do
        fresh = read_json(state_path)
        updated = yield(fresh)
        write_json(state_path, updated)
        updated
      end
    end

    def session_path(session_id)
      File.join(sessions_dir, "#{safe_session(session_id)}.json")
    end

    def safe_session(session_id)
      cleaned = session_id.to_s.gsub(/[^A-Za-z0-9._-]/, "-")[0, 64]
      cleaned.empty? ? "unknown" : cleaned
    end

    def read_session(session_id)
      read_json(session_path(session_id))
    end

    def update_session(session_id)
      with_lock do
        fresh = read_json(session_path(session_id))
        updated = yield(fresh)
        write_json(session_path(session_id), updated)
        updated
      end
    end

    def latest_session_id
      return nil unless File.directory?(sessions_dir)

      newest = Dir.children(sessions_dir).select { |name| name.end_with?(".json") }.max_by { |name| File.mtime(File.join(sessions_dir, name)) }
      newest && File.basename(newest, ".json")
    rescue StandardError
      nil
    end

    def student_id
      install = Reach::Enroll.current
      install && install["student_id"]
    rescue StandardError
      nil
    end

    def load_index
      Reach::BrainIndex.load(reinforcements: read_state["reinforcements"])
    end

    def cut_text(text)
      return text if text.bytesize <= SOURCE_MAX_BYTES

      "#{text.byteslice(0, SOURCE_MAX_BYTES - CUT_MARK.bytesize).scrub('')}#{CUT_MARK}"
    end

    def hour_bucket(now)
      now.utc.strftime("%Y-%m-%dT%H")
    end

    def day_bucket(now)
      now.utc.strftime("%Y-%m-%d")
    end

    def bucket_count(state, key, now)
      entry = state["hour"].is_a?(Hash) ? state["hour"] : {}
      entry["bucket"] == hour_bucket(now) ? entry[key].to_i : 0
    end

    def day_count(state, now)
      entry = state["day"].is_a?(Hash) ? state["day"] : {}
      entry["bucket"] == day_bucket(now) ? entry["findings"].to_i : 0
    end

    def spend(state, key, now)
      hour = state["hour"].is_a?(Hash) && state["hour"]["bucket"] == hour_bucket(now) ? state["hour"] : { "bucket" => hour_bucket(now) }
      hour[key] = hour[key].to_i + 1
      state = state.merge("hour" => hour)
      if key == "findings"
        day = state["day"].is_a?(Hash) && state["day"]["bucket"] == day_bucket(now) ? state["day"] : { "bucket" => day_bucket(now) }
        day["findings"] = day["findings"].to_i + 1
        state = state.merge("day" => day)
      end
      state
    end

    def capture_turn(session_id:, space:)
      return nil unless enabled?

      config = settings
      now = Time.now.utc
      session = read_session(session_id)
      cursor = session["cursor"].to_i
      entries = Reach::Transcript.read_entries_after(session_id, cursor)
      return nil if entries.empty?

      top = entries.map { |entry| entry["seq"].to_i }.max
      usable = entries.select { |entry| capturable?(entry) }
      lines = usable.map { |entry| "#{entry['kind'] == 'prompt' ? 'Student' : 'Partner'}: #{entry['text'].to_s.strip}" }
      text = cut_text(lines.join("\n").strip)
      captured = nil
      held = false
      too_short = text.length < config["capture_min_chars"]
      digest = Digest::SHA256.hexdigest(text)

      unless too_short
        captured_digests = Array(read_state["digests"])
        if captured_digests.include?(digest[0, 20])
          too_short = true
        elsif read_state["spool_full"] == true && (check_spool(config, now) || read_state["spool_full"] == true)
          held = "spool_full"
        elsif bucket_count(read_state, "sources", now) >= config["sources_per_hour"]
          held = "rate"
        else
          path = "conversations/#{now.strftime('%Y-%m-%d')}/#{safe_session(session_id)[0, 32]}-#{usable.first['seq']}.private.md"
          id = source_id(path, digest)
          record = {
            "text" => text, "path" => path, "source_digest" => digest, "title" => "turn #{usable.first['seq']}",
            "session_id" => session_id.to_s, "space" => space.to_s, "at" => now.iso8601, "student_id" => student_id
          }
          Reach::BrainSpool.append_op(op: "source", kind: "source", id: id, record: record)
          captured = { "id" => id, "digest" => digest, "at" => now.to_i, "bytes" => text.bytesize }
        end
      end

      nudge = false
      update_state do |state|
        if captured
          kept = (Array(state["digests"]) + [digest[0, 20]]).last(DIGEST_KEEP)
          state = spend(state.merge("digests" => kept), "sources", now)
        end
        state
      end
      update_session(session_id) do |fresh|
        fresh = fresh.merge("cursor" => [top, fresh["cursor"].to_i].max)
        if captured
          fresh["last_source"] = { "id" => captured["id"], "digest" => captured["digest"], "at" => captured["at"] }
          fresh["turns"] = fresh["turns"].to_i + 1
          fresh["since_nudge"] = fresh["since_nudge"].to_i + 1
          interval = fresh["interval"].to_i.positive? ? fresh["interval"].to_i : config["nudge_every_turns"]
          if fresh["since_nudge"] >= interval
            interval = [interval * 2, config["nudge_max_turns"]].min if fresh["nudged"] && !fresh["saved_since_nudge"]
            fresh["interval"] = interval
            fresh["nudge_pending"] = true
            fresh["nudged"] = false
            fresh["saved_since_nudge"] = false
            fresh["since_nudge"] = 0
            nudge = true
          end
        end
        fresh
      end

      if captured
        log("brain.captured", "source_id" => captured["id"], "bytes" => captured["bytes"], "entries" => usable.length, "nudge" => nudge)
        check_spool(config, now)
        Reach::Corpus.new(Reach.ports).admit_if_due
      elsif held
        log("brain.source_held", "session_id" => session_id.to_s, "reason" => held)
      end
      captured && captured["id"]
    rescue StandardError => e
      log("brain.failed", "op" => "capture", "error" => e.class.name)
      nil
    end

    def spool_bytes
      Reach::BrainSpool.spool_files(include_admitted: true).inject(0) { |sum, path| sum + File.size(path) }
    end

    def check_spool(config, now)
      state = read_state
      return nil if state["spool_checked_at"].to_i + SPOOL_CHECK_S > now.to_i

      cap = config["max_spool_bytes"]
      before = spool_bytes
      after = before
      full = false
      if before > cap
        index = load_index
        referenced = index.findings.map { |row| row["s"] }
        victims = index.sources.reject { |row| referenced.include?(row["id"]) }.sort_by { |row| [row["w"].to_s, row["id"]] }
        target = (cap * PRUNE_TARGET).to_i
        doomed = []
        freed = 0
        victims.each do |row|
          break if before - freed <= target

          doomed << row["id"]
          freed += row["b"].to_i
        end
        unless doomed.empty?
          Reach::BrainSpool.scrub!(doomed)
          load_index
          after = spool_bytes
          log("brain.pruned", "sources" => doomed.length, "bytes_before" => before, "bytes_after" => after)
        end
        full = after > cap
      end
      update_state { |fresh| fresh.merge("spool_checked_at" => now.to_i, "spool_full" => full) }
      nil
    rescue StandardError => e
      log("brain.failed", "op" => "spool_check", "error" => e.class.name)
      nil
    end

    def capturable?(entry)
      return false unless %w[prompt reply].include?(entry["kind"])
      return false if entry["space"].to_s.empty?
      return false if entry["kind"] == "prompt" && entry["gate"] == "blocked"

      !entry["text"].to_s.strip.empty?
    end

    def source_id(path, digest)
      "source-#{Digest::SHA256.hexdigest("#{path}\n#{digest}")[0, 24]}"
    end

    def finding_id(category, claim)
      normalized = claim.to_s.downcase.gsub(/\s+/, " ").strip
      "finding-#{Digest::SHA256.hexdigest("#{category}\n#{normalized}")[0, 24]}"
    end

    def student_id_regex
      pattern = Reach::Runtime.load_config.dig("enrollment", "student_id_pattern").to_s
      pattern = pattern.sub(/\A(\^|\\A)/, "").sub(/(\$|\\z|\\Z)\z/, "")
      pattern.empty? ? nil : Regexp.new(pattern)
    rescue StandardError
      nil
    end

    def secret?(*texts)
      joined = texts.join("\n")
      return true if joined.match?(SECRET_PATTERN)

      regex = student_id_regex
      return true if regex && joined.match?(regex)

      own = student_id.to_s
      !own.empty? && joined.include?(own)
    end

    def remember(category:, claim:, evidence:, supersedes: nil, session_id: nil)
      config = settings
      raise Reach::Refused, Reach::Messages.text("M-BRAIN-DISABLED") unless config["enabled"]

      category = category.to_s.strip.downcase
      raise Reach::Refused, Reach::Messages.text("M-BRAIN-BAD-CATEGORY", categories: CATEGORIES.join(", ")) unless CATEGORIES.include?(category)

      claim = claim.to_s.strip.gsub(/\s+/, " ")
      raise Reach::Refused, Reach::Messages.text("M-BRAIN-BAD-CLAIM", minimum: CLAIM_MIN) if claim.length < CLAIM_MIN

      evidence = evidence.to_s.strip
      raise Reach::Refused, Reach::Messages.text("M-BRAIN-BAD-EVIDENCE") if evidence.empty?

      claim = claim[0, CLAIM_MAX]
      evidence = evidence[0, EVIDENCE_MAX]
      raise Reach::Refused, Reach::Messages.text("M-BRAIN-REFUSED-SECRET") if secret?(claim, evidence)

      now = Time.now.utc
      index = load_index
      old = nil
      if supersedes && !supersedes.to_s.empty?
        old = index.find_finding(supersedes.to_s)
        raise Reach::Refused, Reach::Messages.text("M-BRAIN-NOT-FOUND", id: supersedes) unless old
      end

      near = index.similar("#{claim}\n#{evidence}", category: category, exclude: old ? [old["id"]] : [])
      similarity = near ? near["similarity"] : 0.0
      nearest = near && near["finding"]
      id = finding_id(category, claim)
      session_id = (session_id.to_s.empty? ? latest_session_id : session_id).to_s

      if nearest && similarity >= config["duplicate"]
        update_state do |state|
          table = state["reinforcements"].is_a?(Hash) ? state["reinforcements"] : {}
          entry = table[nearest["id"]].is_a?(Hash) ? table[nearest["id"]] : { "count" => 0 }
          table = table.merge(nearest["id"] => { "count" => entry["count"].to_i + 1, "last" => now.iso8601 })
          state.merge("reinforcements" => table)
        end
        log("brain.remembered", "outcome" => "reinforced", "id" => nearest["id"], "category" => category)
        return { "outcome" => "reinforced", "id" => nearest["id"], "related_to" => nil, "similarity" => similarity.round(3) }
      end

      allowed = false
      update_state do |state|
        if bucket_count(state, "findings", now) >= config["per_hour"] || day_count(state, now) >= config["per_day"]
          state
        else
          allowed = true
          spend(state, "findings", now)
        end
      end
      unless allowed
        log("brain.remembered", "outcome" => "held", "category" => category)
        return { "outcome" => "held", "id" => nil, "related_to" => nil, "similarity" => similarity.round(3) }
      end

      source = ground(session_id, evidence, now)
      record = {
        "category" => category, "claim" => claim, "evidence" => evidence, "source_id" => source["id"],
        "source_digest" => source["digest"], "salience" => HIGH_SALIENCE.include?(category) ? 0.7 : 0.5,
        "at" => now.iso8601, "student_id" => student_id, "session_id" => session_id
      }
      record["supersedes"] = old["id"] if old
      raise Reach::Refused, Reach::Messages.text("M-BRAIN-BAD-SIZE", limit: config["max_record_bytes"]) if JSON.generate(record).bytesize > config["max_record_bytes"]

      Reach::BrainSpool.append_op(op: "finding", kind: "finding", id: id, record: record)
      Reach::BrainSpool.append_op(op: "tombstone", kind: "finding", id: old["id"], record: { "reason" => "superseded by #{id}" }) if old
      unless session_id.empty?
        update_session(session_id) do |fresh|
          fresh.merge("interval" => config["nudge_every_turns"], "saved_since_nudge" => true)
        end
      end
      related = nearest && similarity >= config["related"] ? nearest["id"] : nil
      log("brain.remembered", "outcome" => "saved", "id" => id, "category" => category, "related" => !related.nil?)
      Reach::Corpus.new(Reach.ports).admit_if_due
      { "outcome" => "saved", "id" => id, "related_to" => related, "similarity" => similarity.round(3) }
    end

    def ground(session_id, evidence, now)
      unless session_id.empty?
        last = read_session(session_id)["last_source"]
        return last if last.is_a?(Hash) && last["id"] && (now.to_i - last["at"].to_i) <= GROUND_WINDOW_S
      end
      text = cut_text(evidence)
      digest = Digest::SHA256.hexdigest(text)
      path = "notes/#{now.strftime('%Y-%m-%d')}/#{SecureRandom.uuid}.private.md"
      id = source_id(path, digest)
      record = {
        "text" => text, "path" => path, "source_digest" => digest, "title" => "note",
        "session_id" => session_id.to_s, "space" => nil, "at" => now.iso8601, "student_id" => student_id
      }
      Reach::BrainSpool.append_op(op: "source", kind: "source", id: id, record: record)
      { "id" => id, "digest" => digest }
    end

    def outcome_message(result)
      case result["outcome"]
      when "saved"
        Reach::Messages.text("M-BRAIN-SAVED", id: result["id"])
      when "reinforced"
        Reach::Messages.text("M-BRAIN-DUPLICATE", id: result["id"])
      else
        Reach::Messages.text("M-BRAIN-HELD")
      end
    end

    def forget(ids: nil, all: false)
      index = load_index
      targets = if all
                  index.findings
                else
                  Array(ids).map do |id|
                    index.find_finding(id.to_s) || raise(Reach::Refused, Reach::Messages.text("M-BRAIN-NOT-FOUND", id: id))
                  end.uniq
                end
      doomed = targets.map { |row| row["id"] }
      doomed.each do |id|
        Reach::BrainSpool.append_op(op: "tombstone", kind: "finding", id: id, record: { "reason" => "forgotten" })
      end
      Reach::Corpus.new(Reach.ports).admit_if_due(force: true)
      scrub = doomed.dup
      if all
        scrub.concat(index.sources.map { |row| row["id"] })
        index.findings.each { |row| scrub.concat(index.lineage(row)) }
      else
        remaining = index.findings.reject { |row| doomed.include?(row["id"]) }.map { |row| row["s"] }
        targets.each do |row|
          chain = [row] + index.lineage(row).map { |id| index.history_row(id) }.compact
          scrub.concat(index.lineage(row))
          chain.each do |link|
            source = index.source_for(link["s"])
            scrub << source["id"] if source && source["p"].to_s.start_with?("notes/") && !remaining.include?(source["id"])
          end
        end
      end
      scrub = scrub.uniq
      removed = Reach::BrainSpool.scrub!(scrub)
      update_state do |state|
        table = state["reinforcements"].is_a?(Hash) ? state["reinforcements"] : {}
        table = table.reject { |id, _| doomed.include?(id) }
        state = state.merge("reinforcements" => table, "spool_checked_at" => 0)
        state = state.merge("digests" => []) if all
        state
      end
      clear_sessions(scrub)
      load_index
      log("brain.forgotten", "findings" => doomed.length, "lines" => removed, "all" => all)
      doomed.length
    end

    def clear_sessions(source_ids)
      return unless File.directory?(sessions_dir)

      Dir.children(sessions_dir).select { |name| name.end_with?(".json") }.each do |name|
        session = File.basename(name, ".json")
        update_session(session) do |fresh|
          last = fresh["last_source"]
          fresh.delete("last_source") if last.is_a?(Hash) && source_ids.include?(last["id"])
          fresh
        end
      end
    end

    def public_row(index, row)
      {
        "id" => row["id"], "category" => row["c"], "claim" => row["m"], "at" => row["a"],
        "salience" => index.effective_salience(row).round(3)
      }
    end

    def ordered(index)
      rank = CATEGORIES.each_with_index.each_with_object({}) { |(name, position), memo| memo[name] = position }
      index.findings.sort_by do |row|
        stamp = begin
          Time.iso8601(row["a"].to_s).to_f
        rescue ArgumentError
          0.0
        end
        [rank.fetch(row["c"], CATEGORIES.length), -index.effective_salience(row), -stamp, row["id"]]
      end
    end

    def list(category: nil, limit: 50)
      index = load_index
      rows = ordered(index)
      rows = rows.select { |row| row["c"] == category.to_s } if category && !category.to_s.empty?
      rows.first(limit.to_i.positive? ? limit.to_i : 50).map { |row| public_row(index, row) }
    end

    def show(id)
      index = load_index
      row = index.find_finding(id.to_s)
      raise Reach::Refused, Reach::Messages.text("M-BRAIN-NOT-FOUND", id: id) unless row

      public_row(index, row).merge(
        "evidence" => row["e"], "source_id" => row["s"], "supersedes" => row["u"],
        "reinforced" => index.reinforcement(row["id"])["count"].to_i
      )
    end

    def export
      index = load_index
      rows = ordered(index).map do |row|
        show_row = public_row(index, row)
        show_row.merge("evidence" => row["e"], "source_id" => row["s"], "supersedes" => row["u"])
      end
      JSON.pretty_generate("findings" => rows)
    end

    def profile_lines(index, budget)
      used = 0
      lines = []
      ordered(index).each do |row|
        line = "- [#{row['c']}] #{row['m']}"
        break if used + line.bytesize > budget

        used += line.bytesize + 1
        lines << line
      end
      lines
    end

    def profile_block
      index = load_index
      return nil if index.findings.empty?

      lines = profile_lines(index, settings["session_budget_bytes"])
      return nil if lines.empty?

      "#{Reach::Messages.text('M-BRAIN-PROFILE')}\n#{lines.join("\n")}"
    end

    def session_context
      return nil unless enabled?

      parts = [Reach::Messages.text("M-BRAIN-CONTEXT")]
      block = profile_block
      parts << block if block
      parts.join("\n\n")
    rescue StandardError => e
      log("brain.failed", "op" => "session_context", "error" => e.class.name)
      nil
    end

    def recall(query:, k: nil, exclude: [], lexical_only: false)
      config = settings
      limit = k.to_i.positive? ? k.to_i : config["prompt_k"]
      rendered = lexical_only ? nil : recall_via_context(query, limit, config)
      return rendered if rendered

      index = load_index
      hits = index.search(query, k: limit + exclude.length).select { |row| row["share"] >= config["prompt_min_score"] && !exclude.include?(row["id"]) }.first(limit)
      used = 0
      lines = []
      chosen = []
      hits.each do |row|
        line = "- [#{row['c']}] #{row['m']}"
        break if used + line.bytesize > config["prompt_budget_bytes"]

        used += line.bytesize + 1
        lines << line
        chosen << row["id"]
      end
      return nil if lines.empty?

      { "text" => "#{Reach::Messages.text('M-BRAIN-RECALL')}\n#{lines.join("\n")}", "ids" => chosen, "hits" => chosen.length, "bytes" => used, "mode" => "index" }
    end

    def recall_via_context(query, limit, config)
      ports = Reach.ports
      return nil unless ports && defined?(Rcorpus::Context)

      corpus = ports.corpus.open("reach")
      return nil unless corpus

      out = Rcorpus::Context.new(corpus).render(query: query, k: limit, budget_bytes: config["prompt_budget_bytes"], kinds: ["finding"])
      body = out.is_a?(Hash) ? out["text"] : out
      body = body.to_s.strip
      return nil if body.empty?

      { "text" => "#{Reach::Messages.text('M-BRAIN-RECALL')}\n#{body}", "ids" => [], "hits" => body.lines.length, "bytes" => body.bytesize, "mode" => "context" }
    rescue StandardError => e
      log("brain.failed", "op" => "context", "error" => e.class.name)
      nil
    end

    def prompt_context(session_id:, prompt:)
      return nil unless enabled?

      parts = []
      session = read_session(session_id)
      recent = Array(session["injected"]).flatten
      found = nil
      if prompt.to_s.gsub(/\s+/, "").length >= MIN_PROMPT_CHARS
        found = recall(query: prompt.to_s, exclude: recent, lexical_only: true)
        parts << found["text"] if found
      end
      nudge = session["nudge_pending"] == true
      parts << Reach::Messages.text("M-BRAIN-DISTILL") if nudge
      if found || nudge
        update_session(session_id) do |fresh|
          fresh["injected"] = (Array(fresh["injected"]) + [found ? found["ids"] : []]).last(INJECT_KEEP)
          if nudge
            fresh["nudge_pending"] = false
            fresh["nudged"] = true
          end
          fresh
        end
      end
      log("brain.recalled", "mode" => found["mode"], "hits" => found["hits"], "bytes" => found["bytes"]) if found
      log("brain.nudged", "session_id" => session_id.to_s) if nudge
      parts.empty? ? nil : parts.join("\n\n")
    rescue StandardError => e
      log("brain.failed", "op" => "prompt_context", "error" => e.class.name)
      nil
    end

    def memory_notice_due?
      return false unless enabled?

      read_state["memory_notice"] != true
    rescue StandardError
      false
    end

    def memory_notice_shown!
      update_state { |state| state.merge("memory_notice" => true) }
      nil
    rescue StandardError
      nil
    end
  end
end
