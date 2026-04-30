# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Report
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'REPORT' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          responses = DavItem.list(path).map do |item|
            item.to_report_xml(data_tag: 'c:calendar-data')
          end

          [207, { 'content-type' => 'text/xml; charset=utf-8' }, [Multistatus.new(responses).to_xml]]
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  def self.etag(body)
    %("#{Digest::SHA256.hexdigest(body)[0..15]}")
  end

  def self.normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Report)
    status, = mw.call(TM.env('REPORT', '/addressbooks/admin/a/'))
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Report, nil, user: nil)
    status, = mw.call(TM.env('REPORT', '/calendars/admin/cal/'))
    status.should == 401
  end

  it "returns full 207 report for a single item" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev = 'BEGIN:VCALENDAR'
    mw.storage.put_item('/calendars/admin/cal/ev.ics', ev, 'text/calendar')
    status, headers, body = mw.call(TM.env('REPORT', '/calendars/admin/cal/'))
    status.should == 207
    headers['content-type'].should == 'text/xml; charset=utf-8'
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/ev.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(ev))}</d:getetag>
              <c:calendar-data>#{Caldav::Xml.escape(ev)}</c:calendar-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns full 207 report for multiple items" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev_a = 'EVENT-A'
    ev_b = 'EVENT-B'
    ev_c = 'EVENT-C'
    mw.storage.put_item('/calendars/admin/cal/a.ics', ev_a, 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/b.ics', ev_b, 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/c.ics', ev_c, 'text/calendar')
    status, _, body = mw.call(TM.env('REPORT', '/calendars/admin/cal/'))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/a.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(ev_a))}</d:getetag>
              <c:calendar-data>#{Caldav::Xml.escape(ev_a)}</c:calendar-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/calendars/admin/cal/b.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(ev_b))}</d:getetag>
              <c:calendar-data>#{Caldav::Xml.escape(ev_b)}</c:calendar-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/calendars/admin/cal/c.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(ev_c))}</d:getetag>
              <c:calendar-data>#{Caldav::Xml.escape(ev_c)}</c:calendar-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns empty multistatus for collection with no items" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/empty/', type: :calendar)
    status, _, body = mw.call(TM.env('REPORT', '/calendars/admin/empty/'))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
      </d:multistatus>
    XML
  end
end
