# frozen_string_literal: true

require "bundler/setup"
require "scampi"

module Protocol
  module Caldav
    class Multistatus
      def initialize(responses)
        @responses = responses
      end

      def to_xml
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
          #{@responses.join}
          </d:multistatus>
        XML
      end
    end
  end
end


test do
  def normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  describe "Protocol::Caldav::Multistatus" do
    it "declares all four required namespaces" do
      xml = Protocol::Caldav::Multistatus.new([]).to_xml
      xml.should.include 'xmlns:d="DAV:"'
      xml.should.include 'xmlns:c="urn:ietf:params:xml:ns:caldav"'
      xml.should.include 'xmlns:cr="urn:ietf:params:xml:ns:carddav"'
      xml.should.include 'xmlns:cs="http://calendarserver.org/ns/"'
    end

    it "emits responses in the order given" do
      responses = ["<d:response><d:href>/a</d:href></d:response>",
                   "<d:response><d:href>/b</d:href></d:response>"]
      xml = Protocol::Caldav::Multistatus.new(responses).to_xml
      xml.index("/a").should.be < xml.index("/b")
    end

    it "produces valid XML for empty response array" do
      xml = Protocol::Caldav::Multistatus.new([]).to_xml
      xml.should.include '<?xml version="1.0"'
      xml.should.include '<d:multistatus'
      xml.should.include '</d:multistatus>'
    end

    it "does not double-escape pre-escaped XML in responses" do
      response = "<d:response><d:href>/Work &amp; Personal</d:href></d:response>"
      xml = Protocol::Caldav::Multistatus.new([response]).to_xml
      xml.should.include '&amp;'
      xml.should.not.include '&amp;amp;'
    end
  end
end
