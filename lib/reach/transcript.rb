require "fileutils"
require "json"
require "time"
require "find"

module Reach
  module Transcript
    ROUTE = "/api/v1/transcripts"
    MAX_TEXT_BYTES = 131_072
    MAX_BATCH_ENTRIES = 200
    MAX_BATCH_BYTES = 900_000
    SCAN_MAX_FILES = 2000
    SCAN_LARGE_BYTES = 1_048_576
    SCAN_SKIP_DIRS = %w[.git node_modules vendor .bundle tmp .claude .codex].freeze
    SCAN_SKIP_ROOT_FILES = %w[.reach-space.json AGENTS.md CLAUDE.md GEMINI.md .mcp.json].freeze
    QUICK_MAX_REQUESTS = 3
    FULL_MAX_REQUESTS = 50
    QUICK_MIN_INTERVAL_S = 60
    SESSION_ID_PATTERN = /\A[A-Za-z0-9._:-]{1,128}\z/
    HARNESSES = %w[claude-code codex hermes unknown].freeze
    HERMES_WRITE_TOOLS = %w[write_file patch].freeze
    SLICES = %w[backend panel verification].freeze
    KINDS = %w[prompt reply reasoning action code].freeze
    DEFAULT_SUPPORTED_KINDS = %w[prompt].freeze
    KIND_FIELDS = {
      "prompt" => %w[text bytes truncated digest gate note],
      "reply" => %w[text bytes truncated digest note],
      "reasoning" => %w[text bytes truncated digest note],
      "action" => %w[tool summary note],
      "code" => %w[category scope path origin deleted binary text bytes truncated digest note reply_seq]
    }.freeze
    CODE_EXT = {
      "ruby" => "rb", "rb" => "rb", "python" => "py", "py" => "py", "javascript" => "js", "js" => "js",
      "typescript" => "ts", "ts" => "ts", "svelte" => "svelte", "html" => "html", "css" => "css",
      "json" => "json", "yaml" => "yml", "yml" => "yml", "bash" => "sh", "sh" => "sh", "shell" => "sh",
      "sql" => "sql", "erb" => "erb", "markdown" => "md", "md" => "md"
    }.freeze
    CODE_FENCE_OPEN = /\A([ \t]*)(`{3,}|~{3,})([A-Za-z0-9_+-]*)\s*\z/

    module_function

    def capture(event, harness:, gate:, note: nil)
      return nil unless Reach::Enroll.current
      return nil if Reach::Enroll.revoked?

      session_id = resolve_session_id(event)
      space = safe_space_kind
      if space && event.is_a?(Hash) && event["transcript_path"]
        Reach::TranscriptIngest.ingest(session_id: session_id, transcript_path: event["transcript_path"], harness: harness, space: space)
      end
      workspace = safe_current_workspace
      meta = workspace ? safe_metadata(workspace) : {}
      cutout_id = meta && meta["cutout_id"]
      slice = meta && meta["slice"]
      slice = nil unless SLICES.include?(slice)

      record(
        session_id,
        kind: "prompt",
        harness: harness,
        cutout_id: cutout_id,
        slice: slice,
        space: space,
        fields: note ? prompt_fields(event, gate: gate).merge("note" => note) : prompt_fields(event, gate: gate)
      )
    rescue StandardError => e
      log_transcript_event("capture_failed", "error" => e.class.name, "session_id" => session_id)
      nil
    end

    def prompt_fields(event, gate:)
      prompt = event.is_a?(Hash) ? event["prompt"] : nil
      if prompt.is_a?(String)
        scrubbed = prompt.dup.force_encoding("UTF-8").scrub("�")
        bytes = scrubbed.bytesize
        if bytes <= MAX_TEXT_BYTES
          text = scrubbed
          truncated = false
        else
          text = truncate_to_bytes(scrubbed, MAX_TEXT_BYTES)
          truncated = true
        end
        { "text" => text, "bytes" => bytes, "truncated" => truncated, "digest" => Reach::Crypto.digest_hex(scrubbed), "gate" => gate, "note" => nil }
      else
        { "text" => nil, "bytes" => 0, "truncated" => false, "digest" => nil, "gate" => gate, "note" => "no prompt in the hook payload" }
      end
    end

    def record(session_id, kind:, harness:, cutout_id: nil, slice: nil, space: nil, at: nil, fields: {})
      record_batch(session_id, [{ "kind" => kind.to_s, "harness" => harness.to_s, "cutout_id" => cutout_id, "slice" => slice, "space" => space, "at" => at }.merge(fields)]).first
    end

    def code(event: {}, harness: nil)
      return nil unless Reach::Enroll.current
      return nil if Reach::Enroll.revoked?

      session_id = resolve_session_id(event)
      resolved_harness = resolve_harness(harness)
      space = safe_space_kind
      return nil unless space

      Reach::TranscriptIngest.ingest(session_id: session_id, transcript_path: event["transcript_path"], harness: resolved_harness, space: space)

      workspace = space == "slice" ? safe_current_workspace : nil
      base = space_base(space, workspace)
      return nil unless base

      base_real = File.expand_path(base)
      meta = workspace ? safe_metadata(workspace) : {}
      cutout_id = meta["cutout_id"]
      slice = meta["slice"]
      assignment = meta["assignment"]

      if resolved_harness == "hermes"
        Reach::TranscriptIngest.record_action(
          session_id, event["tool_name"], event["tool_input"], false,
          harness: resolved_harness, cutout_id: cutout_id, slice: slice, space: space,
          at: Reach::TranscriptIngest.normalized_at(nil), base: base_real
        )
        return nil unless HERMES_WRITE_TOOLS.include?(event["tool_name"])
      end
      return nil unless space == "slice"

      written_paths(event).each do |absolute|
        next if File.symlink?(absolute)
        next unless path_allowed?(absolute, space, workspace, base_real)

        relative = relative_under(absolute, base_real)
        next if relative.nil? || relative.empty?

        fields = file_fields(absolute)
        entry_fields = fields.merge(
          "category" => space == "slice" ? "assignment" : "extracurricular",
          "scope" => space == "slice" ? { "assignment" => assignment, "cutout_id" => cutout_id, "slice" => slice } : nil,
          "path" => relative,
          "origin" => "ai_write",
          "reply_seq" => nil
        )
        record(session_id, kind: "code", harness: resolved_harness, cutout_id: cutout_id, slice: slice, space: space, fields: entry_fields)
        update_space_digest(base_real, relative, fields["digest"], size: safe_size(absolute), mtime: safe_mtime(absolute))
      end
      nil
    rescue StandardError => e
      log_transcript_event("code_failed", "error" => e.class.name)
      nil
    end

    def turn(event: {}, harness: nil, quick: false, final: false)
      begin
        if Reach::Enroll.current && !safe_revoked?
          session_id = resolve_session_id(event)
          resolved_harness = resolve_harness(harness)
          space = safe_space_kind
          if space
            record_hermes_reply(session_id, event, space) if resolved_harness == "hermes" && !final
            Reach::TranscriptIngest.ingest(session_id: session_id, transcript_path: event["transcript_path"], harness: resolved_harness, space: space)
            scan_space(session_id, resolved_harness, space)
          end
        end
      rescue StandardError => e
        log_transcript_event("turn_failed", "error" => e.class.name)
      end
      flush(quick: quick, final: final)
      nil
    end

    def record_hermes_reply(session_id, event, space)
      reply = event["assistant_response"]
      return nil unless reply.is_a?(String) && !reply.strip.empty?

      workspace = space == "slice" ? safe_current_workspace : nil
      meta = workspace ? safe_metadata(workspace) : {}
      cutout_id = meta["cutout_id"]
      slice = meta["slice"]
      category, scope, category_root = Reach::TranscriptIngest.category_info(space, meta["assignment"], cutout_id, slice, workspace)
      record_reply_with_code(
        session_id, harness: "hermes", cutout_id: cutout_id, slice: slice, space: space,
        at: Reach::TranscriptIngest.normalized_at(nil), raw_text: reply,
        category: category, scope: scope, category_root: category_root
      )
    rescue StandardError => e
      log_transcript_event("reply_failed", "error" => e.class.name)
      nil
    end

    def scan_space(session_id, harness, space)
      return unless space == "slice"

      workspace = space == "slice" ? safe_current_workspace : nil
      base = space_base(space, workspace)
      return unless base && Dir.exist?(base)

      base_real = File.expand_path(base)
      meta = workspace ? safe_metadata(workspace) : {}
      cutout_id = meta["cutout_id"]
      slice = meta["slice"]
      assignment = meta["assignment"]

      files = space == "slice" ? owned_files_absolute(workspace) : extracurricular_files(base_real)
      files = files.first(SCAN_MAX_FILES)

      digest_path = space_digest_path(base_real)
      previous = parse_json_file(digest_path) || {}
      current = {}

      files.each do |absolute|
        next if File.symlink?(absolute)

        relative = relative_under(absolute, base_real)
        next if relative.nil? || relative.empty?

        prior = previous[relative]
        size = safe_size(absolute)
        mtime = safe_mtime(absolute)

        if prior.is_a?(Hash) && size && mtime && prior["size"] == size && prior["mtime"] == mtime
          current[relative] = prior
          next
        end

        fields = file_fields(absolute, large_limit: SCAN_LARGE_BYTES)
        current[relative] = { "digest" => fields["digest"], "size" => size, "mtime" => mtime }
        prior_digest = prior.is_a?(Hash) ? prior["digest"] : prior
        next if prior_digest && prior_digest == fields["digest"]

        entry_fields = fields.merge(
          "category" => space == "slice" ? "assignment" : "extracurricular",
          "scope" => space == "slice" ? { "assignment" => assignment, "cutout_id" => cutout_id, "slice" => slice } : nil,
          "path" => relative,
          "origin" => "scan",
          "reply_seq" => nil
        )
        record(session_id, kind: "code", harness: harness, cutout_id: cutout_id, slice: slice, space: space, fields: entry_fields)
      end

      (previous.keys - current.keys).each do |relative|
        entry_fields = {
          "category" => space == "slice" ? "assignment" : "extracurricular",
          "scope" => space == "slice" ? { "assignment" => assignment, "cutout_id" => cutout_id, "slice" => slice } : nil,
          "path" => relative, "origin" => "scan", "deleted" => true, "binary" => false,
          "text" => nil, "bytes" => 0, "truncated" => false, "digest" => nil, "note" => nil, "reply_seq" => nil
        }
        record(session_id, kind: "code", harness: harness, cutout_id: cutout_id, slice: slice, space: space, fields: entry_fields)
      end

      FileUtils.mkdir_p(File.dirname(digest_path))
      File.write(digest_path, JSON.generate(current))
    rescue StandardError
      nil
    end

    def space_base(space, workspace)
      case space
      when "slice"
        workspace
      when "extracurricular"
        Reach::Paths.extracurricular_root
      end
    end

    def owned_files_absolute(workspace)
      Reach::Workspace.owned_files(workspace).map { |rel| File.expand_path(File.join(workspace, rel)) }.select { |path| File.file?(path) }
    end

    def extracurricular_files(base_real)
      found = []
      Find.find(base_real) do |path|
        relative = relative_under(path, base_real)
        next if relative.nil? || relative.empty?

        if File.symlink?(path)
          Find.prune if File.directory?(path)
          next
        end

        if File.directory?(path)
          Find.prune if SCAN_SKIP_DIRS.include?(File.basename(path)) || relative == "materials"
          next
        end

        next if SCAN_SKIP_ROOT_FILES.include?(relative)

        found << path
      end
      found
    end

    def relative_under(absolute, base_real)
      return "" if absolute == base_real
      return nil unless absolute.start_with?("#{base_real}#{File::SEPARATOR}")

      absolute.sub("#{base_real}#{File::SEPARATOR}", "")
    end

    def space_digest_path(base_real)
      File.join(Reach::Paths.transcript_spaces_dir, "#{Reach::Crypto.digest_hex(base_real)}.json")
    end

    def update_space_digest(base_real, relative, digest, size: nil, mtime: nil)
      path = space_digest_path(base_real)
      data = parse_json_file(path) || {}
      data[relative] = { "digest" => digest, "size" => size, "mtime" => mtime }
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(data))
    rescue StandardError
      nil
    end

    def safe_size(path)
      File.size(path)
    rescue StandardError
      nil
    end

    def safe_mtime(path)
      File.mtime(path).to_f
    rescue StandardError
      nil
    end

    def written_paths(event)
      tool_input = event["tool_input"] || {}
      tool_name = event["tool_name"]
      command_text = tool_input["command"]
      if tool_name == "apply_patch" || command_text.to_s.start_with?("*** Begin Patch") || (tool_name == "patch" && tool_input["mode"] == "patch")
        patch_text = tool_input["patch"] || command_text
        Reach::Gate.patch_targets(patch_text).map { |relative| File.expand_path(relative) }
      else
        [tool_input["file_path"], tool_input["notebook_path"], tool_input["path"]].compact.map { |p| File.expand_path(p) }
      end
    end

    def path_allowed?(absolute, space, workspace, base_real)
      case space
      when "slice"
        return false unless workspace

        Reach::Workspace.owned_files(workspace).any? { |rel| File.expand_path(File.join(workspace, rel)) == absolute }
      when "extracurricular"
        real_absolute = File.exist?(absolute) ? File.realpath(absolute) : absolute
        real_base = File.exist?(base_real) ? File.realpath(base_real) : base_real
        real_absolute == real_base || real_absolute.start_with?("#{real_base}#{File::SEPARATOR}")
      else
        false
      end
    end

    def file_fields(absolute_path, large_limit: nil)
      unless File.file?(absolute_path)
        return { "deleted" => true, "binary" => false, "text" => nil, "bytes" => 0, "truncated" => false, "digest" => nil, "note" => nil }
      end

      bytes_total = File.size(absolute_path)
      if large_limit && bytes_total > large_limit
        digest = Reach::Crypto.digest_hex(File.binread(absolute_path))
        return { "deleted" => false, "binary" => false, "text" => nil, "bytes" => bytes_total, "truncated" => false, "digest" => digest, "note" => "too large" }
      end

      head = bytes_total.zero? ? "".b : File.binread(absolute_path, [bytes_total, 8192].min)
      if head.to_s.b.include?("\x00")
        digest = Reach::Crypto.digest_hex(File.binread(absolute_path))
        return { "deleted" => false, "binary" => true, "text" => nil, "bytes" => bytes_total, "truncated" => false, "digest" => digest, "note" => nil }
      end

      raw = File.binread(absolute_path)
      content = raw.dup.force_encoding("UTF-8").scrub("�")
      digest = Reach::Crypto.digest_hex(content)
      bytes = content.bytesize
      if bytes > MAX_TEXT_BYTES
        { "deleted" => false, "binary" => false, "text" => truncate_to_bytes(content, MAX_TEXT_BYTES), "bytes" => bytes, "truncated" => true, "digest" => digest, "note" => nil }
      else
        { "deleted" => false, "binary" => false, "text" => content, "bytes" => bytes, "truncated" => false, "digest" => digest, "note" => nil }
      end
    end

    def record_batch(session_id, drafts)
      return [] if drafts.empty?

      ensure_transcripts_dir!
      entries = []
      File.open(entries_path(session_id), File::RDWR | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        state = read_state(session_id)
        seq = state["last_seq"].to_i
        drafts.each do |draft|
          seq += 1
          entry = { "seq" => seq, "session_id" => session_id, "student_id" => enrolled_student_id }.merge(draft)
          entry["at"] ||= Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          entries << entry
          file.write(JSON.generate(entry) + "\n")
        end
        file.flush
        write_state(session_id, state.merge("last_seq" => seq, "updated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")))
      end
      entries
    end

    def record_reply_with_code(session_id, harness:, cutout_id:, slice:, space:, at:, raw_text:, category:, scope:, category_root:)
      ensure_transcripts_dir!
      entries = []
      File.open(entries_path(session_id), File::RDWR | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        state = read_state(session_id)
        seq = state["last_seq"].to_i
        reply_seq = seq + 1

        plain_text, blocks = split_reply(raw_text, reply_seq: reply_seq, category_root: category_root)
        reply_entry = {
          "seq" => reply_seq, "session_id" => session_id, "at" => at, "harness" => harness.to_s,
          "cutout_id" => cutout_id, "slice" => slice, "space" => space, "kind" => "reply",
          "student_id" => enrolled_student_id
        }.merge(text_fields(plain_text))
        file.write(JSON.generate(reply_entry) + "\n")
        entries << reply_entry
        seq = reply_seq

        blocks.each do |block|
          seq += 1
          code_entry = {
            "seq" => seq, "session_id" => session_id, "at" => at, "harness" => harness.to_s,
            "cutout_id" => cutout_id, "slice" => slice, "space" => space, "kind" => "code",
            "category" => category, "scope" => scope, "path" => block["path"], "origin" => "chat_snippet",
            "deleted" => false, "binary" => false, "reply_seq" => reply_seq, "student_id" => enrolled_student_id
          }.merge(code_text_fields(block["text"]))
          file.write(JSON.generate(code_entry) + "\n")
          entries << code_entry
        end

        file.flush
        write_state(session_id, state.merge("last_seq" => seq, "updated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")))
      end
      entries
    end

    def text_fields(text)
      if text.nil?
        { "text" => nil, "bytes" => 0, "truncated" => false, "digest" => nil, "note" => "reasoning not readable" }
      else
        scrubbed = text.dup.force_encoding("UTF-8").scrub("�")
        bytes = scrubbed.bytesize
        if bytes <= MAX_TEXT_BYTES
          { "text" => scrubbed, "bytes" => bytes, "truncated" => false, "digest" => Reach::Crypto.digest_hex(scrubbed), "note" => nil }
        else
          { "text" => truncate_to_bytes(scrubbed, MAX_TEXT_BYTES), "bytes" => bytes, "truncated" => true, "digest" => Reach::Crypto.digest_hex(scrubbed), "note" => nil }
        end
      end
    end

    def code_text_fields(text)
      scrubbed = text.to_s.dup.force_encoding("UTF-8").scrub("�")
      bytes = scrubbed.bytesize
      if bytes <= MAX_TEXT_BYTES
        { "text" => scrubbed, "bytes" => bytes, "truncated" => false, "digest" => Reach::Crypto.digest_hex(scrubbed), "note" => nil }
      else
        { "text" => truncate_to_bytes(scrubbed, MAX_TEXT_BYTES), "bytes" => bytes, "truncated" => true, "digest" => Reach::Crypto.digest_hex(scrubbed), "note" => nil }
      end
    end

    def split_reply(raw_text, reply_seq:, category_root:)
      return [raw_text, []] if raw_text.nil?

      lines = raw_text.to_s.lines
      out = []
      blocks = []
      i = 0
      n = 0
      while i < lines.length
        line = lines[i]
        match = CODE_FENCE_OPEN.match(line.chomp)
        if match
          indent = match[1]
          fence_char = match[2][0]
          lang = match[3].to_s
          body = []
          i += 1
          while i < lines.length
            candidate = lines[i]
            if candidate.chomp.match?(/\A[ \t]*#{Regexp.escape(fence_char)}{3,}\s*\z/)
              i += 1
              break
            end
            body << (indent.empty? ? candidate : candidate.sub(/\A[ \t]{0,#{indent.length}}/, ""))
            i += 1
          end
          n += 1
          ext = CODE_EXT[lang.downcase] || "txt"
          path = "snippets/#{format('%04d', reply_seq)}-#{n}.#{ext}"
          out << "#{indent}[code #{reply_seq}.#{n} -> #{category_root}/#{path}]\n"
          blocks << { "path" => path, "text" => body.join }
        else
          out << line
          i += 1
        end
      end
      [out.join, blocks]
    end

    def flush(quick: false, final: false)
      install = begin
        Reach::Enroll.current
      rescue StandardError
        nil
      end
      return stopped_result("not_enrolled", quick) unless install
      return stopped_result("revoked", quick) if safe_revoked?
      return stopped_result("offline", quick) if ENV["REACH_OFFLINE"] == "1"

      FileUtils.mkdir_p(Reach::Paths.state_dir)
      result = nil
      File.open(Reach::Paths.flush_lock_file, File::RDWR | File::CREAT, 0o600) do |lock_file|
        unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
          result = stopped_result("busy", quick)
          next
        end

        begin
          if quick && !final && too_soon?
            result = stopped_result("too_soon", quick)
            next
          end

          write_flush_state("last_attempt_at" => Time.now.utc.to_f)
          result = run_flush(install, quick: quick)
        ensure
          lock_file.flock(File::LOCK_UN)
        end
      end
      result
    rescue StandardError => e
      log_transcript_event("flush_failed", "error" => e.class.name)
      { "sent" => 0, "requests" => 0, "stopped" => "error" }
    end

    def stopped_result(reason, quick)
      result = { "sent" => 0, "requests" => 0, "stopped" => reason }
      log_transcript_event("flush", "quick" => quick, "sent" => 0, "requests" => 0, "stopped" => reason)
      result
    end

    def supported_kinds
      status = Reach::Sync.cached_status
      kinds = status && status["transcripts"] && status["transcripts"]["kinds"]
      kinds.is_a?(Array) && !kinds.empty? ? kinds.map(&:to_s) : DEFAULT_SUPPORTED_KINDS
    rescue StandardError
      DEFAULT_SUPPORTED_KINDS
    end

    def split_supported_prefix(entries, supported)
      prefix = []
      entries.each do |entry|
        break unless supported.include?(entry["kind"].to_s)

        prefix << entry
      end
      [prefix, entries.length - prefix.length]
    end

    def counts
      dir = Reach::Paths.transcripts_dir
      return { "sent" => 0, "waiting" => 0, "held" => 0 } unless Dir.exist?(dir)

      sent = 0
      waiting = 0
      held = 0
      supported = supported_kinds
      Dir.glob(File.join(dir, "*.state.json")).each do |path|
        state = parse_json_file(path)
        next unless state

        session_id = File.basename(path, ".state.json")
        acked = state["acked_seq"].to_i
        last = state["last_seq"].to_i
        sent += acked
        remaining_count = [last - acked, 0].max
        waiting += remaining_count
        next if remaining_count.zero?

        remaining = read_entries_after(session_id, acked)
        _prefix, held_count = split_supported_prefix(remaining, supported)
        held += held_count
      end
      { "sent" => sent, "waiting" => waiting, "held" => held }
    rescue StandardError
      { "sent" => 0, "waiting" => 0, "held" => 0 }
    end

    def entries_label(count)
      count.to_i == 1 ? "1 entry" : "#{count.to_i} entries"
    end

    def resolve_session_id(event)
      raw = event.is_a?(Hash) ? event["session_id"].to_s : ""
      cleaned = raw.gsub(/[^A-Za-z0-9._:-]/, "_")[0, 128]
      cleaned.empty? ? "unknown-#{Time.now.utc.strftime('%Y%m%d')}" : cleaned
    end

    def resolve_harness(flag)
      return flag if flag && HARNESSES.include?(flag)
      return "claude-code" if ENV["CLAUDE_PROJECT_DIR"].to_s != ""

      "unknown"
    end

    def truncate_to_bytes(text, max_bytes)
      text.byteslice(0, max_bytes).scrub("")
    end

    def enrolled_student_id
      install = Reach::Enroll.current
      install && install["student_id"]
    rescue StandardError
      nil
    end

    def safe_current_workspace
      Reach::Gate.current_workspace_path
    rescue StandardError
      nil
    end

    def safe_space_kind
      space = Reach::Gate.current_space
      space && space["kind"]
    rescue StandardError
      nil
    end

    def safe_metadata(workspace)
      Reach::Workspace.metadata(workspace)
    rescue StandardError
      {}
    end

    def safe_revoked?
      Reach::Enroll.revoked?
    rescue StandardError
      false
    end

    def ensure_transcripts_dir!
      FileUtils.mkdir_p(Reach::Paths.transcripts_dir)
      File.chmod(0o700, Reach::Paths.transcripts_dir)
    rescue NotImplementedError, Errno::ENOENT
      nil
    end

    def state_path(session_id)
      File.join(Reach::Paths.transcripts_dir, "#{session_id}.state.json")
    end

    def rejected_path(session_id)
      File.join(Reach::Paths.transcripts_dir, "#{session_id}.rejected.jsonl")
    end

    def entries_path(session_id)
      File.join(Reach::Paths.transcripts_dir, "#{session_id}.jsonl")
    end

    def read_state(session_id)
      path = state_path(session_id)
      parsed = File.file?(path) ? parse_json_file(path) : nil
      parsed || { "last_seq" => 0, "acked_seq" => 0, "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
    end

    def write_state(session_id, state)
      path = state_path(session_id)
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(state)) }
      File.rename(tmp, path)
    end

    def update_state(session_id)
      ensure_transcripts_dir!
      updated = nil
      File.open(entries_path(session_id), File::RDWR | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        fresh = read_state(session_id)
        updated = yield(fresh)
        write_state(session_id, updated)
      end
      updated
    end

    def update_acked(session_id, acked_seq)
      File.open(entries_path(session_id), File::RDWR | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        state = read_state(session_id)
        acked = [[state["acked_seq"].to_i, acked_seq.to_i].max, state["last_seq"].to_i].min
        write_state(session_id, state.merge("acked_seq" => acked))
      end
    end

    def parse_json_file(path)
      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end

    def too_soon?
      state = parse_json_file(Reach::Paths.flush_state_file)
      return false unless state && state["last_attempt_at"]

      (Time.now.utc.to_f - state["last_attempt_at"].to_f) < QUICK_MIN_INTERVAL_S
    end

    def write_flush_state(fields)
      state = parse_json_file(Reach::Paths.flush_state_file) || {}
      File.write(Reach::Paths.flush_state_file, JSON.generate(state.merge(fields)))
      begin
        File.chmod(0o600, Reach::Paths.flush_state_file)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
    end

    def run_flush(install, quick:)
      sent = 0
      requests = 0
      stopped = nil
      max_requests = quick ? QUICK_MAX_REQUESTS : FULL_MAX_REQUESTS
      supported = supported_kinds

      pending_sessions(quick).each do |session_id|
        break if stopped

        state = read_state(session_id)
        acked = state["acked_seq"].to_i
        last = state["last_seq"].to_i
        next if acked >= last

        remaining = read_entries_after(session_id, acked)
        next if remaining.empty?

        sendable, held_count = split_supported_prefix(remaining, supported)
        log_transcript_event("unsupported_kind", "session_id" => session_id) if held_count.positive?
        next if sendable.empty?

        batches(session_id, sendable).each do |batch|
          if requests >= max_requests
            stopped = "request_budget"
            break
          end

          requests += 1
          outcome = send_batch(install, session_id: session_id, batch: batch, quick: quick)
          case outcome[:result]
          when :sent
            update_acked(session_id, [outcome[:last_seq].to_i, batch.last["seq"]].min)
            sent += batch.size
          when :rejected
            append_rejected(session_id, batch, outcome[:code])
            update_acked(session_id, batch.last["seq"])
          when :revoked
            Reach::Enroll.mark_revoked!
            stopped = outcome[:code]
          when :stop
            stopped = outcome[:code]
          end
          break if stopped
        end
      end

      log_transcript_event("flush", "quick" => quick, "sent" => sent, "requests" => requests, "stopped" => stopped)
      { "sent" => sent, "requests" => requests, "stopped" => stopped }
    end

    def pending_sessions(_quick)
      dir = Reach::Paths.transcripts_dir
      return [] unless Dir.exist?(dir)

      candidates = Dir.glob(File.join(dir, "*.state.json")).map do |path|
        session_id = File.basename(path, ".state.json")
        state = parse_json_file(path)
        next nil unless state && state["acked_seq"].to_i < state["last_seq"].to_i

        [session_id, state["created_at"].to_s]
      end.compact

      candidates.sort_by { |session_id, created_at| [created_at, session_id] }.map(&:first)
    end

    def read_entries_after(session_id, acked_seq)
      path = entries_path(session_id)
      return [] unless File.file?(path)

      lines = []
      File.foreach(path) do |line|
        parsed = begin
          JSON.parse(line)
        rescue StandardError
          nil
        end
        next unless parsed
        next unless parsed["seq"].to_i > acked_seq

        lines << parsed
      end
      lines.sort_by { |entry| entry["seq"].to_i }
    end

    def batches(session_id, entries)
      result = []
      current = []
      entries.each do |entry|
        candidate = current + [entry]
        if current.empty?
          current = candidate
          next
        end

        if candidate.length > MAX_BATCH_ENTRIES || batch_bytesize(session_id, candidate) > MAX_BATCH_BYTES
          result << current
          current = [entry]
        else
          current = candidate
        end
      end
      result << current unless current.empty?
      result
    end

    def batch_bytesize(session_id, entries)
      last_entry = entries.last
      harness = wire_harness(last_entry["harness"])
      JSON.generate(batch_body(session_id, harness, last_entry["cutout_id"], last_entry["slice"], entries)).bytesize
    end

    def wire_harness(value)
      harness = HARNESSES.include?(value) ? value : "unknown"
      return harness unless harness == "hermes"

      status = Reach::Sync.cached_status
      status && status["wire_contract_sha256"] == Reach::Wire.digest ? "hermes" : "unknown"
    rescue StandardError
      "unknown"
    end

    def send_batch(install, session_id:, batch:, quick:)
      last_entry = batch.last
      harness = wire_harness(last_entry["harness"])
      body = batch_body(session_id, harness, last_entry["cutout_id"], last_entry["slice"], batch)
      first_seq = batch.first["seq"]
      last_seq = batch.last["seq"]
      key = Reach::Crypto.digest_hex("#{install['install_id']}\n#{session_id}\n#{first_seq}\n#{last_seq}")

      response = Reach::Client.for_install(install, quick: quick).post_json(ROUTE, body, idempotency_key: key)
      json = response.json || {}
      { result: :sent, last_seq: json["last_seq"] }
    rescue Reach::RemoteRefused => e
      handle_remote_refused(e)
    rescue Reach::Offline
      { result: :stop, code: "offline" }
    rescue Reach::NetworkError
      { result: :stop, code: "network" }
    end

    def handle_remote_refused(error)
      if %w[invalid_request too_large].include?(error.code)
        { result: :rejected, code: error.code }
      elsif %w[revoked not_enrolled].include?(error.code)
        { result: :revoked, code: error.code }
      else
        { result: :stop, code: error.code }
      end
    end

    def append_rejected(session_id, batch, code)
      path = rejected_path(session_id)
      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        batch.each do |entry|
          record = entry.merge("rejected" => { "code" => code, "at" => now })
          file.write(JSON.generate(record) + "\n")
        end
      end
      log_transcript_event("flush_rejected", "session_id" => session_id, "code" => code)
    end

    def batch_body(session_id, harness, cutout_id, slice, entries)
      {
        "session_id" => session_id,
        "harness" => harness,
        "cutout_id" => cutout_id,
        "slice" => slice,
        "entries" => entries.map { |entry| wire_entry(entry) }
      }
    end

    def wire_entry(entry)
      kind = entry["kind"].to_s
      fields = KIND_FIELDS[kind] || []
      wire = { "seq" => entry["seq"], "at" => entry["at"], "kind" => kind }
      fields.each { |field| wire[field] = entry[field] }
      wire
    end

    def log_transcript_event(event, fields = {})
      FileUtils.mkdir_p(Reach::Paths.logs_dir)
      record = { "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "event" => event }
      fields.each { |k, v| record[k.to_s] = v }
      File.open(Reach::Paths.transcript_log, File::WRONLY | File::CREAT | File::APPEND, 0o644) do |file|
        file.puts(JSON.generate(record))
      end
    rescue StandardError
      nil
    end
  end
end
