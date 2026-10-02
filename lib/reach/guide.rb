require "json"
require "cgi"

module Reach
  module Guide
    RELATIVE_PATH = File.join("docs", "INSTALLATION-AND-SETUP-GUIDE.docx").freeze
    DOCUMENT_ENTRY = "word/document.xml".freeze
    MAX_DOCUMENT_BYTES = 8 * 1_048_576
    SCREENSHOT = "[Screenshot]".freeze

    module_function

    def path
      File.join(Reach::Runtime.root, RELATIVE_PATH)
    end

    def run(format: "text", path_only: false)
      file = path
      raise Reach::Error, Reach::Messages.text("M-GUIDE-MISSING", path: file) unless File.file?(file)
      return file if path_only && format.to_s != "json"

      body = text(file)
      return JSON.generate("path" => file, "text" => body) if format.to_s == "json"

      body
    end

    def text(file = path)
      lines(document_xml(file)).join("\n")
    end

    def document_xml(file)
      File.open(file, "rb") do |io|
        entry = Reach::Unzip.central_directory(io).find { |candidate| candidate[:name] == DOCUMENT_ENTRY }
        raise Reach::Error, Reach::Messages.text("M-GUIDE-DAMAGED", path: file) unless entry
        raise Reach::Error, Reach::Messages.text("M-GUIDE-DAMAGED", path: file) if entry[:usize] > MAX_DOCUMENT_BYTES

        buffer = +""
        Reach::Unzip.each_chunk(io, entry) { |piece| buffer << piece }
        buffer.force_encoding("UTF-8")
      end
    end

    def lines(xml)
      body = xml[%r{<w:body>(.*)</w:body>}m, 1] || xml
      flattened = body.gsub(%r{<w:tr[ >].*?</w:tr>}m) do |row|
        cells = row.scan(%r{<w:tc>.*?</w:tc>}m).map do |cell|
          cell.scan(%r{<w:p[ >].*?</w:p>}m).map { |para| paragraph_text(para) }.reject(&:empty?).join(" ")
        end
        "<w:p><w:r><w:t>#{cells.reject(&:empty?).join(' | ')}</w:t></w:r></w:p>"
      end
      flattened.scan(%r{<w:p[ >].*?</w:p>}m).map { |para| paragraph_text(para) }.reject(&:empty?).map { |line| CGI.unescapeHTML(line) }
    end

    def paragraph_text(para)
      parts = []
      para.scan(%r{<w:t(?: [^>]*)?>([^<]*)</w:t>|<w:(tab|br)\b[^>]*/>|<w:(drawing)>}) do |text, mark, drawing|
        if drawing
          parts << SCREENSHOT
        elsif mark
          parts << " "
        else
          parts << text
        end
      end
      parts.join.gsub(/[ \t]+/, " ").strip
    end
  end
end
