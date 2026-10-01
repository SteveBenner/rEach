require "json"
require "time"
require "fileutils"
require "securerandom"
require "openssl"

module Reach
  module Integrity
    ROUTE = "/api/v1/integrity".freeze
    KINDS = %w[vault_tampered corrupt_mark foreign_mark ledger_break sidecar_conflict enrolled directive_dump login_failed identity_denied outside_access fingerprint_mismatch].freeze

    module_function

    def report(kind, detail:, workspace: nil, path: nil, once: true)
      body = build_body(kind, detail: detail, workspace: workspace, path: path, once: once)
      return nil unless body

      send_or_queue(body)
    rescue StandardError
      nil
    end

    def queue(kind, detail:, workspace: nil, path: nil, once: true)
      body = build_body(kind, detail: detail, workspace: workspace, path: path, once: once)
      return nil unless body

      install = Reach::Enroll.current
      return nil unless install

      write_outbox(SecureRandom.uuid, body)
      body
    rescue StandardError
      nil
    end

    def build_body(kind, detail:, workspace:, path:, once:)
      kind = kind.to_s
      return nil unless KINDS.include?(kind)

      detail = truncate(detail.is_a?(Hash) || detail.is_a?(Array) ? JSON.generate(detail) : detail.to_s)
      digest = OpenSSL::Digest::SHA256.hexdigest("#{kind}\n#{path}\n#{detail}")
      return nil if once && seen?(digest)

      meta = workspace ? Reach::Workspace.metadata(workspace) : {}
      Reach::Ledger.append(workspace, "integrity", "event" => kind, "path" => path) if workspace

      body = {
        "kind" => kind,
        "detail" => detail,
        "cutout_id" => meta["cutout_id"],
        "slice" => meta["slice"],
        "path" => path,
        "ledger_head" => workspace ? Reach::Ledger.head(workspace) : nil,
        "client_created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
      remember(digest) if once
      body
    end

    def send_or_queue(body)
      install = Reach::Enroll.current
      return nil unless install

      idempotency_key = SecureRandom.uuid
      outbox_path = write_outbox(idempotency_key, body)
      begin
        response = Reach::Client.for_install(install, quick: true).post_json(ROUTE, body, idempotency_key: idempotency_key)
        FileUtils.rm_f(outbox_path)
        (response.json || {})["event_id"]
      rescue Reach::RemoteRefused
        FileUtils.rm_f(outbox_path)
        nil
      rescue Reach::Offline, Reach::NetworkError
        nil
      end
    rescue StandardError
      nil
    end

    def write_outbox(idempotency_key, body)
      FileUtils.mkdir_p(Reach::Paths.outbox_dir)
      path = File.join(Reach::Paths.outbox_dir, "#{idempotency_key}.json")
      File.write(path, JSON.generate("kind" => "integrity", "route" => ROUTE, "idempotency_key" => idempotency_key, "body" => body))
      path
    end

    def seen?(digest)
      seen.include?(digest)
    end

    def remember(digest)
      list = seen
      list << digest
      FileUtils.mkdir_p(File.dirname(Reach::Paths.integrity_seen_file))
      File.write(Reach::Paths.integrity_seen_file, JSON.generate(list.last(5000)))
    rescue StandardError
      nil
    end

    def seen
      return [] unless File.file?(Reach::Paths.integrity_seen_file)

      parsed = JSON.parse(File.read(Reach::Paths.integrity_seen_file))
      parsed.is_a?(Array) ? parsed : []
    rescue StandardError
      []
    end

    def truncate(text)
      bytes = text.dup.force_encoding(Encoding::UTF_8)
      return bytes if bytes.bytesize <= 2000

      result = +""
      bytes.each_char do |char|
        break if (result.bytesize + char.bytesize) > 2000

        result << char
      end
      result
    end
  end
end
