require "json"
require "time"
require "cgi"
require "digest"

module Reach
  module ExportImport
    module Vendors
      KEPT_ROLES = %w[user assistant].freeze
      TEXT_TYPES = ["text", "multimodal_text", nil].freeze
      TITLE_CHARS = 200
      PROMPTED = /\APrompted\s+/.freeze
      ID_CHARS = 100

      module_function

      def clean(value)
        value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
      end

      def stamp(value)
        case value
        when Numeric
          value.positive? ? Time.at(value).utc.strftime("%Y-%m-%dT%H:%M:%SZ") : nil
        when String
          value.strip.empty? ? nil : value.strip
        end
      rescue StandardError
        nil
      end

      def turn(role, text, at)
        body = clean(text).strip
        return nil if body.empty?

        { "role" => role, "text" => body, "at" => stamp(at) }
      end

      def safe_id(value, prefix)
        raw = value.to_s
        cleaned = raw.gsub(/[^A-Za-z0-9._-]/, "-")[0, ID_CHARS]
        return "#{prefix}-#{Digest::SHA256.hexdigest(raw)[0, 16]}" if cleaned.empty? || cleaned != raw || cleaned.start_with?(".")

        cleaned
      end

      def normalize(kind, vendor, data, ordinal)
        return nil unless data.is_a?(Hash)

        conversation = case kind
                       when "memories" then memories(data, ordinal)
                       when "projects" then project(data, ordinal)
                       else
                         case vendor
                         when "chatgpt" then chatgpt(data, ordinal)
                         when "claude" then claude(data, ordinal)
                         when "gemini" then gemini(data)
                         end
                       end
        return nil unless conversation && !conversation["turns"].empty?

        conversation["title"] = clean(conversation["title"]).strip[0, TITLE_CHARS]
        conversation
      end

      def chatgpt_nodes(mapping, current)
        if current && mapping[current].is_a?(Hash)
          chain = []
          seen = {}
          node = current
          while node && mapping[node].is_a?(Hash) && !seen[node]
            seen[node] = true
            chain << mapping[node]
            node = mapping[node]["parent"]
          end
          return chain.reverse
        end
        nodes = mapping.values.select { |node| node.is_a?(Hash) && node["message"].is_a?(Hash) }
        nodes.each_with_index.sort_by { |node, index| [node["message"]["create_time"].to_f, index] }.map(&:first)
      end

      def chatgpt_text(content)
        return "" unless content.is_a?(Hash)
        return "" unless TEXT_TYPES.include?(content["content_type"])

        Array(content["parts"]).select { |part| part.is_a?(String) }.join("\n")
      end

      def chatgpt(data, ordinal)
        mapping = data["mapping"].is_a?(Hash) ? data["mapping"] : {}
        turns = []
        chatgpt_nodes(mapping, data["current_node"]).each do |node|
          message = node["message"]
          next unless message.is_a?(Hash)

          role = message.dig("author", "role").to_s
          next unless KEPT_ROLES.include?(role)
          next if message.dig("metadata", "is_visually_hidden_from_conversation") == true

          item = turn(role, chatgpt_text(message["content"]), message["create_time"])
          turns << item if item
        end
        id = data["conversation_id"] || data["id"]
        {
          "conversation_id" => safe_id(id, "chatgpt"), "vendor" => "chatgpt", "title" => data["title"],
          "created_at" => stamp(data["create_time"]), "updated_at" => stamp(data["update_time"]), "turns" => turns
        }
      end

      def claude_text(message)
        text = message["text"]
        return text if text.is_a?(String) && !text.strip.empty?

        Array(message["content"]).select { |block| block.is_a?(Hash) && block["type"] == "text" && block["text"].is_a?(String) }.map { |block| block["text"] }.join("\n")
      end

      def claude(data, ordinal)
        turns = []
        Array(data["chat_messages"]).each do |message|
          next unless message.is_a?(Hash)

          role = case message["sender"].to_s
                 when "human" then "user"
                 when "assistant" then "assistant"
                 end
          next unless role

          item = turn(role, claude_text(message), message["created_at"])
          turns << item if item
        end
        {
          "conversation_id" => safe_id(data["uuid"], "claude"), "vendor" => "claude", "title" => data["name"],
          "created_at" => stamp(data["created_at"]), "updated_at" => stamp(data["updated_at"]), "turns" => turns
        }
      end

      def memories(data, ordinal)
        turns = []
        item = turn("memory", data["conversations_memory"], nil)
        turns << item if item
        projects = data["project_memories"]
        if projects.is_a?(Hash)
          projects.keys.sort.each do |key|
            item = turn("memory", projects[key], nil)
            turns << item if item
          end
        end
        { "conversation_id" => "memories-#{ordinal}", "vendor" => "claude", "title" => "Claude memory", "created_at" => nil, "updated_at" => nil, "turns" => turns }
      end

      def project(data, ordinal)
        turns = []
        [["project", data["description"]], ["instructions", data["prompt_template"]]].each do |role, text|
          item = turn(role, text, nil)
          turns << item if item
        end
        Array(data["docs"]).each do |doc|
          next unless doc.is_a?(Hash)

          item = turn("document", "#{doc['filename']}\n\n#{doc['content']}", doc["created_at"])
          turns << item if item
        end
        {
          "conversation_id" => safe_id("project-#{data['uuid'] || ordinal}", "project"), "vendor" => "claude", "title" => data["name"],
          "created_at" => stamp(data["created_at"]), "updated_at" => stamp(data["updated_at"]), "turns" => turns
        }
      end

      def html_text(html)
        text = html.to_s.gsub(%r{<br\s*/?>|</p>|</li>|</h\d>|</div>|</tr>}i, "\n").gsub(/<[^>]*>/, "")
        CGI.unescapeHTML(text).gsub(/\n{3,}/, "\n\n")
      end

      def gemini(data)
        prompt = clean(data["title"]).strip
        return nil unless prompt.match?(PROMPTED)

        prompt = prompt.sub(PROMPTED, "")
        reply = Array(data["safeHtmlItem"]).select { |item| item.is_a?(Hash) }.map { |item| html_text(item["html"]) }.join("\n")
        at = data["time"]
        turns = []
        asked = turn("user", prompt, at)
        turns << asked if asked
        answered = turn("assistant", reply, at)
        turns << answered if answered
        line = prompt.lines.first.to_s.strip
        title = line.length > 80 ? "#{line[0, 77].rstrip}..." : line
        {
          "conversation_id" => "gemini-#{Digest::SHA256.hexdigest("#{at}\n#{data['title']}")[0, 16]}", "vendor" => "gemini", "title" => title,
          "created_at" => stamp(at), "updated_at" => stamp(at), "turns" => turns
        }
      end
    end

    module Render
      ROLE_LABELS = { "user" => "Student", "assistant" => "Assistant" }.freeze
      VENDOR_NAMES = { "chatgpt" => "ChatGPT", "claude" => "Claude", "gemini" => "Gemini" }.freeze

      module_function

      def vendor_name(vendor)
        VENDOR_NAMES.fetch(vendor.to_s, vendor.to_s)
      end

      def markdown(conversation)
        title = conversation["title"].to_s.empty? ? "Untitled conversation" : conversation["title"]
        lines = ["# #{title}", ""]
        lines << "- Source: #{vendor_name(conversation['vendor'])} export"
        lines << "- Started: #{conversation['created_at']}" if conversation["created_at"]
        lines << "- Last updated: #{conversation['updated_at']}" if conversation["updated_at"]
        lines << ""
        conversation["turns"].each do |item|
          label = ROLE_LABELS.fetch(item["role"], item["role"].to_s.capitalize)
          lines << (item["at"] ? "## #{label} (#{item['at']})" : "## #{label}")
          lines << ""
          lines << item["text"]
          lines << ""
        end
        lines.join("\n")
      end

      def split(text, limit)
        parts = []
        current = +""
        text.each_line do |line|
          if current.bytesize + line.bytesize > limit && !current.empty?
            parts << current
            current = +""
          end
          while line.bytesize > limit
            cut = limit
            cut -= 1 while cut.positive? && (line.getbyte(cut) & 0xC0) == 0x80
            unless current.empty?
              parts << current
              current = +""
            end
            parts << line.byteslice(0, cut)
            line = line.byteslice(cut, line.bytesize - cut)
          end
          current << line
        end
        parts << current unless current.empty?
        parts
      end

      def part_path(vendor, conversation_id, index, total)
        base = "import/#{vendor}/#{conversation_id}"
        total > 1 ? "#{base}.part#{index + 1}.md" : "#{base}.md"
      end
    end
  end
end
