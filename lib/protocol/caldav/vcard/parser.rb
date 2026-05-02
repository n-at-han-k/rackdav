# frozen_string_literal: true

require "bundler/setup"
require "scampi"

require "protocol/caldav"

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


test do
  describe "Protocol::Caldav::Vcard::Parser" do
    def parse(text)
      Protocol::Caldav::Vcard::Parser.parse(text)
    end

    it "parses a flat BEGIN:VCARD / END:VCARD" do
      card = parse("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:John\r\nEND:VCARD")
      card.should.not.be.nil
      card.find_property("FN").value.should.equal "John"
    end

    it "handles VERSION:3.0 and VERSION:4.0 without distinction" do
      card3 = parse("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:A\r\nEND:VCARD")
      card4 = parse("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:A\r\nEND:VCARD")
      card3.find_property("VERSION").value.should.equal "3.0"
      card4.find_property("VERSION").value.should.equal "4.0"
    end

    it "handles structured values in N property as raw string" do
      card = parse("BEGIN:VCARD\r\nN:Doe;John;;;Jr.\r\nEND:VCARD")
      card.find_property("N").value.should.equal "Doe;John;;;Jr."
    end

    it "returns nil for empty input" do
      parse("").should.be.nil
    end

    it "returns nil for nil input" do
      parse(nil).should.be.nil
    end

    it "tolerates LF-only line endings" do
      card = parse("BEGIN:VCARD\nFN:Test\nEND:VCARD")
      card.find_property("FN").value.should.equal "Test"
    end

    it "tolerates BOM" do
      card = parse("\xEF\xBB\xBFBEGIN:VCARD\r\nFN:Test\r\nEND:VCARD")
      card.should.not.be.nil
    end
  end
end
