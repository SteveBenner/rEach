require "json"
require "time"
require "open3"
require "timeout"
require "tmpdir"
require "fileutils"
require "securerandom"
require "rbconfig"

module Reach
  module Uninstall
    ROUTE = "/api/v1/installs/withdraw".freeze
    KIND = "install_withdraw".freeze
    SCRIPT_MISSING = "rEach's uninstall script is missing from this install. Follow UNINSTALL.md to download it, then run it.".freeze
    SWITCHED_OFF = "rEach uninstall is switched off on this computer.".freeze
    USAGE = "usage: reach uninstall [--no-receipts-copy] [--purge-checkpoint-mirror] [--delete-hermes-profile] [--keep-workspace-files] [--purge-microbrain] [--no-teach] [--yes] [--format text|json]".freeze
    AGENT_ASK_HINT = "Ask the student with your own question tool, then run this again with --yes.".freeze
    RPLUGIN_HINT = "If you installed rEach with rplugin, also run: rplugin uninstall reach".freeze
    SCRIPT_FLAGS = %w[--no-receipts-copy --purge-checkpoint-mirror --delete-hermes-profile --keep-workspace-files --purge-microbrain].freeze
    TOGGLES = (SCRIPT_FLAGS + %w[--no-teach --yes]).freeze
    HARNESS_NAMES = { "claude-code" => "Claude Code", "codex" => "Codex", "antigravity" => "Antigravity", "hermes" => "Hermes" }.freeze
    OUTBOX_NAMES = { "submissions" => ["submission", "submissions"], "hands" => ["hand raise", "hand raises"], "issues" => ["issue report", "issue reports"], "other" => ["other item", "other items"] }.freeze
    HANDOVER_TIMEOUT_S = 900
    TEACH_TIMEOUT_S = 25
    SENTINELS = { kept: "\u0001KEPT\u0001", teach: "\u0001TEACH\u0001", receipts: "\u0001RECEIPTS\u0001", left: "\u0001LEFT\u0001", folder: "\u0001FOLDER\u0001", items: "\u0001ITEMS\u0001" }.freeze

    module_function

    def script_path
      File.join(Reach::Runtime.root, "scripts", "reach-uninstall")
    end

    def load_script!
      return if defined?(::ReachUninstall)

      raise Reach::Error, SCRIPT_MISSING unless File.file?(script_path)

      Kernel.load(script_path)
      raise Reach::Error, SCRIPT_MISSING unless defined?(::ReachUninstall)
    end

    def parse(args)
      options = { toggles: [], format: "text" }
      list = args.dup
      until list.empty?
        token = list.shift
        if token == "--format"
          value = list.shift
          return nil unless %w[text json].include?(value)

          options[:format] = value
        elsif TOGGLES.include?(token)
          options[:toggles] << token unless options[:toggles].include?(token)
        else
          return nil
        end
      end
      options
    end

    def run(args)
      options = parse(args)
      unless options
        warn USAGE
        return 2
      end
      if ENV["REACH_UNINSTALL_KILL_SWITCH"] == "1"
        warn SWITCHED_OFF
        return 2
      end

      load_script!
      flags = script_flags(options[:toggles])
      plan = JSON.parse(JSON.generate(ReachUninstall.plan(flags)))
      unless plan["installed"]
        say(options, "installed" => false, "text" => Reach::Messages.text("M-UNINSTALL-NOT-INSTALLED"))
        return 0
      end

      context = build_context(options, plan, flags)
      confirmation = confirm(options, context)
      return confirmation[:exit] if confirmation[:exit]

      prepare_and_hand_over(options, context, confirmation)
    rescue Reach::Error => e
      warn e.message
      1
    end

    def say(options, data)
      if options[:format] == "json"
        puts JSON.pretty_generate({ "schema" => "reach.uninstall.result/v1", "ok" => true }.merge(data))
      else
        puts data["text"]
      end
    end

    def script_flags(toggles)
      {
        "receipts_copy" => !toggles.include?("--no-receipts-copy"),
        "purge_checkpoint_mirror" => toggles.include?("--purge-checkpoint-mirror"),
        "delete_hermes_profile" => toggles.include?("--delete-hermes-profile"),
        "keep_workspace_files" => toggles.include?("--keep-workspace-files"),
        "purge_microbrain" => toggles.include?("--purge-microbrain")
      }
    end

    def tilde(path)
      home = Reach::Paths.user_home.to_s
      text = path.to_s
      return text if home.empty?
      return "~" if text == home
      return "~#{text[home.length..-1]}" if text.start_with?(home + "/") || text.start_with?(home + "\\")

      text
    end

    def sentence_list(items)
      list = items.map(&:to_s).reject(&:empty?)
      return "" if list.empty?
      return list.first if list.length == 1
      return "#{list[0]} and #{list[1]}" if list.length == 2

      "#{list[0...-1].join(', ')}, and #{list.last}"
    end

    def teach_enabled?(toggles)
      return false if toggles.include?("--no-teach")
      return false if ENV["REACH_UNINSTALL_TELL_TEACH"] == "0"

      true
    end

    def enrolled_install
      install = Reach::Enroll.current
      install.is_a?(Hash) && install["install_id"] && install["student_id"] ? install : nil
    rescue StandardError
      nil
    end

    def locked?
      Reach::EnrollmentLock.state["locked"] ? true : false
    rescue StandardError
      false
    end

    def build_context(options, plan, flags)
      install = enrolled_install
      consent_case = install && !locked? ? :consent : :flag
      teach_planned = consent_case == :consent && teach_enabled?(options[:toggles]) && ENV["REACH_OFFLINE"] != "1"
      homes = plan["homes"].to_a.select { |home| home["refused"].nil? }.map { |home| tilde(home["path"]) }
      found = plan["harnesses"].to_a.select { |harness| harness["found"] }.map { |harness| HARNESS_NAMES.fetch(harness["id"].to_s, harness["id"].to_s) }
      kept = plan["kept"].to_a.map { |path| tilde(path) }
      {
        plan: plan, flags: flags, install: install, consent_case: consent_case, teach_planned: teach_planned,
        kept_text: sentence_list(kept), kept_paths: kept,
        fields: {
          homes: homes.join(" and "),
          harnesses: found.empty? ? "your AI apps" : sentence_list(found),
          kept: sentence_list(kept),
          unsent: unsent_text(plan),
          receipts: receipts_text(plan),
          mirror: mirror_text(plan, flags),
          microbrain: microbrain_text(plan, flags),
          teach: teach_planned ? Reach::Messages.text("M-UNINSTALL-TEACH") : ""
        },
        messages: render_messages
      }
    end

    def unsent_text(plan)
      outbox = plan["outbox"].is_a?(Hash) ? plan["outbox"] : {}
      total = outbox["total"].to_i
      return "" unless total.positive?

      kinds = outbox["kinds"].is_a?(Hash) ? outbox["kinds"] : {}
      parts = OUTBOX_NAMES.map do |key, (one, many)|
        count = kinds[key].to_i
        count.positive? ? "#{count} #{count == 1 ? one : many}" : nil
      end.compact
      Reach::Messages.text("M-UNINSTALL-UNSENT", count: total, kinds: sentence_list(parts))
    end

    def receipts_text(plan)
      receipts = plan["receipts"].is_a?(Hash) ? plan["receipts"] : {}
      return "" if receipts["copy_to"].to_s.empty?

      Reach::Messages.text("M-UNINSTALL-RECEIPTS", folder: tilde(receipts["copy_to"]))
    end

    def mirror_text(plan, flags)
      records = %w[checkpoint_mirror sidecar].map do |key|
        entry = plan[key].is_a?(Hash) ? plan[key] : {}
        entry["exists"] && !entry["path"].to_s.empty? ? tilde(entry["path"]) : nil
      end.compact
      return "" if records.empty?

      id = flags["purge_checkpoint_mirror"] ? "M-UNINSTALL-MIRROR-PURGE" : "M-UNINSTALL-MIRROR-KEEP"
      Reach::Messages.text(id, records: records.join(" and "))
    end

    def microbrain_text(plan, flags)
      brain = plan["microbrain"].is_a?(Hash) ? plan["microbrain"] : {}
      places = ([brain["exists"] ? brain["path"] : nil] + Array(brain["spools"])).compact.map { |path| tilde(path) }
      return "" if places.empty?

      id = flags["purge_microbrain"] ? "M-UNINSTALL-BRAIN-PURGE" : "M-UNINSTALL-BRAIN-KEEP"
      Reach::Messages.text(id, records: places.join(" and "))
    end

    def render_messages
      why = %w[OFFLINE UNREACHABLE ENDED UNSUPPORTED SKIPPED BUSY ERROR].each_with_object({}) do |code, memo|
        memo[code.downcase] = Reach::Messages.text("M-UNINSTALL-WHY-#{code}")
      end
      {
        declined: Reach::Messages.text("M-UNINSTALL-DECLINED"),
        no_session: Reach::Messages.text("M-UNINSTALL-NO-SESSION"),
        needs_consent: Reach::Messages.text("M-UNINSTALL-NEEDS-CONSENT"),
        told: Reach::Messages.text("M-UNINSTALL-TOLD"),
        failed_told: Reach::Messages.text("M-UNINSTALL-FAILED-TOLD"),
        not_told: why.each_with_object({}) { |(code, reason), memo| memo[code] = Reach::Messages.text("M-UNINSTALL-NOT-TOLD", reason: reason) },
        receipts_saved: Reach::Messages.text("M-UNINSTALL-RECEIPTS-SAVED", folder: SENTINELS[:folder]),
        left: Reach::Messages.text("M-UNINSTALL-LEFT", items: SENTINELS[:items]),
        done: Reach::Messages.text("M-UNINSTALL-DONE", kept: SENTINELS[:kept], teach: SENTINELS[:teach], receipts: SENTINELS[:receipts], left: SENTINELS[:left])
      }
    end

    def terminal?
      $stdin.tty? && $stdout.tty?
    end

    def confirm(options, context)
      toggles = options[:toggles]
      messages = context[:messages]
      yes_flag = toggles.include?("--yes")

      if terminal?
        puts Reach::Messages.text("M-UNINSTALL-ASK", **context[:fields])
        print "Type yes to remove rEach: "
        $stdout.flush
        answer = $stdin.gets.to_s.strip.downcase
        unless %w[yes y].include?(answer)
          puts messages[:declined]
          return { exit: 4 }
        end

        return { consent: nil, via: :terminal }
      end

      if context[:consent_case] == :consent
        if yes_flag
          warn messages[:needs_consent]
          return { exit: 3 }
        end
        subject = { "install_id" => context[:install]["install_id"] }
        if Reach::Consent.declined?(kind: KIND, subject: subject)
          Reach::Consent.clear_declined!(kind: KIND, subject: subject)
          puts messages[:declined]
          return { exit: 4 }
        end
        consent = Reach::Consent.take!(kind: KIND, subject: subject)
        return { consent: consent, via: :consent } if consent

        unless Reach::Workspace.space_for(Reach::Paths.cwd)
          puts messages[:no_session]
          return { exit: 3 }
        end
        puts Reach::Consent.ask!(kind: KIND, subject: subject, message_id: "M-UNINSTALL-ASK", fields: context[:fields])
        return { exit: 3 }
      end

      return { consent: nil, via: :flag } if yes_flag

      puts Reach::Messages.text("M-UNINSTALL-ASK", **context[:fields])
      puts AGENT_ASK_HINT
      { exit: 3 }
    end

    def tell_teach(install, consent, toggles)
      return { "state" => "skipped", "reason" => "not_enrolled" } unless install && consent
      return { "state" => "not_told", "reason" => "skipped" } unless teach_enabled?(toggles)
      return { "state" => "not_told", "reason" => "offline" } if ENV["REACH_OFFLINE"] == "1"

      body = { "consent" => consent, "client_created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
      Timeout.timeout(TEACH_TIMEOUT_S) do
        client = Reach::Client.for_install(install, connect_timeout: 5, read_timeout: 10, max_retries: 1, quiet: true)
        client.post_json(ROUTE, body, idempotency_key: SecureRandom.uuid)
      end
      { "state" => "told", "reason" => nil }
    rescue Reach::Offline
      { "state" => "not_told", "reason" => "offline" }
    rescue Reach::NetworkError => e
      { "state" => "not_told", "reason" => e.cause_name.to_s == "http_429" ? "busy" : "unreachable" }
    rescue Timeout::Error
      { "state" => "not_told", "reason" => "unreachable" }
    rescue Reach::RemoteRefused => e
      { "state" => "not_told", "reason" => refusal_reason(e) }
    rescue StandardError
      { "state" => "not_told", "reason" => "error" }
    end

    def refusal_reason(error)
      case error.code.to_s
      when "revoked", "not_enrolled" then "ended"
      when "forbidden", "rate_limited" then "busy"
      when "not_found" then "unsupported"
      else error.status.to_i == 404 ? "unsupported" : "error"
      end
    end

    def unconfigure_codex
      return { "state" => "nothing", "text" => "Codex settings were not touched.", "left" => [] } unless Reach::CodexSetup.respond_to?(:unconfigure!)
      return { "state" => "nothing", "text" => "No Codex settings file.", "left" => [] } unless File.file?(Reach::CodexSetup.config_path)

      result = Reach::CodexSetup.unconfigure!
      result.is_a?(Hash) ? result : { "state" => "nothing", "text" => "", "left" => [] }
    rescue StandardError
      { "state" => "unsafe", "text" => "Codex settings could not be checked.", "left" => ["Open your Codex settings file and remove the rEach entries by hand."] }
    end

    def safe_tmpdir
      dir = Dir.mktmpdir("reach-uninstall-")
      real = File.realpath(dir)
      forbidden = [Reach::Paths.root, Reach::Paths.workspace_base, Reach::Paths.legacy_home].compact.map { |path| File.expand_path(path) }
      inside = forbidden.any? { |path| real == path || real.start_with?(path + File::SEPARATOR) }
      if inside
        FileUtils.remove_entry(dir)
        raise Reach::Refused, "rEach cannot find a safe temporary folder to finish the removal, so nothing was removed."
      end
      dir
    end

    def prepare_and_hand_over(options, context, confirmation)
      toggles = options[:toggles]
      messages = context[:messages]
      via = confirmation[:via]
      teach = case via
              when :terminal then { "state" => "not_told", "reason" => "skipped" }
              when :flag then { "state" => "skipped", "reason" => "not_enrolled" }
              else tell_teach(context[:install], confirmation[:consent], toggles)
              end
      codex = unconfigure_codex
      dir = safe_tmpdir
      begin
        prepared = File.join(dir, "prepared.json")
        File.open(prepared, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.generate("teach" => teach, "codex_config" => codex))
        end
        copy = File.join(dir, "reach-uninstall")
        FileUtils.cp(script_path, copy)
        command = [RbConfig.ruby, copy, "apply", "--yes", "--format", "json", "--prepared", prepared] + (toggles & SCRIPT_FLAGS)
        quiet!
        stdout, status = run_script(command)
      ensure
        FileUtils.remove_entry(dir) if dir && File.exist?(dir)
      end
      finish(options, context, teach, messages, stdout, status)
    end

    def quiet!
      ENV["REACH_SETUP_LOG"] = "0"
      Thread.current[:reach_debug_silent] = true
    end

    def run_script(command)
      out = nil
      code = nil
      Open3.popen3(*command, chdir: Reach::Paths.user_home) do |stdin, stdout, stderr, waiter|
        stdin.close
        readers = [Thread.new { out = stdout.read }, Thread.new { stderr.read }]
        if waiter.join(HANDOVER_TIMEOUT_S)
          readers.each(&:join)
          code = waiter.value.exitstatus
        else
          begin
            Process.kill("KILL", waiter.pid)
          rescue SystemCallError
            nil
          end
          readers.each { |reader| reader.join(2) }
          code = 1
        end
      end
      [out.to_s, code.nil? ? 1 : code]
    rescue SystemCallError, IOError
      ["", 1]
    end

    def parse_result(stdout)
      stdout.to_s.lines.reverse_each do |line|
        text = line.strip
        next unless text.start_with?("{")

        data = begin
          JSON.parse(text)
        rescue JSON::ParserError
          nil
        end
        return data if data.is_a?(Hash)
      end
      data = begin
        JSON.parse(stdout.to_s)
      rescue JSON::ParserError
        nil
      end
      return data if data.is_a?(Hash)

      start = stdout.to_s.index("{")
      return nil unless start

      data = begin
        JSON.parse(stdout.to_s[start..-1])
      rescue JSON::ParserError
        nil
      end
      data.is_a?(Hash) ? data : nil
    end

    def teach_sentence(teach, messages)
      case teach["state"]
      when "told" then messages[:told]
      when "not_told" then messages[:not_told].fetch(teach["reason"].to_s, messages[:not_told]["error"])
      else ""
      end
    end

    def final_text(result, teach, messages, context)
      receipts = result["receipts_copy"].to_s.empty? ? "" : messages[:receipts_saved].sub(SENTINELS[:folder]) { tilde(result["receipts_copy"]) }
      items = Array(result["left"]).map { |item| item.is_a?(Hash) ? item["what"].to_s : item.to_s }.reject(&:empty?)
      left = items.empty? ? "" : messages[:left].sub(SENTINELS[:items]) { items.join("; ") }
      text = messages[:done]
             .sub(SENTINELS[:kept]) { context[:kept_text] }
             .sub(SENTINELS[:teach]) { teach_sentence(teach, messages) }
             .sub(SENTINELS[:receipts]) { receipts }
             .sub(SENTINELS[:left]) { left }
      hint = result["rplugin_hint"] ? RPLUGIN_HINT : nil
      [text, hint].compact.join("\n")
    end

    def failure_text(result, status, teach, messages)
      steps = result ? Array(result["steps"]).select { |step| step.is_a?(Hash) && %w[failed skipped].include?(step["status"]) && !step["detail"].to_s.empty? } : []
      detail = steps.map { |step| step["detail"].to_s }.join("; ")
      detail = "the removal did not finish" if detail.empty?
      told = teach["state"] == "told" ? messages[:failed_told] : ""
      "rEach could not finish removing itself (#{detail}). Nothing of your work was touched.#{told} Exit code #{status}."
    end

    def finish(options, context, teach, messages, stdout, status)
      result = parse_result(stdout)
      ok = result && result["ok"] == true && status.zero?
      text = ok ? final_text(result, teach, messages, context) : failure_text(result, status, teach, messages)
      if options[:format] == "json"
        merged = (result || { "schema" => "reach.uninstall.result/v1", "ok" => false }).merge("teach" => teach, "text" => text)
        puts JSON.pretty_generate(merged)
      else
        puts text
      end
      status
    end
  end
end
