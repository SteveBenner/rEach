require "openssl"
require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Ledger
    MAX_RECORDS = 20_000
    SPLIT_RECORDS = 5000
    TAIL_LIMIT = 2000

    module_function

    def path(workspace)
      meta = Reach::Workspace.metadata(workspace)
      File.join(Reach::Paths.ledger_dir, meta["course"].to_s, meta["assignment"].to_s, "#{File.basename(workspace)}.jsonl")
    end

    def head_path(workspace)
      "#{path(workspace)}.head.json"
    end

    def key
      seal_key = Reach::Seal.ledger_key
      return [seal_key, guardrails_version] if seal_key

      [local_key, nil]
    end

    def guardrails_version
      Reach::Guardrails.version
    rescue StandardError
      nil
    end

    def local_key
      file = Reach::Paths.ledger_key_file
      return File.read(file).strip if File.file?(file)

      FileUtils.mkdir_p(File.dirname(file))
      value = SecureRandom.hex(32)
      File.write(file, value, perm: 0o600)
      value
    end

    def append(workspace, kind, fields = {})
      return nil unless workspace && File.directory?(File.join(workspace, Reach::Workspace::MARKER_DIR))

      file = path(workspace)
      FileUtils.mkdir_p(File.dirname(file))
      record = nil
      held = Reach::Locks.exclusive(file, mode: File::RDWR | File::CREAT | File::APPEND, perm: 0o666) do |f|
        last = read_head(workspace, f)
        ledger_key, version = key
        record = { "n" => last["n"].to_i + 1, "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "kind" => kind.to_s }
        fields.each { |k, v| record[k.to_s] = v }
        record["student_id"] = enrolled_student_id
        record["gv"] = version
        record["prev"] = last["tag"].to_s
        record["tag"] = tag(record, ledger_key)
        f.write(JSON.generate(record) + "\n")
        f.flush
        write_head(workspace, record)
      end
      return nil if held == :busy

      split_if_large(workspace)
      Reach::Sidecar.update_head(File.basename(workspace), record["tag"], record["n"])
      Reach::Progress.assignment_started(workspace)
      record
    rescue StandardError
      nil
    end

    def enrolled_student_id
      install = Reach::Enroll.current
      install && install["student_id"]
    rescue StandardError
      nil
    end

    def tag(record, ledger_key)
      unsigned = record.reject { |k, _| k == "tag" }
      OpenSSL::HMAC.hexdigest("SHA256", ledger_key.to_s, Reach::Crypto.canonical_json(unsigned))
    end

    def records(workspace)
      file = path(workspace)
      return [] unless File.file?(file)

      File.readlines(file).map { |line| JSON.parse(line) }
    rescue StandardError
      []
    end

    def head(workspace)
      read_head(workspace, nil)["tag"].to_s
    end

    def count(workspace)
      read_head(workspace, nil)["n"].to_i
    end

    def witnessed(workspace)
      digests = {}
      records(workspace).each do |record|
        digests[record["path"]] = record["after"] if record["kind"] == "write" && record["path"]
      end
      digests
    end

    def last_harness(workspace)
      records(workspace).reverse_each do |record|
        return record["harness"] if record["kind"] == "session" && record["harness"]
      end
      nil
    end

    def integrity_count(workspace)
      records(workspace).count { |record| record["kind"] == "integrity" }
    end

    def tail_text(workspace, limit = TAIL_LIMIT)
      file = path(workspace)
      return "" unless File.file?(file)

      File.readlines(file).last(limit).join
    end

    def read_head(workspace, handle)
      head_file = head_path(workspace)
      if File.file?(head_file)
        parsed = JSON.parse(File.read(head_file))
        return parsed if parsed.is_a?(Hash)
      end
      last_line = nil
      if handle
        handle.rewind
        handle.each_line { |line| last_line = line }
      elsif File.file?(path(workspace))
        File.foreach(path(workspace)) { |line| last_line = line }
      end
      last_line ? JSON.parse(last_line) : { "n" => 0, "tag" => "" }
    rescue StandardError
      { "n" => 0, "tag" => "" }
    end

    def write_head(workspace, record)
      File.write(head_path(workspace), JSON.generate("n" => record["n"], "tag" => record["tag"], "at" => record["at"]))
    rescue StandardError
      nil
    end

    def split_if_large(workspace)
      file = path(workspace)
      lines = File.readlines(file)
      return if lines.length <= MAX_RECORDS

      archive = file.sub(/\.jsonl\z/, ".#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.jsonl")
      File.write(archive, lines.first(SPLIT_RECORDS).join)
      File.write(file, lines.drop(SPLIT_RECORDS).join)
    rescue StandardError
      nil
    end
  end
end
