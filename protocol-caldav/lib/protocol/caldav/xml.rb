# frozen_string_literal: true

module Protocol
  module Caldav
    module Xml
      module_function

      def escape(str)
        return '' unless str

        str.to_s
           .gsub('&', '&amp;')
           .gsub('<', '&lt;')
           .gsub('>', '&gt;')
           .gsub('"', '&quot;')
      end

      def extract_value(xml, tag)
        return nil if xml.nil? || xml.empty?

        match = xml.match(/<[^>]*#{Regexp.escape(tag)}[^>]*>([^<]*)</)
        return nil unless match

        value = match[1].strip
        value.empty? ? nil : value
      end

      def extract_attr(xml, tag, attr)
        return nil if xml.nil? || xml.empty?

        match = xml.match(/<[^>]*#{Regexp.escape(tag)}[^>]*#{Regexp.escape(attr)}="([^"]*)"/)
        match ? match[1] : nil
      end
    end
  end
end
