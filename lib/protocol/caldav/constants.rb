# frozen_string_literal: true

require "bundler/setup"
require "scampi"

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


test do
  describe "Protocol::Caldav::Constants" do
    it "DAV_HEADERS is frozen" do
      Protocol::Caldav::Constants::DAV_HEADERS.should.be.frozen
    end

    it "DAV_HEADERS includes calendar-access" do
      Protocol::Caldav::Constants::DAV_HEADERS['dav'].should.include 'calendar-access'
    end

    it "DAV_HEADERS includes addressbook" do
      Protocol::Caldav::Constants::DAV_HEADERS['dav'].should.include 'addressbook'
    end

    it "defines all required namespace URIs" do
      Protocol::Caldav::Constants::DAV_NS.should.equal 'DAV:'
      Protocol::Caldav::Constants::CALDAV_NS.should.equal 'urn:ietf:params:xml:ns:caldav'
      Protocol::Caldav::Constants::CARDDAV_NS.should.equal 'urn:ietf:params:xml:ns:carddav'
      Protocol::Caldav::Constants::CALSERVER_NS.should.equal 'http://calendarserver.org/ns/'
    end

    it "defines media types" do
      Protocol::Caldav::Constants::CALENDAR_MEDIA_TYPE.should.equal 'text/calendar'
      Protocol::Caldav::Constants::VCARD_MEDIA_TYPE.should.equal 'text/vcard'
    end
  end
end
