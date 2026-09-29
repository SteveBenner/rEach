require "open3"
require "json"
require "fileutils"
require "tmpdir"
require "time"
require "digest"
require "yaml"

module Reach
  module Suite
    SUITE_KIND = "suite"
    TIMEOUT_S = 90
    RUBY26_CEILING = Gem::Version.new("3.1.999")

    class << self
      def run(slice:)
        workspace = resolve_workspace(slice)
        manifest = read_manifest(workspace)
        run_dir = assemble_run_dir(workspace, manifest)
        gemfile_path = ensure_gems_installed(run_dir)
        started_at = Time.now
        stdout, stderr, status = run_cucumber(run_dir, gemfile_path, manifest.fetch("tags", []))
        duration_ms = ((Time.now - started_at) * 1000).round
        if duration_ms > TIMEOUT_S * 1000
          return { duration_ms: duration_ms, scenarios: [], timed_out: true }
        end

        { duration_ms: duration_ms, scenarios: parse_results(stdout, stderr, status) }
      end

      def gemfile_lock_for(ruby_version = RUBY_VERSION)
        Gem::Version.new(ruby_version) <= RUBY26_CEILING ? "Gemfile.ruby26.lock" : "Gemfile.lock"
      end

      def reference_panel_dir(module_id)
        ensure_suite_unpacked(module_id)
        panel = File.join(reference_dir(module_id), "modules", module_id.to_s, "panel")
        File.directory?(panel) ? panel : nil
      rescue Reach::Refused
        nil
      end

      private

      def resolve_workspace(slice)
        return slice if slice.is_a?(String) && File.directory?(File.join(slice, ".reach"))

        match = Reach::Workspace.current_slices.find do |path|
          File.basename(path) == slice.to_s || slice_id_of(path) == slice.to_s
        end
        raise Reach::Refused, "reach: no workspace found for slice #{slice.inspect}" unless match

        match
      end

      def slice_id_of(workspace_path)
        Reach::Workspace.metadata(workspace_path)["slice"]
      end

      def read_manifest(workspace_path)
        Reach::Workspace.metadata(workspace_path)
      end

      def suite_dir
        Reach::Paths.suite_vault_dir
      end

      def reference_dir(module_id)
        File.join(suite_dir, "reference_build", module_id.to_s)
      end

      def ensure_suite_unpacked(module_id)
        packages = Reach::Packages.new
        version = packages.latest_version(SUITE_KIND)
        raise Reach::Refused, Reach::Messages.text("M-TIPS-INCOMPLETE") unless version

        marker = File.join(suite_dir, ".version")
        current = File.file?(marker) ? File.read(marker).strip.to_i : nil
        unless current == version && File.directory?(File.join(suite_dir, "reference_build"))
          packages.unpack(SUITE_KIND, version, into: suite_dir)
          File.write(marker, version.to_s)
        end

        module_dir = reference_dir(module_id)
        raise Reach::Refused, Reach::Messages.text("M-TIPS-INCOMPLETE") unless !module_id.to_s.empty? && File.directory?(module_dir) && !Dir.children(module_dir).empty?
      end

      def assemble_run_dir(workspace_path, manifest)
        module_id = manifest["module"]
        ensure_suite_unpacked(module_id)
        run_dir = File.join(Reach::Paths.vault_dir, "runs", File.basename(workspace_path))
        FileUtils.rm_rf(run_dir)
        FileUtils.mkdir_p(run_dir)
        FileUtils.cp_r(Dir.glob(File.join(reference_dir(module_id), "*")), run_dir)
        features_source = File.join(suite_dir, "features")
        if File.directory?(features_source)
          FileUtils.mkdir_p(File.join(run_dir, "features"))
          FileUtils.cp_r(Dir.glob(File.join(features_source, "*")), File.join(run_dir, "features"))
        end
        %w[Gemfile Gemfile.lock Gemfile.ruby26.lock reasons.yml].each do |name|
          source = File.join(suite_dir, name)
          FileUtils.cp(source, File.join(run_dir, name)) if File.file?(source)
        end
        chosen_lock_name = gemfile_lock_for
        if chosen_lock_name != "Gemfile.lock"
          chosen_source = File.join(run_dir, chosen_lock_name)
          FileUtils.cp(chosen_source, File.join(run_dir, "Gemfile.lock")) if File.file?(chosen_source)
        end
        owned = Reach::Workspace.owned_files(workspace_path)
        owned.each do |relative_path|
          source = File.join(workspace_path, relative_path)
          next unless File.file?(source)

          destination = File.join(run_dir, relative_path)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(source, destination)
        end
        manifest["run_dir"] = run_dir
        run_dir
      end

      def bundle_env_dir
        File.join(Reach::Paths.gems_dir, "bundle-env")
      end

      def bundle_envs_dir
        File.join(Reach::Paths.gems_dir, "bundle-envs")
      end

      def selected_lock_path
        File.expand_path(File.join(__dir__, "..", "..", gemfile_lock_for))
      end

      def ensure_gems_installed(run_dir)
        vault_gemfile = File.join(run_dir, "Gemfile")
        return ensure_vault_gems_installed(run_dir, vault_gemfile) if File.file?(vault_gemfile)

        ensure_fallback_gems_installed
      end

      def ensure_vault_gems_installed(run_dir, vault_gemfile)
        lock_name = gemfile_lock_for
        lock_path = File.join(run_dir, lock_name)
        lock_path = File.join(run_dir, "Gemfile.lock") unless File.file?(lock_path)
        raise Reach::Error, "reach: the tips suite carries no #{lock_name}" unless File.file?(lock_path)

        gemfile_bytes = File.binread(vault_gemfile)
        lock_bytes = File.binread(lock_path)
        digest = Digest::SHA256.hexdigest(gemfile_bytes + lock_bytes)
        env_dir = File.join(bundle_envs_dir, digest)
        marker = File.join(env_dir, ".installed")
        env_gemfile = File.join(env_dir, "Gemfile")
        return env_gemfile if File.file?(marker)

        FileUtils.mkdir_p(env_dir)
        File.binwrite(env_gemfile, gemfile_bytes)
        File.binwrite(File.join(env_dir, "Gemfile.lock"), lock_bytes)

        env = { "BUNDLE_GEMFILE" => env_gemfile, "BUNDLE_PATH" => Reach::Paths.gems_dir }
        _stdout, stderr, status = Open3.capture3(env, "bundle", "install", "--quiet", chdir: env_dir)
        raise Reach::Error, "reach: could not install the tips suite's gems (#{stderr.strip})" unless status.success?

        File.write(marker, Time.now.utc.iso8601)
        env_gemfile
      end

      def ensure_fallback_gems_installed
        marker = File.join(bundle_env_dir, ".installed-#{gemfile_lock_for}")
        gemfile_path = File.join(bundle_env_dir, "Gemfile")
        return gemfile_path if File.file?(marker)

        FileUtils.mkdir_p(bundle_env_dir)
        lock_path = File.join(bundle_env_dir, "Gemfile.lock")
        File.write(gemfile_path, generated_gemfile_source)
        FileUtils.cp(selected_lock_path, lock_path)

        env = { "BUNDLE_GEMFILE" => gemfile_path }
        _stdout, stderr, status = Open3.capture3(
          env,
          "bundle", "install",
          "--path", Reach::Paths.gems_dir,
          "--deployment",
          "--quiet"
        )
        raise Reach::Error, "reach: could not install the tips suite's gems (#{stderr.strip})" unless status.success?

        File.write(marker, Time.now.utc.iso8601)
        gemfile_path
      end

      def generated_gemfile_source
        <<~GEMFILE
          source "https://rubygems.org"

          gem "cucumber"
          gem "capybara"
          gem "cuprite"
          gem "ferrum"
          gem "nokogiri"
        GEMFILE
      end

      def chromium_binary
        candidate = ENV["REACH_CHROME"].to_s
        return candidate unless candidate.empty?

        %w[google-chrome chromium chromium-browser microsoft-edge].each do |name|
          _out, _err, status = Open3.capture3("which", name)
          return name if status.success?
        end
        pinned = File.join(Reach::Paths.chromium_dir, "chrome")
        File.file?(pinned) ? pinned : nil
      end

      def run_cucumber(run_dir, gemfile_path, tags)
        env = {
          "BUNDLE_GEMFILE" => gemfile_path,
          "BUNDLE_PATH" => Reach::Paths.gems_dir
        }
        chrome = chromium_binary
        env["REACH_CHROME"] = chrome if chrome

        args = ["bundle", "exec", "cucumber", "--format", "json"]
        Array(tags).each { |tag| args += ["--tags", tag] }

        Open3.capture3(env, *args, chdir: run_dir)
      end

      def parse_results(stdout, _stderr, status)
        return [] if stdout.to_s.strip.empty?

        begin
          features = JSON.parse(stdout)
        rescue JSON::ParserError
          return status.success? ? [] : [{ name: "reach tips", passed: false, reason: failure_reason_for("resilience"), category: "resilience" }]
        end

        scenarios = []
        features.each do |feature|
          Array(feature["elements"]).each do |element|
            next unless element["type"] == "scenario"

            steps = Array(element["steps"])
            failed_step = steps.find { |step| step.dig("result", "status") == "failed" }
            passed = failed_step.nil?
            message = failed_step ? failed_step.dig("result", "error_message").to_s : ""
            category = message.include?("not_built") ? "not_built" : category_for(Array(element["tags"]))
            reason = passed ? nil : failure_reason_for(category)
            scenarios << {
              name: element["name"].to_s,
              passed: passed,
              reason: reason,
              category: passed ? nil : category
            }
          end
        end
        scenarios
      end

      def failure_reason_for(category)
        suite_reasons[category.to_s] || Reach::Messages.failure_reason(category)
      end

      def suite_reasons
        path = File.join(suite_dir, "reasons.yml")
        return {} unless File.file?(path)

        data = YAML.safe_load(File.read(path))
        data.is_a?(Hash) ? data.select { |_, text| text.is_a?(String) && !text.strip.empty? } : {}
      rescue Psych::Exception
        {}
      end

      def category_for(tags)
        tag = Array(tags).map { |t| t["name"].to_s }.find { |name| name.start_with?("@category:") }
        tag ? tag.sub("@category:", "") : "behaviour"
      end
    end
  end
end
