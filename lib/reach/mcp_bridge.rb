require "json"
require "stringio"

module Reach
  module MCPBridge
    TOOLS = [
      {
        "name" => "reach_status",
        "description" => "The student's enrollment, current assignment, slices, package versions and outstanding receipts",
        "inputSchema" => { "type" => "object", "properties" => {} }
      },
      {
        "name" => "reach_receipts",
        "description" => "Receipts newest first",
        "inputSchema" => { "type" => "object", "properties" => {} }
      },
      {
        "name" => "reach_shape_check",
        "description" => "Shape findings for the current slice, classified invisible or visible",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "changed" => { "type" => "string" } }
        }
      },
      {
        "name" => "reach_qualify",
        "description" => "Prove the slice before submitting: reach check, coverage of every graded scenario name, the agent's own scenarios locally where they can run, then the course server's qualification run; returns the record and the attempt ladder's next rung",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "slice" => { "type" => "string", "description" => "The slice folder name; defaults to the current slice" },
            "local_only" => { "type" => "boolean", "description" => "Run only the local steps; never counts as an attempt" },
            "task" => { "type" => "string", "description" => "One line: what you were attempting, kept for a hand" },
            "summary" => { "type" => "string", "description" => "What failed last time and what you changed, kept for a hand" }
          }
        }
      },
      {
        "name" => "reach_attempts",
        "description" => "The slice's attempt ladder (action show), or record the student's yes to keep trying after a hand (action continue; refused unless the student has written since the hand)",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[show continue] },
            "slice" => { "type" => "string" }
          },
          "required" => ["action"]
        }
      },
      {
        "name" => "reach_submit",
        "description" => "Submit the current slice and wait for the ingest receipt",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "slice" => { "type" => "string", "description" => "The slice folder name; defaults to the current slice" } }
        }
      },
      {
        "name" => "reach_raise_hand",
        "description" => "Raise a hand with a summary",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "summary" => { "type" => "string" },
            "trigger" => { "type" => "string" },
            "slice" => { "type" => "string" }
          },
          "required" => ["summary"]
        }
      },
      {
        "name" => "reach_hand_status",
        "description" => "A hand's state and reply",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "hand_id" => { "type" => "string" } },
          "required" => ["hand_id"]
        }
      },
      {
        "name" => "reach_hello",
        "description" => "The session-start greeting and context for rEach",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "harness" => { "type" => "string" } }
        }
      },
      {
        "name" => "reach_profile_show",
        "description" => "The student's saved interview answers",
        "inputSchema" => { "type" => "object", "properties" => {} }
      },
      {
        "name" => "reach_profile_save",
        "description" => "Save the student's interview answers",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "fields" => { "type" => "object" },
            "status" => { "type" => "string" }
          },
          "required" => ["fields", "status"]
        }
      },
      {
        "name" => "reach_profile_forget",
        "description" => "Delete the student's saved interview answers",
        "inputSchema" => { "type" => "object", "properties" => {} }
      },
      {
        "name" => "reach_enroll",
        "description" => "Enroll in a course using the code the instructor gave the student",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "code" => { "type" => "string" },
            "teach_url" => { "type" => "string" }
          },
          "required" => ["code"]
        }
      },
      {
        "name" => "reach_sync",
        "description" => "Fetch new packages and refresh workspaces",
        "inputSchema" => { "type" => "object", "properties" => {} }
      },
      {
        "name" => "reach_check",
        "description" => "Check the slice's code against the course and engineering rules; returns findings with ids, files, lines and fixes",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "changed" => { "type" => "string" } }
        }
      },
      {
        "name" => "reach_checkpoint",
        "description" => "Save, list, show or restore a snapshot of the slice's files",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[save list show restore] },
            "note" => { "type" => "string" },
            "n" => { "type" => "integer" }
          },
          "required" => ["action"]
        }
      },
      {
        "name" => "reach_plan",
        "description" => "Save, update or show the slice plan",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[save note show] },
            "fields" => { "type" => "object" }
          },
          "required" => ["action"]
        }
      },
      {
        "name" => "reach_directive",
        "description" => "The full text of a directive from the workspace's AGENTS.md table",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "opcode" => { "type" => "string" } },
          "required" => ["opcode"]
        }
      },
      {
        "name" => "reach_reference",
        "description" => "Read the course reference material: list its files, show one, search it, or list its links",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[list show search links] },
            "path" => { "type" => "string" },
            "terms" => { "type" => "string", "description" => "Words that must all appear, for search" }
          },
          "required" => ["action"]
        }
      },
      {
        "name" => "reach_support",
        "description" => "The fixed crisis message (911, 988, the course's support line) to give the student word for word; raises the wellbeing hand like reach support",
        "inputSchema" => { "type" => "object", "properties" => {} }
      },
      {
        "name" => "reach_part",
        "description" => "List the student's own-part questions with answered flags, or record one from the student's latest typed prompt (never from text you supply)",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "record" => { "type" => "string", "description" => "A question id to record from the student's latest captured prompt" } }
        }
      },
      {
        "name" => "reach_transfer_request",
        "description" => "Ask Reach to request a module move; returns Reach's own question to give the student word for word until the student's captured yes, then sends the request to Teach",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "modules" => { "type" => "array", "items" => { "type" => "string" }, "minItems" => 2, "maxItems" => 2 },
            "note" => { "type" => "string" }
          },
          "required" => ["modules"]
        }
      },
      {
        "name" => "reach_modules",
        "description" => "Show the student's modules or options, or choose them; returns Reach's lock-in question to give the student word for word until the student's captured yes",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "choose" => { "type" => "array", "items" => { "type" => "string" } } }
        }
      },
      {
        "name" => "reach_remember",
        "description" => "Keep one durable thing you learned about the student or their work: a preference, goal, decision, struggle, skill, project, fact or your own considered thought. Quote or cite the student in evidence. Pass supersedes (a finding id) when something changed",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "category" => { "type" => "string", "enum" => Reach::Brain::CATEGORIES },
            "claim" => { "type" => "string" },
            "evidence" => { "type" => "string" },
            "supersedes" => { "type" => "string" }
          },
          "required" => %w[category claim evidence]
        }
      },
      {
        "name" => "reach_recall",
        "description" => "What rEach remembers about the student: the profile when query is absent, or the memories matching query",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "query" => { "type" => "string" }, "k" => { "type" => "integer" } }
        }
      },
      {
        "name" => "reach_memory_forget",
        "description" => "Forget remembered findings by id, or everything with all true (only after the student confirms)",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "ids" => { "type" => "array", "items" => { "type" => "string" } }, "all" => { "type" => "boolean" } }
        }
      },
      {
        "name" => "reach_next",
        "description" => "The deterministic next step for the student, in business terms",
        "inputSchema" => { "type" => "object", "properties" => {} }
      }
    ].freeze

    UNLOCKED_TOOLS = %w[reach_hello reach_support].freeze

    class << self
      PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze

      def serve(input: STDIN, output: STDOUT)
        input.binmode if input.respond_to?(:binmode)
        output.binmode if output.respond_to?(:binmode)
        loop do
          line = input.gets
          break if line.nil?

          text = line.strip
          next if text.empty?

          framed = false
          if (framing = text.match(/\AContent-Length:\s*(\d+)\z/i))
            loop do
              header = input.gets
              break if header.nil? || header.strip.empty?
            end
            text = input.read(framing[1].to_i).to_s
            framed = true
          end

          message = begin
            JSON.parse(text)
          rescue JSON::ParserError
            write_message(output, error(nil, -32700, "reach: parse error"), framed)
            next
          end
          unless message.is_a?(Hash)
            write_message(output, error(nil, -32600, "reach: invalid request"), framed)
            next
          end

          response = handle(message)
          write_message(output, response, framed) if response
        end
      end

      private

      def write_message(io, message, framed)
        body = JSON.generate(message)
        io.write(framed ? "Content-Length: #{body.bytesize}\r\n\r\n#{body}" : "#{body}\n")
        io.flush
      end

      def negotiated_version(params)
        requested = params["protocolVersion"].to_s
        PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first
      end

      def handle(message)
        id = message["id"]
        method_name = message["method"]
        params = message["params"] || {}

        case method_name
        when "initialize"
          result(id, {
            "protocolVersion" => negotiated_version(params),
            "capabilities" => { "tools" => {} },
            "serverInfo" => { "name" => "reach", "version" => Reach::VERSION }
          })
        when "notifications/initialized"
          nil
        when "tools/list"
          result(id, { "tools" => TOOLS })
        when "tools/call"
          call_tool(id, params)
        when "shutdown"
          result(id, {})
        else
          return nil if id.nil?

          error(id, -32601, "reach: unknown method #{method_name.inspect}")
        end
      end

      def call_tool(id, params)
        name = params["name"]
        arguments = params["arguments"] || {}
        payload = dispatch(name, arguments)
        result(id, { "content" => [{ "type" => "text", "text" => JSON.generate(payload) }] })
      rescue Reach::Error => e
        error(id, -32000, e.message)
      rescue StandardError => e
        error(id, -32000, "reach: #{e.class}: #{e.message}")
      end

      def dispatch(name, arguments)
        lock = UNLOCKED_TOOLS.include?(name) ? nil : Reach::EnrollmentLock.state
        if lock && lock["locked"]
          raise Reach::Refused, Reach::Messages.text(%w[reach_enroll reach_enrol].include?(name) ? "M-GATE-NOENROLL" : lock["message_id"])
        end

        case name
        when "reach_status"
          { "summary" => Reach::Status.summary }
        when "reach_receipts"
          Reach::Receipts.list
        when "reach_shape_check"
          Reach::Shape.check(workspace_path: shape_workspace, changed: arguments["changed"], format: :agent)
        when "reach_qualify"
          workspace = workspace_for(slice_argument(arguments))
          Reach::Qualify.run(workspace, local_only: arguments["local_only"] == true, task: arguments["task"], agent_summary: arguments["summary"])
        when "reach_attempts"
          workspace = workspace_for(slice_argument(arguments))
          arguments["action"] == "continue" ? { "message" => Reach::Attempts.continue(workspace) } : Reach::Attempts.show(workspace)
        when "reach_submit"
          result = Reach::Submit.submit(slice: slice_argument(arguments))
          result = result.merge("announcement" => Reach::Receipts.announce(result["receipt"])) if result["state"] == "ingested"
          result
        when "reach_raise_hand"
          record = Reach::Hands.raise_record(
            trigger: arguments.fetch("trigger", "student_request"),
            summary: arguments.fetch("summary"),
            slice: slice_argument(arguments)
          )
          if record["refused"]
            raise Reach::Refused, Reach::Messages.text("M-HAND-REFUSED", reason: record["refused"]["message"])
          end

          result = { "hand_id" => record["hand_id"], "queued" => record["queued"] == true }
          result = result.merge("text" => Reach::Messages.text("M-HAND-QUEUED"), "relay_verbatim" => true) if result["queued"]
          result
        when "reach_hand_status"
          Reach::Hands.status(arguments.fetch("hand_id"))
        when "reach_hello"
          JSON.parse(Reach::Hello.run(harness: arguments["harness"], format: "json"))
        when "reach_profile_show"
          Reach::Profile.load
        when "reach_profile_save"
          Reach::Profile.save(fields: arguments.fetch("fields"), status: arguments.fetch("status"))
        when "reach_profile_forget"
          { "forgotten" => Reach::Profile.forget! }
        when "reach_enroll", "reach_enrol"
          install = Reach::Enroll.generate_and_register(arguments.fetch("code"), arguments["teach_url"] || Reach::Runtime.default_teach_url)
          { "install" => install, "sync" => Reach::Sync.run }
        when "reach_sync"
          Reach::Sync.run
        when "reach_check"
          Reach::Check.run(current_workspace!, changed: arguments["changed"], format: :agent)
        when "reach_checkpoint"
          checkpoint_tool(current_workspace!, arguments)
        when "reach_plan"
          plan_tool(current_workspace!, arguments)
        when "reach_directive"
          Reach::Directives.show(arguments.fetch("opcode"), workspace: Reach::Gate.focus_workspace)
        when "reach_reference"
          reference_tool(arguments)
        when "reach_support"
          { "text" => capture_stdout { Reach::Support.run! }.to_s.strip, "relay_verbatim" => true }
        when "reach_part"
          part_tool(arguments)
        when "reach_transfer_request"
          modules = Array(arguments["modules"]).map { |item| item.to_s.strip }.reject(&:empty?)
          raise Reach::Refused, "reach: reach_transfer_request needs the two module ids in modules" if modules.empty?

          choice_payload(Reach::Transfer.request!(modules: modules, note: arguments["note"]))
        when "reach_modules"
          chosen = Array(arguments["choose"]).map { |item| item.to_s.strip }.reject(&:empty?)
          chosen.empty? ? { "text" => Reach::Modules.summary_text, "relay_verbatim" => true } : choice_payload(Reach::Modules.choose!(chosen))
        when "reach_remember"
          result = Reach::Brain.remember(
            category: arguments.fetch("category"), claim: arguments.fetch("claim"), evidence: arguments.fetch("evidence"),
            supersedes: arguments["supersedes"]
          )
          result.merge("message" => Reach::Brain.outcome_message(result))
        when "reach_recall"
          recall_tool(arguments)
        when "reach_memory_forget"
          forget_tool(arguments)
        when "reach_next"
          step = Reach::Next.compute
          step.merge("relay_verbatim" => true)
        else
          raise Reach::Error, "reach: unknown tool #{name.inspect}"
        end
      end

      def recall_tool(arguments)
        query = arguments["query"].to_s
        if query.strip.empty?
          block = Reach::Brain.profile_block
          return { "text" => block || Reach::Messages.text("M-BRAIN-EMPTY"), "hits" => 0 }
        end

        found = Reach::Brain.recall(query: query, k: arguments["k"])
        found ? { "text" => found["text"], "hits" => found["hits"] } : { "text" => Reach::Messages.text("M-BRAIN-NO-MATCH"), "hits" => 0 }
      end

      def forget_tool(arguments)
        everything = arguments["all"] == true
        ids = Array(arguments["ids"]).map(&:to_s).reject(&:empty?)
        raise Reach::Refused, Reach::Messages.text("M-BRAIN-FORGET-WHAT") if !everything && ids.empty?

        count = Reach::Brain.forget(ids: ids, all: everything)
        { "forgotten" => count, "message" => Reach::Messages.text("M-BRAIN-FORGOTTEN", count: count) }
      end

      def capture_stdout
        original = $stdout
        buffer = StringIO.new
        $stdout = buffer
        yield
        buffer.string
      ensure
        $stdout = original
      end

      def choice_payload(result)
        result.merge("relay_verbatim" => true)
      end

      def part_tool(arguments)
        question_id = arguments["record"].to_s
        unless question_id.empty?
          workspace = current_workspace!
          answer = Reach::Part.record!(question_id, workspace: workspace)
          question = Reach::Part.questions(Reach::Workspace.metadata(workspace)["assignment"]).find { |item| item["id"] == answer["question_id"] }
          return { "text" => Reach::Messages.text("M-PART-RECORDED", question: question ? question["question"] : answer["question_id"]), "relay_verbatim" => true }
        end

        workspace = Reach::Gate.focus_workspace
        assignment = workspace ? Reach::Workspace.metadata(workspace)["assignment"] : nil
        status = Reach::Sync.cached_status || {}
        assignment ||= status["current_assignment"].is_a?(Hash) ? status["current_assignment"]["id"] : nil
        rows = assignment ? Reach::Part.status(assignment) : []
        answers = assignment ? Reach::Part.document(assignment)["answers"] : []
        questions = rows.map do |row|
          answer = answers.find { |item| item["question_id"] == row["id"] }
          row.merge("text" => answer && answer["text"])
        end
        payload = { "assignment" => assignment, "questions" => questions }
        payload["text"] = Reach::Messages.text("M-PART-LIST-EMPTY") if rows.empty?
        payload
      end

      def workspace_for(slice)
        workspace = Reach::Workspace.current_slices.find { |path| File.basename(path) == slice.to_s }
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOGUARD") unless workspace

        workspace
      end

      def current_workspace!
        workspace = Reach::Gate.focus_workspace
        ensure_slice_choice!(workspace)
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOGUARD") unless workspace

        workspace
      end

      def ensure_slice_choice!(workspace)
        return if workspace
        return unless Reach::Gate.root_kind? && Reach::Workspace.current_slices.length > 1

        raise Reach::Refused, Reach::Gate.pick_slice_text
      end

      def shape_workspace
        return Dir.pwd unless Reach::Gate.root_kind?

        workspace = Reach::Gate.focus_workspace
        ensure_slice_choice!(workspace)
        workspace || Dir.pwd
      end

      def reference_tool(arguments)
        case arguments.fetch("action")
        when "list" then { "files" => Reach::Reference.list }
        when "show" then { "text" => Reach::Reference.show(arguments.fetch("path")) }
        when "search" then { "results" => Reach::Reference.search(arguments.fetch("terms").to_s.split) }
        when "links" then { "links" => Reach::Reference.links }
        else raise Reach::Error, "reach: unknown reference action"
        end
      end

      def checkpoint_tool(workspace, arguments)
        case arguments.fetch("action")
        when "save" then Reach::Checkpoint.save(workspace, note: arguments["note"])
        when "list" then Reach::Checkpoint.list(workspace)
        when "show" then Reach::Checkpoint.show(workspace, arguments.fetch("n"))
        when "restore" then Reach::Checkpoint.restore(workspace, arguments.fetch("n"))
        else raise Reach::Error, "reach: unknown checkpoint action"
        end
      end

      def plan_tool(workspace, arguments)
        case arguments.fetch("action")
        when "save", "note"
          Reach::Plan.save(workspace, arguments["fields"] || {})
        when "show"
          Reach::Plan.load(workspace) || {}
        else
          raise Reach::Error, "reach: unknown plan action"
        end
      end

      def slice_argument(arguments)
        given = arguments["slice"].to_s
        return given unless given.empty?

        slices = Reach::Workspace.current_slices
        cwd = File.realpath(Dir.pwd)
        here = slices.find do |workspace|
          real_workspace = File.realpath(workspace)
          cwd == real_workspace || cwd.start_with?(real_workspace + File::SEPARATOR)
        end
        here ||= slices.first if slices.size == 1
        ensure_slice_choice!(here)
        raise Reach::Refused, "reach: more than one slice is open; pass slice (for example #{File.basename(slices.first)})" if here.nil? && slices.size > 1
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOGUARD") if here.nil?

        File.basename(here)
      end

      def result(id, value)
        { "jsonrpc" => "2.0", "id" => id, "result" => value }
      end

      def error(id, code, message)
        { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
      end
    end
  end
end
