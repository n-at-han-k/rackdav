# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Propfind
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'PROPFIND' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          depth = env['HTTP_DEPTH'] || '1'
          collection = DavCollection.find(path)
          item = DavItem.find(path)

          if !collection && !item && path.depth > 2
            [404, { 'content-type' => 'text/xml; charset=utf-8' }, ['Not Found']]
          else
            responses = []

            if collection
              responses << collection.to_propfind_xml
            elsif item
              responses << item.to_propfind_xml
            else
              responses << path.to_propfind_xml
            end

            if depth == '1'
              DavCollection.list(path).each do |col|
                responses << col.to_propfind_xml
              end

              DavItem.list(path).each do |itm|
                responses << itm.to_propfind_xml
              end
            end

            [207, { 'content-type' => 'text/xml; charset=utf-8', 'cache-control' => 'no-store' }, [Multistatus.new(responses).to_xml]]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  def self.ctag(storage, path, displayname, description = nil, color = nil)
    item_etags = storage.list_items(path).map { |_, data| data[:etag] }.sort.join(":")
    Digest::SHA256.hexdigest("#{path}:#{displayname}:#{description}:#{color}:#{item_etags}")[0..15]
  end

  def self.etag(body)
    %("#{Digest::SHA256.hexdigest(body)[0..15]}")
  end

  def self.normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Propfind)
    status, = mw.call(TM.env('PROPFIND', '/addressbooks/admin/'))
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Propfind, nil, user: nil)
    status, = mw.call(TM.env('PROPFIND', '/calendars/admin/', headers: { 'Depth' => '0' }))
    status.should == 401
  end

  it "returns 404 for non-existent deep path" do
    mw = TM.new(Caldav::Calendar::Propfind)
    status, = mw.call(TM.env('PROPFIND', '/calendars/admin/nope/nothing/', headers: { 'Depth' => '0' }))
    status.should == 404
  end

  it "returns full 207 response for a calendar collection at depth 0" do
    mw = TM.new(Caldav::Calendar::Propfind)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'My Cal')
    status, headers, body = mw.call(TM.env('PROPFIND', '/calendars/admin/cal/', headers: { 'Depth' => '0' }))
    status.should == 207
    headers['content-type'].should == 'text/xml; charset=utf-8'
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
              <d:displayname>My Cal</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/calendars/admin/cal/', 'My Cal')}</cs:getctag>
              <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns full 207 response for a single item at depth 0" do
    mw = TM.new(Caldav::Calendar::Propfind)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    item_body = 'BEGIN:VCALENDAR'
    mw.storage.put_item('/calendars/admin/cal/ev.ics', item_body, 'text/calendar')
    status, _, body = mw.call(TM.env('PROPFIND', '/calendars/admin/cal/ev.ics', headers: { 'Depth' => '0' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/ev.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(item_body))}</d:getetag>
              <d:getcontenttype>text/calendar</d:getcontenttype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns collection and children at depth 1" do
    mw = TM.new(Caldav::Calendar::Propfind)
    mw.storage.create_collection('/calendars/admin/', type: :collection)
    mw.storage.create_collection('/calendars/admin/cal1/', type: :calendar, displayname: 'Cal1')
    mw.storage.create_collection('/calendars/admin/cal2/', type: :calendar, displayname: 'Cal2')
    status, _, body = mw.call(TM.env('PROPFIND', '/calendars/admin/', headers: { 'Depth' => '1' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/></d:resourcetype>
              <cs:getctag>#{ctag(mw.storage, '/calendars/admin/', nil)}</cs:getctag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/calendars/admin/cal1/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
              <d:displayname>Cal1</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/calendars/admin/cal1/', 'Cal1')}</cs:getctag>
              <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/calendars/admin/cal2/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
              <d:displayname>Cal2</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/calendars/admin/cal2/', 'Cal2')}</cs:getctag>
              <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns collection with child items at depth 1" do
    mw = TM.new(Caldav::Calendar::Propfind)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Cal')
    ev1 = 'EVENT1'
    ev2 = 'EVENT2'
    mw.storage.put_item('/calendars/admin/cal/ev1.ics', ev1, 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/ev2.ics', ev2, 'text/calendar')
    status, _, body = mw.call(TM.env('PROPFIND', '/calendars/admin/cal/', headers: { 'Depth' => '1' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
              <d:displayname>Cal</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/calendars/admin/cal/', 'Cal')}</cs:getctag>
              <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/calendars/admin/cal/ev1.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(ev1))}</d:getetag>
              <d:getcontenttype>text/calendar</d:getcontenttype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/calendars/admin/cal/ev2.ics</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(ev2))}</d:getetag>
              <d:getcontenttype>text/calendar</d:getcontenttype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns depth 0 with no children" do
    mw = TM.new(Caldav::Calendar::Propfind)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Cal')
    mw.storage.put_item('/calendars/admin/cal/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    status, _, body = mw.call(TM.env('PROPFIND', '/calendars/admin/cal/', headers: { 'Depth' => '0' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
              <d:displayname>Cal</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/calendars/admin/cal/', 'Cal')}</cs:getctag>
              <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns 207 for /calendars/ path fallback" do
    mw = TM.new(Caldav::Calendar::Propfind)
    status, _, body = mw.call(TM.env('PROPFIND', '/calendars/', headers: { 'Depth' => '0' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns 207 for /calendars/admin/ path fallback" do
    mw = TM.new(Caldav::Calendar::Propfind)
    status, _, body = mw.call(TM.env('PROPFIND', '/calendars/admin/', headers: { 'Depth' => '0' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end
end
