require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Debug
    KINDS = %w[session hook gate command request lock sync check qualify submit transcript brain update error].freeze
    ROUTE = "/api/v1/debug".freeze
    HARNESSES = %w[claude-code codex hermes unknown].freeze
    DROP_KEY = /code|password|secret|token|key|signature|pem|passphrase/i.freeze
    RINS = /RINS1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/.freeze
    PEM_BLOCK = /-----BEGIN [A-Z0-9 ]+-----.*?(?:-----END [A-Z0-9 ]+-----|\z)/m.freeze
    COURSE_SHAPE = /[A-Z0-9]{3,}-[A-Z0-9]{4}-[A-Z0-9]{4}/.freeze
    MAX_STRING_BYTES = 1024
    MAX_KEYS = 64
    MAX_ARRAY = 32
    SESSIONS_KEPT = 50
    SENT_FILES_READ = 2
    BATCH_MAX_BYTES = 900_000
    QUICK_MAX_BATCHES = 2
    FULL_MAX_BATCHES = 20
    QUICK_BACKOFF_S = 60
    DEFAULTS = { "render" => "auto", "spool_max_bytes" => 5_242_880, "batch_max_events" => 500, "show_max_rows" => 40 }.freeze
    PLUGIN_ROOT = File.expand_path("../..", __dir__)
    SCRUBBED = "[scrubbed]".freeze
    SUBCOMMAND_COMMANDS = %w[gate transcript instructor shape modules transfer login memory directive reference part update runtime setup debug brain].freeze

    module_function

    def config
      section = Reach::Runtime.load_config["debug"]
      section = {} unless section.is_a?(Hash)
      DEFAULTS.merge(section.select { |key, value| DEFAULTS.key?(key) && !value.nil? })
    rescue StandardError
      DEFAULTS.dup
    end

    def dir
      File.join(Reach::Paths.home, "debug")
    end

    def spool_file
      File.join(dir, "spool.jsonl")
    end

    def switch_file
      File.join(dir, "switch.json")
    end

    def state_file
      File.join(dir, "state.json")
    end

    def lock_file
      File.join(dir, "lock")
    end

    def flush_lock_file
      File.join(dir, "flush.lock")
    end

    def sent_file(day = Time.now.utc.strftime("%Y%m%d"))
      File.join(dir, "sent-#{day}.jsonl")
    end

    def rejected_file
      File.join(dir, "rejected-#{Time.now.utc.strftime('%Y%m%d')}.jsonl")
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((clock - started) * 1000).round
    end

    def future?(value)
      return true if value.nil? || value.to_s.empty?

      Time.parse(value.to_s) > Time.now
    rescue ArgumentError
      false
    end

    def read_json(path)
      return nil unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError
      nil
    end

    def reason
      home = Reach::Paths.home
      return @reason_memo[1] if @reason_memo && @reason_memo[0] == home

      value = compute_reason
      @reason_memo = [home, value]
      value
    rescue StandardError
      nil
    end

    def reset!
      @reason_memo = nil
      @patterns = nil
    end

    def on?
      !reason.nil?
    end

    def compute_reason
      return "persona" if Reach::Persona.active?

      switch = read_json(switch_file)
      return "local" if switch && switch["on"] == true && future?(switch["until"])

      status = Reach::Sync.cached_status
      requested = status.is_a?(Hash) ? status["debug"] : nil
      return "remote" if requested.is_a?(Hash) && requested["requested"] == true && future?(requested["until"])

      nil
    rescue StandardError
      nil
    end

    def until_value
      case reason
      when "local"
        switch = read_json(switch_file)
        switch && switch["until"]
      when "remote"
        status = Reach::Sync.cached_status
        status && status["debug"].is_a?(Hash) ? status["debug"]["until"] : nil
      end
    rescue StandardError
      nil
    end

    def turn_on!(minutes = nil)
      ensure_dir
      until_at = minutes ? (Time.now.utc + (minutes.to_i * 60)).strftime("%Y-%m-%dT%H:%M:%SZ") : nil
      write_json(switch_file, "on" => true, "until" => until_at, "set_at" => now_s)
      reset!
      until_at
    end

    def turn_off!
      return reset! unless File.file?(switch_file)

      ensure_dir
      write_json(switch_file, "on" => false, "until" => nil, "set_at" => now_s)
      reset!
    end

    def ensure_dir
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)
    rescue NotImplementedError
      nil
    end

    def write_json(path, data)
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      File.rename(tmp, path)
      File.chmod(0o600, path)
    end

    def locked(path = lock_file)
      ensure_dir
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end

    def load_state
      read_json(state_file) || {}
    end

    def save_state(state)
      write_json(state_file, state)
    end

    def context
      @context ||= {}
      @context
    end

    def begin_hook(event, harness_flag)
      event = {} unless event.is_a?(Hash)
      harness = resolve_harness(harness_flag)
      session = event["session_id"].to_s.empty? ? "cli" : Reach::Transcript.resolve_session_id(event)
      @context = { "session_id" => session, "harness" => harness, "surface" => Reach::DebugRender.detect(harness, event) }
      @context
    rescue StandardError
      @context = {}
    end

    def resolve_harness(flag)
      value = flag.to_s
      return value if HARNESSES.include?(value)
      return "claude-code" if ENV["CLAUDE_CODE_ENTRYPOINT"].to_s != ""

      guessed = Reach::Hello.resolve_harness(nil)
      HARNESSES.include?(guessed) ? guessed : "unknown"
    end

    def envelope_context
      current = context
      harness = HARNESSES.include?(current["harness"]) ? current["harness"] : resolve_harness(nil)
      surface = %w[tui gui].include?(current["surface"]) ? current["surface"] : Reach::DebugRender.detect(harness, {})
      session = current["session_id"].to_s.empty? ? "cli" : current["session_id"].to_s[0, 128]
      { "session_id" => session, "harness" => harness, "surface" => surface }
    end

    def emit(kind, fields = {})
      return nil if Thread.current[:reach_debug_busy]
      return nil unless on?

      Thread.current[:reach_debug_busy] = true
      begin
        append(kind.to_s, fields)
      ensure
        Thread.current[:reach_debug_busy] = false
      end
      nil
    rescue StandardError
      nil
    end

    def append(kind, fields)
      return unless KINDS.include?(kind)

      scoped = envelope_context
      clean = scrub_fields(fields)
      current_reason = reason
      persona = Reach::Paths.persona_id
      locked do
        state = load_state
        seqs = state["seq"].is_a?(Hash) ? state["seq"] : {}
        number = seqs[scoped["session_id"]].to_i + 1
        seqs.delete(scoped["session_id"])
        seqs[scoped["session_id"]] = number
        seqs.delete(seqs.keys.first) while seqs.size > SESSIONS_KEPT
        state["seq"] = seqs
        if kind == "session" && state["dropped"].to_i.positive?
          clean["dropped_events"] = state["dropped"].to_i
          state["dropped"] = 0
        end
        event = { "id" => SecureRandom.hex(16), "at" => now_s, "seq" => number, "kind" => kind, "persona_id" => persona, "fields" => clean }
        line = scoped.merge("reason" => current_reason, "event" => event)
        File.open(spool_file, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |file| file.puts(JSON.generate(line)) }
        trim_spool(state)
        save_state(state)
      end
    end

    def trim_spool(state)
      limit = config["spool_max_bytes"].to_i
      return unless limit.positive? && File.size(spool_file) > limit

      lines = File.readlines(spool_file)
      total = lines.sum(&:bytesize)
      dropped = 0
      while total > (limit * 0.9) && lines.length > 1
        total -= lines.shift.bytesize
        dropped += 1
      end
      File.open(spool_file, File::WRONLY | File::TRUNC, 0o600) { |file| file.write(lines.join) }
      state["dropped"] = state["dropped"].to_i + dropped
    end

    def identity_patterns
      @patterns ||= begin
        enrollment = Reach::Runtime.load_config["enrollment"]
        enrollment = {} unless enrollment.is_a?(Hash)
        %w[username_pattern student_id_pattern].map do |name|
          source = enrollment[name].to_s
          next nil if source.empty?

          body = source.sub(/\A\^/, "").sub(/\$\z/, "")
          Regexp.new("(?<![A-Za-z0-9])(?:#{body})(?![A-Za-z0-9])")
        end.compact
      end
    rescue StandardError
      []
    end

    def scrub_string(text)
      value = text.to_s.dup
      value = value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?") unless value.encoding == Encoding::UTF_8 && value.valid_encoding?
      value = value.gsub(PEM_BLOCK, SCRUBBED).gsub(RINS, SCRUBBED).gsub(COURSE_SHAPE, SCRUBBED)
      identity_patterns.each { |pattern| value = value.gsub(pattern, SCRUBBED) }
      return value if value.bytesize <= MAX_STRING_BYTES

      value.byteslice(0, MAX_STRING_BYTES).scrub("")
    end

    def scrub_scalar(value)
      case value
      when nil, true, false
        value
      when String
        scrub_string(value)
      when Symbol
        scrub_string(value.to_s)
      when Integer
        value
      when Float
        value.finite? ? value : nil
      when Time
        value.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      else
        :skip
      end
    end

    def scrub_fields(fields)
      clean = {}
      return clean unless fields.is_a?(Hash)

      fields.each do |name, value|
        break if clean.size >= MAX_KEYS

        key = name.to_s
        next if key.empty? || DROP_KEY.match?(key)

        if value.is_a?(Array)
          items = value.first(MAX_ARRAY).map { |item| scrub_scalar(item) }.reject { |item| item == :skip }
          clean[scrub_string(key)] = items
        else
          scalar = scrub_scalar(value)
          clean[scrub_string(key)] = scalar unless scalar == :skip
        end
      end
      clean
    end

    def relative_frames(error)
      Array(error.backtrace).first(12).map { |frame| frame.to_s.sub(PLUGIN_ROOT + "/", "") }
    end

    def error(error, where = nil)
      return nil unless on?

      fields = { "exception" => error.class.name, "where" => where, "frames" => relative_frames(error) }
      if error.respond_to?(:message_id) && error.message_id
        fields["message_id"] = error.message_id
      else
        fields["message"] = error.message.to_s
      end
      emit("error", fields)
    rescue StandardError
      nil
    end

    def note(failure)
      @noted = failure
      error(failure, "command") unless failure.is_a?(Reach::GateBlocked)
    end

    def command(argv, exit_value, started, raised = nil)
      return nil unless on?

      raised ||= @noted

      name = argv.first.to_s
      return nil if name == "debug"

      rest = argv.drop(1)
      flags = rest.select { |token| token.start_with?("--") }.map { |token| token.split("=", 2).first }.select { |token| token.match?(/\A--[a-z][a-z-]{0,30}\z/) }
      sub = rest.first.to_s
      sub = nil unless SUBCOMMAND_COMMANDS.include?(name) && sub.match?(/\A[a-z][a-z-]{0,23}\z/)
      emit(
        "command",
        "command" => name.match?(/\A[a-z-]{1,24}\z/) ? name : "?", "sub" => sub, "flags" => flags,
        "exit" => exit_value, "duration_ms" => elapsed_ms(started), "error" => raised ? raised.class.name : nil
      )
      error(raised, "command") if raised && !raised.is_a?(Reach::Error)
    rescue StandardError
      nil
    end

    def hook(event, decision, rule, started)
      return nil unless on?

      space = begin
        found = Reach::Gate.current_space
        found ? found["kind"] : "outside"
      rescue StandardError
        "outside"
      end
      emit("hook", "event" => event, "decision" => decision, "rule" => rule, "space" => space, "latency_ms" => elapsed_ms(started))
    rescue StandardError
      nil
    end

    def request(method, path, status, error_name, request_id, attempt, latency_ms, bytes_out, bytes_in)
      return nil unless on?

      route = path.to_s.split("?").first.to_s
      return nil if route == ROUTE

      route = route.gsub(%r{/[A-Za-z0-9_.:-]*[0-9][A-Za-z0-9_.:-]{6,}}, "/:id")
      emit(
        "request",
        "route" => route, "method" => method.to_s.upcase, "status" => status, "error" => error_name.to_s.empty? ? nil : error_name,
        "request_id" => request_id, "attempt" => attempt, "latency_ms" => latency_ms, "bytes_out" => bytes_out, "bytes_in" => bytes_in
      )
    rescue StandardError
      nil
    end

    def response(method, path, answer, attempt, latency_ms, body)
      return nil unless on?

      parsed = begin
        answer.json
      rescue StandardError
        nil
      end
      parsed = {} unless parsed.is_a?(Hash)
      detail = parsed["error"].is_a?(Hash) ? parsed["error"]["code"] : nil
      request(
        method, path, answer.status, answer.status < 400 ? nil : detail,
        answer.headers["x-request-id"] || parsed["request_id"], attempt, latency_ms, body.to_s.bytesize, answer.body.to_s.bytesize
      )
    rescue StandardError
      nil
    end

    def lock(state)
      return nil unless on?

      locked_now = state["locked"] ? true : false
      why = state["reason"].to_s
      signature = "#{locked_now}:#{why}"
      changed = false
      locked do
        data = load_state
        if data["lock"] != signature
          data["lock"] = signature
          save_state(data)
          changed = true
        end
      end
      return nil unless changed

      emit(
        "lock",
        "state" => locked_now ? "locked" : "unlocked", "reason" => why.empty? ? nil : why,
        "stamp" => why == "stamp_invalid" ? "invalid" : "ok", "fingerprint" => why == "moved" ? "mismatch" : "match"
      )
    rescue StandardError
      nil
    end

    def sync(summary, started)
      return nil unless on?

      packages = summary["packages"].is_a?(Hash) ? summary["packages"].map { |kind, version| "#{kind}@#{version}" } : []
      emit(
        "sync",
        "state" => summary["state"], "packages" => packages, "workspaces" => Array(summary["workspaces"]).length,
        "outbox_sent" => summary["outbox_sent"], "transcript_sent" => summary["transcript_sent"],
        "warnings" => Array(summary["warnings"]).length, "duration_ms" => elapsed_ms(started)
      )
    rescue StandardError
      nil
    end

    def check(findings, files)
      return nil unless on?

      counts = Array(findings).each_with_object(Hash.new(0)) { |finding, memo| memo[(finding[:id] || finding["id"]).to_s] += 1 }
      emit("check", "files_checked" => files, "findings" => Array(findings).length, "rules" => counts.map { |rule, total| "#{rule}=#{total}" })
    rescue StandardError
      nil
    end

    def qualify(record, local_only)
      return nil unless on?

      ladder = record["ladder"].is_a?(Hash) ? record["ladder"] : {}
      emit(
        "qualify",
        "passed" => record["passed"] ? true : false, "pending" => record["pending"] ? true : false,
        "failed" => Array(record["findings"]).length, "graded" => Array(record["graded"]).length,
        "attempt" => record["attempt"], "ladder_failed" => ladder["failed"], "ladder_rung" => ladder["rung"],
        "mode" => local_only ? "local" : "teach"
      )
    rescue StandardError
      nil
    end

    def submit(result)
      return nil unless on?

      receipt = result["receipt"].is_a?(Hash) ? result["receipt"] : {}
      rejection = result["rejection"].is_a?(Hash) ? result["rejection"] : {}
      emit(
        "submit",
        "outcome" => result["state"], "receipt_id" => receipt["receipt_id"] || receipt["id"], "late" => receipt["late"] ? true : false,
        "rejected_as" => rejection["code"].to_s.empty? ? nil : "rejected"
      )
    rescue StandardError
      nil
    end

    def session(harness, source)
      return nil unless on?

      install = begin
        Reach::Enroll.current
      rescue StandardError
        nil
      end
      status = begin
        Reach::Sync.cached_status
      rescue StandardError
        nil
      end
      persona = Reach::Persona.current
      version = ENV["CLAUDE_CODE_EXECPATH"].to_s[/(\d+\.\d+\.\d+)/, 1]
      emit(
        "session",
        "reach" => Reach::VERSION, "ruby" => RUBY_VERSION, "platform" => RUBY_PLATFORM, "harness" => harness, "harness_version" => version,
        "surface" => envelope_context["surface"], "source" => source, "runtime_kit" => (Reach::RuntimeKit.platform rescue nil),
        "install_id" => install && install["install_id"], "course_id" => install && install["course"].is_a?(Hash) ? install["course"]["id"] : nil,
        "persona_id" => Reach::Paths.persona_id, "persona_kind" => persona && persona["kind"],
        "wire_match" => status && status["wire_contract_sha256"] ? status["wire_contract_sha256"] == Reach::Wire.digest : nil
      )
    rescue StandardError
      nil
    end

    def remote_notice(_session = nil)
      return nil unless reason == "remote"

      session_id = envelope_context["session_id"]

      @notices ||= {}
      return @notices[session_id] if @notices.key?(session_id)

      text = nil
      locked do
        state = load_state
        told = state["notice"].is_a?(Hash) ? state["notice"] : {}
        unless told[session_id]
          told[session_id] = true
          told.delete(told.keys.first) while told.size > SESSIONS_KEPT
          state["notice"] = told
          save_state(state)
          text = Reach::Messages.text("M-DEBUG-NOTICE")
        end
      end
      @notices[session_id] = text
    rescue StandardError
      nil
    end

    def read_lines(path)
      return [] unless File.file?(path)

      File.foreach(path).map do |line|
        begin
          parsed = JSON.parse(line)
          parsed.is_a?(Hash) && parsed["event"].is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end
      end.compact
    end

    def sent_files
      Dir.glob(File.join(dir, "sent-*.jsonl")).sort.last(SENT_FILES_READ)
    end

    def read_events
      return [] unless File.directory?(dir)

      seen = {}
      list = []
      (sent_files.flat_map { |path| read_lines(path) } + read_lines(spool_file)).each do |entry|
        id = entry["event"]["id"]
        next if seen[id]

        seen[id] = true
        list << entry
      end
      list
    end

    def counts
      queued = read_lines(spool_file).length
      sent = Dir.glob(File.join(dir, "sent-*.jsonl")).sum { |path| File.foreach(path).count }
      { "queued" => queued, "sent" => sent, "dropped" => load_state["dropped"].to_i }
    rescue StandardError
      { "queued" => 0, "sent" => 0, "dropped" => 0 }
    end

    def pending(session_id)
      state = load_state
      shown = state["shown"].is_a?(Hash) ? state["shown"] : {}
      streams = [session_id, "cli"].uniq
      read_events.select do |entry|
        streams.include?(entry["session_id"]) && entry["event"]["seq"].to_i > shown.fetch(entry["session_id"].to_s, 0).to_i
      end
    end

    def mark_shown(entries)
      return if entries.empty?

      locked do
        state = load_state
        shown = state["shown"].is_a?(Hash) ? state["shown"] : {}
        entries.each do |entry|
          sid = entry["session_id"].to_s
          shown[sid] = [shown[sid].to_i, entry["event"]["seq"].to_i].max
        end
        shown.delete(shown.keys.first) while shown.size > SESSIONS_KEPT
        state["shown"] = shown
        save_state(state)
      end
    end

    def block(session_id, harness, payload, format: nil)
      return nil unless on?

      entries = pending(session_id)
      return nil if entries.empty?

      mark_shown(entries)
      Reach::DebugRender.block(entries, harness: harness, payload: payload, format: format)
    rescue StandardError
      nil
    end

    def prompt_message(event, harness_flag)
      return nil unless on?

      scoped = begin_hook(event, harness_flag)
      return nil if scoped["harness"] == "hermes"

      parts = []
      notice = remote_notice(scoped["session_id"])
      parts << notice if notice
      outside = begin
        Reach::Gate.current_space.nil?
      rescue StandardError
        true
      end
      if outside
        shown = block(scoped["session_id"], scoped["harness"], event)
        parts << shown if shown
      end
      parts.empty? ? nil : parts.join("\n\n")
    rescue StandardError
      nil
    end

    def turn_message(event, harness_flag)
      return nil unless on?

      scoped = begin_hook(event, harness_flag)
      return nil if scoped["harness"] == "hermes"

      block(scoped["session_id"], scoped["harness"], event)
    end

    def stopped(result, why)
      result.merge("stopped" => why)
    end

    def flush(quick: false)
      empty = { "sent" => 0, "batches" => 0, "stopped" => nil }
      return stopped(empty, "empty") unless File.file?(spool_file) && File.size(spool_file).positive?

      install = begin
        Reach::Enroll.current
      rescue StandardError
        nil
      end
      return stopped(empty, "not_enrolled") unless install
      return stopped(empty, "revoked") if install["revoked"]
      return stopped(empty, "offline") if ENV["REACH_OFFLINE"] == "1"

      result = empty
      File.open(flush_lock_file, File::RDWR | File::CREAT, 0o600) do |handle|
        unless handle.flock(File::LOCK_EX | File::LOCK_NB)
          result = stopped(empty, "busy")
          next
        end

        Thread.current[:reach_debug_busy] = true
        begin
          result = run_flush(install, quick)
        ensure
          Thread.current[:reach_debug_busy] = false
          handle.flock(File::LOCK_UN)
        end
      end
      result
    rescue StandardError
      { "sent" => 0, "batches" => 0, "stopped" => "error" }
    end

    def run_flush(install, quick)
      summary = { "sent" => 0, "batches" => 0, "stopped" => nil }
      if quick
        backoff = load_state["backoff_until"].to_f
        return stopped(summary, "backoff") if backoff > Time.now.to_f
      end

      client = Reach::Client.for_install(install, quick: quick)
      limit = quick ? QUICK_MAX_BATCHES : FULL_MAX_BATCHES
      pending_batches.each do |batch|
        if summary["batches"] >= limit
          summary["stopped"] = "batch_budget"
          break
        end

        summary["batches"] += 1
        outcome = send_batch(client, batch)
        case outcome
        when :sent
          summary["sent"] += batch["entries"].length
        when :rejected
          nil
        when :revoked
          Reach::Enroll.mark_revoked!
          summary["stopped"] = "revoked"
          break
        else
          set_backoff(quick)
          summary["stopped"] = outcome.to_s
          break
        end
      end
      summary
    end

    def set_backoff(quick)
      locked do
        state = load_state
        state["backoff_until"] = Time.now.to_f + (quick ? QUICK_BACKOFF_S : 5)
        save_state(state)
      end
    end

    def pending_batches
      entries = read_lines(spool_file)
      max_events = [[config["batch_max_events"].to_i, 1].max, 500].min
      groups = entries.group_by { |entry| entry.values_at("session_id", "harness", "surface", "reason") }
      batches = []
      groups.each do |(session, harness, surface, why), members|
        current = []
        bytes = 0
        members.each do |entry|
          size = JSON.generate(entry["event"]).bytesize + 1
          if !current.empty? && (current.length >= max_events || bytes + size > BATCH_MAX_BYTES)
            batches << { "session_id" => session, "harness" => harness, "surface" => surface, "reason" => why, "entries" => current }
            current = []
            bytes = 0
          end
          current << entry
          bytes += size
        end
        batches << { "session_id" => session, "harness" => harness, "surface" => surface, "reason" => why, "entries" => current } unless current.empty?
      end
      batches
    end

    def send_batch(client, batch)
      body = batch.reject { |name, _| name == "entries" }.merge("events" => batch["entries"].map { |entry| entry["event"] })
      response = client.post_json(ROUTE, body)
      answer = response.json || {}
      retire(batch["entries"], sent_file)
      remember_classification(answer["classification"])
      :sent
    rescue Reach::RemoteRefused => e
      if %w[invalid_request too_large].include?(e.code)
        retire(batch["entries"], rejected_file)
        :rejected
      elsif %w[revoked not_enrolled].include?(e.code)
        :revoked
      else
        e.code.to_s.empty? ? :refused : e.code.to_sym
      end
    rescue Reach::Offline, Reach::NetworkError
      :network
    end

    def remember_classification(value)
      return unless %w[instructor student].include?(value.to_s)

      locked do
        state = load_state
        state["classification"] = value.to_s
        state.delete("backoff_until")
        save_state(state)
      end
    end

    def retire(entries, destination)
      ids = {}
      entries.each { |entry| ids[entry["event"]["id"]] = true }
      locked do
        File.open(destination, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
          entries.each { |entry| file.puts(JSON.generate(entry)) }
        end
        remaining = File.file?(spool_file) ? File.readlines(spool_file).reject { |line| spooled_id_in?(line, ids) } : []
        File.open(spool_file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(remaining.join) }
      end
    end

    def spooled_id_in?(line, ids)
      entry = JSON.parse(line)
      entry.is_a?(Hash) && entry["event"].is_a?(Hash) && ids.key?(entry["event"]["id"])
    rescue JSON::ParserError
      false
    end

    def status
      {
        "on" => on?, "reason" => reason, "until" => until_value, "classification" => load_state["classification"],
        "spool" => counts, "render" => config["render"]
      }
    end
  end
end
