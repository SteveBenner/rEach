require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Qualify
    ROUTE = "/api/v1/qualifications"
    FEATURES_DIR = "qualify/features"
    STEPS_DIR = "qualify/step_definitions"
    KIT_DIR = "qualify/kit"
    PRACTICE_README_RELATIVE = "practice/README.md".freeze
    PRACTICE_README = "qualify/kit/practice/README.md".freeze
    PRACTICE_DETAIL = "the local check replays the course's reference on practice data, and it holds no answer for this call; write this scenario with the practice values in qualify/kit/practice/README.md (the course server still runs your graded scenarios on the real data)".freeze
    RECORD_FILE = "qualification.json"
    POLL_INTERVAL_S = 10
    MAX_POLLS = 36
    STEP_IDS = %w[check coverage local_pass local_stub remote].freeze
    SCENARIO_LINE = /\A\s*(?:Scenario|Scenario Outline|Example):\s*(.+?)\s*\z/.freeze

    class << self
      def run(workspace, local_only: false, task: nil, agent_summary: nil)
        Reach::Login.require_active!
        meta = Reach::Workspace.metadata(workspace)
        qualify = meta["qualify"]
        raise Reach::Refused, Reach::Messages.text("M-QUALIFY-NOKIT") unless qualify.is_a?(Hash) && qualify["tag"]

        blocked = Reach::Ladder.blocked_message(workspace)
        if blocked
          failed = Reach::Ladder.state(workspace)["failed"]
          raise Reach::Refused, Reach::Messages.text(blocked, attempt: failed, limit: Reach::Ladder::HARD_STOP)
        end

        record = {
          "schema" => "reach.qualification-record/v1",
          "slice" => File.basename(workspace),
          "cutout_id" => meta["cutout_id"],
          "attempt" => Reach::Ladder.next_attempt(workspace),
          "at" => now,
          "files_digest" => files_digest(workspace),
          "tests_digest" => tests_digest(workspace),
          "steps" => {},
          "findings" => [],
          "passed" => false,
          "pending" => false,
          "qualification_id" => nil,
          "task" => task,
          "agent_summary" => agent_summary
        }
        notice = Reach::Ladder.continue_notice(workspace)
        record["notice"] = notice if notice

        run_steps(workspace, meta, qualify, record, local_only)
        record["passed"] = !record["pending"] && record["findings"].empty? && !local_only
        finish(workspace, record, local_only)
      end

      def run_steps(workspace, meta, qualify, record, local_only)
        return unless step_check(workspace, record)
        return unless step_coverage(workspace, meta, qualify, record)

        if qualify["local"]
          return unless step_local(workspace, meta, qualify, record, stub: false)
          return unless step_local(workspace, meta, qualify, record, stub: true)
        end
        return if local_only

        step_remote(workspace, meta, qualify, record)
      end

      def finish(workspace, record, local_only)
        record["ladder"] = if record["pending"] || local_only
                             nil
                           else
                             Reach::Ladder.record(workspace, record)
                           end
        write_record(workspace, record) unless local_only
        record
      end

      def step_check(workspace, record)
        owned = Array(Reach::Workspace.metadata(workspace)["owned_files"])
        findings = Array(Reach::Check.run(workspace, format: :agent)).select { |finding| owned.include?(finding[:file].to_s) }
        rows = findings.map { |finding| { "id" => finding[:id], "file" => finding[:file], "line" => finding[:line], "message" => finding[:message] } }
        record["steps"]["check"] = { "ran" => true, "passed" => rows.empty?, "rows" => rows }
        rows.each { |row| record["findings"] << { "code" => "QF-CHECK", "detail" => "#{row['id']} #{row['file']}:#{row['line']} #{row['message']}" } }
        rows.empty?
      end

      def step_coverage(workspace, meta, qualify, record)
        graded = Array(meta["scenarios"]).map { |item| item.is_a?(Hash) ? item["name"] : item }.compact.map(&:to_s).uniq
        covered = agent_scenarios(workspace, qualify["tag"])
        missing = graded.reject { |name| covered.include?(name) }
        record["graded"] = graded
        record["steps"]["coverage"] = { "ran" => true, "passed" => missing.empty?, "rows" => missing.map { |name| { "name" => name } } }
        missing.each { |name| record["findings"] << { "code" => "QF-UNCOVERED", "name" => name } }
        if covered.empty? && graded.empty?
          record["findings"] << { "code" => "QF-UNCOVERED", "name" => nil, "detail" => "no scenario under #{FEATURES_DIR} carries #{qualify['tag']}" }
          record["steps"]["coverage"]["passed"] = false
        end
        record["steps"]["coverage"]["passed"]
      end

      def agent_scenarios(workspace, tag)
        names = []
        Dir.glob(File.join(workspace, FEATURES_DIR, "**", "*.feature")).sort.each do |path|
          feature_tags = []
          pending = []
          File.foreach(path) do |line|
            stripped = line.strip
            if stripped.start_with?("@")
              pending.concat(stripped.split(/\s+/))
            elsif stripped.start_with?("Feature:")
              feature_tags = pending
              pending = []
            elsif (match = SCENARIO_LINE.match(line.chomp))
              names << match[1] if (feature_tags + pending).include?(tag)
              pending = []
            elsif !stripped.empty? && !stripped.start_with?("#")
              pending = [] unless stripped.start_with?("Examples:")
            end
          end
        end
        names.uniq
      end

      ENV_KEY = /\A[A-Z][A-Z0-9_]{0,63}\z/.freeze
      ENV_DENIED = %w[PATH HOME RUBYOPT RUBYLIB].freeze
      ENV_DENIED_PREFIXES = %w[BUNDLE_ GEM_ LD_ DYLD_ REACH_ TEACH_].freeze

      def sanitize_env(raw)
        accepted = {}
        dropped = []
        return [accepted, dropped] unless raw.is_a?(Hash)

        raw.each do |key, value|
          name = key.to_s
          valid = name =~ ENV_KEY &&
                  !ENV_DENIED.include?(name) &&
                  ENV_DENIED_PREFIXES.none? { |prefix| name.start_with?(prefix) } &&
                  value.is_a?(String) &&
                  value.bytesize <= 512 &&
                  !value.start_with?("/", "\\") &&
                  value !~ /\A[A-Za-z]:/ &&
                  !value.split(%r{[/\\]}).include?("..")
          if valid
            accepted[name] = value
          else
            dropped << name
          end
        end
        [accepted, dropped]
      end

      def step_local(workspace, meta, qualify, record, stub:)
        id = stub ? "local_stub" : "local_pass"
        env, dropped = sanitize_env(qualify["env"])
        passed = run_local(workspace, meta, qualify, record, env, stub: stub)
        if qualify["env"].is_a?(Hash) && qualify["env"].key?("GROKIT_REPLAY") || File.file?(File.join(workspace, KIT_DIR, PRACTICE_README_RELATIVE))
          record["practice_readme"] = PRACTICE_README
        end
        step = record["steps"][id]
        step["env_dropped"] = dropped if step.is_a?(Hash) && !dropped.empty?
        passed
      end

      def run_local(workspace, meta, qualify, record, env, stub:)
        id = stub ? "local_stub" : "local_pass"
        run_dir = assemble_local(workspace, meta, stub: stub)
        Reach::Suite.select_lock!(run_dir)
        gems = Reach::Suite.install_gems(run_dir)
        output = Reach::Suite.cucumber(run_dir, gems, [qualify["tag"]], env)
        rows = output["timed_out"] ? nil : Reach::Suite.report_rows(output["stdout"])
        if rows.nil? || rows.empty?
          reason = output["timed_out"] ? "the run did not finish in #{Reach::Suite::RUN_TIMEOUT_S} s" : first_error_line(output["stderr"])
          record["steps"][id] = { "ran" => true, "passed" => false, "rows" => [], "error" => reason }
          record["findings"] << { "code" => stub ? "QF-VACUOUS" : "QF-LOCAL-FAIL", "name" => nil, "detail" => reason }
          return false
        end

        if stub
          graded = Array(record["graded"])
          vacuous = rows.select { |row| graded.include?(row["name"]) && row["result"] == "passed" }
          record["steps"][id] = { "ran" => true, "passed" => vacuous.empty?, "rows" => rows.map { |row| row.slice("name", "result") } }
          vacuous.each { |row| record["findings"] << { "code" => "QF-VACUOUS", "name" => row["name"] } }
          vacuous.empty?
        else
          failing = rows.reject { |row| row["result"] == "passed" }
          record["steps"][id] = { "ran" => true, "passed" => failing.empty?, "rows" => rows.map { |row| row.slice("name", "result", "step", "message") } }
          failing.each do |row|
            if practice_miss?(row, output)
              record["findings"] << { "code" => "QF-PRACTICE", "name" => row["name"], "step" => row["step"], "detail" => PRACTICE_DETAIL }
            else
              record["findings"] << { "code" => "QF-LOCAL-FAIL", "name" => row["name"], "step" => row["step"], "detail" => row["message"] }
            end
          end
          failing.empty?
        end
      end

      def practice_miss?(row, output)
        return true if row["message"].to_s.include?("not_recorded")

        row["message"].to_s.empty? && "#{output['stdout']}#{output['stderr']}".include?("not_recorded")
      end

      def first_error_line(text)
        line = text.to_s.lines.map(&:strip).reject(&:empty?).find { |candidate| !candidate.start_with?("from ") }
        line ? line[0, 300] : "the scenarios could not run"
      end

      def assemble_local(workspace, meta, stub:)
        run_dir = File.join(Reach::Paths.vault_dir, "runs", "#{File.basename(workspace)}-#{stub ? 'stub' : 'pass'}")
        make_writable(run_dir)
        FileUtils.rm_rf(run_dir)
        FileUtils.mkdir_p(run_dir)
        kit = File.join(workspace, KIT_DIR)
        copy_tree(kit, run_dir)
        owned_contents(workspace, meta, stub: stub).each do |relative, data|
          target = File.join(run_dir, relative)
          if data.nil?
            FileUtils.rm_f(target)
          else
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.rm_f(target)
            File.binwrite(target, data)
          end
        end
        copy_tree(File.join(workspace, FEATURES_DIR), File.join(run_dir, "features", "agent"))
        copy_tree(File.join(workspace, STEPS_DIR), File.join(run_dir, "features", "step_definitions"))
        Dir.glob(File.join(run_dir, "**", ".keep"), File::FNM_DOTMATCH).each { |path| FileUtils.rm_f(path) }
        Dir.glob(File.join(run_dir, "**", "*")).each do |path|
          File.chmod(File.directory?(path) ? 0o755 : 0o644, path)
        end
        run_dir
      end

      def owned_contents(workspace, meta, stub:)
        owned = Array(meta["owned_files"])
        return owned.map { |relative| [relative, read_or_nil(File.join(workspace, relative))] }.to_h unless stub

        starting = starting_copies(workspace, meta)
        owned.map { |relative| [relative, starting[relative]] }.to_h
      end

      def starting_copies(workspace, meta)
        packages = Reach::Packages.new
        version = packages.latest_version(Reach::Workspace::KIND)
        raise Reach::Refused, Reach::Messages.text("M-QUALIFY-NOKIT") unless version

        _header, entries = packages.open(Reach::Workspace::KIND, version)
        root = "#{meta['cutout_id']}-#{meta['slice']}"
        Array(meta["owned_files"]).map { |relative| [relative, entries["#{root}/#{relative}"]] }.to_h
      end

      def read_or_nil(path)
        File.file?(path) ? File.binread(path) : nil
      end

      def copy_tree(source, dest)
        return unless File.directory?(source)

        FileUtils.mkdir_p(dest)
        Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          next if %w[. ..].include?(File.basename(path))
          next if File.symlink?(path)

          relative = path.sub("#{source}/", "")
          target = File.join(dest, relative)
          if File.directory?(path)
            FileUtils.mkdir_p(target)
          else
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.rm_f(target)
            FileUtils.cp(path, target)
            File.chmod(File.executable?(path) ? 0o755 : 0o644, target)
          end
        end
      end

      def make_writable(dir)
        return unless File.directory?(dir)

        File.chmod(0o755, dir)
        Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
          next if File.symlink?(path) || %w[. ..].include?(File.basename(path))

          File.chmod(File.directory?(path) ? 0o755 : 0o644, path)
        end
      end

      def step_remote(workspace, meta, qualify, record)
        install = Reach::Enroll.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

        previous = read_record(workspace)
        qualification_id = if previous && previous["pending"] && previous["qualification_id"] &&
                               previous["files_digest"] == record["files_digest"] && previous["tests_digest"] == record["tests_digest"]
                              record["attempt"] = previous["attempt"]
                              previous["qualification_id"]
                            end

        client = Reach::Client.for_install(install)
        qualification_id ||= begin
          post_qualification(client, install, workspace, meta, record)
        rescue Reach::Offline, Reach::NetworkError => e
          return pending!(record, nil, e.message)
        rescue Reach::RemoteRefused => e
          return pending!(record, nil, e.message) if e.code == "unavailable"

          record["steps"]["remote"] = { "ran" => true, "passed" => false, "rows" => [], "error" => e.message }
          record["findings"] << { "code" => "QF-REMOTE-FAIL", "name" => nil, "detail" => e.message }
          return false
        end
        record["qualification_id"] = qualification_id

        result = poll(client, qualification_id)
        return pending!(record, qualification_id, "the course server has not finished yet") unless result

        judge_remote(record, result)
      end

      def pending!(record, qualification_id, reason)
        record["pending"] = true
        record["qualification_id"] = qualification_id
        record["steps"]["remote"] = { "ran" => false, "passed" => false, "rows" => [], "error" => reason }
        record["findings"] << { "code" => "QF-PENDING", "name" => nil, "detail" => reason }
        false
      end

      def post_qualification(client, install, workspace, meta, record)
        owned = Array(meta["owned_files"])
        digests = {}
        entries = {}
        owned.each do |relative|
          data = read_or_nil(File.join(workspace, relative))
          digests[relative] = data ? Reach::Crypto.digest_hex(data) : nil
          entries["files/#{relative}"] = data if data
        end
        tests = {}
        test_files(workspace).each do |relative, data|
          tests[relative] = Reach::Crypto.digest_hex(data)
          entries[relative] = data
        end
        manifest = {
          "schema" => "reach.qualification/v1",
          "course" => meta["course"], "assignment" => meta["assignment"],
          "cutout_id" => meta["cutout_id"], "slice" => meta["slice"],
          "owned_files" => owned, "digests" => digests, "tests" => tests,
          "attempt" => record["attempt"], "reach_version" => Reach::VERSION, "client_created_at" => now
        }
        tar = Reach::Tarball.write({ "manifest.json" => JSON.generate(manifest) }.merge(entries))
        envelope = seal(install, meta, tar)
        body = {
          "cutout_id" => meta["cutout_id"], "slice" => meta["slice"], "assignment" => meta["assignment"],
          "package" => envelope, "client_created_at" => now
        }
        response = client.post_json(ROUTE, body, idempotency_key: SecureRandom.uuid)
        id = (response.json || {})["qualification_id"]
        raise Reach::NetworkError, "reach: the course server gave no qualification id" if id.to_s.empty?

        id
      end

      def poll(client, qualification_id)
        MAX_POLLS.times do |index|
          sleep(POLL_INTERVAL_S) if index.positive?
          body = client.get("#{ROUTE}/#{qualification_id}").json || {}
          return body if %w[done failed_to_run].include?(body["status"])
        end
        nil
      rescue Reach::Offline, Reach::NetworkError
        nil
      end

      def judge_remote(record, result)
        if result["status"] == "failed_to_run"
          record["steps"]["remote"] = { "ran" => true, "passed" => false, "rows" => [], "error" => result["reason"] }
          record["findings"] << { "code" => "QF-REMOTE-FAIL", "name" => nil, "detail" => result["reason"] }
          return false
        end

        graded = Array(record["graded"])
        agent = Array(result["agent"])
        stub = Array(result["stub"])
        hidden = Array(result["hidden"])
        record["suite_version"] = result["suite_version"]
        agent.reject { |row| row["result"] == "passed" }.each do |row|
          record["findings"] << { "code" => "QF-REMOTE-FAIL", "name" => row["name"], "step" => row["step"], "detail" => row["error"] }
        end
        record["findings"] << { "code" => "QF-REMOTE-FAIL", "name" => nil, "detail" => "no scenario ran on the course server" } if agent.empty?
        stub.select { |row| graded.include?(row["name"]) && row["result"] == "passed" }.each do |row|
          record["findings"] << { "code" => "QF-VACUOUS", "name" => row["name"], "detail" => "passed on the course server with the starting copy" }
        end
        hidden.reject { |row| row["result"] == "passed" }.each do |row|
          record["findings"] << { "code" => "QF-HIDDEN", "name" => row["name"], "detail" => row["reason"] }
        end
        passed = record["findings"].empty?
        record["steps"]["remote"] = { "ran" => true, "passed" => passed, "rows" => { "agent" => agent, "stub" => stub, "hidden" => hidden } }
        passed
      end

      def seal(install, meta, tar_bytes)
        encryption_key = install.fetch("encryption_key")
        header = {
          "schema" => "teach.package/v1",
          "kind" => "qualification",
          "id" => "renv_#{SecureRandom.hex(10)}",
          "version" => 1,
          "course" => meta["course"],
          "assignment" => meta["assignment"],
          "student_id" => install["student_id"],
          "created_at" => now,
          "signing_key_id" => install["install_id"],
          "recipient_key_id" => encryption_key["key_id"]
        }
        Reach::Crypto.seal(
          header: header,
          plaintext: tar_bytes,
          recipient_public_key: Reach::Crypto.load_public_key(encryption_key["pem"]),
          signer_private_key: Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
        )
      end

      def test_files(workspace)
        files = {}
        [FEATURES_DIR, STEPS_DIR].each do |dir|
          base = File.join(workspace, dir)
          next unless File.directory?(base)

          Dir.glob(File.join(base, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
            next unless File.file?(path) && !File.symlink?(path)
            next if File.basename(path) == ".keep"

            files["#{dir}/#{path.sub("#{base}/", '')}"] = File.binread(path)
          end
        end
        files
      end

      def files_digest(workspace)
        meta = Reach::Workspace.metadata(workspace)
        map = {}
        Array(meta["owned_files"]).each do |relative|
          data = read_or_nil(File.join(workspace, relative))
          map[relative] = data ? Reach::Crypto.digest_hex(data) : nil
        end
        Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(map))
      end

      def tests_digest(workspace)
        map = test_files(workspace).map { |relative, data| [relative, Reach::Crypto.digest_hex(data)] }.to_h
        Reach::Crypto.digest_hex(Reach::Crypto.canonical_json(map))
      end

      def record_path(workspace)
        File.join(workspace, Reach::Workspace::MARKER_DIR, RECORD_FILE)
      end

      def read_record(workspace)
        path = record_path(workspace)
        return nil unless File.file?(path)

        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end

      def write_record(workspace, record)
        File.write(record_path(workspace), JSON.generate(record))
        Reach::Corpus.new(Reach.ports).qualification(record.reject { |key, _| key == "ladder" })
        Reach::Ledger.append(
          workspace, "qualify",
          "attempt" => record["attempt"], "passed" => record["passed"], "pending" => record["pending"],
          "files_digest" => record["files_digest"], "tests_digest" => record["tests_digest"],
          "qualification_id" => record["qualification_id"]
        )
      rescue StandardError
        nil
      end

      def current?(workspace)
        record = read_record(workspace)
        return nil unless record && record["passed"]
        return nil unless record["files_digest"] == files_digest(workspace) && record["tests_digest"] == tests_digest(workspace)

        record
      end

      def now
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end

      def listing(workspace)
        meta = Reach::Workspace.metadata(workspace)
        qualify = meta["qualify"].is_a?(Hash) ? meta["qualify"] : {}
        names = Array(meta["scenarios"]).map { |item| item.is_a?(Hash) ? item["name"] : item }.compact.uniq
        lines = ["Tag: #{qualify['tag'] || 'none (run reach sync)'}",
                 "Runs here too: #{qualify['local'] ? 'yes' : 'no, only on the course server'}",
                 "Graded scenario names:"]
        lines.concat(names.map { |name| "  #{name}" })
        lines.join("\n")
      end

      def render(record, format)
        case format
        when :json, :agent
          JSON.generate(record)
        else
          render_text(record)
        end
      end

      def render_text(record)
        lines = []
        lines << record["notice"] if record["notice"]
        lines << "Qualification attempt #{record['attempt']} for #{record['slice']}"
        STEP_IDS.each do |id|
          step = record["steps"][id]
          next unless step

          word = if !step["ran"]
                   "pending"
                 else
                   step["passed"] ? "passed" : "failed"
                 end
          lines << "  #{id}: #{word}"
        end
        record["findings"].each do |finding|
          parts = [finding["code"], finding["name"], finding["step"], finding["detail"]].compact.map(&:to_s).reject(&:empty?)
          lines << "  #{parts.join(' | ')}"
        end
        lines << (record["passed"] ? "Qualified." : (record["pending"] ? "Waiting for the course server." : "Not qualified."))
        ladder = record["ladder"]
        lines << ladder["message"] if ladder && ladder["message"]
        lines.join("\n")
      end
    end
  end
end
