module Reach
  module JsonStream
    CHUNK_BYTES = 1_048_576
    STRING_STOP = /["\\]/n.freeze
    STRUCTURAL = /["\[\]{}]/n.freeze
    BACKSLASH = 0x5C
    QUOTE = 0x22
    OPEN_BRACE = 0x7B
    CLOSE_BRACE = 0x7D
    OPEN_BRACKET = 0x5B
    CLOSE_BRACKET = 0x5D

    module_function

    def each_element(io, skip: 0, chunk_bytes: CHUNK_BYTES, &block)
      return enum_for(:each_element, io, skip: skip, chunk_bytes: chunk_bytes) unless block

      parser = Parser.new(skip: skip)
      buffer = +""
      while io.read(chunk_bytes, buffer)
        parser.feed(buffer, &block)
        break if parser.finished?
      end
      parser.elements
    end

    class Parser
      attr_reader :elements, :position, :last_end

      def initialize(skip: 0)
        @skip = skip
        @elements = 0
        @position = 0
        @started = false
        @finished = false
        @depth = 0
        @in_string = false
        @escaped = false
        @string_element = false
        @collecting = false
        @active = false
        @buffer = nil
        @start = 0
        @last_end = 0
      end

      def finished?
        @finished
      end

      def feed(chunk)
        data = chunk.force_encoding(Encoding::BINARY)
        size = data.bytesize
        base = @position
        @position += size
        index = 0
        mark = 0
        while index < size && !@finished
          if @escaped
            @escaped = false
            index += 1
            next
          end

          if @in_string
            found = data.index(STRING_STOP, index)
            break unless found

            if data.getbyte(found) == BACKSLASH
              if found + 1 >= size
                @escaped = true
                index = size
              else
                index = found + 2
              end
            else
              @in_string = false
              index = found + 1
              if @string_element
                @string_element = false
                finish_element(data, mark, index, base) { |text, offset| yield text, offset }
                mark = index
              end
            end
            next
          end

          found = data.index(STRUCTURAL, index)
          break unless found

          byte = data.getbyte(found)
          index = found + 1
          case byte
          when QUOTE
            if @started && @depth.zero?
              begin_element(found, base)
              mark = found
              @string_element = true
            end
            @in_string = true
          when OPEN_BRACE, OPEN_BRACKET
            if !@started
              @started = true if byte == OPEN_BRACKET
            elsif @depth.zero?
              begin_element(found, base)
              mark = found
              @depth = 1
            else
              @depth += 1
            end
          when CLOSE_BRACE, CLOSE_BRACKET
            if @depth.positive?
              @depth -= 1
              if @depth.zero?
                finish_element(data, mark, index, base) { |text, offset| yield text, offset }
                mark = index
              end
            elsif byte == CLOSE_BRACKET && @started
              @finished = true
            end
          end
        end
        @buffer << data.byteslice(mark, size - mark) if @active && @collecting && size > mark
        self
      end

      private

      def begin_element(found, base)
        @active = true
        @collecting = @elements >= @skip
        @start = base + found
        @buffer = +"".b if @collecting
      end

      def finish_element(data, mark, stop, base)
        @last_end = base + stop
        @buffer << data.byteslice(mark, stop - mark) if @collecting
        text = @collecting ? @buffer.force_encoding(Encoding::UTF_8) : nil
        @elements += 1
        @active = false
        collecting = @collecting
        @collecting = false
        @buffer = nil
        yield text, @start if collecting
      end
    end
  end
end
