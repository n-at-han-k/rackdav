# frozen_string_literal: true

require "bundler/setup"
require "caldav"

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

test do
  it "wraps a single response in correct multistatus XML" do
    fragment = <<~XML.strip
      <d:response><d:href>/</d:href></d:response>
    XML
    ms = Caldav::Multistatus.new([fragment])
    ms.to_xml.should == <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
      <d:response><d:href>/</d:href></d:response>
      </d:multistatus>
    XML
  end

  it "joins multiple responses" do
    r1 = <<~XML.strip
      <d:response><d:href>/a</d:href></d:response>
    XML
    r2 = <<~XML.strip
      <d:response><d:href>/b</d:href></d:response>
    XML
    ms = Caldav::Multistatus.new([r1, r2])
    ms.to_xml.should == <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
      <d:response><d:href>/a</d:href></d:response><d:response><d:href>/b</d:href></d:response>
      </d:multistatus>
    XML
  end

  it "renders empty multistatus with no responses" do
    ms = Caldav::Multistatus.new([])
    ms.to_xml.should == <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">

      </d:multistatus>
    XML
  end
end
