require "json"
require "time"
require "fileutils"

module Reach
  module TranscriptIngest
    MAX_ENTRIES_PER_INGEST = 2000
    SEEN_UUID_LIMIT = 2000

    module_function

    def ingest(session_id:, transcript_path:, harness:, space:)
      return nil if transcript_path.nil? || transcript_path.to_s.empty?

      unless File.file?(transcript_path)
        Reach::Transcript.log_transcript_event("ingest_skipped", "session_id" => session_id)
        return nil
      end

      with_ingest_lock(session_id) do
        perform_ingest(session_id: session_id, transcript_path: transcript_path, harness: harness, space: space)
      end
      nil
    rescue StandardError => e
      Reach::Transcript.log_transcript_event("ingest_failed", "error" => e.class.name, "session_id" => session_id)
      nil
    end

    def with_ingest_lock(session_id)
      FileUtils.mkdir_p(Reach::Paths.transcripts_dir)
      lock_path = File.join(Reach::Paths.transcripts_dir, "#{session_id}.ingest.lock")
      Reach::Locks.exclusive(lock_path) { yield }
    end

    def perform_ingest(session_id:, transcript_path:, harness:, space:)
      state = Reach::Transcript.read_state(session_id)
      offset = state["transcript_path"] == transcript_path ? state["transcript_offset"].to_i : 0
      seen_uuids = Array(state["seen_uuids"])

      if File.size(transcript_path) < offset
        offset = 0
        Reach::Transcript.log_transcript_event("transcript_restarted", "session_id" => session_id)
      end

      workspace = space.to_s == "slice" ? safe_current_workspace : nil
      meta = workspace ? safe_metadata(workspace) : {}
      cutout_id = meta["cutout_id"]
      slice = meta["slice"]
      assignment = meta["assignment"]
      category, scope, category_root = category_info(space, assignment, cutout_id, slice, workspace)
      base = Reach::Transcript.space_base(space.to_s, workspace)

      records = read_line_records(transcript_path, offset)
      running_offset = offset
      processed_total = 0

      records.each do |raw_line, byte_len|
        break if processed_total >= MAX_ENTRIES_PER_INGEST

        parsed = safe_json(raw_line)
        unless parsed
          running_offset += byte_len
          next
        end

        processed = case harness.to_s
                    when "claude-code"
                      ingest_claude_line(session_id, parsed, seen_uuids, harness: harness, cutout_id: cutout_id, slice: slice, space: space, category: category, scope: scope, category_root: category_root, base: base)
                    when "codex"
                      ingest_codex_line(session_id, parsed, harness: harness, cutout_id: cutout_id, slice: slice, space: space, category: category, scope: scope, category_root: category_root, base: base)
                    else
                      0
                    end
        processed_total += processed
        running_offset += byte_len
      end

      seen_uuids = seen_uuids.last(SEEN_UUID_LIMIT)
      Reach::Transcript.merge_state(session_id, "transcript_path" => transcript_path, "transcript_offset" => running_offset, "seen_uuids" => seen_uuids)
      nil
    end

    def read_line_records(path, offset)
      content = File.open(path, "rb") do |file|
        file.seek(offset)
        file.read
      end
      return [] if content.nil? || content.empty?

      records = []
      content.each_line do |raw|
        next unless raw.end_with?("\n")

        records << [raw.chomp("\n"), raw.bytesize]
      end
      records
    end

    def ingest_claude_line(session_id, parsed, seen_uuids, harness:, cutout_id:, slice:, space:, category:, scope:, category_root:, base:)
      return 0 unless parsed.is_a?(Hash) && parsed["type"] == "assistant"

      uuid = parsed["uuid"]
      return 0 if uuid && seen_uuids.include?(uuid)

      message = parsed["message"] || {}
      content = Array(message["content"])
      at = normalized_at(parsed["timestamp"])
      note_subagent = parsed["isSidechain"] == true

      processed = 0
      content.each do |block|
        next unless block.is_a?(Hash)

        case block["type"]
        when "text"
          Reach::Transcript.record_reply_with_code(
            session_id, harness: harness, cutout_id: cutout_id, slice: slice, space: space, at: at,
            raw_text: block["text"], category: category, scope: scope, category_root: category_root
          )
          processed += 1
        when "thinking", "redacted_thinking"
          record_reasoning(session_id, block["thinking"], harness: harness, cutout_id: cutout_id, slice: slice, space: space, at: at)
          processed += 1
        when "tool_use"
          record_action(session_id, block["name"], block["input"] || {}, note_subagent, harness: harness, cutout_id: cutout_id, slice: slice, space: space, at: at, base: base)
          processed += 1
        end
      end
      seen_uuids << uuid if uuid
      processed
    end

    def ingest_codex_line(session_id, parsed, harness:, cutout_id:, slice:, space:, category:, scope:, category_root:, base:)
      return 0 unless parsed.is_a?(Hash) && parsed["type"] == "response_item"

      payload = parsed["payload"] || {}
      at = normalized_at(parsed["timestamp"] || payload["timestamp"])
      processed = 0

      case payload["type"]
      when "message"
        return 0 unless payload["role"] == "assistant"

        Array(payload["content"]).each do |block|
          next unless block.is_a?(Hash) && block["type"] == "output_text"

          Reach::Transcript.record_reply_with_code(
            session_id, harness: harness, cutout_id: cutout_id, slice: slice, space: space, at: at,
            raw_text: block["text"], category: category, scope: scope, category_root: category_root
          )
          processed += 1
        end
      when "reasoning"
        summaries = Array(payload["summary"]).map { |item| item.is_a?(Hash) ? item["text"] : item }.compact
        text = summaries.empty? ? nil : summaries.join("\n\n")
        record_reasoning(session_id, text, harness: harness, cutout_id: cutout_id, slice: slice, space: space, at: at)
        processed += 1
      when "function_call", "custom_tool_call"
        tool = (payload["name"] || payload["tool"] || payload["type"]).to_s
        input = parse_maybe_json(payload["arguments"] || payload["input"])
        record_action(session_id, tool, input, false, harness: harness, cutout_id: cutout_id, slice: slice, space: space, at: at, base: base)
        processed += 1
      end
      processed
    end

    def record_reasoning(session_id, text, harness:, cutout_id:, slice:, space:, at:)
      readable = text.is_a?(String) && !text.strip.empty?
      fields = readable ? Reach::Transcript.text_fields(text) : { "text" => nil, "bytes" => 0, "truncated" => false, "digest" => nil, "note" => "reasoning not readable" }
      Reach::Transcript.record(session_id, kind: "reasoning", harness: harness, cutout_id: cutout_id, slice: slice, space: space, at: at, fields: fields)
    end

    def record_action(session_id, tool_name, input, note_subagent, harness:, cutout_id:, slice:, space:, at:, base:)
      tool = tool_name.to_s.byteslice(0, 64)
      fields = { "tool" => tool, "summary" => action_summary(tool, input, base), "note" => note_subagent ? "subagent" : nil }
      Reach::Transcript.record(session_id, kind: "action", harness: harness, cutout_id: cutout_id, slice: slice, space: space, at: at, fields: fields)
    end

    def action_summary(tool, input, base)
      input = input.is_a?(Hash) ? input : {}
      text = case tool
             when "Bash", "shell", "exec_command", "terminal"
               (input["command"] || input["cmd"]).to_s
             when "Read", "Grep", "Glob"
               relativize_path((input["path"] || input["pattern"] || input["file_path"]).to_s, base)
             when "Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch", "write_file", "patch"
               "wrote #{write_paths(input).map { |p| relativize_path(p, base) }.join(', ')}"
             else
               "#{tool} #{JSON.generate(input)}"
             end
      text.to_s.byteslice(0, 2000).to_s
    end

    def write_paths(input)
      paths = [input["file_path"], input["notebook_path"], input["path"]].compact
      paths.concat(Reach::Gate.patch_targets(input["patch"] || input["command"])) if paths.empty? && (input["patch"] || input["command"].to_s.start_with?("*** Begin Patch"))
      paths.uniq
    end

    def relativize_path(path, base)
      return path.to_s if path.nil? || path.to_s.empty? || base.nil?

      absolute = File.expand_path(path.to_s)
      base_real = File.expand_path(base)
      return "." if absolute == base_real
      return absolute.sub("#{base_real}#{File::SEPARATOR}", "") if absolute.start_with?("#{base_real}#{File::SEPARATOR}")

      File.basename(absolute)
    end

    def category_info(space, assignment, cutout_id, slice, workspace)
      if space.to_s == "slice" && workspace
        root = "deliverables/#{assignment}/#{cutout_id}-#{slice}"
        scope = { "assignment" => assignment, "cutout_id" => cutout_id, "slice" => slice }
        ["assignment", scope, root]
      else
        ["extracurricular", nil, "extracurricular"]
      end
    end

    def normalized_at(value)
      return Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") if value.nil? || value.to_s.empty?

      Time.parse(value.to_s).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    rescue StandardError
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def parse_maybe_json(value)
      return value if value.is_a?(Hash)
      return {} if value.nil?

      JSON.parse(value.to_s)
    rescue StandardError
      { "raw" => value.to_s }
    end

    def safe_json(line)
      JSON.parse(line)
    rescue StandardError
      nil
    end

    def safe_current_workspace
      Reach::Gate.current_workspace_path
    rescue StandardError
      nil
    end

    def safe_metadata(workspace)
      Reach::Workspace.metadata(workspace)
    rescue StandardError
      {}
    end
  end
end
