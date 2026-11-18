require "json"

module Reach
  module Capsule
    LIMIT = 16_384
    RECENT = 20
    TELEMETRY_LIMIT = 4096
    TELEMETRY_SCHEMA = "reach.telemetry/v1".freeze
    CODES_MAX = 12
    MODULES_MAX = 40
    ASSIGNMENTS_MAX = 20
    CODE_FORMAT = /\A[A-Z]{1,4}-[A-Z0-9-]{2,48}\z/.freeze
    HARNESS_FORMAT = /\A[a-z0-9-]{1,32}\z/.freeze
    ASSIGNMENT_FORMAT = /\A[A-Za-z0-9_.-]{1,24}\z/.freeze
    MODULE_FORMAT = /\A[a-z0-9_.-]{1,48}\z/.freeze

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

    def telemetry(meta = {}, qualification: nil)
      meta = {} unless meta.is_a?(Hash)
      signals = guarded { Reach::Signals.recent } || []
      body = {
        "schema" => TELEMETRY_SCHEMA,
        "signals" => signals,
        "codes" => guarded { telemetry_codes(signals, qualification) },
        "hooks" => guarded { telemetry_hooks },
        "held" => guarded { telemetry_held(meta) }
      }
      fit_telemetry(body)
    end

    def telemetry_codes(signals, qualification)
      found = signals.reverse.map { |row| row["code"] }
      found += telemetry_finding_codes(qualification)
      found.select { |code| code.is_a?(String) && code.match?(CODE_FORMAT) }.uniq.first(CODES_MAX)
    end

    def telemetry_finding_codes(qualification)
      return [] unless qualification.is_a?(Hash)

      Array(qualification["findings"]).map { |finding| finding.is_a?(Hash) ? finding["code"] : nil }
    end

    def telemetry_hooks
      harness = Reach::HookLiveness.harness
      {
        "stale" => Reach::HookLiveness.hooks_stale?,
        "prompt_quiet" => Reach::HookLiveness.prompt_hook_quiet?(Reach::HookLiveness::PROMPT_WITHOUT_WORK_S),
        "harness" => harness.is_a?(String) && harness.match?(HARNESS_FORMAT) ? harness : nil
      }
    end

    def telemetry_held(meta)
      held = {
        "modules" => Reach::Modules.module_ids.select { |id| id.match?(MODULE_FORMAT) }.sort.first(MODULES_MAX),
        "assignments" => held_assignments
      }
      wanted = meta["assignment"]
      held["wanted"] = wanted if wanted.is_a?(String) && wanted.match?(ASSIGNMENT_FORMAT)
      held
    end

    def held_assignments
      root = Reach::Paths.packages_dir
      return [] unless File.directory?(root)

      packages = Reach::Packages.new
      names = Dir.children(root).select { |kind| File.directory?(File.join(root, kind)) }
      found = names.flat_map do |kind|
        packages.send(:stored_versions, kind).map { |version| packages.send(:stored_assignment, kind, version) }
      end
      found.select { |value| value.is_a?(String) && value.match?(ASSIGNMENT_FORMAT) }.uniq.sort.first(ASSIGNMENTS_MAX)
    end

    def fit_telemetry(body)
      body = body.dup
      signals = Array(body["signals"])
      while signals.any? && JSON.generate(body.merge("signals" => signals)).bytesize > TELEMETRY_LIMIT
        signals = signals.drop(1)
      end
      body["signals"] = signals
      held = body["held"]
      if held.is_a?(Hash)
        modules = Array(held["modules"])
        while modules.any? && JSON.generate(body.merge("held" => held.merge("modules" => modules))).bytesize > TELEMETRY_LIMIT
          modules = modules.drop(1)
        end
        body["held"] = held.merge("modules" => modules)
      end
      body
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
        {
          "kind" => event["kind"].to_s,
          "where" => fields["where"].to_s[0, 64],
          "at" => event["at"].to_s,
          "code" => fields["message_id"].to_s[CODE_FORMAT] ? fields["message_id"].to_s : nil
        }
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
