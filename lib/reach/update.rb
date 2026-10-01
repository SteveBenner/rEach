require "json"
require "net/http"
require "openssl"
require "open3"
require "timeout"
require "uri"
require "time"
require "fileutils"
require "rbconfig"
require "securerandom"

module Reach
  module Update
    SCHEMA = "reach.update/v1".freeze
    DEFAULT_REPOSITORY = "https://github.com/SteveBenner/rEach".freeze
    DEFAULT_INTERVAL_S = 3600
    DEFAULT_JITTER_S = 600
    MAX_BACKOFF_S = 86_400
    DEFAULT_MAX_ATTEMPTS = 5
    CONNECT_TIMEOUT_S = 10
    LISTING_READ_TIMEOUT_S = 30
    HTTP_ATTEMPTS = 3
    RETRY_AFTER_CAP_S = 300
    RELEASES_PER_PAGE = 30
    APPLY_TIMEOUT_S = 600
    ANNOUNCE_KEEP = 50
    DONE_WINDOW_S = 3600
    ACTIVE_PHASES = %w[detected downloaded staged swapped refreshed].freeze
    VERSION_TAG = /\Av?(\d+\.\d+\.\d+)\z/.freeze
    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError, EOFError
    ].freeze

    module_function

    def defaults
      {
        "schema" => SCHEMA,
        "local_version" => nil,
        "remote_versions" => [],
        "source" => "none",
        "target_version" => nil,
        "target_tag" => nil,
        "phase" => "idle",
        "applying" => false,
        "staged_path" => nil,
        "backup_path" => nil,
        "started_at" => nil,
        "updated_at" => nil,
        "attempts" => 0,
        "last_check_at" => nil,
        "next_check_at" => nil,
        "failures" => 0,
        "last_error" => nil,
        "etag" => nil,
        "releases_blocked_until" => nil,
        "harness_results" => {},
        "announced" => {},
        "sessions" => {},
        "completed_version" => nil,
        "completed_at" => nil
      }
    end

    def now_s
      Time.now.utc.iso8601
    end

    def parse_time(value)
      return nil if value.nil? || value.to_s.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def load_manifest
      parsed = JSON.parse(File.read(Reach::Paths.update_manifest_file))
      parsed.is_a?(Hash) ? defaults.merge(parsed) : defaults
    rescue StandardError
      defaults
    end

    def save_manifest(manifest)
      manifest["updated_at"] = now_s
      file = Reach::Paths.update_manifest_file
      merge_session_records(manifest, file)
      FileUtils.mkdir_p(File.dirname(file))
      temp = "#{file}.tmp.#{Process.pid}.#{rand(1_000_000)}"
      File.open(temp, "w", 0o600) { |handle| handle.write(JSON.pretty_generate(manifest)) }
      File.rename(temp, file)
      manifest
    end

    def merge_session_records(manifest, file)
      return unless File.file?(file)

      disk = JSON.parse(File.read(file))
      return unless disk.is_a?(Hash)

      %w[announced sessions].each do |key|
        stored = disk[key]
        next unless stored.is_a?(Hash)

        current = manifest[key].is_a?(Hash) ? manifest[key] : {}
        if key == "announced"
          stored.each { |name, ids| current[name] = (Array(ids) | Array(current[name])).last(ANNOUNCE_KEEP) }
        else
          stored.each { |id, at| current[id] ||= at }
          current = current.to_a.sort_by { |_id, at| at.to_s }.last(ANNOUNCE_KEEP).to_h
        end
        manifest[key] = current
      end
    rescue StandardError
      nil
    end

    def record_session!(session_id)
      return if session_id.to_s.empty?

      manifest = load_manifest
      sessions = manifest["sessions"].is_a?(Hash) ? manifest["sessions"] : {}
      return if sessions.key?(session_id.to_s)

      sessions[session_id.to_s] = now_s
      manifest["sessions"] = sessions
      save_manifest(manifest)
    end

    def session_started_before?(manifest, session_id, time)
      sessions = manifest["sessions"]
      return false unless sessions.is_a?(Hash) && time

      started = parse_time(sessions[session_id.to_s])
      started ? started < time : false
    end

    def setting_int(value, default)
      number = Integer(value)
      number > 0 ? number : default
    rescue ArgumentError, TypeError
      default
    end

    def config
      section = Reach::Runtime.load_config["updates"]
      section = {} unless section.is_a?(Hash)
      repository = ENV["REACH_UPDATE_REPOSITORY"].to_s
      repository = section["repository"].to_s if repository.empty?
      repository = DEFAULT_REPOSITORY if repository.empty?
      {
        "repository" => repository,
        "interval_s" => setting_int(section["interval_s"], DEFAULT_INTERVAL_S),
        "jitter_s" => setting_int(section["jitter_s"], DEFAULT_JITTER_S),
        "max_attempts" => setting_int(section["max_attempts"], DEFAULT_MAX_ATTEMPTS)
      }
    end

    def disabled?
      ENV["REACH_UPDATE_DISABLE"] == "1"
    end

    def offline?
      ENV["REACH_OFFLINE"] == "1"
    end

    def managed?
      dir = Reach::Paths.managed_install_dir
      File.file?(File.join(dir, "VERSION")) && !File.exist?(File.join(dir, ".git"))
    end

    def local_version
      return Reach::VERSION unless managed?

      File.read(File.join(Reach::Paths.managed_install_dir, "VERSION")).strip
    rescue StandardError
      Reach::VERSION
    end

    def owner_repo
      uri = URI(config["repository"])
      raise Reach::Error, "update repository must be an https URL" unless uri.is_a?(URI::HTTPS)

      path = uri.path.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "").sub(/\.git\z/, "").sub(%r{/+\z}, "")
      parts = path.split("/")
      raise Reach::Error, "update repository must be owner/repo" unless parts.length == 2 && parts.none?(&:empty?)

      host = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
      [parts[0], parts[1], host]
    rescue URI::InvalidURIError
      raise Reach::Error, "update repository is not a valid URL"
    end

    def log(event, fields = {})
      FileUtils.mkdir_p(Reach::Paths.logs_dir)
      record = { "at" => now_s, "event" => event }.merge(fields)
      File.open(Reach::Paths.update_log_file, "a", 0o600) { |handle| handle.puts(JSON.generate(record)) }
      nil
    rescue StandardError
      nil
    end

    def retry_after(response)
      value = response["retry-after"]
      return nil unless value && value.to_s.strip =~ /\A\d+\z/

      [value.to_i, RETRY_AFTER_CAP_S].min
    end

    def request_once(uri, headers, read_timeout)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: CONNECT_TIMEOUT_S, read_timeout: read_timeout) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri, headers))
      end
    end

    def http_get(uri, headers, read_timeout, destination: nil, redirects: 0)
      uri = URI(uri.to_s)
      raise Reach::Error, "only https URLs are allowed" unless uri.is_a?(URI::HTTPS)
      raise Reach::Error, "too many redirects" if redirects > 5

      last = nil
      HTTP_ATTEMPTS.times do |attempt|
        wait = nil
        begin
          response = request_once(uri, headers, read_timeout)
          if response.is_a?(Net::HTTPRedirection)
            target = URI.join(uri, response.fetch("location"))
            return http_get(target, headers, read_timeout, destination: destination, redirects: redirects + 1)
          end
          if response.code.to_i >= 500
            last = "HTTP #{response.code}"
            wait = retry_after(response)
          else
            File.binwrite(destination, response.body.to_s) if destination && response.is_a?(Net::HTTPSuccess)
            return response
          end
        rescue *NETWORK_ERRORS => e
          last = e.message
        end
        sleep(wait || (rand * (2**attempt))) if attempt + 1 < HTTP_ATTEMPTS
      end
      raise Reach::NetworkError, "request to #{uri.host} failed: #{last}"
    end

    def api_headers(manifest)
      headers = {
        "Accept" => "application/vnd.github+json",
        "User-Agent" => "rEach/#{Reach::VERSION}",
        "X-GitHub-Api-Version" => "2022-11-28"
      }
      headers["If-None-Match"] = manifest["etag"] if manifest["etag"].to_s != ""
      headers
    end

    def list_releases(manifest)
      blocked = parse_time(manifest["releases_blocked_until"])
      return nil if blocked && blocked > Time.now

      owner, repo, _host = owner_repo
      uri = URI("https://api.github.com/repos/#{owner}/#{repo}/releases?per_page=#{RELEASES_PER_PAGE}")
      response = http_get(uri, api_headers(manifest), LISTING_READ_TIMEOUT_S)
      case response.code.to_i
      when 304
        cached = manifest["cached_releases"]
        cached.is_a?(Array) ? cached : nil
      when 200
        parsed = JSON.parse(response.body.to_s)
        return nil unless parsed.is_a?(Array)

        list = []
        parsed.each do |entry|
          next unless entry.is_a?(Hash) && entry["draft"] != true && entry["prerelease"] != true

          match = VERSION_TAG.match(entry["tag_name"].to_s)
          list << { "version" => match[1], "tag" => entry["tag_name"].to_s, "source" => "releases" } if match
        end
        manifest["etag"] = response["etag"]
        manifest["cached_releases"] = list
        list
      when 403, 429
        reset = response["x-ratelimit-reset"].to_i
        until_time = [Time.at(reset), Time.now + 3600].max
        manifest["releases_blocked_until"] = until_time.utc.iso8601
        nil
      end
    rescue StandardError
      nil
    end

    def parse_pkt_lines(data)
      data = data.to_s.dup.force_encoding(Encoding::BINARY)
      lines = []
      position = 0
      while position + 4 <= data.bytesize
        length = data.byteslice(position, 4).to_i(16)
        if length.zero?
          position += 4
          next
        end
        break if length < 4

        lines << data.byteslice(position + 4, length - 4).to_s
        position += length
      end
      lines.map { |line| line.sub(/\0.*\z/m, "").chomp }
    end

    def list_tags
      owner, repo, host = owner_repo
      uri = URI("https://#{host}/#{owner}/#{repo}.git/info/refs?service=git-upload-pack")
      response = http_get(uri, { "User-Agent" => "git/2.0 (rEach/#{Reach::VERSION})" }, LISTING_READ_TIMEOUT_S)
      raise Reach::NetworkError, "tag listing returned HTTP #{response.code}" unless response.code.to_i == 200

      list = []
      parse_pkt_lines(response.body).each do |line|
        match = %r{\A\h+ refs/tags/(v?\d+\.\d+\.\d+)\z}.match(line)
        next unless match

        list << { "version" => VERSION_TAG.match(match[1])[1], "tag" => match[1], "source" => "tags" }
      end
      list
    end

    def check_due?(manifest)
      return false if disabled? || offline?

      due = parse_time(manifest["next_check_at"])
      due.nil? || due <= Time.now
    end

    def check(manifest)
      settings = config
      local = local_version
      releases = list_releases(manifest)
      candidates = releases && !releases.empty? ? releases : list_tags
      seen = {}
      unique = candidates.select do |entry|
        next false if seen[entry["version"]]

        seen[entry["version"]] = true
      end
      newer = unique.select { |entry| Gem::Version.new(entry["version"]) > Gem::Version.new(local) }
      newer.sort_by! { |entry| Gem::Version.new(entry["version"]) }
      manifest["local_version"] = local
      manifest["remote_versions"] = newer
      manifest["source"] = newer.empty? ? (unique.empty? ? "none" : unique.first["source"]) : newer.last["source"]
      manifest["last_check_at"] = now_s
      manifest["failures"] = 0
      manifest["next_check_at"] = (Time.now.utc + settings["interval_s"] + rand(settings["jitter_s"] + 1)).iso8601
      resuming = manifest["applying"] == true || %w[swapped refreshed].include?(manifest["phase"])
      if !newer.empty?
        newest = newer.last
        if newest["version"] != manifest["target_version"] && !resuming
          manifest["target_version"] = newest["version"]
          manifest["target_tag"] = newest["tag"]
          manifest["phase"] = "detected"
          manifest["attempts"] = 0
          manifest["last_error"] = nil
          manifest["staged_path"] = nil
        end
      elsif !ACTIVE_PHASES.include?(manifest["phase"])
        manifest["phase"] = "idle"
      end
      save_manifest(manifest)
      log("check", "source" => manifest["source"], "local" => local, "remote" => newer.map { |entry| entry["version"] }, "phase" => manifest["phase"])
      manifest
    rescue StandardError => e
      begin
        settings = config
        manifest["failures"] = manifest["failures"].to_i + 1
        manifest["last_error"] = e.message
        backoff = [settings["interval_s"] * (2**manifest["failures"]), MAX_BACKOFF_S].min
        manifest["next_check_at"] = (Time.now.utc + backoff + rand(settings["jitter_s"] + 1)).iso8601
        save_manifest(manifest)
        log("error", "phase" => "check", "message" => e.message, "failures" => manifest["failures"])
      rescue StandardError
        nil
      end
      manifest
    end

    def stage(manifest)
      unless %w[detected downloaded].include?(manifest["phase"]) && manifest["target_tag"].to_s != ""
        raise Reach::Error, "nothing to stage"
      end

      owner, repo, host = owner_repo
      tag = manifest["target_tag"]
      target = manifest["target_version"]
      url = "https://#{host}/#{owner}/#{repo}/archive/refs/tags/#{tag}.zip"
      load File.join(Reach::Runtime.root, "bin", "reach-install") unless defined?(::ReachInstall)
      FileUtils.mkdir_p(Reach::Paths.updates_dir, mode: 0o700)
      Dir[File.join(Reach::Paths.updates_dir, "staging-*")].each { |orphan| remove_staging(orphan) }
      temp = File.join(Reach::Paths.updates_dir, "staging-#{target}-#{SecureRandom.hex(3)}")
      reach_root = ReachInstall.stage(url: url, temp: temp)
      manifest["staging_dir"] = temp
      manifest["phase"] = "downloaded"
      save_manifest(manifest)
      version = File.read(File.join(reach_root, "VERSION")).strip
      raise Reach::Error, "release #{tag} carries VERSION #{version}" unless version == target
      raise Reach::Error, "release #{tag} carries no update/apply.rb" unless File.file?(File.join(reach_root, "update", "apply.rb"))

      manifest["phase"] = "staged"
      manifest["staged_path"] = reach_root
      manifest["last_error"] = nil
      save_manifest(manifest)
      log("stage", "target" => target, "tag" => tag, "staged_path" => reach_root)
      manifest
    rescue StandardError => e
      remove_staging(temp)
      manifest["staging_dir"] = nil
      manifest["attempts"] = manifest["attempts"].to_i + 1
      manifest["last_error"] = e.message
      save_manifest(manifest)
      log("error", "phase" => "stage", "message" => e.message, "attempts" => manifest["attempts"])
      raise
    end

    def remove_staging(path)
      return if path.nil? || path.to_s.empty?

      root = File.expand_path(Reach::Paths.updates_dir) + File::SEPARATOR
      target = File.expand_path(path.to_s)
      FileUtils.rm_rf(target) if target.start_with?(root) && File.basename(target).start_with?("staging-")
    rescue StandardError
      nil
    end

    def run_apply_script(command)
      Open3.popen3(*command) do |stdin, stdout, stderr, waiter|
        stdin.close
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        unless waiter.join(APPLY_TIMEOUT_S)
          begin
            Process.kill("TERM", waiter.pid)
          rescue StandardError
            nil
          end
          raise Reach::Error, "apply.rb timed out after #{APPLY_TIMEOUT_S} s"
        end
        [readers[0].value.to_s, readers[1].value.to_s, waiter.value]
      end
    end

    def apply(manifest, resume: false)
      raise Reach::Error, "no managed install" unless managed?

      phase = manifest["phase"]
      staged = manifest["staged_path"].to_s
      unless %w[staged swapped refreshed].include?(phase) && !staged.empty?
        raise Reach::Error, "nothing to apply"
      end

      resuming = resume || %w[swapped refreshed].include?(phase)
      if phase == "staged" && !File.directory?(staged)
        if local_version == manifest["target_version"]
          manifest["phase"] = "swapped"
          resuming = true
        else
          manifest["phase"] = "detected"
          manifest["applying"] = false
          save_manifest(manifest)
          raise Reach::Error, "staged release vanished"
        end
      end

      manifest["applying"] = true
      manifest["started_at"] ||= now_s
      manifest["local_version"] ||= local_version
      save_manifest(manifest)
      script_dir = resuming ? Reach::Paths.managed_install_dir : staged
      command = [
        RbConfig.ruby, File.join(script_dir, "update", "apply.rb"),
        "--staged", staged, "--destination", Reach::Paths.managed_install_dir,
        "--manifest", Reach::Paths.update_manifest_file,
        "--from", manifest["local_version"].to_s, "--to", manifest["target_version"].to_s
      ]
      command << "--resume" if resuming
      from_version = manifest["local_version"]
      status = nil
      errors = ""
      begin
        _out, errors, status = run_apply_script(command)
      rescue StandardError => e
        errors = e.message
      end
      manifest.replace(defaults.merge(load_manifest))
      if status && status.success? && manifest["phase"] == "completed"
        manifest["applying"] = false
        manifest["attempts"] = 0
        manifest["completed_version"] = manifest["target_version"]
        manifest["completed_at"] ||= now_s
        manifest["local_version"] = manifest["target_version"]
        done = Gem::Version.new(manifest["target_version"])
        manifest["remote_versions"] = Array(manifest["remote_versions"]).select { |entry| Gem::Version.new(entry["version"]) > done }
        manifest["last_error"] = nil
        remove_staging(manifest["staging_dir"])
        manifest["staging_dir"] = nil
        save_manifest(manifest)
        log("apply", "from" => from_version, "to" => manifest["target_version"], "result" => "completed")
        manifest
      else
        message = errors.to_s.lines.map(&:strip).reject(&:empty?).last
        message ||= "apply.rb exited #{status ? status.exitstatus.inspect : 'abnormally'}"
        manifest["applying"] = false
        manifest["attempts"] = manifest["attempts"].to_i + 1
        manifest["last_error"] = message
        save_manifest(manifest)
        log("error", "phase" => "apply", "message" => message, "attempts" => manifest["attempts"])
        raise Reach::Error, message
      end
    end

    def with_lock
      FileUtils.mkdir_p(Reach::Paths.state_dir)
      File.open(Reach::Paths.update_lock_file, File::RDWR | File::CREAT, 0o600) do |handle|
        return :locked unless handle.flock(File::LOCK_EX | File::LOCK_NB)

        begin
          handle.truncate(0)
          handle.rewind
          handle.write("#{Process.pid}\n")
          handle.flush
          yield
        ensure
          handle.flock(File::LOCK_UN)
        end
      end
    end

    def lock_live?
      file = Reach::Paths.update_lock_file
      return false unless File.file?(file)

      File.open(file, "r") do |handle|
        if handle.flock(File::LOCK_SH | File::LOCK_NB)
          handle.flock(File::LOCK_UN)
          false
        else
          true
        end
      end
    rescue StandardError
      false
    end

    def installing?(manifest = load_manifest)
      manifest["applying"] == true && lock_live?
    end

    def hold!
      manifest = load_manifest
      return unless installing?(manifest)

      raise Reach::GateBlocked.new(
        "M-UPDATE-INSTALLING",
        Reach::Messages.text("M-UPDATE-INSTALLING", version: manifest["target_version"])
      )
    rescue Reach::GateBlocked
      raise
    rescue StandardError
      nil
    end

    def interrupted_swap?(manifest)
      return true if %w[swapped refreshed].include?(manifest["phase"])
      return false unless manifest["phase"] == "staged"

      staged = manifest["staged_path"].to_s
      (staged.empty? || !File.directory?(staged)) && manifest["target_version"].to_s == local_version
    rescue StandardError
      false
    end

    def pending_version(manifest)
      target = manifest["target_version"].to_s
      return nil if target.empty? || !ACTIVE_PHASES.include?(manifest["phase"])

      Gem::Version.new(target) > Gem::Version.new(local_version) ? target : nil
    rescue StandardError
      nil
    end

    def spawn_background(apply:)
      return nil if disabled?

      exe = File.join(Reach::Runtime.root, "exe", "reach")
      arguments = [RbConfig.ruby, exe, "update", "run"]
      arguments << "--apply" if apply
      options = { in: File::NULL, out: File::NULL, err: File::NULL }
      if Reach::Runtime.windows?
        options[:new_pgroup] = true
      else
        options[:pgroup] = true
      end
      pid = Process.spawn(*arguments, options)
      Process.detach(pid)
      pid
    rescue StandardError
      nil
    end

    def announce!(key, session_id)
      manifest = load_manifest
      announced = manifest["announced"]
      announced = {} unless announced.is_a?(Hash)
      sessions = Array(announced[key])
      id = session_id.to_s.empty? ? "-" : session_id.to_s
      return false if sessions.include?(id)

      announced[key] = (sessions + [id]).last(ANNOUNCE_KEEP)
      manifest["announced"] = announced
      save_manifest(manifest)
      true
    end

    def announced?(manifest, key, session_id)
      id = session_id.to_s.empty? ? "-" : session_id.to_s
      announced = manifest["announced"]
      announced.is_a?(Hash) && Array(announced[key]).include?(id)
    end

    def on_session_start(session_id)
      return nil if disabled? || !managed?

      record_session!(session_id)
      manifest = load_manifest
      if installing?(manifest)
        announce!("updating:#{manifest['target_version']}", session_id)
        return manifest["target_version"]
      end

      if interrupted_swap?(manifest) && !lock_live?
        spawn_background(apply: true)
        announce!("updating:#{manifest['target_version']}", session_id)
        return manifest["target_version"]
      end

      pending = pending_version(manifest)
      if pending && manifest["attempts"].to_i < config["max_attempts"] && !lock_live?
        spawn_background(apply: true)
        announce!("updating:#{pending}", session_id)
        return pending
      end
      spawn_background(apply: true) if check_due?(manifest) && !lock_live?
      nil
    rescue StandardError
      nil
    end

    def notice_sentence(message_id, version)
      "rEach update: when you finish your current answer, tell the student, in a message of its own, exactly: " +
        Reach::Messages.text(message_id, version: version)
    end

    def prompt_notices(session_id)
      return [] if disabled?

      manifest = load_manifest
      spawn_background(apply: false) if check_due?(manifest) && !lock_live? && managed?
      pending = pending_version(manifest)
      applying = manifest["applying"] == true
      done = manifest["completed_version"].to_s
      candidates = []
      completed_at = parse_time(manifest["completed_at"])
      if !done.empty? && completed_at && (Time.now - completed_at) <= DONE_WINDOW_S &&
         (Gem::Version.new(done) > Gem::Version.new(Reach::VERSION) ||
          announced?(manifest, "updating:#{done}", session_id) || announced?(manifest, "ready:#{done}", session_id) ||
          session_started_before?(manifest, session_id, completed_at))
        candidates << ["done:#{done}", "M-UPDATE-DONE", done]
      end
      if pending && manifest["phase"] == "staged" && !applying
        candidates << ["ready:#{pending}", "M-UPDATE-READY", pending]
      end
      if pending && manifest["last_error"].to_s != "" && !applying && manifest["attempts"].to_i >= 1
        candidates << ["retry:#{pending}", "M-UPDATE-RETRY", pending]
      end
      candidates.each do |key, message_id, version|
        next if announced?(manifest, key, session_id)
        next unless announce!(key, session_id)

        return [notice_sentence(message_id, version)]
      end
      []
    rescue StandardError
      []
    end

    def run(apply: false, force: false)
      return { "skipped" => "disabled" } if disabled?

      outcome = with_lock { run_locked(apply, force) }
      outcome == :locked ? { "skipped" => "locked" } : outcome
    end

    def run_locked(apply, force)
      manifest = load_manifest
      managed = managed?
      if managed && apply && interrupted_swap?(manifest)
        apply(manifest, resume: true)
        manifest = load_manifest
      end
      if manifest["phase"] == "staged" && !File.directory?(manifest["staged_path"].to_s)
        manifest["phase"] = "detected"
        manifest["applying"] = false
        manifest["staged_path"] = nil
        save_manifest(manifest)
      end
      due = check_due?(manifest) || (force && !offline?)
      manifest = check(manifest) if due
      attempts_left = manifest["attempts"].to_i < config["max_attempts"]
      if !attempts_left && !force && %w[detected downloaded staged].include?(manifest["phase"])
        return { "held" => "too many attempts", "phase" => manifest["phase"], "target" => manifest["target_version"], "local" => manifest["local_version"] }
      end
      stage(manifest) if managed && %w[detected downloaded].include?(manifest["phase"])
      apply(manifest) if apply && managed && manifest["phase"] == "staged"
      outcome = { "phase" => manifest["phase"], "target" => manifest["target_version"], "local" => manifest["local_version"] || local_version }
      outcome["error"] = manifest["last_error"] if manifest["failures"].to_i > 0 && manifest["last_error"].to_s != ""
      outcome
    rescue StandardError => e
      { "error" => e.message }
    end

    def status_lines
      manifest = load_manifest
      dir = Reach::Paths.managed_install_dir
      reason = if managed?
                 "yes (#{dir})"
               elsif File.exist?(File.join(dir, ".git"))
                 "no (#{dir} is a git checkout)"
               else
                 "no (no install at #{dir})"
               end
      remote = Array(manifest["remote_versions"]).map { |entry| entry["version"] }
      lines = []
      lines << "updates: #{disabled? ? 'disabled' : 'enabled'}#{offline? ? ' (offline)' : ''}"
      lines << "managed install: #{reason}"
      lines << "local version: #{local_version}"
      lines << "source: #{manifest['source']}"
      lines << "remote versions: #{remote.empty? ? 'none newer' : remote.join(', ')}"
      lines << "target: #{manifest['target_version'] || 'none'}"
      lines << "phase: #{manifest['phase']}#{manifest['applying'] == true ? ' (applying)' : ''}"
      lines << "attempts: #{manifest['attempts']}"
      lines << "last check: #{manifest['last_check_at'] || 'never'}"
      lines << "next check: #{manifest['next_check_at'] || 'due'}"
      lines << "last error: #{manifest['last_error']}" if manifest["last_error"].to_s != ""
      results = manifest["harness_results"]
      if results.is_a?(Hash) && !results.empty?
        lines << "harness results: #{results.map { |id, result| "#{id}=#{result}" }.join(', ')}"
      end
      lines
    end
  end
end
