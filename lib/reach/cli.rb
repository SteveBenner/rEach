require "json"
require "timeout"
require "fileutils"
require "yaml"
require "time"
require "shellwords"

module Reach
  module CLI
    STDIN_GRACE_S = 0.5

    class << self
      def run(argv)
        begin
          Reach::Runtime.ensure_shim!
        rescue StandardError
          nil
        end

        args = argv.dup
        command = args.shift

        case command
        when nil, "--help", "-h", "help"
          print_usage
          0
        when "enrol"
          cmd_enrol(args)
        when "sync"
          cmd_sync(args)
        when "status"
          cmd_status(args)
        when "work"
          cmd_work(args)
        when "start"
          cmd_start(args)
        when "gate"
          cmd_gate(args)
        when "shape"
          cmd_shape(args)
        when "tips"
          cmd_tips(args)
        when "submit"
          cmd_submit(args)
        when "receipts"
          cmd_receipts(args)
        when "hand"
          cmd_hand(args)
        when "watch"
          cmd_watch(args)
        when "doctor"
          cmd_doctor(args)
        when "lock"
          cmd_lock(args)
        when "mcp"
          cmd_mcp(args)
        when "hello"
          cmd_hello(args)
        when "setup"
          cmd_setup(args)
        when "profile"
          cmd_profile(args)
        when "attempts"
          cmd_attempts(args)
        when "check"
          cmd_check(args)
        when "checkpoint"
          cmd_checkpoint(args)
        when "plan"
          cmd_plan(args)
        when "directive"
          cmd_directive(args)
        else
          warn "reach: unknown command #{command.inspect}"
          print_usage
          1
        end
      rescue Reach::GateBlocked => e
        warn e.message
        2
      rescue Reach::Error => e
        warn e.message
        1
      end

      private

      def print_usage
        puts <<~USAGE
          usage: reach <command> [options]

          commands:
            enrol <code> [--teach-url URL]       generate keys and enrol with Teach
            sync                                 fetch new packages and refresh workspaces
            status                               enrolment, slices, receipts, open hands
            work [--harness ...] [--slice ...]   open a slice in the chosen harness
            start [--harness ...]                launch a harness outside a course workspace
            gate session|prompt|write|shell      called by harness hooks
            shape check [--changed <path>] [--format text|agent|json]
            tips [--slice ...]                   run the tips suite
            submit [--slice ...]                 submit and wait for the receipt
            receipts [wait|show]                 receipts
            hand raise|status|list               hand-raises
            watch [--slice ...]                  polling shape-check backstop for Codex
            doctor                               check the local install, one line per problem
            lock                                 wipe the decrypted vault
            mcp                                  the stdio MCP bridge
            hello [--harness ...] [--format ...] [--source ...]   session-start greeting
            setup [--harness auto|claude-code|codex|antigravity] [--source ...] [--format ...]
            profile show|save|forget             the student's saved interview answers
            attempts settle [--slice ...]        settle recent attempt counters
            check [--changed <path>] [--format text|agent|json]   check the slice's code against the rules
            checkpoint save|list|show|restore    snapshots of the slice's files, kept by rEach
            plan save|show|note                  the slice plan
            directive <OPCODE> | --list          a directive's full text
        USAGE
      end

      def parse_flags(args, keys)
        options = {}
        remaining = []
        index = 0
        while index < args.length
          token = args[index]
          flag_key = keys.find { |key| token == "--#{key.to_s.tr('_', '-')}" }
          if flag_key
            options[flag_key] = args[index + 1]
            index += 2
          else
            remaining << token
            index += 1
          end
        end
        [options, remaining]
      end

      def parse_bare_flag(args, name)
        found = args.include?("--#{name}")
        remaining = args.reject { |token| token == "--#{name}" }
        [found, remaining]
      end

      def resolve_workspace(slice_hint)
        slices = Reach::Workspace.current_slices
        return nil if slices.nil? || slices.empty?
        return slices.first if slice_hint.nil? && slices.length == 1
        return nil if slice_hint.nil?

        slices.find { |workspace_path| File.basename(workspace_path).include?(slice_hint) }
      rescue StandardError
        nil
      end

      def default_slice_id(slice_hint = nil)
        return slice_hint if slice_hint

        current_workspace_basename || begin
          workspace_path = resolve_workspace(nil)
          workspace_path && File.basename(workspace_path)
        end
      end

      def read_stdin_json
        return {} if STDIN.tty?
        return {} unless IO.select([STDIN], nil, nil, STDIN_GRACE_S)

        data = STDIN.read
        return {} if data.nil? || data.strip.empty?

        JSON.parse(data)
      rescue StandardError
        {}
      end

      def cmd_enrol(args)
        options, remaining = parse_flags(args, [:teach_url])
        code = remaining.shift
        unless code
          warn "usage: reach enrol <code> [--teach-url URL]"
          return 1
        end
        teach_url = options[:teach_url] || Reach::Runtime.default_teach_url
        unless teach_url
          warn "reach: no --teach-url given and no default teach url is configured"
          return 1
        end
        install = Reach::Enrol.generate_and_register(code, teach_url)
        course_title = install["course"] && install["course"]["title"]
        puts Reach::Messages.text("M-ENROL-DONE", course: course_title)
        print_sync_summary(Reach::Sync.run)
        0
      end

      def cmd_sync(_args)
        summary = Reach::Sync.run
        print_sync_summary(summary)
        return 2 if summary["state"] == "revoked"

        0
      end

      def print_sync_summary(summary)
        puts "Course rules: v#{summary["guardrails_version"]} (verified)" if summary["guardrails_version"]
        Array(summary["workspaces"]).each do |workspace|
          puts "Workspace: #{workspace["path"]}"
          kept = workspace["kept_files"]
          puts "Kept your changes: #{Array(kept).join(", ")}" if kept && !Array(kept).empty?
        end
        puts "Sent #{summary["outbox_sent"]} queued item(s)." if summary["outbox_sent"].to_i > 0
        Array(summary["grades"]).each { |text| puts text }
        Array(summary["warnings"]).each { |warning| puts warning }
        puts Reach::Messages.text("M-OFFLINE") if summary["state"] == "offline"
        puts Reach::Messages.text("M-GATE-REVOKED") if summary["state"] == "revoked"
      end

      def cmd_status(_args)
        puts Reach::Status.summary
        0
      end

      def cmd_work(args)
        options, _remaining = parse_flags(args, [:harness, :slice])
        workspace_path = resolve_workspace(options[:slice])
        unless workspace_path
          warn "reach: no matching slice workspace found; run reach sync"
          return 1
        end
        harness_id = options[:harness] || pick_harness
        unless harness_id
          warn "reach: no supported harness found on PATH; pass --harness claude-code|codex|antigravity"
          return 1
        end
        Reach::Harness.launch(harness_id, workspace_path, initial_prompt: "Hi rEach")
        0
      end

      def cmd_start(args)
        options, _remaining = parse_flags(args, [:harness])
        harness_id = options[:harness] || pick_harness
        unless harness_id
          warn "reach: no supported harness found on PATH; pass --harness claude-code|codex|antigravity"
          return 1
        end
        Reach::Harness.launch(harness_id, Dir.pwd, initial_prompt: "Hi rEach")
        0
      end

      def pick_harness
        detected = Reach::Harness.detect
        return nil if detected.nil? || detected.empty?
        return detected.first[:id] if detected.length == 1

        nil
      end

      def cmd_gate(args)
        sub = args.shift
        options, _remaining = parse_flags(args, [:harness, :path, :command])
        event = read_stdin_json
        tool_input = event["tool_input"] || {}
        case sub
        when "session"
          harness_id = options[:harness] || event["harness"] || "claude-code"
          Reach::Gate.session(harness: harness_id)
          announce_guardrails
          0
        when "prompt"
          Reach::Gate.prompt
          0
        when "write"
          path = options[:path] || tool_input["file_path"] || tool_input["path"] || tool_input["notebook_path"]
          tool_name = event["tool_name"]
          command_text = tool_input["command"]
          patch = command_text if tool_name == "apply_patch" || command_text.to_s.start_with?("*** Begin Patch")
          Reach::Gate.write(path: path, patch: patch)
          0
        when "shell"
          command = shell_text(options[:command] || tool_input["command"] || tool_input["cmd"])
          if command.include?("*** Begin Patch")
            Reach::Gate.write(patch: command)
          else
            Reach::Gate.shell(command: command)
          end
          0
        else
          warn "usage: reach gate session|prompt|write|shell"
          1
        end
      end

      def shell_text(command)
        return command.to_s unless command.is_a?(Array)

        parts = command.map(&:to_s)
        if parts.length >= 3 && %w[bash sh zsh].include?(File.basename(parts[0])) && %w[-c -lc].include?(parts[1])
          parts[2..-1].join(" ")
        else
          Shellwords.join(parts)
        end
      end

      def announce_guardrails
        puts "Course rules #{Reach::Guardrails.version} verified."
      rescue StandardError
        nil
      end

      def cmd_shape(args)
        sub = args.shift
        unless sub == "check"
          warn "usage: reach shape check [--changed <path>] [--format text|agent|json]"
          return 1
        end
        options, _remaining = parse_flags(args, [:changed, :format, :slice])
        workspace_path = resolve_workspace(options[:slice]) || Dir.pwd
        format = (options[:format] || "text").to_sym
        findings = Reach::Shape.check(workspace_path: workspace_path, changed: options[:changed], format: format)
        case format
        when :json, :agent
          puts JSON.generate(findings)
        else
          puts findings
        end
        0
      end

      def cmd_tips(args)
        options, _remaining = parse_flags(args, [:slice])
        slice = default_slice_id(options[:slice])
        unless slice
          warn "usage: reach tips --slice <id>"
          return 1
        end
        result = Timeout.timeout(100) { Reach::Suite.run(slice: slice) }
        Array(result[:scenarios]).each do |scenario|
          status_word = scenario[:passed] ? "pass" : "fail"
          line = "#{scenario[:name]}: #{status_word}"
          line = "#{line} - #{scenario[:reason]}" if scenario[:reason]
          puts line
        end
        0
      rescue Timeout::Error
        warn "reach: the tips suite did not finish in time; try again"
        1
      end

      def cmd_submit(args)
        options, _remaining = parse_flags(args, [:slice])
        slice = default_slice_id(options[:slice])
        unless slice
          warn "usage: reach submit --slice <id>"
          return 1
        end
        result = Reach::Submit.submit(slice: slice)
        case result["state"]
        when "ingested"
          puts Reach::Receipts.announce(result["receipt"])
          0
        when "rejected"
          rejection = result["rejection"] || {}
          warn Reach::Messages.text("M-SUBMIT-REJECTED", reason: rejection["reason"], fix: Reach::Messages.rejection_fix(rejection["code"]))
          1
        else
          puts Reach::Messages.text("M-SUBMIT-PENDING")
          0
        end
      end

      def cmd_receipts(args)
        sub = args.shift
        case sub
        when nil
          Reach::Receipts.list.each { |receipt| puts JSON.generate(receipt) }
          0
        when "wait"
          options, _remaining = parse_flags(args, [:submission])
          unless options[:submission]
            warn "usage: reach receipts wait --submission <id>"
            return 1
          end
          receipt = Reach::Receipts.wait(submission_id: options[:submission])
          if receipt
            puts Reach::Receipts.announce(receipt)
          else
            puts Reach::Messages.text("M-SUBMIT-PENDING")
          end
          0
        when "show"
          id = args.shift
          unless id
            warn "usage: reach receipts show <id>"
            return 1
          end
          receipt = Reach::Receipts.show(id)
          if receipt
            puts JSON.generate(receipt)
            0
          else
            warn "reach: no receipt #{id}"
            1
          end
        else
          warn "usage: reach receipts [wait|show]"
          1
        end
      end

      def cmd_hand(args)
        sub = args.shift
        case sub
        when "raise"
          include_profile, args = parse_bare_flag(args, "include-profile")
          options, _remaining = parse_flags(args, [:trigger, :summary, :slice])
          unless options[:summary]
            warn "usage: reach hand raise --summary <text> [--trigger attempt_gate|student_request] [--slice <id>] [--include-profile]"
            return 1
          end
          hand_id = Reach::Hands.raise_hand(
            trigger: options[:trigger] || "student_request",
            summary: options[:summary],
            slice: default_slice_id(options[:slice]),
            include_profile: include_profile
          )
          puts "Hand raised: #{hand_id}"
          0
        when "status"
          id = args.shift
          unless id
            warn "usage: reach hand status <id>"
            return 1
          end
          puts JSON.generate(Reach::Hands.status(id))
          0
        when "list"
          hands = Reach::Hands.respond_to?(:list) ? Reach::Hands.list : []
          hands.each { |hand| puts JSON.generate(hand) }
          0
        else
          warn "usage: reach hand raise|status|list"
          1
        end
      end

      def cmd_watch(args)
        options, _remaining = parse_flags(args, [:slice])
        workspace_path = resolve_workspace(options[:slice])
        unless workspace_path
          warn "reach: no matching slice workspace found"
          return 1
        end
        mtimes = {}
        interrupted = false
        trap("INT") { interrupted = true }
        until interrupted
          changed_path = detect_change(workspace_path, mtimes)
          if changed_path
            begin
              findings = Reach::Shape.check(workspace_path: workspace_path, changed: changed_path, format: :agent)
              puts JSON.generate(findings)
            rescue Reach::Error => e
              warn e.message
            end
          end
          sleep(2)
        end
        0
      end

      def detect_change(workspace_path, mtimes)
        changed_path = nil
        Reach::Workspace.owned_files(workspace_path).each do |relative_path|
          full_path = File.join(workspace_path, relative_path)
          next unless File.exist?(full_path)

          mtime = File.mtime(full_path)
          if mtimes.key?(relative_path) && mtimes[relative_path] != mtime
            changed_path = relative_path
          end
          mtimes[relative_path] = mtime
        end
        changed_path
      rescue StandardError
        nil
      end

      def cmd_doctor(_args)
        problems = []
        problems.concat(check_ruby)
        problems.concat(check_shim)
        problems.concat(check_harness_detected)
        problems.concat(check_enrol)
        problems.concat(check_keys)
        problems.concat(check_guard)
        problems.concat(check_workspaces)
        problems.concat(check_chrome)
        problems.concat(check_gems)
        problems.concat(check_net)
        problems.concat(check_outbox)
        problems.concat(check_outdated)
        problems.concat(check_wire)
        problems.concat(check_version)
        problems.concat(check_persona)
        problems.concat(check_directives)
        problems.concat(check_taste)
        problems.concat(check_sidecar)
        problems.each { |line| puts line }
        problems.empty? ? 0 : 1
      end

      def check_directives
        Reach::Directives.problems.map { |problem| "R-DOC-DIRECTIVES: #{problem}" }
      rescue StandardError => e
        ["R-DOC-DIRECTIVES: the public directives could not be checked (#{e.message})"]
      end

      def check_taste
        dir = File.join(Reach::Runtime.root, "skills", "design-taste-frontend")
        skill = File.join(dir, "SKILL.md")
        return ["R-DOC-TASTE: skills/design-taste-frontend/SKILL.md is missing"] unless File.file?(skill)
        return ["R-DOC-TASTE: skills/design-taste-frontend/LICENSE is missing"] unless File.file?(File.join(dir, "LICENSE"))

        text = File.read(skill)
        return ["R-DOC-TASTE: the taste skill's frontmatter does not read name: design-taste-frontend"] unless text.include?("name: design-taste-frontend")
        return ["R-DOC-TASTE: the taste skill's body does not open with the tasteskill heading"] unless text.include?("# tasteskill: Anti-Slop Frontend Skill")

        []
      rescue StandardError
        ["R-DOC-TASTE: the taste skill could not be checked"]
      end

      def check_sidecar
        Reach::Sidecar.ensure_written
        File.file?(Reach::Sidecar.path) ? [] : ["R-DOC-SEAL: the seal sidecar at #{Reach::Sidecar.path} could not be written"]
      rescue StandardError
        ["R-DOC-SEAL: the seal sidecar at #{Reach::Sidecar.path} could not be written"]
      end

      def check_ruby
        version = Gem::Version.new(RUBY_VERSION)
        ok = version >= Gem::Version.new("2.6.10") && version < Gem::Version.new("4.1.0")
        ok ? [] : ["R-DOC-RUBY: Ruby #{RUBY_VERSION} is outside 2.6.10-4.0.x - use the installer command for this platform"]
      end

      def check_shim
        shim_ok = File.file?(Reach::Runtime.shim_path) && File.file?(Reach::Runtime.shim_root_path)
        root_ok = shim_ok && File.directory?(File.read(Reach::Runtime.shim_root_path).strip) &&
                  File.file?(File.join(File.read(Reach::Runtime.shim_root_path).strip, "exe", "reach"))
        root_ok ? [] : ["R-DOC-SHIM: the reach shim is missing or broken - run reach setup"]
      rescue StandardError
        ["R-DOC-SHIM: the reach shim could not be checked - run reach setup"]
      end

      def check_harness_detected
        detected = Reach::Harness.detect
        detected.nil? || detected.empty? ? ["R-DOC-HARNESS: no supported harness version was found - update the harness or install one"] : []
      rescue StandardError
        ["R-DOC-HARNESS: harness version could not be checked - update the harness or install one"]
      end

      def check_enrol
        Reach::Enrol.current ? [] : ["R-DOC-ENROL: install.yml or the install key is missing - run reach enrol <code>"]
      rescue StandardError
        ["R-DOC-ENROL: enrolment could not be checked - run reach enrol <code>"]
      end

      def check_keys
        install = Reach::Enrol.current
        return [] unless install

        ok = install["signing_public_keys"] && install["encryption_key"]
        ok ? [] : ["R-DOC-KEYS: the instructors' public keys are missing or stale - run reach sync"]
      rescue StandardError
        ["R-DOC-KEYS: keys could not be checked - run reach sync"]
      end

      def check_guard
        Reach::Guardrails.load
        []
      rescue StandardError
        ["R-DOC-GUARD: the guardrails package does not verify or is not the latest known - run reach sync"]
      end

      def check_workspaces
        Reach::Workspace.current_slices.each do |workspace_path|
          next if Reach::Workspace.verify(workspace_path)

          return ["R-DOC-WS: #{workspace_path} failed verification - run reach sync, then reach work"]
        end
        []
      rescue StandardError
        ["R-DOC-WS: workspaces could not be checked - run reach sync, then reach work"]
      end

      def check_chrome
        found = (ENV["REACH_CHROME"] && File.exist?(ENV["REACH_CHROME"])) ||
                which_binary("google-chrome") || which_binary("chromium") || which_binary("chromium-browser") ||
                which_binary("microsoft-edge") || File.directory?(Reach::Paths.chromium_dir)
        found ? [] : ["R-DOC-CHROME: no usable Chromium was found - run reach doctor --install-chromium"]
      rescue StandardError
        ["R-DOC-CHROME: Chromium could not be checked - run reach doctor --install-chromium"]
      end

      def which_binary(name)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
      end

      def check_gems
        dir = Reach::Paths.gems_dir
        installed = File.directory?(dir) && !Dir.children(dir).empty?
        installed ? [] : ["R-DOC-GEMS: the tips suite's gems are not installed yet - reach tips installs them on first run"]
      rescue StandardError
        ["R-DOC-GEMS: the tips suite's gems could not be checked - reach tips installs them on first run"]
      end

      def check_net
        return [] if ENV["REACH_OFFLINE"] == "1"
        return [] unless Reach::Enrol.current

        Reach::Client.anonymous(Reach::Enrol.current["teach_url"], quick: true).get("/api/v1/health")
        cached = Reach::Sync.cached_status
        if cached && cached["server_time"] && cached["fetched_at"]
          skew = (Time.parse(cached["server_time"].to_s).to_f - Time.parse(cached["fetched_at"].to_s).to_f).abs rescue nil
          return ["R-DOC-NET: the course server's clock is more than 300 s from this computer's - check both clocks"] if skew && skew > 300
        end
        []
      rescue StandardError
        ["R-DOC-NET: Teach could not be reached - check the connection or the computer's clock"]
      end

      def check_outbox
        dir = Reach::Paths.outbox_dir
        empty = !File.directory?(dir) || Dir.children(dir).empty?
        empty ? [] : ["R-DOC-OUTBOX: the outbox is not empty - reach submit retries automatically; stay online"]
      rescue StandardError
        ["R-DOC-OUTBOX: the outbox could not be checked - reach submit retries automatically; stay online"]
      end

      def check_outdated
        install = Reach::Enrol.current
        return [] unless install && install["minimum_reach_version"]

        outdated = Gem::Version.new(Reach::VERSION) < Gem::Version.new(install["minimum_reach_version"])
        outdated ? ["R-DOC-OUTDATED: this reach (#{Reach::VERSION}) is older than the course needs (#{install["minimum_reach_version"]}) - update reach"] : []
      rescue StandardError
        []
      end

      def check_wire
        cached = Reach::Sync.cached_status
        return [] unless cached && cached["wire_contract_sha256"]

        cached["wire_contract_sha256"] == Reach::Wire.digest ? [] : ["R-DOC-WIRE: this reach's wire contract does not match the course server's - update reach"]
      rescue StandardError
        []
      end

      def check_version
        root = Reach::Runtime.root
        expected = Reach::VERSION
        candidates = {
          "plugin.json" => File.join(root, "plugin.json"),
          ".claude-plugin/plugin.json" => File.join(root, ".claude-plugin", "plugin.json"),
          ".codex-plugin/plugin.json" => File.join(root, ".codex-plugin", "plugin.json"),
          "reach.rplugin.yml" => File.join(root, "reach.rplugin.yml")
        }
        candidates.each do |label, path|
          next unless File.file?(path)

          value = path.end_with?(".yml") ? YAML.safe_load(File.read(path))["version"] : JSON.parse(File.read(path))["version"]
          return ["R-DOC-VERSION: #{label} version #{value} does not match VERSION #{expected}"] if value != expected
        end
        marketplace_path = File.join(root, ".claude-plugin", "marketplace.json")
        if File.file?(marketplace_path)
          data = JSON.parse(File.read(marketplace_path))
          plugin = Array(data["plugins"]).first
          version = plugin && plugin["version"]
          return ["R-DOC-VERSION: .claude-plugin/marketplace.json version #{version} does not match VERSION #{expected}"] if version && version != expected
        end
        []
      rescue StandardError
        ["R-DOC-VERSION: plugin versions could not be checked"]
      end

      def check_persona
        root = Reach::Runtime.root
        skill_path = File.join(root, "skills", "reach-assistant", "SKILL.md")
        agent_path = File.join(root, "agents", "reach.md")
        return ["R-DOC-PERSONA: skills/reach-assistant/SKILL.md or agents/reach.md is missing"] unless File.file?(skill_path) && File.file?(agent_path)

        skill_body = File.read(skill_path).sub(/\A---.*?---\n/m, "")
        agent_body = File.read(agent_path).sub(/\A---.*?---\n/m, "")
        return ["R-DOC-PERSONA: the reach-assistant skill body and the reach agent body do not match"] unless skill_body == agent_body

        greeting = Reach::Greetings.text("G-FIRST-RUN")
        missing = greeting.split("\n").reject { |line| line.empty? || skill_body.include?(line) }
        return ["R-DOC-PERSONA: the persona body does not quote the first-run greeting in full"] unless missing.empty?

        []
      rescue StandardError
        ["R-DOC-PERSONA: the persona body could not be checked"]
      end

      def cmd_lock(_args)
        vault = Reach::Paths.vault_dir
        FileUtils.rm_rf(vault)
        FileUtils.mkdir_p(vault)
        begin
          File.chmod(0o700, vault)
        rescue NotImplementedError, Errno::ENOENT
          nil
        end
        puts "Vault locked."
        0
      end

      def cmd_mcp(_args)
        Reach::MCPBridge.serve
        0
      end

      def cmd_hello(args)
        options, _remaining = parse_flags(args, [:harness, :format, :source])
        puts Reach::Hello.run(
          harness: options[:harness],
          source: options[:source],
          format: options[:format] || "hook",
          cwd: Dir.pwd
        )
        0
      end

      def cmd_setup(args)
        options, _remaining = parse_flags(args, [:harness, :source, :format])
        output, exit_code = Reach::Setup.run(
          harness: options[:harness] || "auto",
          source: options[:source],
          format: options[:format] || "text"
        )
        puts output
        exit_code
      end

      def cmd_profile(args)
        sub = args.shift
        case sub
        when "show"
          options, _remaining = parse_flags(args, [:format])
          profile = Reach::Profile.load
          if (options[:format] || "text") == "json"
            puts JSON.generate(profile)
          elsif profile["fields"].nil? || profile["fields"].empty?
            puts "No profile yet."
          else
            profile["fields"].each { |key, value| puts "#{key}: #{value}" }
            puts "Status: #{profile["status"]}"
          end
          0
        when "save"
          options, remaining = parse_flags(args, [:status])
          fields = {}
          index = 0
          while index < remaining.length
            token = remaining[index]
            if token.start_with?("--")
              fields[token[2..-1].tr("-", "_")] = remaining[index + 1]
              index += 2
              next
            end
            index += 1
          end
          Reach::Profile.save(fields: fields, status: options[:status] || "partial")
          puts "Saved."
          0
        when "forget"
          Reach::Profile.forget!
          puts "Your profile is deleted."
          0
        else
          warn "usage: reach profile show|save|forget"
          1
        end
      end

      def cmd_attempts(args)
        sub = args.shift
        unless sub == "settle"
          warn "usage: reach attempts settle [--slice <basename>]"
          return 1
        end
        options, _remaining = parse_flags(args, [:slice])
        slice = options[:slice] || current_workspace_basename
        result = slice ? Reach::Attempts.settle(slice: slice) : []
        puts JSON.generate(result)
        0
      end

      def workspace_or_fail(slice_hint)
        workspace_path = resolve_workspace(slice_hint)
        workspace_path ||= Reach::Gate.current_workspace_path
        warn Reach::Messages.text("M-GATE-NOGUARD") unless workspace_path
        workspace_path
      end

      def cmd_check(args)
        options, _remaining = parse_flags(args, [:changed, :format, :slice])
        event = read_stdin_json
        tool_input = event["tool_input"] || {}
        changed = options[:changed] || tool_input["file_path"] || tool_input["path"] || tool_input["notebook_path"]
        workspace_path = workspace_or_fail(options[:slice])
        return 1 unless workspace_path

        format = (options[:format] || "text").to_sym
        findings = Reach::Check.run(workspace_path, changed: changed, format: format)
        if format == :text
          puts findings
          findings == Reach::Messages.text("M-CHECK-CLEAN") ? 0 : 1
        else
          puts JSON.generate(findings)
          findings.empty? ? 0 : 1
        end
      end

      def cmd_checkpoint(args)
        sub = args.shift
        options, remaining = parse_flags(args, [:note, :slice])
        workspace_path = workspace_or_fail(options[:slice])
        return 1 unless workspace_path

        case sub
        when "save"
          result = Reach::Checkpoint.save(workspace_path, note: options[:note] || remaining.first)
          puts result["message"]
          0
        when "list"
          entries = Reach::Checkpoint.list(workspace_path)
          if entries.empty?
            puts Reach::Messages.text("M-CHECKPOINT-NONE")
          else
            previous = nil
            entries.each do |entry|
              changed = Reach::Checkpoint.changed_count(entry, previous)
              note = entry["note"].to_s.empty? ? (entry["automatic"] ? "(automatic)" : "") : entry["note"]
              shown_at = Reach::Messages.respond_to?(:course_time) ? Reach::Messages.course_time(entry["at"]) : entry["at"]
              puts "#{entry['n']}  #{shown_at}  #{note}  #{changed} file(s) changed"
              previous = entry
            end
          end
          0
        when "show"
          entry = Reach::Checkpoint.show(workspace_path, remaining.first)
          if entry
            puts JSON.generate(entry)
            0
          else
            warn Reach::Messages.text("M-CHECKPOINT-UNKNOWN", n: remaining.first)
            1
          end
        when "restore"
          result = Reach::Checkpoint.restore(workspace_path, remaining.first)
          puts result["message"]
          0
        else
          warn "usage: reach checkpoint save [--note <text>] | list | show <n> | restore <n>"
          1
        end
      end

      def cmd_plan(args)
        sub = args.shift
        options, remaining = parse_flags(args, [:slice, :format])
        workspace_path = workspace_or_fail(options[:slice])
        return 1 unless workspace_path

        case sub
        when "save", "note"
          fields = {}
          index = 0
          while index < remaining.length
            token = remaining[index]
            if token.start_with?("--")
              fields[token[2..-1].tr("-", "_")] = remaining[index + 1]
              index += 2
              next
            end
            index += 1
          end
          Reach::Plan.save(workspace_path, fields)
          puts Reach::Messages.text("M-PLAN-SAVED")
          0
        when "show"
          if (options[:format] || "text") == "json"
            puts JSON.generate(Reach::Plan.load(workspace_path) || {})
          else
            puts Reach::Plan.render(workspace_path)
          end
          0
        else
          warn "usage: reach plan save --behaviour <text> [--input ...] [--output ...] [--steps a|b|c] [--edge-cases a|b] [--scenarios a|b] [--evidence ...] | note --progress <text> --next <text> | show [--format json]"
          1
        end
      end

      def cmd_directive(args)
        listing, remaining = parse_bare_flag(args, "list")
        options, remaining = parse_flags(remaining, [:format])
        if listing
          Reach::Directives.rows.each { |row| puts Reach::Directives.render_row(row) }
          return 0
        end
        opcode = remaining.first
        unless opcode
          warn "usage: reach directive <OPCODE> [--format text|json] | --list"
          return 1
        end
        result = Reach::Directives.show(opcode, workspace: Reach::Gate.current_workspace_path)
        if (options[:format] || "text") == "json"
          puts JSON.generate(result)
        else
          puts result["body"]
        end
        0
      end

      def current_workspace_basename
        cwd = File.realpath(Dir.pwd)
        workspace_path = Reach::Workspace.current_slices.find do |workspace|
          real_workspace = File.realpath(workspace)
          cwd == real_workspace || cwd.start_with?(real_workspace + File::SEPARATOR)
        end
        return nil unless workspace_path

        File.basename(workspace_path)
      rescue StandardError
        nil
      end
    end
  end
end
