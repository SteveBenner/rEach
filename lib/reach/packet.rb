require "fileutils"
require "json"
require "open3"
require "tempfile"
require "time"
require "yaml"

module Reach
  module Packet
    MANIFEST = "MANIFEST.sha256".freeze
    SIGNATURE = "MANIFEST.sig".freeze
    NAMESPACE = "reach-sidecar".freeze
    IDENTITY = "teach".freeze
    SKIP_EXACT = [MANIFEST, SIGNATURE, "student.yml"].freeze
    SKIP_PREFIX = ["deliverables/", ".checkpoints/", ".runs/", ".gems/"].freeze
    RECEIPT_FILE = "sidecar-receipt.json".freeze
    KEPT_DIR = "before-sidecar-import".freeze
    IMPORT_FILE = "sidecar-import.json".freeze
    IMPORT_SCHEMA = "reach.sidecar-import/v1".freeze
    RECEIPT_SCHEMA = "teach.sidecar-receipt/v1".freeze
    WRITABLE_DIRS = %w[qualify/features qualify/step_definitions].freeze
    MAX_MANIFEST_BYTES = 4 * 1024 * 1024
    MAX_RECEIPT_BYTES = 1024 * 1024
    MAX_PROBLEMS = 5
    SLUG_SHAPE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    module_function

    def import!(folder, allowed_signers: nil, bundle: nil, qualify: true)
      Reach::Login.require_active!
      root = locate_root(folder)
      packet = verify!(root, allowed_signers: allowed_signers)
      install = Reach::Enroll.current
      raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install.is_a?(Hash)

      student = load_student(root)
      match_student!(student, install)
      course = load_course(root, student["course"])
      match_course!(course, install)

      result = {
        "schema" => IMPORT_SCHEMA,
        "folder" => root,
        "packet" => packet,
        "course" => enrolled_course_id(install),
        "warnings" => [],
        "slices" => [],
        "answers" => {},
        "receipts" => {},
        "ok" => true
      }
      stale = stale_line(packet)
      result["warnings"] << stale if stale

      started = started_slices(root, student["course"])
      raise Reach::Refused, Reach::Messages.text("M-PACKET-NOTHING") if started.empty?

      started.each { |rec| result["slices"] << import_slice(root, rec, result) }
      assignments = result["slices"].select { |row| row["imported"] }.map { |row| row["assignment"] }.uniq
      assignments.each do |assignment|
        result["answers"][assignment] = import_answers(root, student["course"], assignment, course, result)
        result["receipts"][assignment] = import_receipt(root, student, assignment, bundle, result)
      end
      result["slices"].each do |row|
        next unless row["imported"]

        write_import_record(row["workspace"], root, packet, result, row)
        row["check"] = check_count(row["workspace"])
        row["qualify"] = qualify ? qualify_outcome(row["workspace"]) : "skipped"
      end
      result["ok"] = result["slices"].all? { |row| row["imported"] }
      result["text"] = render(result)
      result
    end

    def locate_root(folder)
      raise Reach::Refused, Reach::Messages.text("M-PACKET-NOT-A-PACKET", path: folder.to_s) if folder.to_s.strip.empty?

      path = File.expand_path(folder.to_s)
      nested = File.join(path, "reach-sidecar")
      path = nested if !File.file?(File.join(path, MANIFEST)) && File.file?(File.join(nested, MANIFEST))
      raise Reach::Refused, Reach::Messages.text("M-PACKET-NOT-A-PACKET", path: folder.to_s) unless File.file?(File.join(path, MANIFEST))

      path
    end

    def verify!(root, allowed_signers: nil)
      lines = signer_lines(allowed_signers)
      raise Reach::Refused, Reach::Messages.text("M-PACKET-NO-SIGNER") if lines.empty?

      keygen = which("ssh-keygen")
      raise Reach::Refused, Reach::Messages.text("M-PACKET-NO-KEYGEN") unless keygen

      problems = []
      problems << "#{SIGNATURE} is missing" unless File.file?(File.join(root, SIGNATURE))
      manifest_path = File.join(root, MANIFEST)
      problems << "#{MANIFEST} is too large" if File.size(manifest_path) > MAX_MANIFEST_BYTES
      listed = problems.empty? ? manifest_entries(manifest_path, problems) : {}
      check_files(root, listed, problems) if problems.empty?
      check_signature(root, keygen, lines, problems) if problems.empty?
      unless problems.empty?
        raise Reach::Refused, Reach::Messages.text("M-PACKET-TAMPERED", problems: problems.first(MAX_PROBLEMS).join("; "))
      end

      build = read_yaml(File.join(root, "build.yml"))
      {
        "built_at" => build["built_at"].to_s,
        "key_id" => build["key_id"].to_s,
        "teach_version" => build["teach_version"].to_s,
        "warn_after_days" => build["warn_after_days"].to_i,
        "files_verified" => listed.length
      }
    end

    def which(executable)
      exts = ENV["PATHEXT"].to_s.split(File::PATH_SEPARATOR)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, executable)
        return candidate if File.file?(candidate) && File.executable?(candidate)

        exts.each do |ext|
          with_ext = candidate + ext
          return with_ext if File.file?(with_ext) && File.executable?(with_ext)
        end
      end
      nil
    end

    def signer_lines(path)
      if path
        raise Reach::Refused, Reach::Messages.text("M-PACKET-NO-SIGNER") unless File.file?(path)

        return File.read(path).lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
      end
      section = Reach::Runtime.load_config["sidecar"]
      lines = section.is_a?(Hash) ? section["allowed_signers"] : nil
      Array(lines).map(&:to_s).map(&:strip).reject(&:empty?)
    rescue StandardError
      []
    end

    def manifest_entries(path, problems)
      entries = {}
      File.foreach(path) do |line|
        text = line.chomp
        next if text.empty?

        match = text.match(/\A([0-9a-f]{64})  (.+)\z/)
        unless match
          problems << "#{MANIFEST} has a line this rEach cannot read"
          break
        end
        entries[match[2]] = match[1]
      end
      entries
    end

    def skipped?(relative)
      SKIP_EXACT.include?(relative) || SKIP_PREFIX.any? { |prefix| relative.start_with?(prefix) }
    end

    def check_files(root, listed, problems)
      listed.each do |relative, digest|
        next if skipped?(relative)
        break if problems.length >= MAX_PROBLEMS

        full = File.join(root, relative)
        if !relative.match?(%r{\A[^/]}) || relative.include?("../") || relative.include?("\\")
          problems << "#{relative} is not a packet path"
        elsif !File.file?(full)
          problems << "#{relative} is missing"
        elsif Reach::Crypto.digest_hex(File.binread(full)) != digest
          problems << "#{relative} was changed"
        end
      end
      return unless problems.empty?

      tree_files(root).each do |relative|
        break if problems.length >= MAX_PROBLEMS
        next if skipped?(relative) || listed.key?(relative)

        problems << "#{relative} is not part of the sidecar"
      end
    end

    def tree_files(base)
      prefix = "#{File.expand_path(base)}/"
      Dir.glob(File.join(File.expand_path(base), "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
         .map { |path| path[prefix.length..-1] }.reject { |relative| relative.start_with?(".checkpoints/", "deliverables/", ".runs/", ".gems/") }.sort
    end

    def check_signature(root, keygen, lines, problems)
      signers = Tempfile.new(["reach-signers", ".txt"])
      signers.write(lines.join("\n") + "\n")
      signers.close
      manifest = File.binread(File.join(root, MANIFEST))
      out, err, status = Open3.capture3(keygen, "-Y", "verify", "-f", signers.path, "-I", IDENTITY, "-n", NAMESPACE,
                                        "-s", File.join(root, SIGNATURE), stdin_data: manifest)
      return if status.success?

      detail = (err.to_s + out.to_s).lines.map(&:strip).reject(&:empty?).first.to_s[0, 120]
      problems << "the signature on #{MANIFEST} does not verify#{detail.empty? ? '' : " (#{detail})"}"
    rescue SystemCallError => e
      problems << "ssh-keygen could not run (#{e.class.name})"
    ensure
      signers.unlink if signers
    end

    def read_yaml(path)
      return {} unless File.file?(path)

      data = YAML.safe_load(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def read_json(path)
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    def load_student(root)
      student = read_yaml(File.join(root, "student.yml"))
      raise Reach::Refused, Reach::Messages.text("M-PACKET-NO-STUDENT") if student["email"].to_s.strip.empty? || student["course"].to_s.strip.empty?

      student
    end

    def match_student!(student, install)
      enrolled = install["username"].to_s.strip.downcase
      raise Reach::Refused, Reach::Messages.text("M-PACKET-NO-EMAIL") if enrolled.empty?

      email = student["email"].to_s.strip.downcase
      return if email == enrolled || email.split("@").first == enrolled

      raise Reach::Refused, Reach::Messages.text("M-PACKET-OTHER-STUDENT", email: mask_email(student["email"].to_s.strip))
    end

    def load_course(root, slug)
      unless slug.to_s.match?(SLUG_SHAPE) && File.file?(File.join(root, "courses", slug.to_s, "course.yml"))
        raise Reach::Refused, Reach::Messages.text("M-PACKET-OTHER-COURSE", course: slug.to_s, enrolled: enrolled_course_id(Reach::Enroll.current))
      end

      read_yaml(File.join(root, "courses", slug.to_s, "course.yml"))
    end

    def enrolled_course_id(install)
      course = install.is_a?(Hash) ? install["course"] : nil
      course.is_a?(Hash) ? course["id"].to_s : ""
    end

    def match_course!(course, install)
      enrolled = enrolled_course_id(install)
      return if same_course?(course["id"], enrolled)

      raise Reach::Refused, Reach::Messages.text("M-PACKET-OTHER-COURSE", course: course["id"].to_s, enrolled: enrolled)
    end

    def same_course?(left, right)
      a = Reach::Identity.normalize_course_id(left.to_s)
      b = Reach::Identity.normalize_course_id(right.to_s)
      !a.nil? && a == b
    end

    def stale_line(packet)
      built = Time.iso8601(packet["built_at"])
      days = packet["warn_after_days"]
      return nil unless days.positive? && Time.now.utc - built > days * 86_400

      Reach::Messages.text("M-PACKET-STALE", date: built.strftime("%Y-%m-%d"), days: days)
    rescue ArgumentError
      nil
    end

    def started_slices(root, slug)
      base = File.join(root, "deliverables", slug.to_s)
      Dir.glob(File.join(base, "*", "*", "slice.json")).sort.map do |path|
        dir = File.dirname(path)
        meta = read_json(path)
        {
          "path" => dir,
          "assignment" => File.basename(File.dirname(dir)),
          "name" => File.basename(dir),
          "cutout_id" => meta["cutout_id"].to_s,
          "slice" => meta["slice"].to_s,
          "owned_files" => Array(meta["owned_files"]).map(&:to_s),
          "checkpoints" => File.join(root, ".checkpoints", slug.to_s, File.basename(File.dirname(dir)), File.basename(dir))
        }
      end
    end

    def import_slice(root, rec, result)
      row = { "slice" => rec["name"], "assignment" => rec["assignment"], "imported" => false, "files" => 0, "checkpoints" => 0, "skipped" => [], "kept" => [] }
      workspace = Reach::Workspace.find(cutout_id: rec["cutout_id"], slice: rec["slice"])
      meta = workspace ? Reach::Workspace.metadata(workspace) : {}
      if workspace.nil? || meta["assignment"].to_s != rec["assignment"] || !same_course?(meta["course"], result["course"])
        result["warnings"] << Reach::Messages.text("M-PACKET-NO-WORKSPACE", slice: rec["name"])
        return row
      end

      owned = Array(meta["owned_files"]).map(&:to_s)
      unless Reach::Workspace.changed_owned_files(workspace).empty?
        Reach::Checkpoint.save(workspace, note: "before sidecar import", automatic: true)
      end
      row["checkpoints"] = replay_checkpoints(rec, workspace, owned)
      row["files"] = copy_current(rec, workspace, owned, row, result)
      unless row["kept"].empty?
        result["warnings"] << Reach::Messages.text("M-PACKET-KEPT-COPY", slice: rec["name"], count: row["kept"].length, folder: File.join(Reach::Workspace::MARKER_DIR, KEPT_DIR))
      end
      Reach::Seal.stamp(workspace)
      Reach::Checkpoint.save(workspace, note: "sidecar import", automatic: true)
      Reach::Ledger.append(workspace, "sidecar_import", "files" => row["files"], "checkpoints" => row["checkpoints"],
                                                      "built_at" => result["packet"]["built_at"], "key_id" => result["packet"]["key_id"])
      row["workspace"] = workspace
      row["imported"] = true
      row
    end

    def checkpoint_entries(dir)
      return [] unless File.directory?(dir)

      Dir.children(dir).select { |name| name.match?(/\A\d{3,}\z/) }.sort.map do |name|
        entry = read_json(File.join(dir, name, "meta.json"))
        entry.empty? ? nil : entry.merge("files_dir" => File.join(dir, name, "files"))
      end.compact
    end

    def replay_checkpoints(rec, workspace, owned)
      count = 0
      checkpoint_entries(rec["checkpoints"]).each do |entry|
        written = 0
        owned.each do |relative|
          source = File.join(entry["files_dir"], relative)
          next unless safe_source?(source, entry["files_dir"])

          write_owned(workspace, relative, File.binread(source))
          written += 1
        end
        next if written.zero?

        note = "sidecar #{entry['n']}: #{entry['note']}"[0, 200]
        saved = Reach::Checkpoint.save(workspace, note: note, automatic: entry["automatic"] == true)
        count += 1 if saved["saved"]
      end
      count
    end

    def copy_current(rec, workspace, owned, row, result)
      count = 0
      rec["owned_files"].each do |relative|
        source = File.join(rec["path"], relative)
        next unless safe_source?(source, rec["path"])

        unless owned.include?(relative)
          row["skipped"] << relative
          result["warnings"] << Reach::Messages.text("M-PACKET-FILE-SKIPPED", slice: rec["name"], path: relative)
          next
        end
        write_owned(workspace, relative, File.binread(source))
        count += 1
      end
      WRITABLE_DIRS.each do |dir|
        base = File.join(rec["path"], dir)
        next unless File.directory?(base)

        Dir.glob(File.join(base, "**", "*")).select { |path| File.file?(path) }.sort.each do |path|
          relative = File.join(dir, path[(base.length + 1)..-1])
          next if File.basename(path) == ".keep" || !safe_source?(path, base)

          write_extra(workspace, relative, File.binread(path), row)
          count += 1
        end
      end
      plan = File.join(rec["path"], "plan.md")
      if safe_source?(plan, rec["path"])
        write_extra(workspace, "plan.md", File.binread(plan), row)
        count += 1
      end
      count
    end

    def safe_source?(path, base)
      return false unless File.file?(path) && !File.symlink?(path)

      File.realpath(path).start_with?(File.realpath(base) + File::SEPARATOR)
    rescue SystemCallError
      false
    end

    def write_owned(workspace, relative, data)
      full = File.join(workspace, relative)
      Reach::Workspace.open_path(workspace, File.dirname(relative))
      FileUtils.mkdir_p(File.dirname(full))
      Reach::Workspace.safe_chmod(0o644, full) if File.file?(full)
      File.open(full, "wb") { |file| file.write(data) }
    end

    def write_extra(workspace, relative, data, row)
      full = File.join(workspace, relative)
      if File.file?(full) && File.binread(full) != data
        kept = File.join(workspace, Reach::Workspace::MARKER_DIR, KEPT_DIR, relative)
        FileUtils.mkdir_p(File.dirname(kept))
        FileUtils.cp(full, kept)
        row["kept"] << relative
      end
      write_owned(workspace, relative, data)
    end

    def import_answers(root, slug, assignment, course, result)
      answers = packet_answers(root, slug, assignment)
      questions = Reach::Part.questions(assignment)
      questions = course_questions(course, assignment) if questions.empty?
      workspace = result["slices"].find { |row| row["imported"] && row["assignment"] == assignment }["workspace"]
      recorded = []
      skipped = []
      questions.each do |question|
        id = question["id"].to_s
        answer = answers[id]
        next unless answer

        text = answer["text"].to_s
        words = Reach::Part.word_count(text)
        minimum = question["min_words"].to_i
        if words < minimum
          skipped << Reach::Messages.text("M-PACKET-ANSWER-SHORT", id: id, words: words, min: minimum)
          next
        end
        outcome = Reach::Part.import!(id, text: text, recorded_at: answer["recorded_at"].to_s, workspace: workspace)
        recorded << id if outcome
      end
      skipped.each { |line| result["warnings"] << line }
      { "recorded" => recorded, "skipped" => skipped.length, "questions" => questions.length }
    end

    def course_questions(course, assignment)
      rows = Array(course["assignments"]).select { |row| row.is_a?(Hash) && row["id"].to_s == assignment }
      rows.flat_map { |row| Array(row["student_part"]).select { |item| item.is_a?(Hash) } }
    end

    def packet_answers(root, slug, assignment)
      answers = {}
      started_slices(root, slug).select { |rec| rec["assignment"] == assignment }.each do |rec|
        Array(read_json(File.join(rec["path"], "part.json"))["answers"]).each do |answer|
          next unless answer.is_a?(Hash) && answer["text"].is_a?(String)

          id = answer["question_id"].to_s
          answers[id] = answer if answers[id].nil? || answer["recorded_at"].to_s >= answers[id]["recorded_at"].to_s
        end
      end
      answers
    end

    def import_receipt(root, student, assignment, bundle, result)
      path = bundle ? File.expand_path(bundle) : latest_bundle(root, student["course"], assignment)
      unless path && File.file?(path)
        result["warnings"] << Reach::Messages.text("M-PACKET-NO-BUNDLE", assignment: assignment)
        return nil
      end

      receipt = read_receipt(path)
      unless receipt && receipt["schema"] == RECEIPT_SCHEMA && receipt["assignment"].to_s == assignment &&
             receipt["course"].to_s == student["course"].to_s && receipt.dig("student", "email").to_s.strip.downcase == student["email"].to_s.strip.downcase
        result["warnings"] << Reach::Messages.text("M-PACKET-BUNDLE-MISMATCH", bundle: path, assignment: assignment)
        return nil
      end

      result["slices"].each do |row|
        next unless row["imported"] && row["assignment"] == assignment

        target = File.join(row["workspace"], Reach::Workspace::MARKER_DIR, RECEIPT_FILE)
        File.write(target, JSON.generate(receipt))
      end
      { "bundle" => path, "digest" => receipt["digest"], "bundled_at" => receipt["bundled_at"], "key_id" => receipt.dig("sidecar", "key_id") }
    end

    def latest_bundle(root, slug, assignment)
      file = File.join(root, ".checkpoints", slug.to_s, assignment, "bundles.json")
      return nil unless File.file?(file)

      history = JSON.parse(File.read(file))
      return nil unless history.is_a?(Array)

      allowed = [root, Reach::Archive.downloads_dir].map { |dir| real_dir(dir) }.compact
      history.select { |entry| entry.is_a?(Hash) && bundle_path?(entry["path"].to_s, allowed) }.map { |entry| entry["path"].to_s }.last
    rescue JSON::ParserError
      nil
    end

    def real_dir(dir)
      File.realpath(dir)
    rescue SystemCallError
      nil
    end

    def bundle_path?(path, allowed)
      return false unless path.end_with?(".zip") && File.file?(path) && !File.symlink?(path)

      real = File.realpath(path)
      allowed.any? { |dir| real.start_with?(dir + File::SEPARATOR) }
    rescue SystemCallError
      false
    end

    def mask_email(email)
      local, domain = email.split("@", 2)
      return "***" if local.to_s.empty?

      "#{local[0, 2]}#{'*' * [local.length - 2, 3].max}#{domain ? "@#{domain}" : ''}"
    end

    def read_receipt(zip_path)
      File.open(zip_path, "rb") do |io|
        entry = Reach::Unzip.central_directory(io).find { |item| item[:name].to_s.end_with?("/rEach/receipt.json") }
        return nil unless entry && entry[:usize].to_i <= MAX_RECEIPT_BYTES

        buffer = +""
        Reach::Unzip.each_chunk(io, entry, max_bytes: MAX_RECEIPT_BYTES) { |piece| buffer << piece }
        data = JSON.parse(buffer)
        data.is_a?(Hash) ? data : nil
      end
    rescue StandardError
      nil
    end

    def write_import_record(workspace, root, packet, result, row)
      assignment = row["assignment"]
      receipt = result["receipts"][assignment]
      record = {
        "schema" => IMPORT_SCHEMA,
        "imported_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "folder" => root,
        "packet" => packet.reject { |key, _| key == "files_verified" },
        "bundle" => receipt && receipt["bundle"],
        "files" => row["files"],
        "checkpoints" => row["checkpoints"],
        "answers" => Array(result["answers"][assignment] && result["answers"][assignment]["recorded"])
      }
      File.write(File.join(workspace, Reach::Workspace::MARKER_DIR, IMPORT_FILE), JSON.pretty_generate(record))
    end

    def check_count(workspace)
      owned = Array(Reach::Workspace.owned_files(workspace))
      Array(Reach::Check.run(workspace, format: :agent)).count { |finding| owned.include?(finding[:file].to_s) }
    rescue Reach::Error
      -1
    end

    def qualify_outcome(workspace)
      record = Reach::Qualify.run(workspace)
      return "passed" if record["passed"]
      return "pending" if record["pending"]

      "failed (#{record['findings'].map { |finding| finding['code'] }.uniq.join(', ')})"
    rescue Reach::Error => e
      "refused: #{e.message}"
    end

    def render(result)
      lines = []
      result["slices"].each do |row|
        next unless row["imported"]

        check = row["check"].to_i.negative? ? "not run" : (row["check"].to_i.zero? ? "clean" : "#{row['check']} finding(s)")
        lines << Reach::Messages.text("M-PACKET-SLICE", slice: row["slice"], files: row["files"], checkpoints: row["checkpoints"], check: check, qualify: row["qualify"])
      end
      result["answers"].each do |assignment, info|
        tail = info["skipped"].to_i.positive? ? ", #{info['skipped']} left out" : ""
        lines << Reach::Messages.text("M-PACKET-ANSWERS", count: info["recorded"].length, assignment: assignment, skipped: tail)
      end
      result["receipts"].each_value do |info|
        lines << Reach::Messages.text("M-PACKET-RECEIPT", bundle: info["bundle"]) if info
      end
      result["warnings"].each { |line| lines << line }
      lines << next_line(result)
      lines.join("\n")
    end

    def next_line(result)
      imported = result["slices"].select { |row| row["imported"] }
      return Reach::Messages.text("M-PACKET-NEXT-NONE") if imported.empty?
      return Reach::Messages.text("M-PACKET-NEXT-NOQUALIFY") if imported.any? { |row| row["qualify"] == "skipped" }
      return Reach::Messages.text("M-PACKET-NEXT-SUBMIT") if imported.all? { |row| row["qualify"] == "passed" }

      Reach::Messages.text("M-PACKET-NEXT-QUALIFY")
    end
  end
end
