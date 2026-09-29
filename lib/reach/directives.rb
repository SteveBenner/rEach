require "yaml"

module Reach
  module Directives
    LABEL_WIDTH = 20
    RULE_WIDTH = 88
    POINTER_WIDTH = 26
    ENFORCE_WIDTH = 22
    TABLE_LIMIT = 6000
    ROUTE = "/api/v1/directives".freeze
    OPCODE_PATTERN = /\A[A-Z][A-Z0-9]{2,9}\z/
    ALIAS_PATTERN = /\A[A-Z]\z/
    TIERS = %w[public private].freeze
    SLICES = %w[all backend panel verification].freeze
    REQUIRED = %w[id opcode alias tier rule when enforce].freeze
    PUBLIC_ALIASES = ("A".."M").to_a.freeze
    PRIVATE_ALIASES = ("N".."Z").to_a.freeze
    POINTER_SENTENCE = "Every row binds. When a row's condition applies, run `reach directive <OPCODE>` (or the reach_directive tool) and follow the full text. Rows cover different surfaces and do not override one another; the numbered rules above come first.".freeze

    module_function

    def public_dir
      File.join(Reach::Runtime.root, "directives")
    end

    def public_files
      Dir.glob(File.join(public_dir, "*.md")).sort.reject { |path| File.basename(path) == "README.md" }
    end

    def public_rows
      public_files.map { |path| parse_file(path, "public") }.compact
    end

    def private_rows(guardrails = nil)
      data = guardrails || Reach::Guardrails.load
      Array(data["directives"]).select { |entry| entry.is_a?(Hash) && entry["opcode"] }.map { |entry| normalize(entry.merge("tier" => "private")) }
    rescue StandardError
      []
    end

    def rows(slice: nil, guardrails: nil)
      (private_rows(guardrails) + public_rows).select { |row| applies_to_slice?(row, slice) }
    end

    def applies_to_slice?(row, slice)
      scope = row["slice"].to_s
      scope.empty? || scope == "all" || slice.nil? || scope == slice.to_s
    end

    def table(slice: nil, guardrails: nil)
      private_lines = private_rows(guardrails).select { |row| applies_to_slice?(row, slice) }.map { |row| render_row(row) }
      public_lines = public_rows.select { |row| applies_to_slice?(row, slice) }.map { |row| render_row(row) }
      lines = []
      unless private_lines.empty?
        lines << "## Course directives"
        lines << ""
        lines.concat(private_lines)
        lines << ""
      end
      unless public_lines.empty?
        lines << "## Engineering directives"
        lines << ""
        lines.concat(public_lines)
        lines << ""
      end
      lines << POINTER_SENTENCE unless private_lines.empty? && public_lines.empty?
      lines.join("\n")
    end

    def render_row(row)
      label = "[#{row['alias']} · #{row['opcode']}]"
      pointer = "reach directive #{row['opcode']}"
      format("%-#{LABEL_WIDTH}s %-#{RULE_WIDTH}s %-#{POINTER_WIDTH}s ⚙ %-#{ENFORCE_WIDTH}s ⚡ %s", label, row["rule"], pointer, row["enforce"], when_text(row["when"]))
    end

    def when_text(value)
      list = value.is_a?(Array) ? value : value.to_s.delete("[]").split(",").map(&:strip)
      "[#{list.join(', ')}]"
    end

    def find(opcode)
      wanted = opcode.to_s.upcase
      rows.find { |row| row["opcode"] == wanted }
    end

    def show(opcode, workspace: nil)
      row = find(opcode)
      raise Reach::Error, Reach::Messages.text("M-DIRECTIVE-UNKNOWN", opcodes: rows.map { |r| r["opcode"] }.join(", ")) unless row

      body = row["tier"] == "public" ? public_body(row) : private_body(row, workspace)
      Reach::Ledger.append(workspace, "directive", "opcode" => row["opcode"], "tier" => row["tier"]) if workspace
      { "opcode" => row["opcode"], "tier" => row["tier"], "rule" => row["rule"], "body" => body }
    end

    def public_body(row)
      _front, body = split_frontmatter(File.read(row["path"]))
      body
    end

    REFUSAL_CODES = %w[revoked forbidden unauthenticated not_enrolled].freeze

    def private_body(row, workspace = nil)
      body = remote_body(row, workspace)
      body = Reach::Guardrails.private_body(row["opcode"]) if body.nil?
      return body unless body.to_s.strip.empty?

      "#{row['rule']}\n\n#{Reach::Messages.text('M-DIRECTIVE-OFFLINE', opcode: row['opcode'])}"
    end

    def remote_body(row, workspace)
      install = Reach::Enrol.current
      return nil unless install

      query = {}
      if workspace
        meta = Reach::Workspace.metadata(workspace)
        query["cutout_id"] = meta["cutout_id"].to_s unless meta["cutout_id"].to_s.empty?
        query["slice"] = meta["slice"].to_s unless meta["slice"].to_s.empty?
      end
      response = Reach::Client.for_install(install, quick: true).get("#{ROUTE}/#{row['opcode']}", query: query)
      (response.json || {})["body"].to_s
    rescue Reach::RemoteRefused => e
      REFUSAL_CODES.include?(e.code.to_s) ? "" : nil
    rescue StandardError
      nil
    end

    def problems
      found = []
      seen_opcodes = {}
      seen_aliases = {}
      public_files.each do |path|
        row = parse_file(path, "public")
        name = File.basename(path)
        if row.nil?
          found << "#{name}: unreadable frontmatter"
          next
        end
        REQUIRED.each { |key| found << "#{name}: missing #{key}" if row[key].to_s.empty? }
        found << "#{name}: opcode #{row['opcode'].inspect} is not 3-10 uppercase letters or digits" unless row["opcode"].to_s.match?(OPCODE_PATTERN)
        found << "#{name}: alias #{row['alias'].inspect} is not one letter A-M" unless PUBLIC_ALIASES.include?(row["alias"].to_s)
        found << "#{name}: tier must be public" unless row["tier"] == "public"
        found << "#{name}: slice #{row['slice'].inspect} unknown" unless row["slice"].to_s.empty? || SLICES.include?(row["slice"].to_s)
        found << "#{name}: rule longer than #{RULE_WIDTH} characters" if row["rule"].to_s.length > RULE_WIDTH
        found << "#{name}: id must be R-#{row['opcode']}" unless row["id"] == "R-#{row['opcode']}"
        found << "#{name}: file name must be #{row['opcode'].to_s.downcase}.md" unless name == "#{row['opcode'].to_s.downcase}.md"
        found << "#{name}: opcode #{row['opcode']} repeats #{seen_opcodes[row['opcode']]}" if seen_opcodes[row["opcode"]]
        found << "#{name}: alias #{row['alias']} repeats #{seen_aliases[row['alias']]}" if seen_aliases[row["alias"]]
        seen_opcodes[row["opcode"]] = name
        seen_aliases[row["alias"]] = name
      end
      length = table(slice: nil, guardrails: { "directives" => [] }).length
      found << "the public table is #{length} characters, over #{TABLE_LIMIT}" if length > TABLE_LIMIT
      found
    end

    def parse_file(path, tier)
      front, _body = split_frontmatter(File.read(path))
      return nil unless front.is_a?(Hash)

      normalize(front.merge("tier" => tier, "path" => path))
    rescue StandardError
      nil
    end

    def normalize(entry)
      row = {}
      entry.each { |k, v| row[k.to_s] = v }
      row["opcode"] = row["opcode"].to_s.upcase
      row["alias"] = row["alias"].to_s.upcase
      row["slice"] = (row["slice"] || "all").to_s
      row["when"] = Array(row["when"]).map(&:to_s)
      row["enforce"] = (row["enforce"] || "none").to_s
      row
    end

    def split_frontmatter(text)
      return [nil, text] unless text.start_with?("---\n")

      closing = text.index("\n---\n", 4)
      return [nil, text] unless closing

      front = YAML.safe_load(text[4...closing])
      [front, text[(closing + 5)..-1].to_s]
    end
  end
end
