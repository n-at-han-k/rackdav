# frozen_string_literal: true

require "bundler/setup"
require "scampi"

require "protocol/caldav"

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


test do
  describe "Protocol::Caldav::Ical::Parser" do
    def parse(text)
      Protocol::Caldav::Ical::Parser.parse(text)
    end

    describe "line unfolding" do
      it "unfolds CRLF SPACE continuations" do
        ical = "BEGIN:VCALENDAR\r\nSUMMARY:Annual\r\n planning\r\nEND:VCALENDAR"
        c = parse(ical)
        c.find_property("SUMMARY").value.should.equal "Annualplanning"
      end

      it "unfolds CRLF TAB continuations" do
        ical = "BEGIN:VCALENDAR\r\nSUMMARY:Annual\r\n\tplanning\r\nEND:VCALENDAR"
        c = parse(ical)
        c.find_property("SUMMARY").value.should.equal "Annualplanning"
      end

      it "handles three consecutive folded lines" do
        ical = "BEGIN:VCALENDAR\r\nX-LONG:a\r\n b\r\n c\r\nEND:VCALENDAR"
        c = parse(ical)
        c.find_property("X-LONG").value.should.equal "abc"
      end
    end

    describe "component nesting" do
      it "parses a flat VCALENDAR with no children" do
        c = parse("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR")
        c.name.should.equal "VCALENDAR"
        c.components.should.equal []
      end

      it "parses one VEVENT inside VCALENDAR" do
        ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Test\r\nEND:VEVENT\r\nEND:VCALENDAR"
        c = parse(ical)
        c.components.length.should.equal 1
        c.components[0].name.should.equal "VEVENT"
        c.components[0].find_property("SUMMARY").value.should.equal "Test"
      end

      it "parses multiple sibling VEVENTs" do
        ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:A\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nSUMMARY:B\r\nEND:VEVENT\r\nEND:VCALENDAR"
        c = parse(ical)
        c.components.length.should.equal 2
      end

      it "parses VALARM nested inside VEVENT" do
        ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR"
        c = parse(ical)
        vevent = c.components[0]
        vevent.components.length.should.equal 1
        vevent.components[0].name.should.equal "VALARM"
      end

      it "raises on mismatched END" do
        ical = "BEGIN:VEVENT\r\nEND:VTODO"
        lambda { parse(ical) }.should.raise Protocol::Caldav::ParseError
      end

      it "handles BEGIN/END names case-insensitively" do
        c = parse("begin:vcalendar\r\nend:vcalendar")
        c.name.should.equal "VCALENDAR"
      end

      it "preserves component order" do
        ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VEVENT\r\nBEGIN:VTODO\r\nEND:VTODO\r\nEND:VCALENDAR"
        c = parse(ical)
        c.components[0].name.should.equal "VEVENT"
        c.components[1].name.should.equal "VTODO"
      end
    end

    describe "property parsing" do
      it "parses a property with no parameters" do
        c = parse("BEGIN:VCALENDAR\r\nSUMMARY:Hello\r\nEND:VCALENDAR")
        c.find_property("SUMMARY").value.should.equal "Hello"
        c.find_property("SUMMARY").params.should.equal({})
      end

      it "parses a property with one parameter" do
        c = parse("BEGIN:VCALENDAR\r\nDTSTART;TZID=America/New_York:20260101T090000\r\nEND:VCALENDAR")
        p = c.find_property("DTSTART")
        p.params["TZID"].should.equal "America/New_York"
        p.value.should.equal "20260101T090000"
      end

      it "handles a property value containing colons" do
        c = parse("BEGIN:VCALENDAR\r\nURL:https://example.com:8080/path\r\nEND:VCALENDAR")
        c.find_property("URL").value.should.equal "https://example.com:8080/path"
      end

      it "handles an empty property value" do
        c = parse("BEGIN:VCALENDAR\r\nDESCRIPTION:\r\nEND:VCALENDAR")
        c.find_property("DESCRIPTION").value.should.equal ""
      end

      it "handles X-prefix custom properties" do
        c = parse("BEGIN:VCALENDAR\r\nX-WR-CALNAME:My Calendar\r\nEND:VCALENDAR")
        c.find_property("X-WR-CALNAME").value.should.equal "My Calendar"
      end
    end

    describe "edge cases" do
      it "returns nil for empty input" do
        parse("").should.be.nil
      end

      it "returns nil for nil input" do
        parse(nil).should.be.nil
      end

      it "tolerates trailing whitespace and blank lines" do
        c = parse("BEGIN:VCALENDAR\r\n\r\nVERSION:2.0\r\n\r\nEND:VCALENDAR\r\n  \r\n")
        c.name.should.equal "VCALENDAR"
      end

      it "tolerates BOM at start of file" do
        c = parse("\xEF\xBB\xBFBEGIN:VCALENDAR\r\nEND:VCALENDAR")
        c.name.should.equal "VCALENDAR"
      end

      it "tolerates LF-only line endings" do
        c = parse("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR")
        c.name.should.equal "VCALENDAR"
      end
    end
  end
end
