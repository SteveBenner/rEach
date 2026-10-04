require "json"
require "digest"

module Reach
  module Holdings
    ROUTE = "/api/v1/holdings".freeze
    FILE = "holdings.json".freeze
    UNSUPPORTED_WAIT_S = 21_600

    module_function

    def current
      packages = Reach::Packages.new
      version = packages.latest_version("guardrails")
      envelope = version ? packages.stored_envelope("guardrails", version) : nil
      header = envelope.is_a?(Hash) ? envelope["header"] : nil
      guardrails = header.is_a?(Hash) ? { "version" => header["version"], "content_digest" => header["content_digest"] } : nil
      blobs = Reach::Reference.blob_paths.map { |path| { "name" => File.basename(path), "sha256" => Digest::SHA256.file(path).hexdigest } }
      { "guardrails" => guardrails, "reference" => blobs }
    end

    def report!
      install = Reach::Enroll.current
      return nil unless install

      state = Reach::StateFile.read(FILE)
      return { "skipped" => "unsupported" } if state["unsupported_until"].to_i > Time.now.to_i

      body = current
      digest = Digest::SHA256.hexdigest(JSON.generate(body))
      return { "skipped" => "unchanged" } if state["reported_digest"] == digest

      response = Reach::Client.for_install(install, quiet: true).post_json(ROUTE, body, idempotency_key: digest)
      answered = response.json || {}
      Reach::StateFile.update(FILE) do |fresh|
        fresh["reported_digest"] = digest
        fresh["reported_at"] = Reach::StateFile.now_s
        fresh["current"] = answered["current"]
        fresh.delete("unsupported_until")
      end
      { "reported" => true, "current" => answered["current"] }
    rescue Reach::RemoteRefused => e
      raise unless e.status == 404

      Reach::StateFile.update(FILE) { |fresh| fresh["unsupported_until"] = Time.now.to_i + UNSUPPORTED_WAIT_S }
      { "skipped" => "unsupported" }
    end
  end
end
