require "fileutils"
require "json"
require "rbconfig"

module Reach
  module Paths
    module_function

    RESOLUTION_TTL_S = 2
    NEW_HOME_NAME = ".reach-home".freeze

    def root
      override = path_override
      return override[:root] if override && override[:root]

      value = ENV["REACH_ROOT"].to_s
      File.expand_path(value.empty? ? "~/rEach" : value)
    end

    def legacy_home
      File.expand_path("~/.reach")
    end

    def legacy_workspace_root
      File.expand_path("~/reach-work")
    end

    def new_home
      File.join(root, NEW_HOME_NAME)
    end

    def relocation_pointer_file
      File.join(new_home, "state", "relocation.json")
    end

    def with_override(home:, root:)
      previous = Thread.current[:reach_paths_override]
      Thread.current[:reach_paths_override] = { home: File.expand_path(home), root: File.expand_path(root) }
      yield
    ensure
      Thread.current[:reach_paths_override] = previous
    end

    def path_override
      Thread.current[:reach_paths_override]
    end

    def home
      override = path_override
      return override[:home] if override && override[:home]

      value = ENV["REACH_HOME"].to_s
      return File.expand_path(value) unless value.empty?

      resolution[:home]
    end

    def legacy_active?
      return false unless ENV["REACH_HOME"].to_s.empty?
      return false if path_override

      resolution[:mode] == :legacy
    end

    def relocation_completed?
      pointer = relocation_pointer_file
      return false unless File.file?(pointer)

      data = JSON.parse(File.read(pointer))
      data.is_a?(Hash) && data["phase"] == "completed"
    rescue StandardError
      false
    end

    def legacy_present?
      legacy = legacy_home
      File.file?(File.join(legacy, "install.yml")) || File.directory?(File.join(legacy, "plugin"))
    rescue StandardError
      false
    end

    def resolution
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      key = [root, legacy_home]
      cache = (@resolution_cache ||= {})
      return cache[:value] if cache[:value] && cache[:key] == key && now - cache[:at] < RESOLUTION_TTL_S

      value = if relocation_completed?
                { mode: :new, home: new_home }
              elsif legacy_present?
                { mode: :legacy, home: legacy_home }
              else
                { mode: :new, home: new_home }
              end
      @resolution_cache = { value: value, key: key, at: now }
      value
    end

    def forget_resolution!
      @resolution_cache = nil
      nil
    end

    def realish(path)
      expanded = File.expand_path(path.to_s)
      return File.realpath(expanded) if File.exist?(expanded)

      rest = []
      current = expanded
      until File.exist?(current) || current == File.dirname(current)
        rest.unshift(File.basename(current))
        current = File.dirname(current)
      end
      real = File.exist?(current) ? File.realpath(current) : current
      File.join(real, *rest)
    rescue SystemCallError, ArgumentError
      File.expand_path(path.to_s)
    end

    def case_insensitive_fs?
      RbConfig::CONFIG["host_os"].to_s =~ /mswin|mingw|darwin/i ? true : false
    end

    def path_within?(path, base)
      return false if path.nil? || base.nil?

      left = case_insensitive_fs? ? path.downcase : path
      right = case_insensitive_fs? ? base.downcase : base
      left == right || left.start_with?("#{right}#{File::SEPARATOR}")
    end

    def inside_home?(path)
      path_within?(realish(path), realish(home))
    end

    def inside_legacy_trees?(path)
      target = realish(path)
      [legacy_home, legacy_workspace_root].any? { |tree| path_within?(target, realish(tree)) }
    end

    def install_file
      File.join(home, "install.yml")
    end

    def keys_dir
      File.join(home, "keys")
    end

    def install_key_file
      File.join(keys_dir, "install.pem")
    end

    def packages_dir(kind = nil)
      kind ? File.join(home, "packages", kind.to_s) : File.join(home, "packages")
    end

    def vault_dir
      File.join(home, "vault")
    end

    def shape_vault_dir
      File.join(vault_dir, "shape")
    end

    def suite_vault_dir
      File.join(vault_dir, "suite")
    end

    def guardrails_vault_dir
      File.join(vault_dir, "guardrails")
    end

    def outbox_dir
      File.join(home, "outbox")
    end

    def receipts_dir
      File.join(home, "receipts")
    end

    def receipt_acks_dir
      File.join(receipts_dir, "acks")
    end

    def logs_dir
      File.join(home, "logs")
    end

    def gems_dir
      File.join(home, "gems")
    end

    def runtime_dir
      File.join(home, "runtime")
    end

    def runtime_logs_file
      File.join(logs_dir, "runtime.jsonl")
    end

    def chromium_dir
      File.join(home, "chromium")
    end

    def state_dir
      File.join(home, "state")
    end

    def status_cache_file
      File.join(state_dir, "status.json")
    end

    def bucket_file
      File.join(state_dir, "bucket.json")
    end

    def requests_log
      File.join(logs_dir, "requests.jsonl")
    end

    def ledger_dir
      File.join(state_dir, "ledger")
    end

    def ledger_key_file
      File.join(state_dir, "ledger.key")
    end

    def checkpoints_dir
      File.join(home, "checkpoints")
    end

    def submit_gate_dir
      File.join(state_dir, "submit-gate")
    end

    def integrity_seen_file
      File.join(state_dir, "integrity-seen.json")
    end

    def transcripts_dir
      File.join(home, "transcripts")
    end

    def hermes_state_file
      File.join(state_dir, "hermes.json")
    end

    def flush_lock_file
      File.join(state_dir, "transcript-flush.lock")
    end

    def flush_state_file
      File.join(state_dir, "transcript-flush.json")
    end

    def transcript_log
      File.join(logs_dir, "transcript.jsonl")
    end

    def login_state_dir
      File.join(state_dir, "login")
    end

    def enroll_state_dir
      File.join(state_dir, "enroll")
    end

    def enroll_flow_file
      File.join(enroll_state_dir, "flow.json")
    end

    def enroll_moved_file
      File.join(enroll_state_dir, "moved.json")
    end

    def enroll_pending_key_file
      File.join(enroll_state_dir, "pending_key.pem")
    end

    def enroll_pending_fingerprint_file
      File.join(enroll_state_dir, "pending_fingerprint.json")
    end

    def enroll_notice_file
      File.join(enroll_state_dir, "just_enrolled.json")
    end

    def fingerprint_cache_file
      File.join(enroll_state_dir, "fingerprint_cache.json")
    end

    def fingerprint_file
      File.join(home, "fingerprint.json")
    end

    def stamp_file
      File.join(home, "stamp.json")
    end

    def consent_dir
      File.join(state_dir, "consent")
    end

    def modules_state_dir
      File.join(state_dir, "modules")
    end

    def part_state_dir
      File.join(state_dir, "part")
    end

    def sandbox_state_dir
      File.join(state_dir, "sandbox")
    end

    def imports_file
      File.join(state_dir, "imports.jsonl")
    end

    def transcripts_archive_dir
      File.join(transcripts_dir, "archive")
    end

    def corpus_fallback_dir
      File.join(home, "corpus-fallback")
    end

    def managed_install_dir
      File.join(home, "plugin")
    end

    def update_manifest_file
      File.join(state_dir, "update.json")
    end

    def update_lock_file
      File.join(state_dir, "update.lock")
    end

    def update_log_file
      File.join(logs_dir, "update.log")
    end

    def updates_dir
      File.join(home, "updates")
    end

    def install_backup_dir
      File.join(home, ".backup")
    end

    def ensure_home!
      [home, keys_dir, packages_dir, vault_dir, outbox_dir, receipts_dir, logs_dir, state_dir].each do |dir|
        FileUtils.mkdir_p(dir)
      end
      begin
        File.chmod(0o700, home)
        File.chmod(0o700, keys_dir)
        File.chmod(0o700, vault_dir)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
    end

    def workspace_root
      override = path_override
      return override[:root] if override && override[:root]

      value = ENV["REACH_WORKSPACE_ROOT"].to_s
      return File.expand_path(value) unless value.empty?

      return root if path_within?(File.expand_path(home), root)

      legacy_workspace_root
    end

    def deliverables_root
      File.join(workspace_root, "deliverables")
    end

    def extracurricular_root
      File.join(workspace_root, "extracurricular")
    end

    def workspace_path(course, assignment, cutout, slice)
      File.join(deliverables_root, course.to_s, assignment.to_s, "#{cutout}-#{slice}")
    end

    def legacy_workspace_path(course, assignment, cutout, slice)
      File.join(workspace_root, course.to_s, assignment.to_s, "#{cutout}-#{slice}")
    end

    def transcript_spaces_dir
      File.join(transcripts_dir, "spaces")
    end
  end
end
