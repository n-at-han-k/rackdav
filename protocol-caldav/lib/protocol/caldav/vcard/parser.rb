# frozen_string_literal: true

module Protocol
  module Caldav
    module Vcard
      module Parser
        module_function

        def parse(text)
          return nil if text.nil? || text.strip.empty?

          text = text.sub(/\A\xEF\xBB\xBF/, '')

          lines = ContentLine.unfold(text).split("\n").map(&:strip).reject(&:empty?)
          props = []
          inside = false

          lines.each do |line|
            parsed = ContentLine.parse_line(line)
            next unless parsed

            name, params, value = parsed

            if name.casecmp?('BEGIN') && value.strip.casecmp?('VCARD')
              inside = true
            elsif name.casecmp?('END') && value.strip.casecmp?('VCARD')
              break
            elsif inside
              props << Ical::Property.new(name: name, params: params, value: value)
            end
          end

          props.empty? ? nil : Card.new(properties: props)
        end
      end
    end
  end
end
