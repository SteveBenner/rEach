require "json"
require "yaml"
require "timeout"

module Reach
  module Patterns
    SCHEMA = "reach.patterns/v1".freeze
    PACKAGE_KIND = "patterns".freeze
    PACKAGE_ENTRY = "patterns.yml".freeze
    GENERIC_FILE = File.expand_path("../../patterns/generic.yml", __dir__)
    SEVERITIES = %w[block warn info].freeze
    POINTS = %w[plan scenarios code].freeze
    KINDS = %w[regex_owned regex_feature regex_steps i18n_keys last_run literal_echo port_args faked_port_echo].freeze
    MODES = %w[enforce advise off].freeze
    FEATURES_DIR = "qualify/features".freeze
    STEPS_DIR = "qualify/step_definitions".freeze
    KIT_DIR = "qualify/kit".freeze
    LAST_RUN_FILE = "qualify/last-run.json".freeze
    CODE_GLOBS = %w[modules/*/lib/**/behaviours/*.rb modules/*/panel/src/cutouts/*.svelte].freeze
    MESSAGE_GLOBS = %w[modules/*/panel/messages/en-US.json panel/messages/en-US.json].freeze
    I18N_CALL = /\bt\(\s*['"]([\w.\-]+)['"]\s*[,)]/.freeze
    SCENARIO_LINE = /\A\s*(?:Scenario|Scenario Outline|Example):/.freeze
    COMMON_NUMBERS = %w[10 100 1000].freeze
    MAX_FILE_BYTES = 262_144

    class Scope
      attr_reader :workspace, :base, :kit

      def initialize(workspace, root, kit)
        @workspace = workspace.to_s
        @base = (root || workspace).to_s
        @kit = (kit || File.join(@workspace, KIT_DIR)).to_s
      end

      def meta
        @meta ||= read_meta
      end

      def read_meta
        [File.join(workspace, Reach::Workspace::MARKER_DIR, Reach::Workspace::MARKER_FILE), File.join(workspace, "slice.json"), File.join(base, "slice.json")].each do |path|
          next unless File.file?(path)

          data = JSON.parse(File.read(path))
          return data if data.is_a?(Hash)
        end
        {}
      rescue StandardError
        {}
      end

      def owned
        Array(meta["owned_files"]).map(&:to_s)
      end

      def code_files(extensions)
        list = owned
        list = glob(CODE_GLOBS) if list.empty?
        list.select { |relative| extensions.include?(File.extname(relative).delete(".")) && file?(relative) }.sort
      end

      def feature_files
        glob(["#{FEATURES_DIR}/**/*.feature"]).select { |relative| file?(relative) }
      end

      def step_files
        glob(["#{STEPS_DIR}/**/*.rb"]).select { |relative| file?(relative) }
      end

      def glob(patterns)
        patterns.flat_map { |pattern| Dir.glob(File.join(base, pattern)) }.map { |path| path.sub("#{base}/", "") }.uniq.sort
      end

      def file?(relative)
        path = File.join(base, relative)
        File.file?(path) && !File.symlink?(path)
      end

      def read(relative, from = base)
        path = File.join(from, relative)
        return nil unless File.file?(path) && !File.symlink?(path) && File.size(path) <= MAX_FILE_BYTES

        File.binread(path).force_encoding(Encoding::UTF_8).scrub
      rescue SystemCallError
        nil
      end

      def constraints_text
        @constraints_text ||= begin
          file = File.join(workspace, "api", "slice-api.json")
          data = File.file?(file) ? JSON.parse(File.read(file)) : {}
          Array(data.is_a?(Hash) ? data["constraints"] : nil).map(&:to_s).join("\n")
        rescue StandardError
          ""
        end
      end

      def contract_text
        @contract_text ||= begin
          file = File.join(workspace, "api", "slice-api.json")
          data = File.file?(file) ? JSON.parse(File.read(file)) : {}
          operation = data.is_a?(Hash) && data["operation"].is_a?(Hash) ? JSON.generate(data["operation"]) : ""
          [operation, read(File.join("contract", "README.md"), workspace).to_s].join("\n")
        rescue StandardError
          ""
        end
      end

      def message_keys
        @message_keys ||= begin
          keys = {}
          [base, kit].uniq.each do |dir|
            MESSAGE_GLOBS.each do |pattern|
              Dir.glob(File.join(dir, pattern)).each do |path|
                data = JSON.parse(File.read(path))
                flatten(data, "", keys) if data.is_a?(Hash)
              rescue StandardError
                next
              end
            end
          end
          keys
        end
      end

      def flatten(hash, prefix, keys)
        hash.each do |key, value|
          name = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
          if value.is_a?(Hash)
            flatten(value, name, keys)
          else
            keys[name] = true
          end
        end
      end
    end

    module_function

    def mode
      section = Reach::CourseProfile.section("qualify")["ledger"]
      value = section.is_a?(Hash) ? section["mode"].to_s : ""
      MODES.include?(value) ? value : "advise"
    rescue StandardError
      "advise"
    end

    def valid?(entry)
      entry.is_a?(Hash) && entry["id"].to_s.match?(/\A[A-Z][A-Z0-9\-]{1,63}\z/) &&
        SEVERITIES.include?(entry["severity"].to_s) && KINDS.include?(entry["kind"].to_s) &&
        entry["points"].is_a?(Array) && !entry["points"].empty? && entry["points"].all? { |point| POINTS.include?(point.to_s) }
    end

    def load_file(path)
      return [] unless File.file?(path)

      data = YAML.safe_load(File.read(path))
      list = data.is_a?(Hash) && data["schema"] == SCHEMA ? data["patterns"] : nil
      Array(list).select { |entry| valid?(entry) }
    rescue StandardError
      []
    end

    def course_entries
      packages = Reach::Packages.new
      version = packages.latest_version(PACKAGE_KIND)
      return [] unless version

      if @course_version == version && @course_entries
        return @course_entries
      end

      _header, files = packages.open(PACKAGE_KIND, version)
      raw = files[PACKAGE_ENTRY]
      data = raw ? YAML.safe_load(raw.dup.force_encoding(Encoding::UTF_8)) : nil
      list = data.is_a?(Hash) && data["schema"] == SCHEMA ? Array(data["patterns"]) : []
      @course_version = version
      @course_entries = list.select { |entry| valid?(entry) }
    rescue StandardError
      []
    end

    def course_version
      Reach::Packages.new.latest_version(PACKAGE_KIND)
    rescue StandardError
      nil
    end

    def entries
      merged = {}
      (load_file(GENERIC_FILE) + course_entries).each { |entry| merged[entry["id"]] = entry }
      merged.values
    end

    def entries_for(point, meta = {})
      entries.select do |entry|
        next false unless Array(entry["points"]).map(&:to_s).include?(point.to_s)
        next false if entry["state"] && entry["state"].to_s != "active"
        next false if entry["cutout"] && entry["cutout"].to_s != meta["cutout_id"].to_s
        next false if entry["slice"] && entry["slice"].to_s != meta["slice"].to_s

        true
      end
    end

    def describe(point, workspace)
      meta = Scope.new(workspace, nil, nil).meta
      entries_for(point, meta).map do |entry|
        { "id" => entry["id"], "severity" => entry["severity"], "message" => entry["message"].to_s, "remedy" => entry["remedy"].to_s }
      end
    end

    def match(workspace, point:, root: nil, kit: nil)
      scope = Scope.new(workspace, root, kit)
      found = entries_for(point, scope.meta).flat_map { |entry| run_entry(entry, scope) }
      found.uniq { |row| [row["id"], row["file"], row["line"]] }
    end

    def blocking(rows)
      Array(rows).select { |row| row["severity"] == "block" }
    end

    def run_entry(entry, scope)
      Thread.current[:reach_pattern_deadline] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BUDGET_S
      if Regexp.respond_to?(:timeout)
        run_entry_bounded(entry, scope)
      else
        Timeout.timeout(BUDGET_S, PatternTimeout) { run_entry_bounded(entry, scope) }
      end
    rescue *timeout_errors
      [timeout_row(entry)]
    ensure
      Thread.current[:reach_pattern_deadline] = nil
    end

    def run_entry_bounded(entry, scope)
      params = entry["parameters"].is_a?(Hash) ? entry["parameters"] : {}
      return [] unless constraints_apply?(params, scope)

      hits = case entry["kind"]
             when "regex_owned" then regex_hits(scope, scope.code_files(extensions(params)), params)
             when "regex_feature" then regex_hits(scope, scope.feature_files, params)
             when "regex_steps" then regex_hits(scope, scope.step_files, params)
             when "i18n_keys" then i18n_hits(scope, params)
             when "last_run" then last_run_hits(scope, params)
             when "literal_echo" then params["mode"].to_s == "owned_then" ? owned_then_hits(scope) : given_then_hits(scope, params)
             when "port_args" then port_hits(scope, params)
             when "faked_port_echo" then faked_port_echo_hits(scope)
             else []
             end
      hits.map do |file, line|
        { "id" => entry["id"], "severity" => entry["severity"], "file" => file, "line" => line, "message" => entry["message"].to_s, "remedy" => entry["remedy"].to_s }
      end
    rescue *timeout_errors
      raise
    rescue StandardError
      []
    end

    def extensions(params)
      list = Array(params["ext"]).map(&:to_s)
      list.empty? ? %w[rb] : list
    end

    class PatternTimeout < StandardError; end

    BUDGET_S = 2
    TIMEOUT_ID = "pattern_timeout".freeze

    def compile(source)
      return nil if source.to_s.empty?

      Regexp.respond_to?(:timeout) ? Regexp.new(source.to_s, timeout: BUDGET_S) : Regexp.new(source.to_s)
    rescue RegexpError
      nil
    end

    def check_deadline!
      deadline = Thread.current[:reach_pattern_deadline]
      raise PatternTimeout if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    def timeout_row(entry)
      message = Reach::Messages.text("M-PATTERNS-TIMEOUT", id: entry["id"])
      { "id" => TIMEOUT_ID, "severity" => "warn", "file" => nil, "line" => nil, "message" => message, "remedy" => Reach::Messages.text("M-PATTERNS-TIMEOUT-FIX") }
    end

    def timeout_errors
      defined?(Regexp::TimeoutError) ? [PatternTimeout, Regexp::TimeoutError] : [PatternTimeout]
    end

    def constraints_apply?(params, scope)
      gate = compile(params["constraints"])
      return true unless gate

      text = scope.constraints_text
      text.empty? || text.match?(Regexp.respond_to?(:timeout) ? Regexp.new(gate.source, Regexp::IGNORECASE, timeout: BUDGET_S) : Regexp.new(gate.source, Regexp::IGNORECASE))
    end

    def comment_line?(relative, line)
      %w[.rb .feature].include?(File.extname(relative)) && line.strip.start_with?("#")
    end

    def regex_hits(scope, files, params)
      pattern = compile(params["pattern"])
      return [] unless pattern

      exclude = compile(params["exclude"])
      requires = compile(params["file_requires"])
      excludes = compile(params["file_excludes"])
      hits = []
      files.each do |relative|
        text = scope.read(relative)
        next unless text
        next if requires && !text.match?(requires)
        next if excludes && text.match?(excludes)

        text.each_line.with_index(1) do |line, number|
          check_deadline!
          next if comment_line?(relative, line)
          next unless line.match?(pattern)
          next if exclude && line.match?(exclude)

          hits << [relative, number]
          break if params["once"]
        end
      end
      hits
    end

    def i18n_hits(scope, params)
      known = scope.message_keys
      return [] if known.empty?

      call = compile(params["call"]) || I18N_CALL
      hits = []
      scope.code_files(extensions(params)).each do |relative|
        text = scope.read(relative)
        next unless text

        text.each_line.with_index(1) do |line, number|
          next if line.strip.start_with?("//")

          line.scan(call) { |match| hits << [relative, number] unless known.key?(Array(match).first.to_s) }
        end
      end
      hits
    end

    def last_run_hits(scope, params)
      relative = params["file"].to_s.empty? ? LAST_RUN_FILE : params["file"].to_s
      text = scope.read(relative, scope.workspace)
      return [] unless text

      data = JSON.parse(text)
      return [] unless data.is_a?(Hash) && data["passed"] == true

      rows = Array(data["rows"]).select { |row| row.is_a?(Hash) }
      ran = rows.reject { |row| row["result"].to_s == "skipped" }
      dry = data["mode"].to_s.match?(/dry/i) || data["dry_run"] == true
      dry || ran.empty? ? [[relative, nil]] : []
    rescue JSON::ParserError
      []
    end

    def scenario_blocks(text)
      blocks = []
      current = nil
      text.each_line.with_index(1) do |line, number|
        if line.match?(SCENARIO_LINE)
          current = []
          blocks << current
        end
        current << [line, number] if current
      end
      blocks
    end

    def given_then_hits(scope, params)
      given = compile(params["given"])
      then_pattern = compile(params["then"])
      return [] unless given && then_pattern

      hits = []
      scope.feature_files.each do |relative|
        text = scope.read(relative)
        next unless text

        scenario_blocks(text).each do |block|
          given_values = block.select { |line, _| line.match?(given) }.flat_map { |line, _| line.scan(/\d+(?:\.\d+)?/) }
          next if given_values.empty?

          block.each do |line, number|
            matched = line.match(then_pattern)
            hits << [relative, number] if matched && given_values.include?(matched[1].to_s)
          end
        end
      end
      hits
    end

    def literals(line)
      numbers = line.scan(/(?<![\w.])\d+\.\d+(?![\w.])|(?<![\w.])\d{2,}(?![\w.])/).reject { |value| COMMON_NUMBERS.include?(value) }
      strings = line.scan(/"([^"\n]{3,})"/).flatten
      numbers + strings
    end

    def owned_then_hits(scope)
      asserted = {}
      scope.feature_files.each do |relative|
        text = scope.read(relative)
        next unless text

        text.each_line do |line|
          next unless line.strip.start_with?("Then", "And")

          literals(line).each { |value| asserted[value] = true }
        end
      end
      return [] if asserted.empty?

      constraints = scope.constraints_text
      contract = scope.contract_text
      stated = ->(value) { constraints.include?(value) || contract.match?(/(?<![\w.])#{Regexp.escape(value)}(?![\w.])/) }
      hits = []
      scope.code_files(%w[rb]).each do |relative|
        text = scope.read(relative)
        next unless text

        text.each_line.with_index(1) do |line, number|
          next if comment_line?(relative, line)

          found = literals(line).find { |value| asserted.key?(value) && !stated.call(value) }
          hits << [relative, number] if found
        end
      end
      hits
    end

    FAKE_CALL = /grokit_fake\(\s*:(\w+)\s*,\s*(?:\w+:\s*|:\w+\s*=>\s*)(.+?)\s*\)\s*(?:\z|\bdo\b|\{|$)/.freeze
    FIXED_VALUE = /\A(?:-?\d+(?:\.\d+)?|"[^"]*"|'[^']*'|[a-z_]\w*)\z/.freeze
    VALUE_TOKEN = /-?\d+(?:\.\d+)?|"[^"\n]+"/.freeze

    def required_port_names(scope)
      Array(Reach::PlanAudit.constraints(scope.workspace)["required_apis"]).map { |line| line.to_s[/\Aports\.(\w+)\./, 1] }.compact.uniq
    rescue StandardError
      []
    end

    def fixed_fake_values(scope)
      required = required_port_names(scope)
      values = []
      fixed = false
      scope.step_files.each do |relative|
        text = scope.read(relative)
        next unless text

        text.each_line do |line|
          next if comment_line?(relative, line)

          match = line.match(FAKE_CALL)
          next unless match
          next unless required.empty? || required.include?(match[1])

          expression = match[2].strip
          next unless expression.match?(FIXED_VALUE)

          fixed = true
          values.concat(expression.scan(VALUE_TOKEN))
        end
      end
      [fixed, values]
    end

    def faked_port_echo_hits(scope)
      fixed, step_values = fixed_fake_values(scope)
      return [] unless fixed

      hits = []
      scope.feature_files.each do |relative|
        text = scope.read(relative)
        next unless text

        scenario_blocks(text).each do |block|
          set = block.select { |line, _| line.strip.start_with?("Given") }.flat_map { |line, _| line.scan(VALUE_TOKEN) } + step_values
          next if set.empty?

          block.each do |line, number|
            next unless line.strip.start_with?("Then", "And")

            echoed = line.scan(VALUE_TOKEN) & set
            hits << [relative, number] unless echoed.empty?
          end
        end
      end
      hits
    end

    def port_hits(scope, params)
      call = compile(params["call"])
      return [] unless call

      hits = []
      scope.code_files(%w[rb]).each do |relative|
        text = scope.read(relative)
        next unless text

        text.each_line.with_index(1) do |line, number|
          check_deadline!
          next if comment_line?(relative, line)

          hits << [relative, number] if line.match?(call)
        end
      end
      hits
    end
  end
end
