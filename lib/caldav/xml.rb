# frozen_string_literal: true

require "bundler/setup"
require "caldav"

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
      match ? match[1] : nil
    end
  end
end
