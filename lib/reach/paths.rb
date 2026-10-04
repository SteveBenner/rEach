require "fileutils"
require "json"

module Reach
  module Paths
    module_function

    PERSONA_ID = /\A[0-9a-f]{8}\z/.freeze

    def root
      value = ENV["REACH_HOME"].to_s
      File.expand_path(value.empty? ? "~/.reach" : value)
    end

    def workspace_base
      value = ENV["REACH_WORKSPACE_ROOT"].to_s
      File.expand_path(value.empty? ? "~/reach-work" : value)
    end

    def persona_pointer_file
      File.join(root, "persona.json")
    end

    def persona_home_for(id)
      File.join(root, "personas", id.to_s)
    end

    def persona_workspace_for(id)
      File.join(workspace_base, "personas", id.to_s)
    end

    def persona_override=(id)
      @persona_override = id
      @persona_memo = nil
    end

    def reset_persona_memo!
      @persona_memo = nil
    end

    def persona_record
      return nil if @persona_override
      return @persona_memo[:record] if @persona_memo && @persona_memo[:root] == root

      record = begin
        data = JSON.parse(File.read(persona_pointer_file))
        data.is_a?(Hash) && data["id"].to_s.match?(PERSONA_ID) && File.directory?(persona_home_for(data["id"])) ? data : nil
      rescue StandardError
        nil
      end
      @persona_memo = { root: root, record: record }
      record
    end

    def persona_id
      return @persona_override if @persona_override

      record = persona_record
      record ? record["id"] : nil
    end

    def home
      id = persona_id
      id ? persona_home_for(id) : root
    end

    def root_state_dir
      File.join(root, "state")
    end

    def teach_url_file
      File.join(root_state_dir, "teach.json")
    end

    def root_logs_dir
      File.join(root, "logs")
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
      File.join(root, "gems")
    end

    def runtime_dir
      File.join(root, "runtime")
    end

    def runtime_logs_file
      File.join(root_logs_dir, "runtime.jsonl")
    end

    def chromium_dir
      File.join(root, "chromium")
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

    def workspace_log
      File.join(logs_dir, "workspace.jsonl")
    end

    def transcript_log
      File.join(logs_dir, "transcript.jsonl")
    end

    def transcripts_archive_dir
      File.join(transcripts_dir, "archive")
    end

    def transcript_spaces_dir
      File.join(transcripts_dir, "spaces")
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

    def corpus_fallback_dir
      File.join(home, "corpus-fallback")
    end

    def storage_state_file
      File.join(state_dir, "storage.json")
    end

    def storage_lock_file(name)
      File.join(state_dir, "storage-#{name}.lock")
    end

    def import_spool_dir
      File.join(Reach::BrainSpool.state_home, "reach", "import-spool")
    end

    def imports_dir
      File.join(Reach::Brain.dir, "imports")
    end

    def managed_install_dir
      File.join(root, "plugin")
    end

    def update_manifest_file
      File.join(root_state_dir, "update.json")
    end

    def update_lock_file
      File.join(root_state_dir, "update.lock")
    end

    def update_log_file
      File.join(root_logs_dir, "update.log")
    end

    def updates_dir
      File.join(root, "updates")
    end

    def install_backup_dir
      File.join(root, ".backup")
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
      id = persona_id
      id ? persona_workspace_for(id) : workspace_base
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
  end
end
