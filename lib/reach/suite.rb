require "open3"
require "json"
require "fileutils"
require "time"
require "digest"
require "timeout"

module Reach
  module Suite
    SUITE_KIND = "suite"
    SYSTEM_RUBY_FLOOR = Gem::Version.new("3.2.0")
    RUN_TIMEOUT_S = 300
    PIPE_GRACE_S = 5
    CHUNK_BYTES = 65_536

    class << self
      def reference_panel_dir(module_id)
        return nil if module_id.to_s.empty?

        packages = Reach::Packages.new
        version = packages.latest_version(SUITE_KIND)
        return nil unless version

        suite_dir = Reach::Paths.suite_vault_dir
        marker = File.join(suite_dir, ".version")
        current = File.file?(marker) ? File.read(marker).strip.to_i : nil
        unless current == version && File.directory?(File.join(suite_dir, "reference_build"))
          packages.unpack(SUITE_KIND, version, into: suite_dir)
          File.write(marker, version.to_s)
        end
        panel = File.join(suite_dir, "reference_build", module_id.to_s, "modules", module_id.to_s, "panel")
        File.directory?(panel) ? panel : nil
      rescue StandardError
        nil
      end

      def select_lock!(run_dir, ruby_version = RUBY_VERSION)
        runtime = Reach::RuntimeKit.active
        return if runtime && runtime["ruby_exe"]
        return if Gem::Version.new(ruby_version) >= SYSTEM_RUBY_FLOOR

        Reach::RuntimeAuto.start
        raise Reach::Refused, Reach::Messages.text("M-QUALIFY-NORUNTIME", ruby: ruby_version)
      end

      def install_gems(run_dir)
        gemfile = File.join(run_dir, "Gemfile")
        lock = File.join(run_dir, "Gemfile.lock")
        raise Reach::Error, "reach: the qualify kit carries no Gemfile; run reach sync" unless File.file?(gemfile) && File.file?(lock)

        gemfile_bytes = File.binread(gemfile)
        lock_bytes = File.binread(lock)
        runtime = Reach::RuntimeKit.active
        runtime = nil unless runtime && runtime["ruby_exe"]
        ruby_exe = runtime && runtime["ruby_exe"]
        ruby_bin = runtime && runtime["ruby_bin"]

        profile_note = nil
        if runtime
          profile = Reach::RuntimeKit.gems_for(lock_bytes) || profile_covering(runtime, gemfile_bytes, lock_bytes)
          if profile.nil?
            profile_note = "the checking tools carry no prebuilt gems for this course's Gemfile"
          elsif profile_ready?(ruby_exe, ruby_bin, profile)
            return { "gemfile" => profile["gemfile"], "bundle_path" => profile["dir"], "ruby_bin" => ruby_bin, "ruby_exe" => ruby_exe, "profile" => true }
          else
            profile_note = "the prebuilt gems did not pass bundle check: #{@profile_failure || 'no answer in time'}"
          end
        end
        if Reach::Untar.windows?
          raise Reach::Error, "reach: the checking tools could not be used (#{profile_note || 'no runtime kit is installed'}); " \
                              "rEach does not compile gems on Windows. Run `reach runtime install` to reinstall the checking tools, then run reach qualify again"
        end

        env_dir = bundle_env_dir(gemfile_bytes, lock_bytes)
        marker = File.join(env_dir, ".installed")
        env_gemfile = File.join(env_dir, "Gemfile")
        result = { "gemfile" => env_gemfile, "bundle_path" => Reach::Paths.gems_dir, "ruby_bin" => ruby_bin, "ruby_exe" => ruby_exe, "profile" => false }
        return result if File.file?(marker)

        FileUtils.mkdir_p(env_dir)
        File.binwrite(env_gemfile, gemfile_bytes)
        File.binwrite(File.join(env_dir, "Gemfile.lock"), lock_bytes)
        env = { "BUNDLE_GEMFILE" => env_gemfile, "BUNDLE_PATH" => Reach::Paths.gems_dir }
        command = runtime ? [ruby_exe, File.join(ruby_bin, "bundle"), "install", "--quiet"] : ["bundle", "install", "--quiet"]
        env["PATH"] = "#{ruby_bin}#{File::PATH_SEPARATOR}#{ENV['PATH']}" if ruby_bin
        env = Reach::RuntimeKit.clean_env(env) if runtime
        stdout, stderr, status = Open3.capture3(env, *command, chdir: env_dir)
        unless status.success?
          hint = if runtime
                   " (#{profile_note})"
                 elsif Reach::RuntimeAuto.installing?
                   Reach::RuntimeAuto::STILL_INSTALLING
                 else
                   " (run `reach runtime install` to get the course's checking tools)"
                 end
          raise Reach::Error, "reach: could not install the checking tools (#{install_failure_reason(stdout, stderr)})#{hint}"
        end

        File.write(marker, Time.now.utc.iso8601)
        result
      end

      def normalized_gemfile(bytes)
        bytes.to_s.gsub("\r\n", "\n")
      end

      def lock_without_platforms(bytes)
        normalized_gemfile(bytes).sub(/^PLATFORMS\n(?:[ \t]+[^\n]*\n|\n)*/, "")
      end

      def profile_covering(runtime, gemfile_bytes, lock_bytes)
        wanted = normalized_gemfile(gemfile_bytes)
        return nil if wanted.empty? || lock_bytes.to_s.empty?

        Array(runtime["profiles"]).each do |entry|
          dir = entry["dir"].to_s
          gemfile = File.join(dir, "Gemfile")
          lock = File.join(dir, "Gemfile.lock")
          next unless File.directory?(dir) && File.file?(gemfile) && File.file?(lock)
          next unless normalized_gemfile(File.binread(gemfile)) == wanted
          next unless profile_lock_matches?(entry, File.binread(lock), lock_bytes)

          return { "dir" => dir, "gemfile" => gemfile, "lock" => lock }
        end
        nil
      rescue SystemCallError
        nil
      end

      def profile_lock_matches?(entry, installed_lock, wanted_lock)
        wanted = lock_without_platforms(wanted_lock)
        return true if lock_without_platforms(installed_lock) == wanted

        name = entry["name"].to_s
        return false unless name.match?(/\A[A-Za-z0-9_-]+\z/)

        source = File.join(Reach::Runtime.root, "runtime", "locks", name, "Gemfile.lock")
        return false unless File.file?(source)

        bytes = File.binread(source)
        Reach::RuntimeKit.lock_digests(bytes).include?(entry["lock_sha256"]) && lock_without_platforms(bytes) == wanted
      end

      def bundle_env_dir(gemfile_bytes, lock_bytes)
        File.join(Reach::Paths.gems_dir, "bundle-envs", Digest::SHA256.hexdigest(gemfile_bytes + lock_bytes))
      end

      def gems_ready?(kit_dir)
        gemfile = File.join(kit_dir, "Gemfile")
        lock = File.join(kit_dir, "Gemfile.lock")
        return false unless File.file?(gemfile) && File.file?(lock)

        gemfile_bytes = File.binread(gemfile)
        lock_bytes = File.binread(lock)
        runtime = Reach::RuntimeKit.active
        return true if runtime && runtime["ruby_exe"] && Reach::RuntimeKit.gems_for(lock_bytes)

        File.file?(File.join(bundle_env_dir(gemfile_bytes, lock_bytes), ".installed"))
      end

      def install_failure_reason(stdout, stderr)
        out_lines = stdout.to_s.lines.map(&:strip).reject(&:empty?)
        err_lines = stderr.to_s.lines.map(&:strip).reject(&:empty?)
        line = (err_lines + out_lines).find { |candidate| candidate =~ /error|could not|failed|cannot/i } ||
               err_lines.first || out_lines.last || "bundle install exited without a message"
        gem_name = failing_gem(stdout, stderr)
        line = line[0, 300]
        native = "#{stderr}\n#{stdout}".match?(/Gem::Ext::BuildError|Failed to build gem native extension/)
        return "the gem #{gem_name || 'a gem'} needs a compiler this computer does not have (#{line})" if native

        gem_name ? "the gem #{gem_name} failed to install: #{line}" : line
      end

      def failing_gem(stdout, stderr)
        text = "#{stderr}\n#{stdout}"
        text[/An error occurred while installing ([A-Za-z0-9_.\-]+)(?: \(|,)/, 1]
      end

      CHECK_TIMEOUT_S = 180

      def profile_ready?(ruby_exe, ruby_bin, profile)
        @profile_failure = nil
        env = Reach::RuntimeKit.clean_env("BUNDLE_GEMFILE" => profile["gemfile"], "BUNDLE_PATH" => profile["dir"], "BUNDLE_FROZEN" => "true",
                                          "PATH" => "#{ruby_bin}#{File::PATH_SEPARATOR}#{ENV['PATH']}")
        stdout = String.new
        stderr = String.new
        status = nil
        timed_out = false
        group = Reach::Untar.windows? ? { new_pgroup: true } : { pgroup: true }
        Open3.popen3(env, ruby_exe, File.join(ruby_bin, "bundle"), "check", chdir: profile["dir"], **group) do |stdin, out, err, waiter|
          stdin.close
          readers = [Thread.new { pump(out, stdout) }, Thread.new { pump(err, stderr) }]
          unless waiter.join(CHECK_TIMEOUT_S)
            timed_out = true
            kill_tree(waiter.pid)
            waiter.join
          end
          readers.each { |reader| reader.join(PIPE_GRACE_S) || reader.kill }
          status = waiter.value
        end
        if timed_out
          @profile_failure = "bundle check did not finish in #{CHECK_TIMEOUT_S} s"
          return false
        end
        return true if status.success?

        @profile_failure = install_failure_reason(stdout, stderr)
        false
      rescue StandardError => e
        @profile_failure = e.message.to_s.lines.first.to_s.strip[0, 300]
        false
      end

      def chromium_binary
        candidate = ENV["REACH_CHROME"].to_s
        return candidate unless candidate.empty?

        runtime = Reach::RuntimeKit.active
        return runtime["chrome_exe"] if runtime && runtime["chrome_exe"]

        %w[google-chrome chromium chromium-browser microsoft-edge].each do |name|
          found = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |path| File.executable?(path) }
          return found if found
        end
        pinned = File.join(Reach::Paths.chromium_dir, "chrome")
        File.file?(pinned) ? pinned : nil
      end

      def sandbox_blocked?(chrome)
        return false unless RUBY_PLATFORM =~ /linux/

        return true if Process.uid.zero?

        runtime = Reach::RuntimeKit.active
        return false unless runtime && runtime["chrome_exe"] && chrome == runtime["chrome_exe"]

        File.file?("/proc/sys/kernel/apparmor_restrict_unprivileged_userns") &&
          File.read("/proc/sys/kernel/apparmor_restrict_unprivileged_userns").strip == "1"
      rescue SystemCallError
        false
      end

      def cucumber(run_dir, gems, tags, extra_env = {})
        gems = { "gemfile" => gems, "bundle_path" => Reach::Paths.gems_dir } if gems.is_a?(String)
        ruby_exe = gems["ruby_exe"]
        ruby_bin = gems["ruby_bin"]
        env = { "BUNDLE_GEMFILE" => gems["gemfile"], "BUNDLE_PATH" => gems["bundle_path"], "CUCUMBER_PUBLISH_QUIET" => "true" }
        env["BUNDLE_FROZEN"] = "true" if gems["profile"]
        env["PATH"] = "#{ruby_bin}#{File::PATH_SEPARATOR}#{ENV['PATH']}" if ruby_bin
        chrome = chromium_binary
        env["REACH_CHROME"] = chrome if chrome
        env["CUPRITE_NO_SANDBOX"] = "1" if sandbox_blocked?(chrome)
        env.merge!(extra_env)
        env = Reach::RuntimeKit.clean_env(env) if ruby_exe && ruby_bin
        args = ruby_exe && ruby_bin ? [ruby_exe, File.join(ruby_bin, "bundle"), "exec", "cucumber", "--format", "json"] : ["bundle", "exec", "cucumber", "--format", "json"]
        Array(tags).each { |tag| args += ["--tags", tag] }

        stdout = +""
        stderr = +""
        status = nil
        timed_out = false
        group = Reach::Untar.windows? ? { new_pgroup: true } : { pgroup: true }
        Open3.popen3(env, *args, chdir: run_dir, **group) do |stdin, out, err, wait_thr|
          stdin.close
          out_buffer = String.new
          err_buffer = String.new
          out_reader = Thread.new { pump(out, out_buffer) }
          err_reader = Thread.new { pump(err, err_buffer) }
          unless wait_thr.join(RUN_TIMEOUT_S)
            timed_out = true
            kill_tree(wait_thr.pid)
            wait_thr.join
          end
          [out_reader, err_reader].each { |reader| reader.join(PIPE_GRACE_S) || reader.kill }
          stdout = out_buffer.dup.force_encoding(Encoding::UTF_8).scrub
          stderr = err_buffer.dup.force_encoding(Encoding::UTF_8).scrub
          status = wait_thr.value
        end
        { "stdout" => stdout, "stderr" => stderr, "status" => status && status.exitstatus, "timed_out" => timed_out, "command" => args }
      end

      def pump(stream, buffer)
        loop { buffer << stream.readpartial(CHUNK_BYTES) }
      rescue EOFError, IOError
        nil
      end

      def kill_tree(pid)
        if Reach::Untar.windows?
          system("taskkill", "/PID", pid.to_s, "/T", "/F", out: File::NULL, err: File::NULL)
        else
          begin
            Process.kill("KILL", -pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
        end
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def report_rows(stdout)
        features = JSON.parse(stdout.to_s)
        rows = []
        Array(features).each do |feature|
          Array(feature["elements"]).each do |element|
            next unless element["type"] == "scenario"

            rows << report_row(element)
          end
        end
        rows
      rescue JSON::ParserError
        nil
      end

      def report_row(element)
        steps = Array(element["steps"])
        hooks = Array(element["before"]) + Array(element["after"])
        bad_step = steps.find { |step| %w[failed undefined pending ambiguous].include?(step.dig("result", "status")) }
        bad_hook = hooks.find { |hook| hook.dig("result", "status") == "failed" }
        statuses = steps.map { |step| step.dig("result", "status") }
        result = if bad_step || bad_hook
                   "failed"
                 elsif !statuses.empty? && statuses.all? { |status| status == "passed" }
                   "passed"
                 else
                   "skipped"
                 end
        culprit = bad_step || bad_hook
        message = culprit ? culprit.dig("result", "error_message").to_s : ""
        message = "the step \"#{bad_step['name']}\" has no step definition" if bad_step && bad_step.dig("result", "status") == "undefined"
        {
          "name" => element["name"].to_s,
          "tags" => Array(element["tags"]).map { |tag| tag["name"].to_s },
          "result" => result,
          "step" => bad_step ? "#{bad_step['keyword'].to_s.strip} #{bad_step['name']}".strip : nil,
          "message" => message.empty? ? nil : message[0, 500]
        }
      end
    end
  end
end
