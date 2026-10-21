require "json"
require "digest"
require "time"
require "fileutils"
require "timeout"

module Reach
  module GuidedLearner
    class Invalid < Reach::Refused; end

    POLICY_ID = "polispec.guided-learner".freeze
    POLICY_SCHEMA = "polispec.behavior/v1".freeze
    COMPILED_SCHEMA = "polispec.behavior.compiled/v1".freeze
    IDS = %w[GL-CODE GL-NOTERM GL-DETAIL GL-SCOPE GL-PLAIN GL-OPEN].freeze
    DETECTOR_IDS = %w[GL-CODE GL-NOTERM GL-DETAIL].freeze
    OPCODES = { "GL-CODE" => "GLCODE", "GL-NOTERM" => "GLTERM", "GL-DETAIL" => "GLDETAIL", "GL-SCOPE" => "GLSCOPE", "GL-PLAIN" => "GLPLAIN", "GL-OPEN" => "GLOPEN" }.freeze
    REACH_COMMAND_HANDOFF = /(?:\A|[.!?\n])\s*(?:[-*]\s*)?(?:please\s+)?(?:you\s+(?:should|must|need to)\s+)?(?:run|execute)\s+(?:the\s+)?`?reach\s+[a-z][a-z0-9-]*(?:\s+[a-z][a-z0-9-]*)?/i.freeze
    STATE_TTL = 600

    module_function

    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value.fetch(key)) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def digest(value)
      "sha256:" + Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def artifact_path
      File.join(Reach::Runtime.root, "policy", "guided-learner.json")
    end

    def bundle
      stat = File.lstat(artifact_path)
      raise Invalid, "presentation policy artifact is not a regular file" unless stat.file? && !stat.symlink?
      raise Invalid, "presentation policy artifact is too large" if stat.size > 131_072
      key = [stat.size, stat.mtime.to_r, stat.ctime.to_r, stat.ino]
      return @bundle if @key == key && @bundle

      candidate = JSON.parse(Reach::SafeFiles.read(File.dirname(File.dirname(artifact_path)), "policy/guided-learner.json", max_bytes: 131_072))
      validate_bundle!(candidate)
      @bundle = candidate
      @key = key
      @bundle
    rescue SystemCallError, JSON::ParserError, KeyError, TypeError, ArgumentError => e
      raise Invalid, "presentation policy could not be read: #{e.message}"
    end

    def validate_bundle!(candidate)
      unless candidate.is_a?(Hash) && candidate["schema"] == COMPILED_SCHEMA && candidate["policy"].is_a?(Hash)
        raise Invalid, "unrecognized presentation policy"
      end
      policy = candidate.fetch("policy")
      raise Invalid, "presentation policy digest mismatch" unless candidate["digest"] == digest(policy)
      unless policy["schema"] == POLICY_SCHEMA && policy["id"] == POLICY_ID && policy["version"].is_a?(Integer) && policy["version"] > 0
        raise Invalid, "unrecognized presentation policy identity"
      end
      unless policy["authority"] == { "id" => "polispec", "kind" => "application", "authentication" => "release" }
        raise Invalid, "presentation policy authority mismatch"
      end
      raise Invalid, "presentation policy scope mismatch" unless policy.dig("scope", "application") == "guided-learner"
      rows = policy.dig("parameters", "presentation")
      unless rows.is_a?(Hash) && rows["max_text_bytes"] == 65_536 && rows["max_event_bytes"] == 131_072 && rows["max_rewrites"] == 1 && ["fallback", "recovery"].all? { |key| rows[key].is_a?(String) && rows[key].valid_encoding? && rows[key].bytesize <= 65_536 }
        raise Invalid, "presentation policy parameters are invalid"
      end
      directives = policy["directives"]
      ids = directives.is_a?(Array) ? directives.map { |row| row.is_a?(Hash) ? row["id"] : nil } : []
      raise Invalid, "presentation policy directives are incomplete" unless ids.all? { |id| id.is_a?(String) } && ids.sort == IDS.sort && ids.uniq == ids
      detectors = rows["detectors"]
      detector_ids = detectors.is_a?(Array) ? detectors.map { |row| row.is_a?(Hash) ? row["id"] : nil } : []
      raise Invalid, "presentation detectors are invalid" unless detectors.is_a?(Array) && detectors.length.between?(DETECTOR_IDS.length, 32) && detector_ids.all? { |id| id.is_a?(String) } && DETECTOR_IDS.sort == detector_ids.uniq.sort
      detectors.each do |row|
        raise Invalid, "presentation detector is invalid" unless row.is_a?(Hash) && row["pattern"].is_a?(String) && row["pattern"].valid_encoding? && row["pattern"].bytesize.between?(1, 2048) && ["i", ""].include?(row["flags"])
        Regexp.new(row["pattern"], row["flags"] == "i" ? Regexp::IGNORECASE : 0)
      end
      raise Invalid, "presentation directives are invalid" unless directives.all? { |row| row.is_a?(Hash) && row["tier"] == "public" && row["opcode"] == OPCODES[row["id"]] && ["rule", "body"].all? { |key| row[key].is_a?(String) && row[key].valid_encoding? && row[key].bytesize <= 8192 } && row["when"] == ["always"] && row["enforce"].is_a?(String) }
      freeze_tree(candidate)
    rescue RegexpError
      raise Invalid, "presentation detector could not be compiled"
    end

    def freeze_tree(value)
      case value
      when Hash then value.each { |key, item| key.freeze; freeze_tree(item) }
      when Array then value.each { |item| freeze_tree(item) }
      end
      value.freeze
    end

    def presentation
      bundle.dig("policy", "parameters", "presentation")
    end

    def context
      policy = bundle.fetch("policy")
      policy.fetch("directives").sort_by { |row| row.fetch("id") }.map do |row|
        "#{row.fetch('opcode')}: #{row.fetch('rule')}\n#{row.fetch('body')}"
      end.join("\n\n")
    end

    def compiled_detectors
      key = bundle.fetch("digest")
      return @compiled if @compiled_key == key && @compiled

      @compiled = presentation.fetch("detectors").group_by { |row| row.fetch("id") }.transform_values do |rows|
        rows.map { |row| Regexp.new(row.fetch("pattern"), row.fetch("flags") == "i" ? Regexp::IGNORECASE : 0) }
      end
      @compiled_key = key
      @compiled
    end

    def violations(text)
      return ["GL-CODE"] unless text.is_a?(String) && text.valid_encoding? && text.bytesize <= presentation.fetch("max_text_bytes")

      detectors = compiled_detectors
      Timeout.timeout(0.05) do
        found = DETECTOR_IDS.select { |id| detectors.fetch(id).any? { |pattern| pattern.match?(text) } }
        found << "GL-NOTERM" if !found.include?("GL-NOTERM") && REACH_COMMAND_HANDOFF.match?(text)
        found
      end
    rescue Timeout::Error
      ["GL-CODE", "GL-NOTERM", "GL-DETAIL"]
    end

    def safe_reply?(text)
      violations(text).empty?
    end

    def state_root
      File.join(Reach::Paths.state_dir, "guided-learner")
    end

    def identity(event)
      %w[session_id turn_id message_id].map do |name|
        value = event[name]
        raise Invalid, "missing display identity" unless value.is_a?(String) && value.bytesize.between?(1, 256) && value.valid_encoding?
        value
      end
    end

    def display_event(raw)
      if Reach::Instructor.mode?
        event = JSON.parse(raw.to_s)
        return display_response(event["delta"].to_s)
      end
      max = presentation.fetch("max_event_bytes")
      raise Invalid, "display event is too large" unless raw.is_a?(String) && raw.bytesize <= max
      event = JSON.parse(raw)
      raise Invalid, "unexpected display event" unless event.is_a?(Hash) && event["hook_event_name"] == "MessageDisplay"
      ids = identity(event)
      index = event["index"]
      delta = event["delta"]
      final = event["final"]
      raise Invalid, "invalid display delta" unless index.is_a?(Integer) && index >= 0 && delta.is_a?(String) && delta.valid_encoding? && [true, false].include?(final)
      raise Invalid, "display delta is too large" if delta.bytesize > presentation.fetch("max_text_bytes")
      digest_key = Digest::SHA256.hexdigest(ids.join("\0"))
      path = File.join(state_root, "#{digest_key}.json")
      FileUtils.mkdir_p(Reach::Paths.state_dir, mode: 0o700)
      raise Invalid, "display state parent is unsafe" if File.symlink?(Reach::Paths.state_dir)
      FileUtils.mkdir_p(state_root, mode: 0o700)
      raise Invalid, "display state directory is unsafe" if File.symlink?(state_root)
      File.chmod(0o700, state_root)
      lock_path = File.join(state_root, "buffer.lock")
      raise Invalid, "display state lock is unsafe" if File.symlink?(lock_path)
      File.open(lock_path, File::RDWR | File::CREAT | Reach::SafeFiles::NOFOLLOW, 0o600) do |lock|
        raise Invalid, "display state lock is unsafe" unless lock.stat.file?
        lock.chmod(0o600)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.5
        until lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Invalid, "display state is busy" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep(0.02 + rand * 0.03)
        end
        prune_expired
        process_display(path, event, index, delta, final)
      end
    rescue StandardError
      fallback_display
    end

    def process_display(path, _event, index, delta, final)
      state = read_state(path)
      now = Time.now.to_i
      state = { "index" => -1, "text" => "", "updated_at" => now } if now - state.fetch("updated_at", 0).to_i > STATE_TTL
      unless index == state.fetch("index") + 1
        File.unlink(path) if File.file?(path) && !File.symlink?(path)
        raise Invalid, "display event order is invalid"
      end
      text = state.fetch("text") + delta
      if text.bytesize > presentation.fetch("max_text_bytes")
        File.unlink(path) if File.file?(path) && !File.symlink?(path)
        raise Invalid, "display text is too large"
      end
      unless final
        write_state(path, { "index" => index, "text" => text, "updated_at" => now })
        return display_response("")
      end
      File.unlink(path) if File.exist?(path)
      display_response(safe_reply?(text) ? text : presentation.fetch("fallback"))
    end

    def read_state(path)
      raise Invalid, "display state is unsafe" if File.symlink?(path)
      return { "index" => -1, "text" => "", "updated_at" => Time.now.to_i } unless File.exist?(path)
      raise Invalid, "display state is unsafe" unless File.lstat(path).file?
      bytes = Reach::SafeFiles.read(state_root, File.basename(path), max_bytes: presentation.fetch("max_text_bytes") * 6 + 1024)
      value = JSON.parse(bytes.to_s)
      raise Invalid, "display state is invalid" unless value.is_a?(Hash) && value["index"].is_a?(Integer) && value["text"].is_a?(String) && value["updated_at"].is_a?(Integer)
      value
    end

    def prune_expired
      now = Time.now.to_i
      active = 0
      Dir.each_child(state_root) do |name|
        next unless name.match?(/\A[0-9a-f]{64}\.json\z/)
        path = File.join(state_root, name)
        stat = File.lstat(path)
        raise Invalid, "display state is unsafe" unless stat.file? && !stat.symlink?
        if now - stat.mtime.to_i > STATE_TTL
          File.unlink(path)
        else
          active += 1
          raise Invalid, "too many display buffers" if active > 256
        end
      end
    end

    def write_state(path, state)
      Reach::StateFile.write_atomic(path, JSON.generate(state), mode: 0o600)
      File.chmod(0o600, path)
    end

    def display_response(text)
      { "hookSpecificOutput" => { "hookEventName" => "MessageDisplay", "displayContent" => text } }
    end

    def fallback_display
      display_response(presentation.fetch("fallback"))
    rescue StandardError
      display_response("I couldn't finish that explanation. Please ask your instructor for help so you can continue your assignment.")
    end

    def stop_response(event)
      return { "review" => "instructor" } if Reach::Instructor.mode?
      return nil unless event.is_a?(Hash)
      message = event["last_assistant_message"]
      return { "review" => "unreviewable" } unless message.is_a?(String) && message.valid_encoding? && message.bytesize <= presentation.fetch("max_text_bytes")
      found = violations(message)
      return { "review" => "clear" } if found.empty?
      return { "review" => "exhausted", "violations" => found } if event["stop_hook_active"] == true

      { "review" => "rewrite", "decision" => "block", "reason" => presentation.fetch("recovery"), "violations" => found }
    rescue StandardError
      { "review" => "unreviewable" }
    end
  end
end
