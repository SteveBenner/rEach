require "json"
require "time"
require "fileutils"
require "digest"

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
        meta = Reach::Workspace.metadata(workspace)
        assignment = meta["assignment"].to_s
        question = questions(assignment).find { |item| item["id"] == question_id.to_s }
        raise Reach::Refused, Reach::Messages.text("M-PART-UNKNOWN", id: question_id) unless question

        entry = latest_prompt(assignment)
        raise Reach::Refused, Reach::Messages.text("M-PART-NO-ANSWER") unless entry

        text = entry["text"]
        words = word_count(text)
        minimum = question["min_words"].to_i
        raise Reach::Refused, Reach::Messages.text("M-PART-TOO-SHORT", words: words, min: minimum) if words < minimum

        answer = {
          "question_id" => question["id"],
          "text" => text,
          "words" => words,
          "digest" => entry["digest"] || Reach::Crypto.digest_hex(text),
          "recorded_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "student_id" => student_id
        }
        state = load_state(assignment, meta["course"])
        state["answers"][question["id"]] = answer
        write_state(assignment, meta["course"], state)
        FileUtils.rm_f(pending_path)
        Reach::Ledger.append(workspace, "part", "question_id" => question["id"], "digest" => answer["digest"])
        answer
      end

      def observe_prompt(space, text)
        return nil unless space.is_a?(Hash) && %w[slice root].include?(space["kind"])
        return nil unless text.is_a?(String) && !text.strip.empty?
        return nil if Reach::Consent.yes?(text) || Reach::Consent.no?(text)

        words = word_count(text)
        return nil if words < smallest_min_words

        meta = space["kind"] == "slice" ? Reach::Workspace.metadata(space["path"]) : {}
        record = {
          "text" => text, "words" => words, "digest" => Digest::SHA256.hexdigest(text),
          "at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "space" => space["kind"],
          "cutout_id" => meta["cutout_id"], "slice" => meta["slice"], "student_id" => student_id
        }
        path = pending_path
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(record)) }
        File.rename(tmp, path)
        record
      rescue StandardError
        nil
      end

      def pending_path
        File.join(Reach::Paths.state_dir, "part", "pending.json")
      end

      def word_count(text)
        text.to_s.split(/\s+/).count { |token| token =~ /[[:alnum:]]/ }
      end

      private

      def student_id
        install = Reach::Enroll.current
        install && install["student_id"]
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
        load_state(assignment_id)["answers"].select { |_, answer| answer.is_a?(Hash) && (answer["student_id"].nil? || answer["student_id"] == current) }
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
        return nil unless entry["student_id"].nil? || entry["student_id"] == student_id
        return nil if Time.now.utc - Time.parse(entry["at"]).utc > WINDOW_S
        return entry if entry["space"] == "root"

        entry["space"] == "slice" && current_cutouts(assignment_id).include?(entry["cutout_id"]) ? entry : nil
      rescue ArgumentError
        nil
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
