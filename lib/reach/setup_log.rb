require "json"
require "time"
require "fileutils"
require "rbconfig"
require "erb"

module Reach
  module SetupLog
    DEFAULTS = {
      "enabled" => true, "threshold" => 3, "max_bytes" => 20_971_520, "report_max_bytes" => 8_388_608,
      "string_max_bytes" => 65_536, "env_every_s" => 600
    }.freeze
    SCHEMA = "reach.setup-report/v1".freeze
    SAFE = [StandardError, NotImplementedError].freeze
    TYPED_KEY = /\A(?:prompt|user_message|message_text|text|answer|username|email|student_id|first_name|last_name|full_name|display_name|given_name|family_name|middle_name|preferred_name|legal_name|nickname|name|passkey|code)\z/i.freeze
    DEVICE_KEY = /fingerprint|salt|binding|hostname|host_name|machine_id/i.freeze
    ENV_KEEP = /\A(?:PATH|HOME|USERPROFILE|SHELL|LANG|LC_ALL|TERM|TMPDIR|TEMP|XDG_[A-Z_]+|RUBY[A-Z_]*|GEM_[A-Z_]+|BUNDLE_[A-Z_]+|REACH_[A-Z_]+|CLAUDE[A-Z_]*|CODEX[A-Z_]*|HERMES[A-Z_]*|ANTIGRAVITY[A-Z_]*|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|SSL_CERT_FILE|SSL_CERT_DIR)\z/i.freeze
    ENV_DROP = /token|key|secret|password|passphrase|signature|pem|credential|passkey|course_code|enroll_code|enrollment_code/i.freeze
    HEADER_DROP = /\A(?:authorization|proxy-authorization|cookie|set-cookie)\z/i.freeze
    URL_USERINFO = %r{(?<=://)[^/@\s]+@}.freeze
    TYPED_COMMANDS = %w[enroll enrol login remember hand instructor memory profile support live].freeze
    BARE_TYPED_COMMANDS = %w[enroll enrol login remember hand].freeze
    SUCCESS_COMMANDS = %w[setup runtime update enroll enrol].freeze
    FAILURE_IDS = %w[
      M-ENR-FAILED M-ENR-OFFLINE M-ENR-REFUSED M-ENR-LOCKED M-ENR-CODE-UNKNOWN M-ENR-CODE-SUGGEST M-ENR-CODE-EXPIRED
      M-ENR-CODE-OLD M-ENR-PASSWORD-RETRY-FAILED M-ENR-STEP-FAILED M-ENR-PASSWORD-RETRY-OFFLINE M-ENR-MOVE-DENIED
      M-ENR-COURSE-ENDED M-REACH-HICCUP-CLI M-ENR-CLI-OFFLINE M-ENROLL-INCOMPLETE
    ].freeze
    ADVANCE_IDS = %w[
      M-ENR-ASK-USERNAME M-ENR-ASK-ID M-ENR-CONFIRM M-ENR-DONE M-ENR-AGENT-ENROLLED
    ].freeze
    MAX_ITEMS = 256
    MAX_DEPTH = 8
    MAX_FRAMES = 500
    MAX_CAUSES = 5
    LOCK_WAIT_S = 1.0
    MESSAGES_KEPT = 50
    FAILURES_KEPT = 10
    DEBUG_EVENTS_KEPT = 200
    INSTALLER_RECORDS_KEPT = 400
    OS_TTL_S = 86_400
    OFF = "0".freeze

    module_function

    def config
      home = Reach::Paths.home
      return @config_memo[1] if @config_memo && @config_memo[0] == home

      section = Reach::Runtime.load_config["setup_log"]
      section = {} unless section.is_a?(Hash)
      value = DEFAULTS.merge(section.select { |key, given| DEFAULTS.key?(key) && !given.nil? })
      @config_memo = [home, value]
      value
    rescue *SAFE
      DEFAULTS.dup
    end

    def reset!
      @active_memo = nil
      @config_memo = nil
      nil
    end

    def unit!
      Thread.current[:reach_setup_counted] = false
      Thread.current[:reach_setup_messages] = []
      nil
    end

    def env_off?
      ENV["REACH_SETUP_LOG"].to_s == OFF
    end

    def dir
      File.join(Reach::Paths.home, "setup-log")
    end

    def log_file(day = Time.now.utc.strftime("%Y%m%d"))
      File.join(dir, "log-#{day}.jsonl")
    end

    def state_file
      File.join(dir, "state.json")
    end

    def lock_file
      File.join(dir, "lock")
    end

    def now_iso
      Time.now.utc.iso8601(3)
    end

    def active?
      return false if env_off?

      key = [Reach::Paths.home, File.file?(Reach::Paths.install_file)]
      return @active_memo[1] if @active_memo && @active_memo[0] == key

      value = config["enabled"] != false && Reach::Enroll.current.nil? && !Reach::Instructor.mode?
      @active_memo = [key, value]
      value
    rescue *SAFE
      false
    end

    def guard
      return nil if Thread.current[:reach_setup_busy]

      Thread.current[:reach_setup_busy] = true
      begin
        yield
      ensure
        Thread.current[:reach_setup_busy] = false
      end
    rescue *SAFE
      nil
    end

    def safely
      yield
    rescue *SAFE
      nil
    end

    def ensure_dir
      anchor = Reach::Paths.home_anchor
      raise Errno::ENOENT, anchor unless File.directory?(anchor)

      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)
    rescue NotImplementedError
      nil
    end

    def read_json(path)
      return nil unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : nil
    rescue *SAFE
      nil
    end

    def write_atomic(path, text)
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(text) }
      File.rename(tmp, path)
      File.chmod(0o600, path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end

    def read_state
      read_json(state_file) || {}
    end

    def with_state
      ensure_dir
      result = nil
      Reach::Locks.exclusive(lock_file, wait_s: LOCK_WAIT_S) do
        state = read_state
        result = yield(state)
        write_atomic(state_file, JSON.generate(state))
      end
      result
    end

    def next_seq
      @seq = @seq.to_i + 1
    end

    def record(kind, fields = {})
      guard do
        next nil unless active?

        append_record(kind, fields)
      end
      nil
    end

    def append_record(kind, fields)
      context = Reach::Debug.envelope_context
      entry = {
        "at" => now_iso, "pid" => Process.pid, "seq" => next_seq, "kind" => kind.to_s, "reach_version" => Reach::VERSION,
        "persona_id" => Reach::Paths.persona_id, "session_id" => context["session_id"], "harness" => context["harness"],
        "surface" => context["surface"], "fields" => redact(fields)
      }
      line = JSON.generate(entry)
      ensure_dir
      Reach::Locks.exclusive(lock_file, wait_s: LOCK_WAIT_S) do
        File.open(log_file, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |file| file.write("#{line}\n") }
        enforce_limits
      end
      nil
    end

    def kept_files
      Dir.glob(File.join(dir, "{log-*,install-*}.jsonl"))
    end

    def enforce_limits
      limit = config["max_bytes"].to_i
      return unless limit.positive?

      files = kept_files.map { |path| [path, File.size(path), File.mtime(path)] }.sort_by { |entry| [entry[2], entry[0]] }
      total = files.sum { |entry| entry[1] }
      return if total <= limit

      current = log_file
      files.each do |path, size, _mtime|
        break if total <= limit
        next if path == current

        FileUtils.rm_f(path)
        total -= size
      end
      trim_current(current, limit) if total > limit && File.file?(current)
    end

    def trim_current(path, limit)
      lines = File.readlines(path)
      total = lines.sum(&:bytesize)
      while total > (limit * 0.9) && lines.length > 1
        total -= lines.shift.bytesize
      end
      write_atomic(path, lines.join)
    end

    def message_id?(value)
      value.start_with?("M-") && Reach::Messages.catalogue(Reach::Messages::DEFAULT_LOCALE).fetch("messages", {}).key?(value)
    rescue *SAFE
      false
    end

    def scrub_text(text)
      value = text.to_s.dup
      return value if message_id?(value)

      value = value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?") unless value.encoding == Encoding::UTF_8 && value.valid_encoding?
      scrubbed = Reach::Debug::SCRUBBED
      value = value.gsub(Reach::Debug::PEM_BLOCK, scrubbed).gsub(Reach::Debug::RINS, scrubbed).gsub(Reach::Debug::COURSE_SHAPE, scrubbed)
      Reach::Debug.identity_patterns.each { |pattern| value = value.gsub(pattern, scrubbed) }
      value = value.gsub(URL_USERINFO, "#{scrubbed}@")
      value = scrub_homes(value)
      limit = config["string_max_bytes"].to_i
      return value unless limit.positive? && value.bytesize > limit

      cut = value.bytesize - limit
      "#{value.byteslice(0, limit).scrub("")}…[cut #{cut} bytes]"
    end

    def scrub_homes(value)
      Reach::Debug.home_prefixes.each do |home|
        [home, home.tr("/", "\\")].uniq.each do |form|
          value = value.gsub(/#{Regexp.escape(form)}(?=[\\\/]|\z|[^A-Za-z0-9._-])/i, "~")
        end
      end
      value
    rescue StandardError
      value
    end

    def typed_shape(value)
      return value if value.is_a?(Hash) && value["typed"] == true
      return nil if value.nil?
      return "[redacted]" unless value.is_a?(String)

      clean = value.scrub
      { "typed" => true, "length" => clean.length, "lines" => clean.lines.length }
    end

    def redact_env(hash)
      out = {}
      hash.each do |name, value|
        break if out.size >= MAX_ITEMS

        out[scrub_text(name)] = ENV_DROP.match?(name.to_s) ? "[redacted]" : redact(value, nil, 1)
      end
      out
    end

    def redact(value, key = nil, depth = 0)
      return "[deep]" if depth > MAX_DEPTH
      return redact_env(value) if key.to_s == "env" && value.is_a?(Hash)

      if key
        name = key.to_s
        return "[redacted]" if Reach::Debug::DROP_KEY.match?(name) || DEVICE_KEY.match?(name)
        return typed_shape(value) if TYPED_KEY.match?(name)
      end
      case value
      when Hash
        out = {}
        value.each do |name, item|
          break if out.size >= MAX_ITEMS

          out[scrub_text(name)] = redact(item, name, depth + 1)
        end
        out
      when Array
        value.first(MAX_ITEMS).map { |item| redact(item, nil, depth + 1) }
      when String, Symbol
        scrub_text(value)
      when nil, true, false, Integer
        value
      when Float
        value.finite? ? value : nil
      when Time
        value.utc.iso8601(3)
      else
        value.class.name
      end
    end

    def frames(error)
      Array(error.backtrace).first(MAX_FRAMES).map { |frame| frame.to_s.sub("#{Reach::Debug::PLUGIN_ROOT}/", "") }
    end

    def causes(error)
      list = []
      current = error.respond_to?(:cause) ? error.cause : nil
      while current && list.length < MAX_CAUSES
        list << { "class" => current.class.name, "message" => current.message.to_s, "frames" => frames(current) }
        current = current.cause
      end
      list
    end

    def error_fields(error)
      return {} unless error
      return { "exception" => error.class.name, "message_id" => error.message_id } if error.respond_to?(:message_id)

      { "exception" => error.class.name, "message" => error.message.to_s, "backtrace" => frames(error), "causes" => causes(error) }
    end

    def redact_argv(argv)
      tokens = Array(argv).map(&:to_s)
      name = tokens.first.to_s
      typed = TYPED_COMMANDS.include?(name)
      hide = false
      tokens.each_with_index.map do |token, index|
        if index.zero?
          token
        elsif token.start_with?("--")
          flag, given = token.split("=", 2)
          bare = flag.sub(/\A-+/, "").tr("-", "_")
          sensitive = Reach::Debug::DROP_KEY.match?(bare) || TYPED_KEY.match?(bare)
          hide = sensitive && given.nil?
          if given.nil?
            scrub_text(flag)
          else
            sensitive ? "#{flag}=[redacted]" : scrub_text(token)
          end
        elsif hide
          hide = false
          "[redacted]"
        elsif typed && !(index == 1 && !BARE_TYPED_COMMANDS.include?(name) && token.match?(/\A[a-z][a-z-]{0,23}\z/))
          "[redacted]"
        else
          scrub_text(token)
        end
      end
    end

    def redact_path(path)
      base, query = path.to_s.split("?", 2)
      return scrub_text(base) unless query

      pairs = query.split("&").map { |pair| "#{pair.split("=", 2).first}=[redacted]" }
      scrub_text("#{base}?#{pairs.join("&")}")
    end

    def redact_headers(headers)
      return {} unless headers.respond_to?(:each_pair)

      out = {}
      headers.each_pair do |name, value|
        next if HEADER_DROP.match?(name.to_s) || Reach::Debug::DROP_KEY.match?(name.to_s)

        out[name.to_s] = value.is_a?(Array) ? value.join(", ") : value.to_s
      end
      redact(out)
    end

    def parsed_body(body)
      return redact(body) if body.is_a?(Hash) || body.is_a?(Array)

      text = body.to_s
      return nil if text.empty?

      redact(JSON.parse(text))
    rescue JSON::ParserError
      scrub_text(text)
    end

    def command(argv, exit_value, duration_ms, raised = nil)
      guard do
        next nil unless active?

        name = Array(argv).first.to_s
        fields = {
          "command" => name, "argv" => redact_argv(argv), "exit" => exit_value, "duration_ms" => duration_ms
        }.merge(error_fields(raised))
        append_record("command", fields)
        result = command_result(argv, name, exit_value, raised)
        tally(result, "where" => "command:#{name}", "exit" => exit_value, "exception" => raised ? raised.class.name : nil) if result
      end
      nil
    end

    def lock_refusal?
      locks = Reach::EnrollmentLock::MESSAGES.values + ["M-GATE-NOENROLL"]
      Array(Thread.current[:reach_setup_messages]).any? { |id| locks.include?(id) }
    rescue *SAFE
      false
    end

    def command_result(argv, name, exit_value, raised)
      return :failure if classify_messages == :failure
      return nil if lock_refusal?
      return nil if name == "mcp" || raised.is_a?(Reach::GateBlocked)
      return nil if Reach::CLI.hook_invocation?(Array(argv))
      return :failure if exit_value.to_i != 0 || (exit_value.nil? && raised)

      SUCCESS_COMMANDS.include?(name) ? :success : nil
    rescue *SAFE
      nil
    end

    def hook(event, decision, rule, space, latency_ms)
      record("hook", "event" => event, "decision" => decision, "rule" => rule, "space" => space, "latency_ms" => latency_ms)
    end

    def http(method, path, status, error_name, request_id, attempt, latency_ms, bytes_out, bytes_in, extra = nil)
      fields = {
        "method" => method.to_s.upcase, "path" => redact_path(path), "status" => status, "error" => error_name,
        "request_id" => request_id, "attempt" => attempt, "latency_ms" => latency_ms, "bytes_out" => bytes_out, "bytes_in" => bytes_in
      }
      fields.merge!(extra) if extra.is_a?(Hash)
      record("http", fields)
    end

    def fault(error, fields, where)
      guard do
        next nil unless active?

        append_record("fault", fields.merge(error_fields(error)))
        tally(:failure, "where" => where, "exception" => error.class.name)
      end
      nil
    end

    def mcp(tool, action, ok, duration_ms, error, failure)
      guard do
        next nil unless active?

        append_record("mcp", "tool" => tool.to_s, "action" => action, "ok" => ok, "duration_ms" => duration_ms, "error" => error)
        tally(:failure, "where" => "mcp:#{tool}", "error" => error) if failure && !lock_refusal?
      end
      nil
    end

    def note_message(id, fields = {})
      return nil if Thread.current[:reach_setup_busy]
      return nil unless active?

      list = (Thread.current[:reach_setup_messages] ||= [])
      list << id.to_s
      list.shift while list.length > MESSAGES_KEPT
      record("message", "id" => id.to_s, "params" => fields.keys.map(&:to_s))
      nil
    rescue *SAFE
      nil
    end

    def noted
      Array(Thread.current[:reach_setup_messages]).dup
    end

    def classify_messages
      ids = Array(Thread.current[:reach_setup_messages])
      return :failure if ids.any? { |id| FAILURE_IDS.include?(id) }
      return :success if ids.any? { |id| ADVANCE_IDS.include?(id) }

      nil
    end

    def outcome!(result, fields = {})
      guard { tally(result, fields) }
      nil
    end

    def tally(result, fields)
      return nil unless active?
      return nil if Thread.current[:reach_setup_counted]

      Thread.current[:reach_setup_counted] = true
      summary = redact(fields)
      streak = nil
      with_state do |state|
        if result == :success
          state["streak"] = 0
          state["last_success_at"] = now_iso
        else
          state["streak"] = state["streak"].to_i + 1
          failures = Array(state["failures"])
          failures << { "at" => now_iso }.merge(summary)
          state["failures"] = failures.last(FAILURES_KEPT)
        end
        streak = state["streak"]
      end
      append_record("outcome", { "result" => result.to_s, "streak" => streak }.merge(fields))
      threshold = [config["threshold"].to_i, 1].max
      if result == :failure && streak && streak.positive? && (streak % threshold).zero?
        path = export_report("streak")
        if path
          offer = { "path" => path, "link" => link(path), "at" => now_iso, "streak" => streak, "shown" => false }
          with_state { |state| state["offer"] = offer }
        end
      end
      nil
    end

    def succeeded!(fields = {})
      return nil if env_off? || config["enabled"] == false

      guard do
        streak_was = nil
        with_state do |state|
          streak_was = state["streak"].to_i
          state["streak"] = 0
          state["last_success_at"] = now_iso
          state.delete("offer")
        end
        append_record("outcome", { "result" => "success", "streak" => 0, "streak_cleared" => streak_was }.merge(fields))
      end
      nil
    end

    def take_offer!
      return nil if env_off? || !File.file?(state_file)

      text = nil
      guard do
        pending = read_state["offer"]
        next nil unless pending.is_a?(Hash) && pending["shown"] != true

        with_state do |state|
          offer = state["offer"]
          next unless offer.is_a?(Hash) && offer["shown"] != true

          offer["shown"] = true
          text = Reach::Messages.text("M-SETUP-REPORT-SAVED", count: offer["streak"], path: offer["path"], link: offer["link"])
        end
      end
      text
    rescue *SAFE
      nil
    end

    def environment(os_data)
      kit = safely { { "kit_id" => Reach::RuntimeKit.current_id, "platform" => Reach::RuntimeKit.platform } }
      flow = safely { Reach::EnrollFlow.read_flow }
      {
        "reach_version" => Reach::VERSION, "plugin_root" => Reach::Debug::PLUGIN_ROOT, "home" => Reach::Paths.home,
        "ruby" => {
          "version" => RUBY_VERSION, "platform" => RUBY_PLATFORM, "engine" => defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby",
          "engine_version" => defined?(RUBY_ENGINE_VERSION) ? RUBY_ENGINE_VERSION : RUBY_VERSION,
          "executable" => RbConfig.ruby, "patchlevel" => RUBY_PATCHLEVEL
        },
        "os" => os_data, "cwd" => safely { Dir.pwd }, "argv0" => $PROGRAM_NAME, "pid" => Process.pid, "ppid" => safely { Process.ppid },
        "env" => ENV.to_h.select { |name, _| ENV_KEEP.match?(name) },
        "teach_url" => safely { Reach::EnrollFlow.teach_url }, "runtime" => kit,
        "enrollment_lock" => safely { Reach::EnrollmentLock.state },
        "enroll_flow_state" => flow.is_a?(Hash) ? flow["state"] : nil
      }
    end

    def os_fresh
      Reach::OsInfo.read_cache || Reach::OsInfo.clean(Reach::OsInfo.collect)
    rescue *SAFE
      {}
    end

    def os_cached(state)
      stored = state["os"]
      if stored.is_a?(Hash) && stored["data"].is_a?(Hash)
        at = safely { Time.iso8601(stored["at"].to_s) }
        return [stored["data"], nil] if at && Time.now - at < OS_TTL_S
      end
      data = os_fresh
      [data, { "at" => now_iso, "data" => data }]
    end

    def record_environment!
      guard do
        next nil unless active?

        state = read_state
        at = safely { Time.iso8601(state["env_at"].to_s) }
        next nil if at && Time.now - at < config["env_every_s"].to_i

        data, stamp = os_cached(state)
        with_state do |current|
          current["env_at"] = now_iso
          current["os"] = stamp if stamp
        end
        append_record("environment", environment(data))
      end
      nil
    end

    def status
      files = kept_files
      state = read_state
      {
        "enabled" => !env_off? && config["enabled"] != false, "active" => active?, "streak" => state["streak"].to_i,
        "files" => files.length, "bytes" => files.sum { |path| safely { File.size(path) }.to_i }
      }
    rescue *SAFE
      { "enabled" => false, "active" => false, "streak" => 0, "files" => 0, "bytes" => 0 }
    end

    def last_error
      @last_error
    end

    def read_jsonl(paths)
      paths.flat_map do |path|
        File.foreach(path).map do |line|
          parsed = JSON.parse(line)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end.compact
      end
    rescue *SAFE
      []
    end

    def log_tail(budget)
      kept = []
      used = 0
      trimmed = 0
      full = false
      Dir.glob(File.join(dir, "log-*.jsonl")).sort.reverse_each do |path|
        File.readlines(path).reverse_each do |line|
          next if line.strip.empty?

          if full
            trimmed += 1
            next
          end
          parsed = safely { JSON.parse(line) }
          next unless parsed.is_a?(Hash)

          if used + line.bytesize > budget
            full = true
            trimmed += 1
            next
          end
          used += line.bytesize
          kept << parsed
        end
      end
      [kept.reverse, trimmed]
    rescue *SAFE
      [[], 0]
    end

    def build_report(reason)
      state = read_state
      installer = read_jsonl(Dir.glob(File.join(dir, "install-*.jsonl")).sort).last(INSTALLER_RECORDS_KEPT).map { |item| redact(item) }
      report = {
        "schema" => SCHEMA, "created_at" => now_iso, "reason" => reason, "reach_version" => Reach::VERSION,
        "streak" => state["streak"].to_i, "recent_failures" => redact(Array(state["failures"])),
        "environment" => redact(environment(os_fresh)), "installer" => installer,
        "debug_events" => redact(safely { Reach::Debug.read_events.last(DEBUG_EVENTS_KEPT) } || []),
        "issues" => redact(safely { Reach::Issues.list } || [])
      }
      limit = config["report_max_bytes"].to_i
      base = JSON.generate(report.merge("log" => [], "log_trimmed" => 0)).bytesize
      records, trimmed = log_tail([limit - base - 4096, 0].max)
      records = records.map { |item| redact(item) }
      loop do
        report["log"] = records
        report["log_trimmed"] = trimmed
        json = JSON.generate(report)
        return json if json.bytesize <= limit || records.empty?

        drop = [records.length / 10, 1].max
        records = records.drop(drop)
        trimmed += drop
      end
    end

    def report_name
      "reach-setup-report-#{Time.now.utc.strftime("%Y%m%d-%H%M%S")}.json"
    end

    def unique_path(folder, name)
      path = File.join(folder, name)
      index = 1
      while File.exist?(path)
        index += 1
        path = File.join(folder, name.sub(/\.json\z/, "-#{index}.json"))
      end
      path
    end

    def report_folders
      first = begin
        folder = Reach::Archive.downloads_dir
        FileUtils.mkdir_p(folder, mode: 0o700) unless File.directory?(folder)
        File.writable?(folder) ? folder : nil
      rescue *SAFE
        nil
      end
      [first, File.join(dir, "reports")].compact
    end

    def write_report(json)
      failure = nil
      report_folders.each do |folder|
        begin
          FileUtils.mkdir_p(folder, mode: 0o700)
          path = unique_path(folder, report_name)
          write_atomic(path, json)
          return path
        rescue *SAFE => e
          failure = e
        end
      end
      raise failure || RuntimeError.new("no folder to write to")
    end

    def export_report(reason)
      @last_error = nil
      json = build_report(reason)
      path = write_report(json)
      append_record("export", "path" => path, "bytes" => json.bytesize, "reason" => reason) if active?
      path
    rescue *SAFE => e
      @last_error = e.message.to_s
      nil
    end

    def export!(reason: "manual")
      path = nil
      @last_error = nil
      guard { path = export_report(reason) }
      @last_error ||= "rEach was busy writing its log; please try again" if path.nil?
      path
    end

    def link(path)
      text = path.to_s.tr("\\", "/")
      text = "/#{text}" if text.match?(/\A[A-Za-z]:/)
      encoded = text.split("/", -1).map do |segment|
        segment.match?(/\A[A-Za-z]:\z/) ? segment : ERB::Util.url_encode(segment)
      end
      "file://#{encoded.join("/")}"
    end
  end
end
