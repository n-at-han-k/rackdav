# frozen_string_literal: true

require "bundler/setup"
require "scampi"

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


test do
  describe "Protocol::Caldav::ContentLine" do
    describe ".unfold" do
      it "unfolds CRLF SPACE continuations" do
        Protocol::Caldav::ContentLine.unfold("SUMMARY:Annual\r\n planning").should.equal "SUMMARY:Annualplanning"
      end

      it "unfolds CRLF TAB continuations" do
        Protocol::Caldav::ContentLine.unfold("SUMMARY:Annual\r\n\tplanning").should.equal "SUMMARY:Annualplanning"
      end

      it "does not unfold CRLF followed by non-whitespace" do
        result = Protocol::Caldav::ContentLine.unfold("SUMMARY:A\r\nDTSTART:B")
        result.should.equal "SUMMARY:A\nDTSTART:B"
      end

      it "removes the space/tab character (not kept in value)" do
        Protocol::Caldav::ContentLine.unfold("X:hello\r\n world").should.equal "X:helloworld"
      end

      it "handles three consecutive folded lines" do
        Protocol::Caldav::ContentLine.unfold("X:a\r\n b\r\n c").should.equal "X:abc"
      end

      it "handles LF-only line endings" do
        Protocol::Caldav::ContentLine.unfold("X:a\n b").should.equal "X:ab"
      end
    end

    describe ".parse_line" do
      it "parses a property with no parameters" do
        name, params, value = Protocol::Caldav::ContentLine.parse_line("SUMMARY:Hello")
        name.should.equal "SUMMARY"
        params.should.equal({})
        value.should.equal "Hello"
      end

      it "parses a property with one parameter" do
        name, params, value = Protocol::Caldav::ContentLine.parse_line("DTSTART;TZID=America/New_York:20260101T090000")
        name.should.equal "DTSTART"
        params["TZID"].should.equal "America/New_York"
        value.should.equal "20260101T090000"
      end

      it "parses a parameter with a quoted value" do
        name, params, value = Protocol::Caldav::ContentLine.parse_line('ATTENDEE;CN="Smith, John":mailto:j@e.com')
        params["CN"].should.equal "Smith, John"
        value.should.equal "mailto:j@e.com"
      end

      it "handles a colon inside a quoted parameter value" do
        name, params, value = Protocol::Caldav::ContentLine.parse_line('X;FOO="a:b":realvalue')
        params["FOO"].should.equal "a:b"
        value.should.equal "realvalue"
      end

      it "handles a property value containing colons" do
        _, _, value = Protocol::Caldav::ContentLine.parse_line("URL:https://example.com:8080/path")
        value.should.equal "https://example.com:8080/path"
      end

      it "handles an empty property value" do
        _, _, value = Protocol::Caldav::ContentLine.parse_line("DESCRIPTION:")
        value.should.equal ""
      end

      it "returns nil for a line with no colon" do
        Protocol::Caldav::ContentLine.parse_line("NOCOLON").should.be.nil
      end

      it "uppercases parameter names" do
        _, params, _ = Protocol::Caldav::ContentLine.parse_line("X;tzid=utc:val")
        params.key?("TZID").should.equal true
      end
    end
  end
end
