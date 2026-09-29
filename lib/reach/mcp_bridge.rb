require "json"

module Reach
  module MCPBridge
    TOOLS = [
      {
        "name" => "reach_status",
        "description" => "The student's enrolment, current assignment, slices, package versions and outstanding receipts",
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
        "name" => "reach_tips",
        "description" => "Run the tips suite and return the plain-language results",
        "inputSchema" => {
          "type" => "object",
          "properties" => { "slice" => { "type" => "string", "description" => "The slice folder name; defaults to the current slice" } }
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
        "name" => "reach_enrol",
        "description" => "Enrol with a course using the code the instructor gave the student",
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
      }
    ].freeze

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
        case name
        when "reach_status"
          { "summary" => Reach::Status.summary }
        when "reach_receipts"
          Reach::Receipts.list
        when "reach_shape_check"
          Reach::Shape.check(workspace_path: Dir.pwd, changed: arguments["changed"], format: :agent)
        when "reach_tips"
          Reach::Suite.run(slice: slice_argument(arguments))
        when "reach_submit"
          result = Reach::Submit.submit(slice: slice_argument(arguments))
          result = result.merge("announcement" => Reach::Receipts.announce(result["receipt"])) if result["state"] == "ingested"
          result
        when "reach_raise_hand"
          hand_id = Reach::Hands.raise_hand(
            trigger: arguments.fetch("trigger", "student_request"),
            summary: arguments.fetch("summary"),
            slice: slice_argument(arguments)
          )
          { "hand_id" => hand_id }
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
        when "reach_enrol"
          install = Reach::Enrol.generate_and_register(arguments.fetch("code"), arguments["teach_url"] || Reach::Runtime.default_teach_url)
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
          Reach::Directives.show(arguments.fetch("opcode"), workspace: Reach::Gate.current_workspace_path)
        when "reach_reference"
          reference_tool(arguments)
        else
          raise Reach::Error, "reach: unknown tool #{name.inspect}"
        end
      end

      def current_workspace!
        workspace = Reach::Gate.current_workspace_path
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOGUARD") unless workspace

        workspace
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
