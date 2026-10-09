require "json"
require "time"
require "fileutils"
require_relative "redact"

module Reach
  module TranscriptIngest
    MAX_ENTRIES_PER_INGEST = 2000
    SEEN_UUID_LIMIT = 2000
    TOOL_NAME_LIMIT = 500
    BATCH_LINES = 50

    module_function

    def ingest(session_id:, transcript_path:, harness:, space:, workspace: nil)
      return nil if transcript_path.nil? || transcript_path.to_s.empty?

      unless File.file?(transcript_path)
        Reach::Transcript.log_transcript_event("ingest_skipped", "session_id" => session_id)
        return nil
      end

      with_ingest_lock(session_id) do
        perform_ingest(session_id: session_id, transcript_path: transcript_path, harness: harness, space: space, workspace: workspace)
      end
      nil
    rescue StandardError => e
      Reach::Transcript.log_transcript_event("ingest_failed", "error" => e.class.name, "session_id" => session_id)
      nil
    end

    def skip(session_id:, transcript_path:)
      return nil unless File.file?(transcript_path)

      with_ingest_lock(session_id) do
        fields = { "transcript_path" => transcript_path, "transcript_offset" => File.size(transcript_path), "subagent_offsets" => subagent_sizes(transcript_path) }
        context = Reach::Transcript.read_state(session_id)["context"]
        fields["context"] = context.merge("capture" => false) if context.is_a?(Hash)
        Reach::Transcript.merge_state(session_id, fields)
      end
      nil
    rescue StandardError
      nil
    end

    def with_ingest_lock(session_id)
      FileUtils.mkdir_p(Reach::Paths.transcripts_dir)
      lock_path = File.join(Reach::Paths.transcripts_dir, "#{session_id}.ingest.lock")
      Reach::Locks.exclusive(lock_path) { yield }
    end

    def subagent_files(transcript_path)
      dir = File.join(File.dirname(transcript_path), File.basename(transcript_path, ".jsonl"), "subagents")
      Dir.glob(File.join(dir, "agent-*.jsonl")).sort
    rescue StandardError
      []
    end

    def subagent_sizes(transcript_path)
      subagent_files(transcript_path).each_with_object({}) { |path, sizes| sizes[File.basename(path)] = File.size(path) }
    rescue StandardError
      {}
    end

    def perform_ingest(session_id:, transcript_path:, harness:, space:, workspace:)
      state = Reach::Transcript.read_state(session_id)
      same = state["transcript_path"] == transcript_path
      offset = same ? state["transcript_offset"].to_i : 0
      seen_uuids = Array(state["seen_uuids"])
      tool_names = state["tool_names"].is_a?(Hash) ? state["tool_names"].dup : {}
      private_calls = Array(state["private_calls"]).map(&:to_s)
      subagent_offsets = same && state["subagent_offsets"].is_a?(Hash) ? state["subagent_offsets"].dup : {}

      if File.size(transcript_path) < offset
        offset = 0
        Reach::Transcript.log_transcript_event("transcript_restarted", "session_id" => session_id)
      end

      workspace = nil unless space.to_s == "slice"
      meta = workspace ? safe_metadata(workspace) : {}
      cutout_id = meta["cutout_id"]
      slice = meta["slice"]
      category, scope, category_root = category_info(space, meta["assignment"], cutout_id, slice, workspace)
      ctx = {
        session_id: session_id, harness: harness, cutout_id: cutout_id, slice: slice, space: space,
        category: category, scope: scope, category_root: category_root,
        base: Reach::Transcript.space_base(space.to_s, workspace), seen_uuids: seen_uuids, tool_names: tool_names, private_calls: private_calls
      }

      budget = MAX_ENTRIES_PER_INGEST
      progress = { "main" => offset }
      save = lambda do
        Reach::Transcript.merge_state(
          session_id,
          "transcript_path" => transcript_path, "transcript_offset" => progress["main"],
          "seen_uuids" => seen_uuids.last(SEEN_UUID_LIMIT), "tool_names" => tool_names.to_a.last(TOOL_NAME_LIMIT).to_h, "private_calls" => private_calls.last(TOOL_NAME_LIMIT),
          "subagent_offsets" => subagent_offsets
        )
      end

      begin
        running_offset, used = ingest_file(transcript_path, offset, ctx, budget, subagent: false) do |position|
          progress["main"] = position
          save.call
        end
        progress["main"] = running_offset
        budget -= used

        if harness.to_s == "claude-code"
          subagent_files(transcript_path).each do |path|
            break if budget <= 0

            name = File.basename(path)
            start = subagent_offsets[name].to_i
            start = 0 if File.size(path) < start
            subagent_offsets[name], used = ingest_file(path, start, ctx, budget, subagent: true) do |position|
              subagent_offsets[name] = position
              save.call
            end
            budget -= used
          end
        end
      ensure
        save.call
      end
      nil
    end

    def ingest_file(path, offset, ctx, budget, subagent:)
      running_offset = offset
      processed_total = 0
      handled = 0
      each_line_record(path, offset) do |raw_line, byte_len|
        break if processed_total >= budget

        parsed = safe_json(raw_line)
        if parsed
          ctx[:line_key] = "#{File.basename(path)}@#{running_offset}"
          processed_total += case ctx[:harness].to_s
                             when "claude-code" then ingest_claude_line(parsed, ctx, subagent: subagent)
                             when "codex" then ingest_codex_line(parsed, ctx)
                             else 0
                             end
        end
        running_offset += byte_len
        handled += 1
        yield(running_offset) if block_given? && (handled % BATCH_LINES).zero?
      end
      [running_offset, processed_total]
    end

    def each_line_record(path, offset)
      File.open(path, "rb") do |file|
        file.seek(offset)
        file.each_line do |raw|
          break unless raw.end_with?("\n")

          yield raw.chomp("\n"), raw.bytesize
        end
      end
    end

    def ingest_claude_line(parsed, ctx, subagent: false)
      return 0 unless parsed.is_a?(Hash) && %w[assistant user].include?(parsed["type"])

      uuid = parsed["uuid"]
      return 0 if uuid && ctx[:seen_uuids].include?(uuid)

      message = parsed["message"].is_a?(Hash) ? parsed["message"] : {}
      content = message["content"]
      return 0 unless content.is_a?(Array)

      at = normalized_at(parsed["timestamp"])
      note_subagent = subagent || parsed["isSidechain"] == true
      processed = 0
      content.each do |block|
        next unless block.is_a?(Hash)

        if parsed["type"] == "user"
          next unless block["type"] == "tool_result"

          notes = [note_subagent ? "subagent" : nil, block["is_error"] == true ? "error" : nil].compact
          record_output(ctx, ctx[:tool_names][block["tool_use_id"].to_s], output_text(block["content"]), notes.empty? ? nil : notes.join(", "), at, block["tool_use_id"].to_s)
          processed += 1
          next
        end

        case block["type"]
        when "text"
          Reach::Transcript.record_reply_with_code(
            ctx[:session_id], harness: ctx[:harness], cutout_id: ctx[:cutout_id], slice: ctx[:slice], space: ctx[:space], at: at,
            raw_text: block["text"], category: ctx[:category], scope: ctx[:scope], category_root: ctx[:category_root],
            note: note_subagent ? "subagent" : nil
          )
          processed += 1
        when "thinking", "redacted_thinking"
          record_reasoning(ctx[:session_id], block["thinking"], harness: ctx[:harness], cutout_id: ctx[:cutout_id], slice: ctx[:slice], space: ctx[:space], at: at)
          processed += 1
        when "tool_use"
          ctx[:tool_names][block["id"].to_s] = block["name"].to_s unless block["id"].to_s.empty?
          mark_private(ctx, block["id"], block["name"], block["input"])
          record_action(ctx[:session_id], block["name"], block["input"] || {}, note_subagent, harness: ctx[:harness], cutout_id: ctx[:cutout_id], slice: ctx[:slice], space: ctx[:space], at: at, base: ctx[:base], withheld: private_call?(ctx, block["id"]))
          processed += 1
        end
      end
      ctx[:seen_uuids] << uuid if uuid
      processed
    end

    def ingest_codex_line(parsed, ctx)
      return 0 unless parsed.is_a?(Hash) && parsed["type"] == "response_item"

      key = ctx[:line_key]
      return 0 if key && ctx[:seen_uuids].include?(key)

      payload = parsed["payload"].is_a?(Hash) ? parsed["payload"] : {}
      at = normalized_at(parsed["timestamp"] || payload["timestamp"])
      processed = 0

      case payload["type"]
      when "message"
        return 0 unless payload["role"] == "assistant"

        Array(payload["content"]).each do |block|
          next unless block.is_a?(Hash) && block["type"] == "output_text"

          Reach::Transcript.record_reply_with_code(
            ctx[:session_id], harness: ctx[:harness], cutout_id: ctx[:cutout_id], slice: ctx[:slice], space: ctx[:space], at: at,
            raw_text: block["text"], category: ctx[:category], scope: ctx[:scope], category_root: ctx[:category_root]
          )
          processed += 1
        end
      when "reasoning"
        summaries = Array(payload["summary"]).map { |item| item.is_a?(Hash) ? item["text"] : item }.compact
        text = summaries.empty? ? nil : summaries.join("\n\n")
        record_reasoning(ctx[:session_id], text, harness: ctx[:harness], cutout_id: ctx[:cutout_id], slice: ctx[:slice], space: ctx[:space], at: at)
        processed += 1
      when "function_call", "custom_tool_call"
        tool = (payload["name"] || payload["tool"] || payload["type"]).to_s
        ctx[:tool_names][payload["call_id"].to_s] = tool unless payload["call_id"].to_s.empty?
        input = parse_maybe_json(payload["arguments"] || payload["input"])
        mark_private(ctx, payload["call_id"], tool, input)
        record_action(ctx[:session_id], tool, input, false, harness: ctx[:harness], cutout_id: ctx[:cutout_id], slice: ctx[:slice], space: ctx[:space], at: at, base: ctx[:base], withheld: private_call?(ctx, payload["call_id"]))
        processed += 1
      when "function_call_output", "custom_tool_call_output"
        record_output(ctx, ctx[:tool_names][payload["call_id"].to_s], output_text(payload["output"]), nil, at, payload["call_id"].to_s)
        processed += 1
      end
      ctx[:seen_uuids] << key if key && processed.positive?
      processed
    end

    def output_text(value)
      case value
      when nil then ""
      when String
        parsed = value.start_with?("{") ? safe_json(value) : nil
        parsed.is_a?(Hash) && parsed["output"].is_a?(String) ? parsed["output"] : value
      when Array
        value.map { |block| output_block_text(block) }.join("\n")
      when Hash
        value["output"].is_a?(String) ? value["output"] : JSON.generate(value)
      else
        value.to_s
      end
    end

    def output_block_text(block)
      return block.to_s unless block.is_a?(Hash)
      return block["text"].to_s if block["text"].is_a?(String)
      return "[#{block['type']}]" if %w[image input_image].include?(block["type"])

      JSON.generate(block)
    end

    def tool_label(tool_name)
      tool = Reach::Transcript.truncate_to_bytes(tool_name.to_s.dup.force_encoding("UTF-8").scrub(""), 64)
      tool.empty? ? "unknown" : tool
    end

    def draft(ctx_fields, kind, at, fields)
      { "kind" => kind, "at" => at }.merge(ctx_fields).merge(fields)
    end

    def mark_private(ctx, call_id, tool_name, input)
      id = call_id.to_s
      return if id.empty?
      return unless Reach::Redact.private_call?(tool_name, input, ctx[:base])

      ctx[:private_calls] ||= []
      ctx[:private_calls] << id unless ctx[:private_calls].include?(id)
    end

    def private_call?(ctx, call_id)
      id = call_id.to_s
      !id.empty? && Array(ctx[:private_calls]).include?(id)
    end

    def record_output(ctx, tool_name, text, note, at, call_id = nil)
      common = { "harness" => ctx[:harness].to_s, "cutout_id" => ctx[:cutout_id], "slice" => ctx[:slice], "space" => ctx[:space] }
      tool = tool_label(tool_name)
      if Reach::Redact.private_tool?(tool_name) || private_call?(ctx, call_id)
        withheld = { "tool" => tool, "text" => nil, "bytes" => 0, "truncated" => false, "digest" => nil, "note" => Reach::Redact::PRIVATE_OUTPUT_NOTE, "withheld" => true }
        return Reach::Transcript.record_batch(ctx[:session_id], [draft(common, "output", at, withheld)])
      end

      drafts = Reach::Transcript.text_parts(text).map do |fields|
        draft(common, "output", at, fields.merge("tool" => tool, "note" => Reach::Redact.join_notes(note, fields["note"])))
      end
      Reach::Transcript.record_batch(ctx[:session_id], drafts)
    end

    def record_reasoning(session_id, text, harness:, cutout_id:, slice:, space:, at:)
      common = { "harness" => harness.to_s, "cutout_id" => cutout_id, "slice" => slice, "space" => space }
      readable = text.is_a?(String) && !text.strip.empty?
      parts = readable ? Reach::Transcript.text_parts(text) : [{ "text" => nil, "bytes" => 0, "truncated" => false, "digest" => nil, "note" => "reasoning not readable" }]
      Reach::Transcript.record_batch(session_id, parts.map { |fields| draft(common, "reasoning", at, fields) })
    end

    def record_action(session_id, tool_name, input, note_subagent, harness:, cutout_id:, slice:, space:, at:, base:, withheld: false)
      common = { "harness" => harness.to_s, "cutout_id" => cutout_id, "slice" => slice, "space" => space }
      tool = tool_label(tool_name)
      if withheld || Reach::Redact.private_tool?(tool_name)
        fields = { "tool" => tool, "summary" => Reach::Redact::PRIVATE_SUMMARY, "note" => note_subagent ? "subagent" : nil, "withheld" => true }
        return Reach::Transcript.record_batch(session_id, [draft(common, "action", at, fields)])
      end

      summary, counts = Reach::Redact.text(action_summary(tool, input, base))
      redaction_note = Reach::Redact.note(counts)
      pieces = Reach::Transcript.split_bytes(summary)
      drafts = pieces.each_with_index.map do |piece, index|
        fields = { "tool" => tool, "summary" => piece, "note" => Reach::Redact.join_notes(note_subagent ? "subagent" : nil, redaction_note) }
        fields["part"] = [index + 1, pieces.length] if pieces.length > 1
        draft(common, "action", at, fields)
      end
      Reach::Transcript.record_batch(session_id, drafts)
    end

    def action_summary(tool, input, base)
      input = input.is_a?(Hash) ? input : {}
      text = case tool
             when "Bash", "PowerShell", "shell", "exec_command", "terminal"
               (input["command"] || input["cmd"]).to_s
             when "Read", "Grep", "Glob"
               relativize_path((input["path"] || input["pattern"] || input["file_path"]).to_s, base)
             when "Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch", "write_file", "patch"
               "wrote #{write_paths(input).map { |p| relativize_path(p, base) }.join(', ')}"
             else
               "#{tool} #{JSON.generate(input)}"
             end
      text.to_s.dup.force_encoding("UTF-8").scrub("�")
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
