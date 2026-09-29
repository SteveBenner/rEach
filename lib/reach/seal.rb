require "yaml"
require "json"
require "fileutils"

module Reach
  module Seal
    ZERO = "​".freeze
    ONE = "‌".freeze
    FRAME = "⁠".freeze
    MARK_BITS = 64
    MARK_PATTERN = /\A[0-9a-f]{16}\z/
    RUBY_MAGIC = "# frozen_string_literal: true".freeze
    STAMPABLE = %w[.rb .svelte].freeze

    module_function

    def path
      File.join(Reach::Paths.guardrails_vault_dir, "seal.yml")
    end

    def data
      return {} unless File.file?(path)

      loaded = YAML.safe_load(File.read(path))
      loaded.is_a?(Hash) ? loaded : {}
    rescue StandardError
      {}
    end

    def present?
      !data.empty?
    end

    def ledger_key
      key = data["ledger_key"].to_s
      key.empty? ? nil : key
    end

    def mark_for(cutout_id, relative_path)
      marks = data["marks"]
      return nil unless marks.is_a?(Hash)

      per_cutout = marks[cutout_id.to_s]
      return nil unless per_cutout.is_a?(Hash)

      mark = per_cutout[relative_path.to_s].to_s
      mark.match?(MARK_PATTERN) ? mark : nil
    end

    def encode(mark)
      bits = mark.to_i(16).to_s(2).rjust(MARK_BITS, "0")
      FRAME + bits.each_char.map { |bit| bit == "1" ? ONE : ZERO }.join + FRAME
    end

    def decode(text)
      return :missing unless text.to_s.include?(FRAME)

      inner = text.to_s.split(FRAME)
      return :corrupt if inner.length < 3

      payload = inner[1]
      return :corrupt unless payload.length == MARK_BITS && payload.each_char.all? { |ch| ch == ZERO || ch == ONE }

      bits = payload.each_char.map { |ch| ch == ONE ? "1" : "0" }.join
      bits.to_i(2).to_s(16).rjust(16, "0")
    end

    def carrier_text(relative_path, cutout_id, slice)
      label = "reach #{cutout_id} #{slice}"
      case File.extname(relative_path)
      when ".rb" then "# #{label}"
      when ".svelte" then "<!-- #{label}"
      end
    end

    def stampable?(relative_path)
      STAMPABLE.include?(File.extname(relative_path))
    end

    def stamp(workspace, report: true)
      meta = Reach::Workspace.metadata(workspace)
      cutout_id = meta["cutout_id"]
      slice = meta["slice"]
      results = {}
      Array(meta["owned_files"]).each do |relative|
        full = File.join(workspace, relative)
        next unless File.file?(full)
        next unless stampable?(relative)

        expected = mark_for(cutout_id, relative)
        if expected.nil?
          results[relative] = "unmarked"
          next
        end

        content = File.binread(full).force_encoding(Encoding::UTF_8)
        state = classify(content, relative, cutout_id, slice, expected)
        results[relative] = state.to_s
        case state
        when :missing
          write_carrier(full, content, relative, cutout_id, slice, expected)
          Reach::Ledger.append(workspace, "mark_restored", "path" => relative) if report
        when :corrupt
          Reach::Integrity.report("corrupt_mark", detail: relative, workspace: workspace, path: relative) if report
          write_carrier(full, content, relative, cutout_id, slice, expected)
        when :foreign
          Reach::Integrity.report("foreign_mark", detail: "#{relative} carries #{decode(carrier_line(content, relative, cutout_id, slice).to_s)}", workspace: workspace, path: relative) if report
        end
      end
      results
    rescue StandardError
      {}
    end

    def verify(workspace)
      meta = Reach::Workspace.metadata(workspace)
      cutout_id = meta["cutout_id"]
      slice = meta["slice"]
      results = {}
      Array(meta["owned_files"]).each do |relative|
        full = File.join(workspace, relative)
        next unless File.file?(full)

        unless stampable?(relative)
          results[relative] = "unmarked"
          next
        end
        expected = mark_for(cutout_id, relative)
        if expected.nil?
          results[relative] = "unmarked"
          next
        end
        content = File.binread(full).force_encoding(Encoding::UTF_8)
        results[relative] = classify(content, relative, cutout_id, slice, expected).to_s
      end
      results
    rescue StandardError
      {}
    end

    def classify(content, relative, cutout_id, slice, expected)
      line = carrier_line(content, relative, cutout_id, slice)
      return :missing if line.nil?

      decoded = decode(line)
      return decoded if decoded == :missing || decoded == :corrupt

      decoded == expected ? :own : :foreign
    end

    def carrier_line(content, relative, cutout_id, slice)
      prefix = carrier_text(relative, cutout_id, slice)
      return nil if prefix.nil?

      content.lines.first(3).find { |line| line.start_with?(prefix) }
    end

    def write_carrier(full, content, relative, cutout_id, slice, expected)
      prefix = carrier_text(relative, cutout_id, slice)
      payload = encode(expected)
      carrier = File.extname(relative) == ".rb" ? "#{prefix} #{payload}" : "#{prefix} #{payload} -->"
      lines = content.lines.map { |line| line.chomp }
      lines = lines.reject { |line| line.start_with?(prefix) }
      if File.extname(relative) == ".rb"
        if lines.first.to_s.start_with?("# frozen_string_literal")
          lines.insert(1, carrier)
        else
          lines.unshift(carrier)
          lines.unshift(RUBY_MAGIC)
        end
      else
        lines.unshift(carrier)
      end
      File.open(full, "wb") { |f| f.write(lines.join("\n") + "\n") }
    end
  end
end
