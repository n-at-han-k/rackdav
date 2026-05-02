# frozen_string_literal: true

require "bundler/setup"
require "scampi"

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


test do
  describe "Protocol::Caldav::Xml" do
    describe ".escape" do
      it "escapes ampersand" do
        Protocol::Caldav::Xml.escape("a&b").should.equal "a&amp;b"
      end

      it "escapes less-than" do
        Protocol::Caldav::Xml.escape("a<b").should.equal "a&lt;b"
      end

      it "escapes greater-than" do
        Protocol::Caldav::Xml.escape("a>b").should.equal "a&gt;b"
      end

      it "escapes double-quote" do
        Protocol::Caldav::Xml.escape('a"b').should.equal "a&quot;b"
      end

      it "escapes all five entities together" do
        Protocol::Caldav::Xml.escape('&<>"').should.equal '&amp;&lt;&gt;&quot;'
      end

      it "returns empty string for nil" do
        Protocol::Caldav::Xml.escape(nil).should.equal ''
      end

      it "returns empty string for empty string" do
        Protocol::Caldav::Xml.escape('').should.equal ''
      end

      it "passes through plain text unchanged" do
        Protocol::Caldav::Xml.escape("hello world").should.equal "hello world"
      end
    end

    describe ".extract_value" do
      it "extracts text content from a tag" do
        Protocol::Caldav::Xml.extract_value('<d:displayname>Work</d:displayname>', 'displayname').should.equal 'Work'
      end

      it "returns nil for empty content" do
        Protocol::Caldav::Xml.extract_value('<d:displayname></d:displayname>', 'displayname').should.be.nil
      end

      it "returns nil when tag not found" do
        Protocol::Caldav::Xml.extract_value('<d:other>x</d:other>', 'displayname').should.be.nil
      end

      it "returns nil for nil input" do
        Protocol::Caldav::Xml.extract_value(nil, 'displayname').should.be.nil
      end

      it "returns nil for empty input" do
        Protocol::Caldav::Xml.extract_value('', 'displayname').should.be.nil
      end

      it "strips whitespace from value" do
        Protocol::Caldav::Xml.extract_value('<d:displayname>  Work  </d:displayname>', 'displayname').should.equal 'Work'
      end
    end

    describe ".extract_attr" do
      it "extracts attribute value from a tag" do
        Protocol::Caldav::Xml.extract_attr('<c:comp-filter name="VCALENDAR">', 'comp-filter', 'name').should.equal 'VCALENDAR'
      end

      it "returns nil when tag not found" do
        Protocol::Caldav::Xml.extract_attr('<c:other name="x">', 'comp-filter', 'name').should.be.nil
      end

      it "returns nil for nil input" do
        Protocol::Caldav::Xml.extract_attr(nil, 'comp-filter', 'name').should.be.nil
      end

      it "returns nil for empty input" do
        Protocol::Caldav::Xml.extract_attr('', 'comp-filter', 'name').should.be.nil
      end
    end
  end
end
