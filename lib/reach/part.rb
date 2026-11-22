require "json"
require "time"
require "fileutils"
require "digest"
require "zlib"

module Reach
  module Part
    SCHEMA = "reach.part/v1".freeze
    WINDOW_S = 1800

    class << self
      def questions(assignment_id)
        Reach::Policy.questions(assignment_id.to_s)
      end

      def required?(assignment_id)
        Reach::Policy.student_part["required"] != false && !questions(assignment_id).empty?
      end

      def status(assignment_id)
        answers = stored_answers(assignment_id)
        questions(assignment_id).map do |question|
          answer = answers[question["id"]]
          {
            "id" => question["id"],
            "question" => question["question"],
            "min_words" => question["min_words"].to_i,
            "answered" => !answer.nil?,
            "words" => answer ? answer["words"].to_i : 0,
            "recorded_at" => answer ? answer["recorded_at"] : nil
          }
        end
      end

      def missing(assignment_id)
        answers = stored_answers(assignment_id)
        questions(assignment_id).reject { |question| answers.key?(question["id"]) }
      end

      def document(assignment_id)
        answers = stored_answers(assignment_id)
        ids = questions(assignment_id).map { |question| question["id"] }
        listed = ids.select { |id| answers.key?(id) }.sort.map do |id|
          answers[id].reject { |key, _| key == "student_id" }
        end
        {
          "schema" => SCHEMA,
          "assignment" => assignment_id.to_s,
          "student_id" => student_id,
          "answers" => listed
        }
      end

      def record!(question_id, workspace:)
        Reach::Login.require_active!
        Reach::HookLiveness.require_hooks!
        meta = Reach::Workspace.metadata(workspace)
        assignment = meta["assignment"].to_s
        question = questions(assignment).find { |item| item["id"] == question_id.to_s }
        raise Reach::Refused, Reach::Messages.text("M-PART-UNKNOWN", id: question_id) unless question

        entry = latest_prompt(assignment)
        unless entry
          short = latest_short(assignment)
          raise Reach::Refused, Reach::Messages.text("M-PART-TOO-SHORT", words: short["words"].to_i, min: question["min_words"].to_i) if short

          quiet = Reach::HookLiveness.prompt_hook_quiet?(WINDOW_S)
          raise Reach::Refused, Reach::Messages.text(quiet ? "M-PART-NO-HOOK" : "M-PART-NO-ANSWER")
        end

        answer = build_answer(question, entry, student_id)
        state = load_state(assignment, meta["course"])
        state["answers"][question["id"]] = answer
        write_state(assignment, meta["course"], state)
        FileUtils.rm_f(pending_path)
        FileUtils.rm_f(short_path)
        Reach::Ledger.append(
          workspace, "part",
          "question_id" => question["id"], "digest" => answer["digest"], "seq" => answer["seq"], "session_id" => answer["session_id"]
        )
        answer
      end

      def recoverable(assignment_id)
        assignment = assignment_id.to_s
        found = []
        skipped = []
        return { "assignment" => assignment, "found" => found, "skipped" => skipped } if assignment.empty? || assignment.include?("/") || assignment.include?("..")

        policy = questions(assignment).each_with_object({}) { |question, memo| memo[question["id"]] = question }
        unanswered = status(assignment).reject { |row| row["answered"] }.map { |row| row["id"] }
        me = student_id
        latest_ledger_parts(assignment).each do |question_id, record|
          course = record["course"]
          question = policy[question_id]
          if question.nil?
            skipped << { "question_id" => question_id, "reason" => "no_longer_asked" }
            next
          end
          next unless unanswered.include?(question_id)

          if record["student_id"] != me
            skipped << { "question_id" => question_id, "reason" => "other_student" }
            next
          end
          if record["session_id"].to_s.empty? || record["seq"].nil?
            skipped << { "question_id" => question_id, "reason" => "no_seq" }
            next
          end
          text = transcript_answer(record["session_id"].to_s, record["seq"].to_i, record["digest"].to_s)
          if text.nil?
            skipped << { "question_id" => question_id, "reason" => "no_transcript" }
            next
          end
          words = word_count(text)
          if words < question["min_words"].to_i
            skipped << { "question_id" => question_id, "reason" => "too_short" }
            next
          end
          found << {
            "question_id" => question_id, "question" => question["question"], "text" => text, "words" => words,
            "digest" => record["digest"], "course" => course, "recorded_at" => record["at"]
          }
        end
        { "assignment" => assignment, "found" => found, "skipped" => skipped }
      end

      def recover!(assignment_id, items)
        assignment = assignment_id.to_s
        restored = []
        me = student_id
        stamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        items.each do |item|
          next unless status(assignment).any? { |row| row["id"] == item["question_id"] && !row["answered"] }

          state = load_state(assignment, item["course"])
          state["answers"][item["question_id"]] = {
            "question_id" => item["question_id"], "text" => item["text"], "words" => item["words"],
            "session_id" => nil, "seq" => nil, "digest" => item["digest"], "recorded_at" => item["recorded_at"],
            "student_id" => me, "recovered_at" => stamp
          }
          write_state(assignment, item["course"], state)
          restored << item
        end
        slice = Reach::Workspace.current_slices.find { |path| Reach::Workspace.metadata(path)["assignment"] == assignment }
        if slice
          restored.each do |item|
            Reach::Ledger.append(slice, "part", "question_id" => item["question_id"], "digest" => item["digest"], "seq" => nil, "session_id" => nil, "origin" => "recover")
          end
        end
        restored.map { |item| item["question_id"] }
      end

      def recover_via_consent!(assignment_id)
        assignment = assignment_id.to_s
        found = recoverable(assignment)
        items = found["found"]
        if items.empty?
          return { "state" => "nothing", "relay_verbatim" => true, "text" => Reach::Messages.text("M-PART-RECOVER-NONE") }
        end

        subject = { "assignment" => assignment, "answers" => items.map { |item| [item["question_id"], item["digest"]] } }
        if Reach::Consent.take!(kind: "part_recover", subject: subject)
          restored = recover!(assignment, items)
          names = items.select { |item| restored.include?(item["question_id"]) }.map { |item| item["question"] }
          return { "state" => "restored", "relay_verbatim" => true, "text" => Reach::Messages.text("M-PART-RECOVERED", n: restored.length, questions: names.join("; ")) }
        end

        listed = items.map { |item| "#{item['question']} (\"#{item['text'].split.first(8).join(' ')}\u2026\", #{item['words']} words)" }.join("; ")
        question = Reach::Consent.ask!(kind: "part_recover", subject: subject, message_id: "M-PART-RECOVER-ASK", fields: { n: items.length, answers: listed })
        { "state" => "needs_confirmation", "relay_verbatim" => true, "text" => question, "message" => question }
      end

      def recover_hint(assignment_id)
        return nil if recoverable(assignment_id)["found"].empty?

        Reach::Messages.text("M-PART-RECOVER-HINT")
      rescue StandardError => e
        Reach::Debug.fault(e, "part:recover_hint")
        nil
      end

      def build_answer(question, entry, identity)
        text = entry.fetch("text")
        words = word_count(text)
        minimum = question["min_words"].to_i
        raise Reach::Refused, Reach::Messages.text("M-PART-TOO-SHORT", words: words, min: minimum) if words < minimum

        {
          "question_id" => question["id"],
          "text" => text,
          "words" => words,
          "session_id" => entry["session_id"],
          "seq" => entry["seq"],
          "digest" => entry["digest"] || Reach::Crypto.digest_hex(text),
          "recorded_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "student_id" => identity
        }
      end

      def import!(question_id, text:, recorded_at:, workspace:)
        meta = Reach::Workspace.metadata(workspace)
        assignment = meta["assignment"].to_s
        question = questions(assignment).find { |item| item["id"] == question_id.to_s }
        return nil unless question

        words = word_count(text)
        return nil if words < question["min_words"].to_i

        stamp = begin
          Time.iso8601(recorded_at).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        rescue ArgumentError
          Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        end
        state = load_state(assignment, meta["course"])
        existing = state["answers"][question["id"]]
        return nil if existing.is_a?(Hash) && existing["recorded_at"].to_s > stamp

        answer = {
          "question_id" => question["id"],
          "text" => text,
          "words" => words,
          "session_id" => nil,
          "seq" => nil,
          "digest" => Reach::Crypto.digest_hex(text),
          "recorded_at" => stamp,
          "student_id" => student_id
        }
        state["answers"][question["id"]] = answer
        write_state(assignment, meta["course"], state)
        Reach::Ledger.append(workspace, "part", "question_id" => question["id"], "digest" => answer["digest"], "seq" => nil, "session_id" => nil, "origin" => "sidecar")
        answer
      end

      def observe_prompt(space, text, recorded = nil)
        return nil unless space.is_a?(Hash) && %w[slice root].include?(space["kind"])
        return nil unless text.is_a?(String) && !text.strip.empty?
        return nil if Reach::Consent.yes?(text) || Reach::Consent.no?(text)

        words = word_count(text)
        meta = space["kind"] == "slice" ? Reach::Workspace.metadata(space["path"]) : {}
        stamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        if words < smallest_min_words
          write_private(short_path, "words" => words, "at" => stamp, "space" => space["kind"], "cutout_id" => meta["cutout_id"], "student_id" => student_id)
          return nil
        end

        record = {
          "text" => text, "words" => words, "digest" => (recorded && recorded["digest"]) || Digest::SHA256.hexdigest(text),
          "session_id" => recorded && recorded["session_id"], "seq" => recorded && recorded["seq"],
          "at" => stamp, "space" => space["kind"],
          "cutout_id" => meta["cutout_id"], "slice" => meta["slice"], "student_id" => student_id
        }
        write_private(pending_path, record)
        record
      end

      def write_private(path, record)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(record)) }
        File.rename(tmp, path)
      end

      def pending_path
        File.join(Reach::Paths.state_dir, "part", "pending.json")
      end

      def short_path
        File.join(Reach::Paths.state_dir, "part", "short.json")
      end

      def word_count(text)
        text.to_s.split(/\s+/).count { |token| token =~ /[[:alnum:]]/ }
      end

      private

      def student_id
        install = Reach::Enroll.current
        install && install["student_id"]
      end

      def latest_ledger_parts(assignment)
        latest = {}
        Dir.glob(File.join(Reach::Paths.ledger_dir, "*", assignment, "*.jsonl")).sort.each do |file|
          course = File.basename(File.dirname(File.dirname(file)))
          File.foreach(file) do |line|
            record = begin
              JSON.parse(line)
            rescue JSON::ParserError
              nil
            end
            next unless record.is_a?(Hash) && record["kind"] == "part" && record["question_id"].is_a?(String)
            next if record["origin"] == "recover"

            held = latest[record["question_id"]]
            key = [record["n"].to_i, record["at"].to_s]
            latest[record["question_id"]] = record.merge("course" => course) if held.nil? || (key <=> [held["n"].to_i, held["at"].to_s]) >= 0
          end
        rescue SystemCallError
          next
        end
        latest
      end

      def spool_entries(session_id)
        return [] if session_id.empty? || session_id =~ %r{[/\\\0]} || session_id.include?("..")

        files = [Reach::Transcript.entries_path(session_id)]
        files += Dir.glob(File.join(Reach::Paths.transcripts_archive_dir, "#{session_id}.jsonl.gz"))
        files += Dir.glob(File.join(Reach::Paths.transcripts_archive_dir, "#{session_id}-*.jsonl.gz")).select { |path| File.basename(path) =~ /\A#{Regexp.escape(session_id)}-\d+\.jsonl\.gz\z/ }
        files.uniq.flat_map do |file|
          next [] unless File.file?(file)

          lines = file.end_with?(".gz") ? Zlib::GzipReader.open(file, &:read).to_s.force_encoding("UTF-8").scrub.lines : File.readlines(file, chomp: false)
          lines.filter_map do |line|
            entry = JSON.parse(line)
            entry.is_a?(Hash) ? entry : nil
          rescue JSON::ParserError
            nil
          end
        rescue SystemCallError, Zlib::Error, IOError
          []
        end
      end

      def usable_prompt?(entry)
        entry["kind"] == "prompt" && entry["withheld"] != true && entry["text"].is_a?(String) && !entry["text"].empty?
      end

      def transcript_answer(session_id, seq, digest)
        prompts = spool_entries(session_id).select { |entry| usable_prompt?(entry) }
        first = prompts.find do |entry|
          next false unless entry["seq"] == seq

          entry["digest"] == digest || Reach::Crypto.digest_hex(entry["text"]) == digest || entry["whole_digest"] == digest
        end
        return nil unless first
        return first["text"] unless first["part"].is_a?(Array)

        total = first["part"][1].to_i
        return nil unless first["part"][0].to_i == 1 && total > 1

        pieces = (1..total).map do |index|
          prompts.find { |entry| entry["seq"] == seq + index - 1 && entry["part"] == [index, total] }
        end
        return nil if pieces.any?(&:nil?)

        pieces.map { |entry| entry["text"] }.join
      end

      def course_id(assignment_id, hint = nil)
        return hint if hint

        slice = Reach::Workspace.current_slices.find { |path| Reach::Workspace.metadata(path)["assignment"] == assignment_id.to_s }
        course = slice && Reach::Workspace.metadata(slice)["course"]
        return course if course

        install = Reach::Enroll.current
        install && install["course"].is_a?(Hash) ? install["course"]["id"] : nil
      rescue StandardError
        nil
      end

      def state_path(assignment_id, course)
        name = "#{course_id(assignment_id, course)}-#{assignment_id}".gsub(/[^A-Za-z0-9._-]/, "_")
        File.join(Reach::Paths.state_dir, "part", "#{name}.json")
      end

      def load_state(assignment_id, course = nil)
        path = state_path(assignment_id, course)
        parsed = File.file?(path) ? JSON.parse(File.read(path)) : nil
        parsed = nil unless parsed.is_a?(Hash) && parsed["answers"].is_a?(Hash)
        parsed || {
          "schema" => SCHEMA,
          "course" => course_id(assignment_id, course),
          "assignment" => assignment_id.to_s,
          "student_id" => student_id,
          "answers" => {}
        }
      rescue JSON::ParserError
        { "schema" => SCHEMA, "course" => course_id(assignment_id, course), "assignment" => assignment_id.to_s, "student_id" => student_id, "answers" => {} }
      end

      def stored_answers(assignment_id)
        current = student_id
        ([nil] + course_keys(assignment_id)).each_with_object({}) do |course, merged|
          load_state(assignment_id, course)["answers"].each do |id, answer|
            next if merged.key?(id)
            next unless answer.is_a?(Hash) && (answer["student_id"].nil? || answer["student_id"] == current)

            merged[id] = answer
          end
        end
      end

      def course_keys(assignment_id)
        slices = Reach::Workspace.current_slices.select { |path| Reach::Workspace.metadata(path)["assignment"] == assignment_id.to_s }
        keys = slices.map { |path| Reach::Workspace.metadata(path)["course"] }
        install = Reach::Enroll.current
        keys << install["course"]["id"] if install && install["course"].is_a?(Hash)
        keys += stored_courses(assignment_id)
        keys.compact.map(&:to_s).reject(&:empty?).uniq
      rescue StandardError => e
        Reach::Debug.fault(e, "part:course_keys")
        []
      end

      def stored_courses(assignment_id)
        suffix = "-#{assignment_id}".gsub(/[^A-Za-z0-9._-]/, "_")
        Dir.glob(File.join(Reach::Paths.state_dir, "part", "*#{suffix}.json")).sort.filter_map do |path|
          parsed = JSON.parse(File.read(path))
          parsed["course"] if parsed.is_a?(Hash) && parsed["assignment"] == assignment_id.to_s && state_path(assignment_id, parsed["course"]) == path
        rescue JSON::ParserError, SystemCallError
          nil
        end
      end

      def write_state(assignment_id, course, state)
        path = state_path(assignment_id, course)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(state)) }
        File.rename(tmp, path)
        state
      end

      def smallest_min_words
        all = (Reach::Policy.student_part || {})["questions"]
        mins = all.is_a?(Hash) ? all.values.flat_map { |list| Array(list) }.select { |item| item.is_a?(Hash) }.map { |item| item["min_words"].to_i } : []
        [mins.min.to_i, 1].max
      rescue StandardError
        1
      end

      def latest_prompt(assignment_id)
        entry = begin
          JSON.parse(File.read(pending_path))
        rescue StandardError
          nil
        end
        return nil unless entry.is_a?(Hash) && entry["text"].is_a?(String) && entry["at"].is_a?(String)

        current_entry?(entry, assignment_id) ? entry : nil
      rescue ArgumentError
        nil
      end

      def latest_short(assignment_id)
        entry = JSON.parse(File.read(short_path))
        entry.is_a?(Hash) && entry["at"].is_a?(String) && current_entry?(entry, assignment_id) ? entry : nil
      rescue SystemCallError, JSON::ParserError, ArgumentError
        nil
      end

      def current_entry?(entry, assignment_id)
        return false unless entry["student_id"].nil? || entry["student_id"] == student_id
        return false if Time.now.utc - Time.parse(entry["at"]).utc > WINDOW_S
        return true if entry["space"] == "root"

        entry["space"] == "slice" && current_cutouts(assignment_id).include?(entry["cutout_id"])
      end

      def current_cutouts(assignment_id)
        status = Reach::Sync.cached_status || {}
        from_status = Array(status["slices"]).select { |slice| slice["assignment"].to_s == assignment_id.to_s }.map { |slice| slice["cutout_id"] }
        from_disk = Reach::Workspace.current_slices.select do |path|
          Reach::Workspace.metadata(path)["assignment"].to_s == assignment_id.to_s
        end.map { |path| Reach::Workspace.metadata(path)["cutout_id"] }
        (from_status + from_disk).compact.uniq
      rescue StandardError
        []
      end
    end
  end
end
