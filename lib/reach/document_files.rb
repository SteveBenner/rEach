# frozen_string_literal: true

require "find"
require "json"

module Reach
  module DocumentFiles
    SLICE = "document"
    GENERATED_NAMES = %w[AGENTS.md CLAUDE.md GEMINI.md README.md INSTRUCTIONS.md .mcp.json].freeze
    GENERATED_DIRS = %w[.claude .codex shape .reach].freeze
    MATERIALS_DIR = "materials"
    JUNK_NAMES = %w[thumbs.db desktop.ini .ds_store].freeze
    AGENT_EXTENSIONS = %w[md txt].freeze
    DEFAULT_EXTENSIONS = %w[pdf docx odt md txt png jpg jpeg].freeze
    DEFAULT_MAX_BYTES = 26_214_400
    MAX_FILES = 200
    MAX_NAME_BYTES = 255
    BODY_LIMIT_BYTES = 36 * 1024 * 1024
    BODY_OVERHEAD_BYTES = 16 * 1024

    module_function

    def document?(workspace)
      workspace.is_a?(String) && Reach::Workspace.metadata(workspace)["slice"] == SLICE
    rescue JSON::ParserError, SystemCallError
      false
    end

    def elsewhere?(workspace)
      document?(workspace) && Reach::Workspace.metadata(workspace)["submit"] == "elsewhere"
    end

    def document_meta?(meta)
      meta.is_a?(Hash) && meta["slice"] == SLICE
    end

    def accepts(meta)
      given = meta.is_a?(Hash) ? meta["accepts"] : nil
      given = {} unless given.is_a?(Hash)
      extensions = Array(given["extensions"]).map { |item| item.to_s.downcase }.reject(&:empty?)
      max_bytes = given["max_bytes"].to_i
      { "extensions" => extensions.empty? ? DEFAULT_EXTENSIONS : extensions, "max_bytes" => max_bytes.positive? ? max_bytes : DEFAULT_MAX_BYTES }
    end

    def junk?(name)
      base = File.basename(name.to_s)
      JUNK_NAMES.include?(base.downcase) || base.start_with?("~$") || base.downcase.end_with?(".tmp")
    end

    def generated?(relative)
      parts = relative.to_s.split("/")
      return true if parts.empty?
      return true if GENERATED_DIRS.include?(parts.first)

      parts.length == 1 && GENERATED_NAMES.include?(parts.first)
    end

    def delivered(workspace)
      digests = Reach::Workspace.read_delivered_digests(workspace)
      (digests.fetch("readonly", {}).keys + digests.fetch("owned", {}).keys).each_with_object({}) { |name, map| map[name] = true }
    end

    def materials?(relative)
      relative.to_s.split("/").first == MATERIALS_DIR
    end

    def student_relative?(workspace, relative, delivered_set: nil)
      name = relative.to_s
      return false if name.empty? || name.start_with?("/") || name.split("/").include?("..") || name.split("/").include?(".")
      return false if generated?(name) || junk?(name)

      set = delivered_set || delivered(workspace)
      !set.key?(name)
    end

    def walk(workspace, skip_materials:)
      return [] unless workspace && File.directory?(workspace)

      root = File.expand_path(workspace)
      set = delivered(workspace)
      found = []
      Find.find(root) do |path|
        next if path == root

        relative = path.sub("#{root}#{File::SEPARATOR}", "")
        top = relative.split(File::SEPARATOR).first
        stat = File.lstat(path)
        if stat.directory?
          Find.prune if GENERATED_DIRS.include?(top) || (skip_materials && top == MATERIALS_DIR)
          next
        end
        next unless stat.file? && !stat.symlink?
        next if skip_materials && top == MATERIALS_DIR
        next unless student_relative?(workspace, relative, delivered_set: set)

        found << relative
      end
      found.sort
    rescue SystemCallError
      []
    end

    def list(workspace)
      return [] if elsewhere?(workspace)

      walk(workspace, skip_materials: true)
    end

    def all_files(workspace)
      walk(workspace, skip_materials: false)
    end

    def text_file?(relative)
      AGENT_EXTENSIONS.include?(File.extname(relative.to_s).delete(".").downcase)
    end

    def agent_writable?(workspace, target)
      return false unless document?(workspace) && !elsewhere?(workspace)

      root = File.realpath(workspace)
      absolute = File.expand_path(target.to_s)
      return false unless absolute.start_with?("#{root}#{File::SEPARATOR}")

      relative = absolute.sub("#{root}#{File::SEPARATOR}", "")
      return false if relative.split("/").any? { |segment| segment.start_with?(".") }
      return false if materials?(relative) || !text_file?(relative)
      return false unless student_relative?(workspace, relative)

      return false if File.symlink?(absolute)

      parent = File.dirname(absolute)
      File.exist?(parent) ? File.realpath(parent).start_with?(root) : true
    rescue SystemCallError
      false
    end

    def digests(workspace, files = nil)
      (files || list(workspace)).each_with_object({}) do |relative, map|
        data = Reach::SafeFiles.read(workspace, relative)
        map[relative] = data ? Reach::Crypto.digest_hex(data) : nil
      end
    end

    def problem(workspace, meta)
      files = list(workspace)
      return ["M-SUBMIT-DOC-EMPTY", { folder: File.basename(workspace) }] if files.empty?
      return ["M-SUBMIT-DOC-COUNT", { limit: MAX_FILES }] if files.length > MAX_FILES

      limits = accepts(meta)
      seen = {}
      files.each do |relative|
        return ["M-SUBMIT-DOC-NAME", { file: relative }] if relative.bytesize > MAX_NAME_BYTES || File.basename(relative).bytesize > MAX_NAME_BYTES

        folded = relative.downcase
        return ["M-SUBMIT-DOC-CASE", { file: relative }] if seen.key?(folded)

        seen[folded] = true
        extension = File.extname(File.basename(relative)).delete(".").downcase
        return ["M-SUBMIT-DOC-NOEXT", { file: relative }] if extension.empty?
        return ["M-SUBMIT-DOC-TYPE", { file: relative, types: limits["extensions"].join(", ") }] unless limits["extensions"].include?(extension)
      end
      total = files.sum { |relative| File.size(File.join(workspace, relative)) }
      return ["M-SUBMIT-DOC-SIZE", { limit_mb: limits["max_bytes"] / (1024 * 1024) }] if total > limits["max_bytes"]
      return ["M-SUBMIT-DOC-BODY", { limit_mb: BODY_LIMIT_BYTES / (1024 * 1024) }] if encoded_too_large?(total + (1536 * files.length) + 65_536)

      nil
    end

    def encoded_too_large?(gzip_bytes)
      (((gzip_bytes + 2) / 3) * 4) + BODY_OVERHEAD_BYTES > BODY_LIMIT_BYTES
    end
  end
end
