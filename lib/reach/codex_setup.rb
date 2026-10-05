require "json"
require "time"
require "fileutils"
require "digest"
require "open3"
require "rbconfig"
require "securerandom"

module Reach
  module CodexSetup
    KIND = "codex_setup".freeze
    MODES = %w[workspace full].freeze
    PROBE_HTTP_TIMEOUT_S = 5
    SANDBOX_MODES = %w[read-only workspace-write danger-full-access].freeze
    SANDBOX_CHOICES = %w[auto workspace full].freeze
    DEFAULTS = { "setup" => true, "sandbox" => "auto", "heal" => true, "probe_timeout_s" => 20 }.freeze
    LOCK_WAIT_S = 5
    VALIDATE_TIMEOUT_S = 15
    HEAL_GAP_S = 6 * 3600
    PROBE_FRESH_S = 24 * 3600
    FULL_ACCESS = "danger-full-access".freeze
    WORKSPACE_WRITE = "workspace-write".freeze
    TRUSTED = "trusted".freeze
    BACKUP_INFIX = ".reach-backup-".freeze

    class Unsafe < StandardError; end

    module Editor
      BARE_KEY = /\A[A-Za-z0-9_-]+/.freeze
      ESCAPES = { "b" => "\b", "t" => "\t", "n" => "\n", "f" => "\f", "r" => "\r", "\"" => "\"", "\\" => "\\" }.freeze
      FORM = "a setting is written in a form rEach does not edit".freeze
      TWICE = "a setting or table appears twice".freeze
      UNREADABLE = "a line rEach cannot read".freeze

      module_function

      def decode(bytes)
        text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
        raise Unsafe, "the file is not UTF-8 text" unless text.valid_encoding?

        text
      end

      def newline_of(text)
        first = text.index("\n")
        return "\n" if first.nil?

        first.positive? && text[first - 1] == "\r" ? "\r\n" : "\n"
      end

      def split_lines(text)
        text.scan(/[^\n]*\n|[^\n]+\z/).map do |raw|
          if raw.end_with?("\r\n")
            { text: raw[0...-2], term: "\r\n" }
          elsif raw.end_with?("\n")
            { text: raw[0...-1], term: "\n" }
          else
            { text: raw, term: "" }
          end
        end
      end

      def scan(text)
        lines = split_lines(text)
        doc = { lines: lines, kinds: [], headers: [], keys: [], top_end: lines.length }
        carry = { mode: :none, depth: 0 }
        current = nil
        lines.each_with_index do |line, index|
          body = line[:text]
          if carry[:mode] != :none || carry[:depth].positive?
            doc[:kinds] << :cont
            scan_value(body, 0, carry)
            next
          end

          stripped = body.strip
          if stripped.empty?
            doc[:kinds] << :blank
          elsif stripped.start_with?("#")
            doc[:kinds] << :comment
          elsif body =~ /\A\s*\[/
            header = parse_header(body)
            header[:index] = index
            doc[:headers] << header
            doc[:kinds] << :header
            doc[:top_end] = index if doc[:top_end] == lines.length
            current = header
          else
            doc[:keys] << parse_key_line(body, index, current, carry)
            doc[:kinds] << :key
          end
        end
        raise Unsafe, UNREADABLE if carry[:mode] != :none || carry[:depth].positive?

        doc
      end

      def parse_header(body)
        position = body.index("[")
        array = body[position + 1] == "["
        position += array ? 2 : 1
        path, position = parse_key_path(body, position)
        position = skip_space(body, position)
        closing = array ? "]]" : "]"
        raise Unsafe, UNREADABLE unless body[position, closing.length] == closing

        rest = body[(position + closing.length)..-1].to_s.strip
        raise Unsafe, UNREADABLE unless rest.empty? || rest.start_with?("#")

        { path: path, array: array }
      end

      def parse_key_line(body, index, current, carry)
        path, position = parse_key_path(body, skip_space(body, 0))
        position = skip_space(body, position)
        raise Unsafe, UNREADABLE unless body[position] == "="

        start = skip_space(body, position + 1)
        raise Unsafe, UNREADABLE if start >= body.length

        finish = scan_value(body, start, carry)
        multiline = carry[:mode] != :none || carry[:depth].positive?
        { index: index, path: path, table: current, value_start: start, value_end: finish, multiline: multiline }
      end

      def skip_space(body, position)
        position += 1 while position < body.length && [" ", "\t"].include?(body[position])
        position
      end

      def parse_key_path(body, position)
        segments = []
        loop do
          position = skip_space(body, position)
          segment, position = parse_key_segment(body, position)
          segments << segment
          position = skip_space(body, position)
          break unless body[position] == "."

          position += 1
        end
        [segments, position]
      end

      def parse_key_segment(body, position)
        case body[position]
        when "\""
          parse_basic(body, position)
        when "'"
          closing = body.index("'", position + 1)
          raise Unsafe, UNREADABLE unless closing

          [body[(position + 1)...closing], closing + 1]
        else
          match = BARE_KEY.match(body[position..-1].to_s)
          raise Unsafe, UNREADABLE unless match

          [match[0], position + match[0].length]
        end
      end

      def parse_basic(body, position)
        out = +""
        cursor = position + 1
        while cursor < body.length
          char = body[cursor]
          return [out, cursor + 1] if char == "\""

          if char == "\\"
            code = body[cursor + 1]
            if ESCAPES.key?(code)
              out << ESCAPES[code]
              cursor += 2
            elsif %w[u U].include?(code)
              size = code == "u" ? 4 : 8
              hex = body[cursor + 2, size].to_s
              raise Unsafe, UNREADABLE unless hex.match?(/\A[0-9A-Fa-f]{#{size}}\z/)

              out << [hex.to_i(16)].pack("U")
              cursor += 2 + size
            else
              raise Unsafe, UNREADABLE
            end
          else
            out << char
            cursor += 1
          end
        end
        raise Unsafe, UNREADABLE
      end

      def scan_value(body, position, carry)
        last = position
        cursor = position
        while cursor < body.length
          char = body[cursor]
          case carry[:mode]
          when :ml_basic
            if body[cursor, 3] == "\"\"\""
              run = 3
              run += 1 while run < 5 && body[cursor + run] == "\""
              carry[:mode] = :none
              cursor += run
              last = cursor
            else
              cursor += char == "\\" ? 2 : 1
            end
          when :ml_literal
            if body[cursor, 3] == "'''"
              run = 3
              run += 1 while run < 5 && body[cursor + run] == "'"
              carry[:mode] = :none
              cursor += run
              last = cursor
            else
              cursor += 1
            end
          else
            if body[cursor, 3] == "\"\"\""
              carry[:mode] = :ml_basic
              cursor += 3
            elsif char == "\""
              _text, cursor = parse_basic(body, cursor)
              last = cursor
            elsif body[cursor, 3] == "'''"
              carry[:mode] = :ml_literal
              cursor += 3
            elsif char == "'"
              closing = body.index("'", cursor + 1)
              raise Unsafe, UNREADABLE unless closing

              cursor = closing + 1
              last = cursor
            elsif char == "#"
              break
            else
              if "[{".include?(char)
                carry[:depth] += 1
              elsif "]}".include?(char)
                carry[:depth] -= 1
                raise Unsafe, UNREADABLE if carry[:depth].negative?
              end
              cursor += 1
              last = cursor unless [" ", "\t"].include?(char)
            end
          end
        end
        last
      end

      def value_text(doc, key)
        doc[:lines][key[:index]][:text][key[:value_start]...key[:value_end]]
      end

      def read_string(doc, key)
        raise Unsafe, FORM if key[:multiline]

        raw = value_text(doc, key)
        if raw.start_with?("\"") && !raw.start_with?("\"\"\"")
          text, finish = parse_basic(raw, 0)
          return text if finish == raw.length
        elsif raw.start_with?("'") && !raw.start_with?("'''") && raw.length >= 2 && raw.end_with?("'") && raw.count("'") == 2
          return raw[1...-1]
        end
        raise Unsafe, FORM
      end

      def read_bool(doc, key)
        raise Unsafe, FORM if key[:multiline]

        raw = value_text(doc, key)
        return true if raw == "true"
        return false if raw == "false"

        raise Unsafe, FORM
      end

      def read_string_array(doc, key)
        raise Unsafe, FORM if key[:multiline]

        raw = value_text(doc, key)
        raise Unsafe, FORM unless raw.start_with?("[") && raw.end_with?("]")

        items = []
        cursor = skip_space(raw, 1)
        loop do
          break if raw[cursor] == "]" && cursor == raw.length - 1

          case raw[cursor]
          when "\""
            text, cursor = parse_basic(raw, cursor)
          when "'"
            closing = raw.index("'", cursor + 1)
            raise Unsafe, FORM unless closing

            text = raw[(cursor + 1)...closing]
            cursor = closing + 1
          else
            raise Unsafe, FORM
          end
          items << text
          cursor = skip_space(raw, cursor)
          if raw[cursor] == ","
            cursor = skip_space(raw, cursor + 1)
          elsif raw[cursor] != "]"
            raise Unsafe, FORM
          end
        end
        items
      end

      def same_path?(left, right)
        a = File.expand_path(left.to_s)
        b = File.expand_path(right.to_s)
        fold = Reach::CodexSetup.windows? || Reach::CodexSetup.macos?
        a = a.tr("\\", "/") if Reach::CodexSetup.windows?
        b = b.tr("\\", "/") if Reach::CodexSetup.windows?
        fold ? a.downcase == b.downcase : a == b
      rescue ArgumentError
        false
      end

      def project_header?(path, workspace)
        path.length == 2 && path[0] == "projects" && same_path?(path[1], workspace)
      end

      def locate(doc, workspace)
        found = { sandbox_mode: nil, sww: nil, project: nil, network_access: nil, writable_roots: nil, trust_level: nil }
        sww = doc[:headers].select { |header| header[:path] == ["sandbox_workspace_write"] }
        project = doc[:headers].select { |header| project_header?(header[:path], workspace) }
        raise Unsafe, TWICE if sww.length > 1 || project.length > 1
        raise Unsafe, FORM if (sww + project).any? { |header| header[:array] }

        found[:sww] = sww.first
        found[:project] = project.first
        doc[:keys].each do |key|
          path = key[:path]
          table = key[:table]
          if table.nil?
            raise Unsafe, FORM if path[0] == "sandbox_workspace_write"
            raise Unsafe, FORM if path[0] == "projects" && (path.length == 1 || same_path?(path[1], workspace))
            next unless path[0] == "sandbox_mode"
            raise Unsafe, FORM unless path.length == 1
            raise Unsafe, TWICE if found[:sandbox_mode]

            found[:sandbox_mode] = key
          elsif table[:path] == ["projects"]
            raise Unsafe, FORM if same_path?(path[0], workspace)
          elsif table.equal?(found[:sww])
            %w[network_access writable_roots].each do |name|
              next unless path[0] == name
              raise Unsafe, FORM unless path.length == 1

              slot = name.to_sym
              raise Unsafe, TWICE if found[slot]

              found[slot] = key
            end
          elsif table.equal?(found[:project])
            next unless path[0] == "trust_level"
            raise Unsafe, FORM unless path.length == 1
            raise Unsafe, TWICE if found[:trust_level]

            found[:trust_level] = key
          end
        end
        found
      end

      def facts(text, workspace)
        decoded = decode(text)
        decoded = decoded[1..-1] if decoded.start_with?("﻿")
        doc = scan(decoded)
        found = locate(doc, workspace)
        roots = found[:writable_roots] ? read_string_array(doc, found[:writable_roots]) : []
        {
          "sandbox_mode" => found[:sandbox_mode] ? read_string(doc, found[:sandbox_mode]) : nil,
          "network_access" => found[:network_access] ? read_bool(doc, found[:network_access]) : nil,
          "workspace_writable" => roots.any? { |root| same_path?(root, workspace) },
          "trusted" => found[:trust_level] ? read_string(doc, found[:trust_level]) == TRUSTED : false
        }
      end

      def satisfied?(facts, mode)
        return false unless facts["trusted"]
        return true if facts["sandbox_mode"] == FULL_ACCESS
        return false if mode == "full"

        facts["sandbox_mode"] == WORKSPACE_WRITE && facts["network_access"] == true && facts["workspace_writable"]
      end

      def quote(value)
        "\"#{value.to_s.gsub(/[\\"]/) { |char| "\\#{char}" }}\""
      end

      def last_filled(doc, from, upto)
        found = nil
        (from...upto).each { |index| found = index unless doc[:kinds][index] == :blank }
        found
      end

      def table_end(doc, header)
        following = doc[:headers].find { |other| other[:index] > header[:index] }
        following ? following[:index] : doc[:lines].length
      end

      def add_array_item(raw, item)
        inner = raw[1...-1]
        return "[#{item}]" if inner.strip.empty?

        head = raw[0...-1].rstrip
        head.end_with?(",") ? "#{head} #{item}]" : "#{head}, #{item}]"
      end

      def edit(bytes, mode, workspace)
        text = decode(bytes)
        bom = text.start_with?("﻿") ? "﻿" : ""
        body = text[bom.length..-1]
        nl = newline_of(body)
        doc = scan(body)
        found = locate(doc, workspace)
        current = facts(body, workspace)
        replace = {}
        after = Hash.new { |hash, key| hash[key] = [] }
        tail = []

        wanted_mode = mode == "full" ? FULL_ACCESS : WORKSPACE_WRITE
        keep_mode = current["sandbox_mode"] == FULL_ACCESS || current["sandbox_mode"] == wanted_mode
        unless keep_mode
          line = "sandbox_mode = #{quote(wanted_mode)}"
          if found[:sandbox_mode]
            key = found[:sandbox_mode]
            replace[key[:index]] = splice(doc, key, quote(wanted_mode))
          else
            spot = last_filled(doc, 0, doc[:top_end])
            after[spot.nil? ? -1 : spot] << line
          end
        end

        if mode == "workspace" && !(current["sandbox_mode"] == FULL_ACCESS)
          lines = []
          root_item = quote(written_path(workspace))
          if found[:writable_roots]
            unless current["workspace_writable"]
              key = found[:writable_roots]
              replace[key[:index]] = splice(doc, key, add_array_item(value_text(doc, key), root_item))
            end
          else
            lines << "writable_roots = [#{root_item}]"
          end
          if found[:network_access]
            key = found[:network_access]
            replace[key[:index]] = splice(doc, key, "true") unless current["network_access"] == true
          else
            lines << "network_access = true"
          end
          if found[:sww]
            unless lines.empty?
              spot = last_filled(doc, found[:sww][:index], table_end(doc, found[:sww]))
              after[spot].concat(lines)
            end
          else
            tail << ["[sandbox_workspace_write]", *lines]
          end
        end

        unless current["trusted"]
          line = "trust_level = #{quote(TRUSTED)}"
          if found[:trust_level]
            key = found[:trust_level]
            replace[key[:index]] = splice(doc, key, quote(TRUSTED))
          elsif found[:project]
            spot = last_filled(doc, found[:project][:index], table_end(doc, found[:project]))
            after[spot] << line
          else
            tail << ["[projects.#{quote(written_path(workspace))}]", line]
          end
        end

        return text if replace.empty? && after.empty? && tail.empty?

        result = render(doc, replace, after, tail, nl)
        result = bom + result
        raise Unsafe, "the result did not read back as set up" unless satisfied?(facts(result, workspace), mode)

        result
      end

      def splice(doc, key, value)
        line = doc[:lines][key[:index]][:text]
        line[0...key[:value_start]] + value + line[key[:value_end]..-1].to_s
      end

      def render(doc, replace, after, tail, nl)
        out = []
        after[-1].each { |line| out << [line, nl] } if after.key?(-1)
        doc[:lines].each_with_index do |line, index|
          out << [replace.key?(index) ? replace[index] : line[:text], line[:term]]
          after[index].each { |added| out << [added, nl] } if after.key?(index)
        end
        tail.each do |table|
          out << ["", nl] unless out.empty? || out.last[0].strip.empty?
          table.each { |added| out << [added, nl] }
        end
        out.each_with_index { |pair, index| pair[1] = nl if pair[1].empty? && index < out.length - 1 }
        out.map { |text, term| text + term }.join
      end

      def written_path(workspace)
        Reach::CodexSetup.windows? ? workspace.tr("/", "\\") : workspace
      end
    end

    module_function

    def windows?
      RbConfig::CONFIG["host_os"].to_s =~ /mswin|mingw|cygwin/ ? true : false
    end

    def macos?
      RbConfig::CONFIG["host_os"].to_s =~ /darwin|mac os/i ? true : false
    end

    def config
      section = Reach::Runtime.load_config["codex"]
      DEFAULTS.merge(section.is_a?(Hash) ? section : {})
    rescue StandardError
      DEFAULTS.dup
    end

    def policy_off?
      return false unless Reach::Enroll.current

      course = Reach::Guardrails.load["course"]
      section = course.is_a?(Hash) ? course["codex"] : nil
      section.is_a?(Hash) && section["setup"] == false
    rescue StandardError
      false
    end

    def enabled?
      return false if ENV["REACH_CODEX_SETUP"].to_s == "0"
      return false if config["setup"] == false

      !policy_off?
    end

    def heal_enabled?
      enabled? && config["heal"] != false
    end

    def mode_wanted
      choice = config["sandbox"].to_s
      choice = "auto" unless SANDBOX_CHOICES.include?(choice)
      return choice unless choice == "auto"

      windows? ? "full" : "workspace"
    end

    def probe_timeout_s
      value = config["probe_timeout_s"]
      value = DEFAULTS["probe_timeout_s"] unless value.is_a?(Numeric)
      value.clamp(5, 60)
    end

    def codex_home
      Reach::CodexCache.codex_home
    end

    def config_path
      File.join(codex_home, "config.toml")
    end

    def state_path
      File.join(Reach::Paths.root_state_dir, "codex_setup.json")
    end

    def lock_path
      File.join(Reach::Paths.root_state_dir, "codex_setup.lock")
    end

    def workspace
      File.expand_path(Reach::Paths.workspace_base)
    end

    def codex_cli
      Reach::Diagnose.which("codex")
    rescue StandardError
      nil
    end

    def codex_present?
      !codex_cli.nil? || File.directory?(codex_home)
    end

    def now_s
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def read_state
      return {} unless File.file?(state_path)

      data = JSON.parse(File.read(state_path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write_state(data)
      FileUtils.mkdir_p(File.dirname(state_path))
      tmp = "#{state_path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
      File.rename(tmp, state_path)
      File.chmod(0o600, state_path)
      data
    end

    def update_state
      write_state(yield(read_state))
    end

    def locked
      FileUtils.mkdir_p(File.dirname(lock_path))
      Reach::Locks.exclusive(lock_path, wait_s: LOCK_WAIT_S) { yield }
    end

    def emit(outcome, fields = {})
      Reach::Debug.emit("brain", fields.merge("event" => "codex_setup.#{outcome}"))
    rescue StandardError
      nil
    end

    def text(id, **fields)
      Reach::Messages.text(id, **fields)
    end

    def answer(state, ok, id, **fields)
      { "state" => state, "ok" => ok, "text" => text(id, **fields) }
    end

    def changes_text(mode)
      text(mode == "full" ? "M-CODEX-SETUP-CHANGES-FULL" : "M-CODEX-SETUP-CHANGES-WORKSPACE")
    end

    def question(mode)
      text("M-CODEX-SETUP-ASK", changes: changes_text(mode))
    end

    def codex_home_writable?
      dir = codex_home
      dir = File.dirname(dir) until File.directory?(dir) || File.dirname(dir) == dir
      probe = File.join(dir, ".reach-write-probe-#{Process.pid}")
      File.write(probe, "")
      File.delete(probe)
      true
    rescue SystemCallError
      false
    end

    def sandboxed?
      Reach::Sandbox.active? && !codex_home_writable?
    end

    def current_bytes
      File.file?(config_path) ? File.binread(config_path) : nil
    end

    def facts
      bytes = current_bytes
      result = Editor.facts(bytes || "", workspace)
      result.merge("readable" => true)
    rescue Unsafe => e
      { "sandbox_mode" => nil, "network_access" => nil, "workspace_writable" => false, "trusted" => false, "readable" => false, "reason" => e.message }
    end

    def satisfied?(mode = mode_wanted, found = facts)
      found["readable"] && Editor.satisfied?(found, mode)
    end

    def status
      found = facts
      state = read_state
      cli = codex_cli
      {
        "codex_present" => !cli.nil? || File.directory?(codex_home),
        "codex_cli" => !cli.nil?,
        "config_path" => config_path,
        "config_exists" => File.file?(config_path),
        "sandbox_mode" => found["sandbox_mode"],
        "network_access" => found["network_access"],
        "workspace_writable" => found["workspace_writable"],
        "trusted" => found["trusted"],
        "mode_wanted" => mode_wanted,
        "satisfied" => satisfied?(mode_wanted, found) ? true : false,
        "consent" => state["consent"],
        "applied_at" => state["applied_at"],
        "backup" => state["backup"],
        "probe" => state["probe"]
      }
    end

    def preflight
      return answer("off", false, "M-CODEX-SETUP-OFF") unless enabled?
      return { "state" => "sandboxed", "ok" => false, "text" => Reach::Sandbox.agent_text } if sandboxed?
      return answer("no_codex", true, "M-CODEX-SETUP-NO-CODEX") unless codex_present?

      nil
    end

    def check_mode!(mode)
      return mode_wanted if mode.nil? || mode.to_s.empty?
      raise Reach::Error, "reach: --mode must be workspace or full" unless MODES.include?(mode.to_s)

      mode.to_s
    end

    def apply!(mode: nil, via:)
      mode = check_mode!(mode)
      early = preflight
      return early if early

      outcome = locked { apply_locked(mode, via) }
      outcome == :busy ? answer("busy", false, "M-CODEX-SETUP-BUSY") : outcome
    rescue Reach::Error
      raise
    rescue StandardError => e
      Reach::Debug.fault(e, "codex_setup:apply")
      answer("unsafe", false, "M-CODEX-SETUP-UNSAFE", reason: "an unexpected error")
    end

    def record_consent(state, answer_word, via)
      state.merge("consent" => { "answer" => answer_word, "at" => now_s, "via" => via })
    end

    def apply_locked(mode, via)
      state = read_state
      state = record_consent(state, "yes", via) unless via == "heal"
      before = current_bytes
      begin
        raise Unsafe, "the settings file is a link" if File.symlink?(config_path)

        after = Editor.edit(before || "", mode, workspace)
      rescue Unsafe => e
        write_state(state)
        emit("refused", "mode" => mode, "via" => via, "reason" => e.message)
        return answer("unsafe", false, "M-CODEX-SETUP-UNSAFE", reason: e.message)
      end

      if !before.nil? && after.b == before.b
        write_state(state.merge("mode" => mode))
        emit("already", "mode" => mode, "via" => via)
        return answer("already", true, "M-CODEX-SETUP-ALREADY")
      end

      write_change(state, mode, via, before, after)
    end

    def write_change(state, mode, via, before, after)
      cli = codex_cli
      FileUtils.mkdir_p(codex_home) if cli && !File.directory?(codex_home)
      baseline = cli ? codex_accepts?(cli) : nil
      old_mode = before.nil? ? 0o600 : (File.stat(config_path).mode & 0o777)
      backup = before.nil? ? nil : write_backup(before, old_mode)
      write_atomic(after, old_mode)
      if cli && baseline == true && codex_accepts?(cli) == false
        before.nil? ? File.delete(config_path) : write_atomic(before, old_mode)
        write_state(state)
        emit("refused", "mode" => mode, "via" => via, "reason" => "codex rejected the file")
        return answer("unsafe", false, "M-CODEX-SETUP-UNSAFE", reason: "codex rejected the file")
      end

      fresh = state.merge(
        "mode" => mode, "applied_at" => now_s, "config_sha256" => Digest::SHA256.hexdigest(after)
      )
      fresh["backup"] = backup if backup
      fresh["healed_at"] = now_s if via == "heal"
      write_state(fresh)
      emit(via == "heal" ? "healed" : "applied", "mode" => mode, "via" => via, "backup" => backup ? File.basename(backup) : nil)
      shown = backup && via == "live" ? File.basename(backup) : backup
      backup ? answer("applied", true, "M-CODEX-SETUP-DONE", backup: shown) : answer("applied", true, "M-CODEX-SETUP-DONE-NEW")
    rescue SystemCallError => e
      write_state(state)
      emit("refused", "mode" => mode, "via" => via, "reason" => "the settings file could not be written", "errno" => e.class.name)
      answer("unsafe", false, "M-CODEX-SETUP-UNSAFE", reason: "the settings file could not be written")
    end

    def write_backup(bytes, file_mode)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      base = "#{config_path}#{BACKUP_INFIX}#{stamp}"
      candidate = base
      count = 1
      loop do
        begin
          File.open(candidate, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, file_mode) { |file| file.write(bytes) }
          File.chmod(file_mode, candidate)
          return candidate
        rescue Errno::EEXIST
          count += 1
          candidate = "#{base}-#{count}"
        end
      end
    end

    def write_atomic(bytes, file_mode)
      tmp = File.join(codex_home, ".config.toml.reach-tmp-#{Process.pid}-#{SecureRandom.hex(4)}")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, file_mode) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.chmod(file_mode, tmp)
      File.rename(tmp, config_path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def codex_accepts?(cli)
      _out, _err, code = run_limited([cli, "features", "list"], VALIDATE_TIMEOUT_S)
      return nil if code == :timeout || code.nil?

      code.zero?
    end

    def run_limited(argv, limit, chdir: nil)
      options = {}
      options[:chdir] = chdir if chdir
      if windows?
        options[:new_pgroup] = true
      else
        options[:pgroup] = true
      end
      Open3.popen3(*argv, options) do |stdin, stdout, stderr, thread|
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        unless thread.join(limit)
          stop(thread.pid)
          thread.join
          return [out_reader.value.to_s, err_reader.value.to_s, :timeout]
        end
        [out_reader.value.to_s, err_reader.value.to_s, thread.value.exitstatus]
      end
    rescue SystemCallError => e
      ["", e.message, nil]
    end

    def stop(pid)
      Process.kill("KILL", windows? ? pid : -pid)
    rescue SystemCallError
      begin
        Process.kill("KILL", pid)
      rescue SystemCallError
        nil
      end
    end

    def configure_terminal(mode: nil, input: $stdin, output: $stdout)
      mode = check_mode!(mode)
      early = preflight
      return early if early
      return answer("already", true, "M-CODEX-SETUP-ALREADY") if satisfied?(mode)

      output.puts question(mode)
      output.print "> "
      output.flush
      reply = input.gets.to_s
      return apply!(mode: mode, via: "terminal") if Reach::Consent.yes?(reply)

      decline!("terminal", mode)
    end

    def decline!(via, mode)
      outcome = locked { write_state(record_consent(read_state, "no", via)) }
      return answer("busy", false, "M-CODEX-SETUP-BUSY") if outcome == :busy

      emit("declined", "mode" => mode, "via" => via)
      answer("declined", false, "M-CODEX-SETUP-DECLINED")
    end

    def config_digest
      bytes = current_bytes
      bytes.nil? ? "none" : Digest::SHA256.hexdigest(bytes)
    end

    def hooks_off?
      label = Reach::KnownIssues.harness.to_s
      !label.empty? && Reach::KnownIssues.family_of(label) == "codex" && Reach::KnownIssues.hooks_stale? &&
        Reach::KnownIssues.enroll_hook_quiet?(Reach::KnownIssues::HOOKS_QUIET_S)
    rescue StandardError
      false
    end

    def ask_chat(mode: nil, mcp: false)
      mode = check_mode!(mode)
      early = preflight
      return early if early
      return answer("already", true, "M-CODEX-SETUP-ALREADY") if satisfied?(mode)
      return answer("terminal", false, "M-CODEX-SETUP-TERMINAL", command: "reach codex configure") if mcp && hooks_off?
      return answer("terminal", false, "M-CODEX-SETUP-SIGN-IN", command: "reach codex configure") if mcp && Reach::Login.enrolled_id.nil?

      subject = { "codex" => mode, "config" => config_digest }
      asked = Reach::Consent.ask!(kind: KIND, subject: subject, message_id: "M-CODEX-SETUP-ASK", fields: { changes: changes_text(mode) })
      { "state" => "asked", "ok" => true, "question" => asked, "text" => text("M-CONSENT-NEEDED", question: asked) }
    end

    def follow_up!(observed)
      subject = observed["subject"].is_a?(Hash) ? observed["subject"] : {}
      mode = MODES.include?(subject["codex"]) ? subject["codex"] : mode_wanted
      if observed["answer"] == "yes"
        Reach::Consent.take!(kind: KIND, subject: subject)
        return apply!(mode: mode, via: "chat")["text"]
      end

      Reach::Consent.clear_declined!(kind: KIND, subject: subject)
      decline!("chat", mode)["text"]
    rescue StandardError => e
      Reach::Debug.fault(e, "codex_setup:follow_up")
      nil
    end

    def newest_backup
      found = Dir.glob("#{config_path}#{BACKUP_INFIX}*").max_by { |path| File.mtime(path) }
      found || read_state["backup"]
    rescue StandardError
      read_state["backup"]
    end

    def withdraw!
      return { "state" => "sandboxed", "ok" => false, "text" => Reach::Sandbox.agent_text } if sandboxed?

      outcome = locked { write_state(record_consent(read_state, "withdrawn", "terminal")) }
      return answer("busy", false, "M-CODEX-SETUP-BUSY") if outcome == :busy

      emit("withdrawn", "mode" => read_state["mode"], "via" => "terminal")
      backup = newest_backup
      backup ? answer("withdrawn", true, "M-CODEX-SETUP-OFF-DONE", backup: backup) : answer("withdrawn", true, "M-CODEX-SETUP-OFF-DONE-NEW")
    end

    def heal!
      return nil unless heal_enabled?

      state = read_state
      consent = state["consent"].is_a?(Hash) ? state["consent"] : {}
      return nil unless consent["answer"] == "yes"
      return nil unless codex_present?
      return nil if Reach::Sandbox.active?
      return nil if recent?(state["healed_at"], HEAL_GAP_S)

      mode = MODES.include?(state["mode"]) ? state["mode"] : mode_wanted
      return nil if satisfied?(mode)

      outcome = locked do
        result = apply_locked(mode, "heal")
        update_state { |fresh| fresh.merge("healed_at" => now_s) }
        result
      end
      outcome == :busy ? nil : outcome
    rescue StandardError => e
      Reach::Debug.fault(e, "codex_setup:heal")
      nil
    end

    def recent?(value, gap)
      return false if value.to_s.empty?

      Time.now.utc - Time.iso8601(value.to_s) < gap
    rescue ArgumentError
      false
    end

    def teach_url
      install = Reach::Enroll.current
      url = install.is_a?(Hash) ? install["teach_url"].to_s : ""
      url.empty? ? Reach::Runtime.default_teach_url : url
    rescue StandardError
      Reach::Runtime.default_teach_url
    end

    def probe_child
      result = { "flag" => ENV["CODEX_SANDBOX_NETWORK_DISABLED"].to_s == "1", "network" => nil, "home_writable" => nil, "reason" => nil }
      if ENV["REACH_OFFLINE"].to_s == "1"
        result["reason"] = "offline flag"
      else
        result["network"] = network_ok?
      end
      result["home_writable"] = Reach::Sandbox.probe_home
      result
    end

    def network_ok?
      return false if ENV["CODEX_SANDBOX_NETWORK_DISABLED"].to_s == "1"

      uri = URI.parse("#{teach_url.to_s.sub(%r{/+\z}, "")}/api/v1/health")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = PROBE_HTTP_TIMEOUT_S
      http.read_timeout = PROBE_HTTP_TIMEOUT_S
      http.request_get(uri.request_uri).code.to_i < 500
    rescue StandardError
      false
    end

    def probe!
      cli = codex_cli
      return finish_probe(probe_record(false, reason: "codex command not found"), store: true) unless cli
      return finish_probe(probe_record(false, reason: "already inside the sandbox"), store: false) if Reach::Sandbox.active?

      unless ENV["REACH_OFFLINE"].to_s == "1"
        begin
          Reach::TokenBucket.acquire!(quick: true)
        rescue Reach::Error
          return finish_probe(probe_record(false, reason: "rEach is pacing its requests, try again in a minute"), store: false)
        end
      end

      cwd = File.directory?(workspace) ? workspace : Dir.pwd
      argv = [cli, "sandbox"] + probe_mode_args + ["--", Reach::Runtime.ruby_path, Reach::Runtime.exe_path, "codex", "probe-child"]
      out, err, code = run_limited(argv, probe_timeout_s, chdir: cwd)
      record = if code == :timeout
                 probe_record(false, reason: "the test did not finish in #{probe_timeout_s} seconds")
               elsif code.nil?
                 probe_record(false, reason: "codex sandbox could not be started")
               elsif !code.zero?
                 probe_record(false, reason: "codex sandbox exited #{code}: #{first_line(err.to_s.empty? ? out : err)}")
               else
                 parsed = parse_child(out)
                 if parsed
                   probe_record(true, network: parsed["network"], home_writable: parsed["home_writable"], reason: parsed["reason"])
                 else
                   probe_record(false, reason: "the test printed no result")
                 end
               end
      record["codex_version"] = codex_version(cli)
      finish_probe(record, store: true)
    rescue StandardError => e
      Reach::Debug.fault(e, "codex_setup:probe")
      finish_probe(probe_record(false, reason: "an unexpected error"), store: false)
    end

    def probe_mode_args
      found = facts["sandbox_mode"].to_s
      SANDBOX_MODES.include?(found) ? ["-c", "sandbox_mode=\"#{found}\""] : []
    rescue StandardError
      []
    end

    def probe_record(available, network: nil, home_writable: nil, reason: nil)
      { "at" => now_s, "available" => available, "network" => network, "home_writable" => home_writable, "reason" => reason, "codex_version" => nil }
    end

    def parse_child(out)
      out.to_s.lines.reverse_each do |line|
        parsed = begin
          JSON.parse(line.strip)
        rescue JSON::ParserError
          nil
        end
        return parsed if parsed.is_a?(Hash) && parsed.key?("home_writable")
      end
      nil
    end

    def first_line(value)
      line = value.to_s.lines.map(&:strip).reject(&:empty?).first.to_s
      line[0, 200]
    end

    def codex_version(cli)
      out, _err, code = run_limited([cli, "--version"], 10)
      return nil unless code.is_a?(Integer) && code.zero?

      out.to_s.strip.split(/\s+/).last
    end

    def finish_probe(record, store:)
      if store
        outcome = locked { update_state { |state| state.merge("probe" => record) } }
        record["stored"] = outcome != :busy
      end
      emit("probed", "available" => record["available"], "network" => record["network"], "home_writable" => record["home_writable"], "reason" => record["reason"])
      record.merge("text" => probe_text(record))
    rescue StandardError
      record.merge("text" => probe_text(record))
    end

    def blocked_what(record)
      network = record["network"] == false
      home = record["home_writable"] == false
      return nil unless network || home
      return text("M-CODEX-PROBE-WHAT-BOTH") if network && home

      text(network ? "M-CODEX-PROBE-WHAT-NETWORK" : "M-CODEX-PROBE-WHAT-HOME")
    end

    def probe_text(record)
      return text("M-CODEX-PROBE-UNAVAILABLE", reason: record["reason"] || "unknown") unless record["available"]

      what = blocked_what(record)
      return text("M-CODEX-PROBE-BLOCKED", what: what) if what
      return text("M-CODEX-PROBE-UNAVAILABLE", reason: record["reason"] || "the internet was not tested") if record["network"].nil?

      text("M-CODEX-PROBE-OK")
    end

    def doctor_probe?
      codex_present? && !codex_cli.nil? && !Reach::Sandbox.active? && ENV["REACH_OFFLINE"].to_s != "1"
    end

    def ok_word(value)
      return "unknown" if value.nil?

      value ? "ok" : "blocked"
    end

    def age_text(value)
      seconds = Time.now.utc - Time.iso8601(value.to_s)
      minutes = (seconds / 60).floor
      return "#{minutes} min ago" if minutes < 120

      hours = (minutes / 60).floor
      return "#{hours} h ago" if hours < 48

      "#{(hours / 24).floor} d ago"
    rescue ArgumentError
      "at an unknown time"
    end

    def doctor_line(found = status)
      codex = if !found["codex_present"]
                "not found"
              elsif !enabled?
                "setup off"
              elsif found["satisfied"]
                "settings ok (#{found['sandbox_mode'] == FULL_ACCESS ? 'full' : 'workspace'})"
              else
                "settings not applied"
              end
      probe = found["probe"]
      sandbox = if probe.is_a?(Hash) && probe["available"]
                  "last probe: internet #{ok_word(probe['network'])}, folder #{ok_word(probe['home_writable'])}, #{age_text(probe['at'])}"
                else
                  "not tested"
                end
      "codex: #{codex}; sandbox #{sandbox}"
    end

    def doctor_problems(found = status)
      return [] unless enabled? && found["codex_present"]

      lines = []
      state = read_state
      consent = state["consent"].is_a?(Hash) ? state["consent"] : {}
      held = MODES.include?(state["mode"]) ? state["mode"] : mode_wanted
      if consent["answer"] == "yes" && !satisfied?(held)
        lines << "R-DOC-CODEX: Codex's settings no longer hold what rEach set - run reach codex configure"
      end
      probe = found["probe"]
      if probe.is_a?(Hash) && probe["available"] && recent?(probe["at"], PROBE_FRESH_S) && blocked_what(probe)
        lines << "R-DOC-CODEX: Codex's sandbox blocks rEach (internet #{ok_word(probe['network'])}, folder #{ok_word(probe['home_writable'])}) - run reach codex configure"
      end
      lines
    end
  end
end
