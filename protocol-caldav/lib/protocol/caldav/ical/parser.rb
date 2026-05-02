# frozen_string_literal: true

module Protocol
  module Caldav
    module Ical
      module Parser
        module_function

        def parse(text)
          return nil if text.nil? || text.strip.empty?

          # Strip BOM
          text = text.sub(/\A\xEF\xBB\xBF/, '')

          lines = ContentLine.unfold(text).split("\n").map(&:strip).reject(&:empty?)
          stack = []
          current = nil

          lines.each do |line|
            parsed = ContentLine.parse_line(line)
            next unless parsed

            name, params, value = parsed

            if name.casecmp?('BEGIN')
              comp = Component.new(name: value.strip.upcase)
              if current
                stack.push(current)
              end
              current = comp
            elsif name.casecmp?('END')
              end_name = value.strip.upcase
              raise ParseError, "Mismatched END:#{end_name} (expected END:#{current&.name})" if current.nil? || !current.name.casecmp?(end_name)

              if stack.empty?
                return current
              else
                parent = stack.pop
                parent.components << current
                current = parent
              end
            else
              current&.properties&.push(Property.new(name: name, params: params, value: value))
            end
          end

          raise ParseError, "Unclosed component: #{current&.name}" if current && stack.any?
          current
        end
      end
    end

    class ParseError < StandardError; end
  end
end
