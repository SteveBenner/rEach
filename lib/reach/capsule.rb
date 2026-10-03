require "json"

module Reach
  module Capsule
    LIMIT = 16_384
    RECENT = 20

    module_function

    def build
      capsule = {
        "runtime" => guarded { Reach::CryptoProbe.facts },
        "kit" => guarded { kit },
        "link" => guarded { link },
        "update" => guarded { update },
        "flags" => guarded { flags },
        "recent" => guarded { recent }
      }
      fit(capsule)
    rescue StandardError
      {}
    end

    def guarded
      yield
    rescue StandardError
      nil
    end

    def kit
      data = Reach::Diagnose.kit
      { "active" => data["active"] == true, "runtime_id" => data["runtime_id"], "platform" => data["platform"] }
    end

    def link
      state = Reach::Link.read_state
      { "state" => state["state"] || "up", "since" => state["since"], "cause" => state["cause"] }
    end

    def update
      manifest = Reach::Update.load_manifest
      { "phase" => manifest["phase"], "staged_version" => manifest["staged_version"] || manifest["version"] }
    end

    def flags
      Reach::Diagnose::ENV_FLAGS.select { |name| !ENV[name].to_s.empty? }
    end

    def recent
      file = Reach::Debug.spool_file
      return [] unless File.file?(file)

      lines = File.readlines(file).last(RECENT * 4)
      rows = lines.map do |line|
        parsed = begin
          JSON.parse(line)
        rescue StandardError
          nil
        end
        event = parsed.is_a?(Hash) ? parsed["event"] : nil
        next nil unless event.is_a?(Hash)

        fields = event["fields"].is_a?(Hash) ? event["fields"] : {}
        { "kind" => event["kind"].to_s, "where" => fields["where"].to_s[0, 64], "at" => event["at"].to_s }
      end
      rows.compact.last(RECENT)
    end

    def fit(capsule)
      return capsule if JSON.generate(capsule).bytesize <= LIMIT

      rows = Array(capsule["recent"])
      while rows.any? && JSON.generate(capsule.merge("recent" => rows)).bytesize > LIMIT
        rows = rows.drop(1)
      end
      trimmed = capsule.merge("recent" => rows)
      JSON.generate(trimmed).bytesize <= LIMIT ? trimmed : { "runtime" => capsule["runtime"], "link" => capsule["link"], "recent" => [] }
    end
  end
end
