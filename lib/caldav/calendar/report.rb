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
          body = request.body&.read
          items = DavItem.list(path)

          # Apply comp-filter if present in the request body
          if body && !body.empty?
            comp_names = body.scan(/<[^>]*comp-filter[^>]*name="([^"]*)"/).flatten
            comp_name = comp_names.reject { |n| n == 'VCALENDAR' }.first
            if comp_name
              items = items.select { |item| item.body.include?("BEGIN:#{comp_name}") }
            end

            # Apply prop-filter/text-match if present
            prop_name = Xml.extract_attr(body, 'prop-filter', 'name')
            if prop_name
              text_match = Xml.extract_value(body, 'text-match')
              if text_match
                items = items.select { |item| item.body.include?(text_match) }
              else
                items = items.select { |item| item.body.include?(prop_name) }
              end
            end
          end

          responses = items.map do |item|
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

  # --- Filtering tests (comp-filter, prop-filter, text-match) ---

  it "returns only VEVENT items when comp-filter name=VEVENT" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Meeting\nEND:VEVENT\nEND:VCALENDAR"
    td = "BEGIN:VCALENDAR\nBEGIN:VTODO\nSUMMARY:Task\nEND:VTODO\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev.ics', ev, 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/td.ics', td, 'text/calendar')
    body = <<~XML
      <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><d:getetag/><c:calendar-data/></d:prop>
        <c:filter>
          <c:comp-filter name="VCALENDAR">
            <c:comp-filter name="VEVENT"/>
          </c:comp-filter>
        </c:filter>
      </c:calendar-query>
    XML
    status, _, resp = mw.call(TM.env('REPORT', '/calendars/admin/cal/', body: body))
    status.should == 207
    normalize(resp.first).should == normalize(<<~XML)
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

  it "returns all items when comp-filter name=VCALENDAR" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nEND:VEVENT\nEND:VCALENDAR"
    td = "BEGIN:VCALENDAR\nBEGIN:VTODO\nEND:VTODO\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev.ics', ev, 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/td.ics', td, 'text/calendar')
    body = <<~XML
      <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><d:getetag/><c:calendar-data/></d:prop>
        <c:filter>
          <c:comp-filter name="VCALENDAR"/>
        </c:filter>
      </c:calendar-query>
    XML
    status, _, resp = mw.call(TM.env('REPORT', '/calendars/admin/cal/', body: body))
    status.should == 207
    xml = normalize(resp.first)
    xml.should.include 'ev.ics'
    xml.should.include 'td.ics'
  end

  it "returns items matching prop-filter text-match on SUMMARY" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev1 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Important Meeting\nEND:VEVENT\nEND:VCALENDAR"
    ev2 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Lunch\nEND:VEVENT\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev1.ics', ev1, 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/ev2.ics', ev2, 'text/calendar')
    body = <<~XML
      <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><d:getetag/><c:calendar-data/></d:prop>
        <c:filter>
          <c:comp-filter name="VCALENDAR">
            <c:comp-filter name="VEVENT">
              <c:prop-filter name="SUMMARY">
                <c:text-match>Important</c:text-match>
              </c:prop-filter>
            </c:comp-filter>
          </c:comp-filter>
        </c:filter>
      </c:calendar-query>
    XML
    status, _, resp = mw.call(TM.env('REPORT', '/calendars/admin/cal/', body: body))
    status.should == 207
    normalize(resp.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/ev1.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(ev1))}</d:getetag>
              <c:calendar-data>#{Caldav::Xml.escape(ev1)}</c:calendar-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns all items with empty filter" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nEND:VEVENT\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev.ics', ev, 'text/calendar')
    body = <<~XML
      <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><d:getetag/><c:calendar-data/></d:prop>
        <c:filter/>
      </c:calendar-query>
    XML
    status, _, resp = mw.call(TM.env('REPORT', '/calendars/admin/cal/', body: body))
    status.should == 207
    normalize(resp.first).should.include 'ev.ics'
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
