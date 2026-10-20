require "json"
require "base64"
require "fileutils"

module Reach
  module Probe
    SUPPORT_FILE = "features/support/zz_reach_probe.rb".freeze
    PORT_CALLS_MIME = "application/vnd.grokit.port-calls+json".freeze
    PORT_ENV = "REACH_PROBE_PORT".freeze
    MODES = %w[on off].freeze

    SUPPORT_SOURCE = <<~'RUBY'.freeze
      module ReachProbe
        module_function

        def perturb(value)
          case value
          when true then false
          when false then true
          when Numeric then value * 1.37 + 1
          when String then value + "~"
          when Array then value.reverse.map { |item| perturb(item) }
          when Hash then Hash[value.to_a.reverse.map { |key, item| [key, perturb(item)] }]
          else value
          end
        end

        class Wrapper
          def initialize(adapter)
            @adapter = adapter
          end

          def method_missing(name, *args, &block)
            ReachProbe.perturb(@adapter.public_send(name, *args, &block))
          end

          def respond_to_missing?(name, include_private = false)
            @adapter.respond_to?(name, include_private)
          end
        end
      end

      module ReachProbePatch
        def build(port_name, context)
          adapter = super
          port_name.to_s == ENV["REACH_PROBE_PORT"].to_s ? ReachProbe::Wrapper.new(adapter) : adapter
        end
      end

      Grokit::Ports.singleton_class.prepend(ReachProbePatch)
    RUBY

    module_function

    def mode
      value = Reach::CourseProfile.section("qualify")["probe"].to_s
      MODES.include?(value) ? value : "on"
    rescue StandardError
      "on"
    end

    def required_ports(workspace)
      Array(Reach::PlanAudit.constraints(workspace)["required_apis"]).map { |line| line.to_s[/\Aports\.(\w+)\./, 1] }.compact.uniq
    end

    def run(workspace, root: nil)
      return [] if mode == "off"

      meta = Reach::Workspace.metadata(workspace)
      qualify = meta["qualify"]
      return [] unless qualify.is_a?(Hash) && qualify["tag"] && qualify["local"]

      ports = required_ports(workspace)
      return [] if ports.empty?

      run_dir = Reach::Qualify.assemble_local(workspace, meta, stub: false, root: root, name: "probe")
      File.write(File.join(run_dir, SUPPORT_FILE), SUPPORT_SOURCE)
      Reach::Suite.select_lock!(run_dir)
      gems = Reach::Suite.install_gems(run_dir)
      env, _dropped = Reach::Qualify.sanitize_env(qualify["env"])
      baseline = observe(run_dir, gems, qualify["tag"], env)
      return [] unless baseline

      rows = []
      ports.each do |port|
        perturbed = observe(run_dir, gems, qualify["tag"], env.merge(PORT_ENV => port))
        next unless perturbed

        baseline.each do |name, before|
          next unless before["result"] == "passed" && before["ports"].include?(port)

          after = perturbed[name]
          next unless after

          rows << { "scenario" => name, "port" => port, "sensitive" => after["result"] != "passed" }
        end
      end
      rows
    ensure
      FileUtils.rm_f(File.join(run_dir, SUPPORT_FILE)) if defined?(run_dir) && run_dir
    end

    def insensitive(rows)
      Array(rows).reject { |row| row["sensitive"] }
    end

    def observe(run_dir, gems, tag, env)
      output = Reach::Suite.cucumber(run_dir, gems, [tag], env)
      return nil if output["timed_out"]

      features = JSON.parse(output["stdout"].to_s)
      seen = {}
      Array(features).each do |feature|
        Array(feature["elements"]).each do |element|
          next unless element["type"] == "scenario"

          row = Reach::Suite.report_row(element)
          seen[row["name"]] = { "result" => row["result"], "ports" => called_ports(element) }
        end
      end
      seen
    rescue JSON::ParserError
      nil
    end

    def called_ports(element)
      hooks = Array(element["before"]) + Array(element["after"]) + Array(element["steps"])
      calls = hooks.flat_map { |hook| Array(hook["embeddings"]) }.select { |item| item["mime_type"] == PORT_CALLS_MIME }.flat_map do |item|
        raw = item["data"].to_s
        text = begin
          Base64.strict_decode64(raw)
        rescue ArgumentError
          raw
        end
        parsed = JSON.parse(text)
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        []
      end
      calls.map { |call| call.to_s.split(".").first }.uniq
    end
  end
end
