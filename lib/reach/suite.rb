require "open3"
require "json"
require "fileutils"
require "time"
require "digest"
require "timeout"

module Reach
  module Suite
    SUITE_KIND = "suite"
    RUBY26_CEILING = Gem::Version.new("3.1.999")
    RUN_TIMEOUT_S = 300

    class << self
      def gemfile_lock_for(ruby_version = RUBY_VERSION)
        Gem::Version.new(ruby_version) <= RUBY26_CEILING ? "Gemfile.ruby26.lock" : "Gemfile.lock"
      end

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

      def select_lock!(run_dir)
        chosen = gemfile_lock_for
        return if chosen == "Gemfile.lock"

        source = File.join(run_dir, chosen)
        FileUtils.cp(source, File.join(run_dir, "Gemfile.lock")) if File.file?(source)
      end

      def install_gems(run_dir)
        gemfile = File.join(run_dir, "Gemfile")
        lock = File.join(run_dir, "Gemfile.lock")
        raise Reach::Error, "reach: the qualify kit carries no Gemfile; run reach sync" unless File.file?(gemfile) && File.file?(lock)

        gemfile_bytes = File.binread(gemfile)
        lock_bytes = File.binread(lock)
        env_dir = File.join(Reach::Paths.gems_dir, "bundle-envs", Digest::SHA256.hexdigest(gemfile_bytes + lock_bytes))
        marker = File.join(env_dir, ".installed")
        env_gemfile = File.join(env_dir, "Gemfile")
        return env_gemfile if File.file?(marker)

        FileUtils.mkdir_p(env_dir)
        File.binwrite(env_gemfile, gemfile_bytes)
        File.binwrite(File.join(env_dir, "Gemfile.lock"), lock_bytes)
        env = { "BUNDLE_GEMFILE" => env_gemfile, "BUNDLE_PATH" => Reach::Paths.gems_dir }
        _stdout, stderr, status = Open3.capture3(env, "bundle", "install", "--quiet", chdir: env_dir)
        raise Reach::Error, "reach: could not install the checking tools (#{stderr.strip.lines.first.to_s.strip})" unless status.success?

        File.write(marker, Time.now.utc.iso8601)
        env_gemfile
      end

      def chromium_binary
        candidate = ENV["REACH_CHROME"].to_s
        return candidate unless candidate.empty?

        %w[google-chrome chromium chromium-browser microsoft-edge].each do |name|
          found = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |path| File.executable?(path) }
          return found if found
        end
        pinned = File.join(Reach::Paths.chromium_dir, "chrome")
        File.file?(pinned) ? pinned : nil
      end

      def cucumber(run_dir, gemfile, tags)
        env = { "BUNDLE_GEMFILE" => gemfile, "BUNDLE_PATH" => Reach::Paths.gems_dir, "CUCUMBER_PUBLISH_QUIET" => "true" }
        chrome = chromium_binary
        env["REACH_CHROME"] = chrome if chrome
        args = ["bundle", "exec", "cucumber", "--format", "json"]
        Array(tags).each { |tag| args += ["--tags", tag] }

        stdout = +""
        stderr = +""
        status = nil
        timed_out = false
        Open3.popen3(env, *args, chdir: run_dir) do |stdin, out, err, wait_thr|
          stdin.close
          out_reader = Thread.new { out.read }
          err_reader = Thread.new { err.read }
          unless wait_thr.join(RUN_TIMEOUT_S)
            timed_out = true
            begin
              Process.kill("KILL", wait_thr.pid)
            rescue Errno::ESRCH, Errno::EPERM
              nil
            end
            wait_thr.join
          end
          stdout = out_reader.value.to_s
          stderr = err_reader.value.to_s
          status = wait_thr.value
        end
        { "stdout" => stdout, "stderr" => stderr, "status" => status && status.exitstatus, "timed_out" => timed_out }
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
