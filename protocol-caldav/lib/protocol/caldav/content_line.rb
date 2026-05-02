# frozen_string_literal: true

module Protocol
  module Caldav
    module ContentLine
      module_function

      # Unfold lines per RFC 5545 §3.1: CRLF followed by a single space or tab
      # is removed (the space/tab is part of the folding, not the value).
      # Also normalizes line endings to LF.
      def unfold(text)
        text.gsub("\r\n", "\n").gsub("\r", "\n").gsub(/\n[ \t]/, '')
      end

      # Parse a single content line into [name, params, value].
      # Format: NAME;PARAM1=VAL1;PARAM2="VAL2":value
      # The value is everything after the first unquoted colon.
      def parse_line(line)
        # Find the first colon not inside a quoted parameter value
        in_quotes = false
        colon_idx = nil
        line.each_char.with_index do |ch, i|
          if ch == '"'
            in_quotes = !in_quotes
          elsif ch == ':' && !in_quotes
            colon_idx = i
            break
          end
        end

        return nil unless colon_idx

        left = line[0...colon_idx]
        value = line[(colon_idx + 1)..]

        parts = split_params(left)
        name = parts.shift
        params = {}
        parts.each do |param_str|
          key, val = param_str.split('=', 2)
          next unless key
          val = val[1..-2] if val&.start_with?('"') && val&.end_with?('"')
          params[key.upcase] = val || ''
        end

        [name, params, value]
      end

      # Split the left side of a content line by semicolons,
      # respecting quoted values.
      def split_params(str)
        parts = []
        current = +''
        in_quotes = false

        str.each_char do |ch|
          if ch == '"'
            in_quotes = !in_quotes
            current << ch
          elsif ch == ';' && !in_quotes
            parts << current
            current = +''
          else
            current << ch
          end
        end
        parts << current unless current.empty?
        parts
      end
    end
  end
end
