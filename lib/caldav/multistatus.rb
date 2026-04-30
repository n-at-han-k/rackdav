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
