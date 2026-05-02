# frozen_string_literal: true

module Protocol
  module Caldav
    module Constants
      DAV_HEADERS = {
        'dav' => '1, 2, 3, calendar-access, addressbook, extended-mkcol',
        'allow' => 'OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCALENDAR, MKCOL, MOVE, REPORT',
        'content-type' => 'text/xml; charset=utf-8'
      }.freeze

      DAV_NS        = 'DAV:'
      CALDAV_NS     = 'urn:ietf:params:xml:ns:caldav'
      CARDDAV_NS    = 'urn:ietf:params:xml:ns:carddav'
      CALSERVER_NS  = 'http://calendarserver.org/ns/'
      APPLE_NS      = 'http://apple.com/ns/ical/'

      CALENDAR_MEDIA_TYPE = 'text/calendar'
      VCARD_MEDIA_TYPE    = 'text/vcard'
    end
  end
end
