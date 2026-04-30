# frozen_string_literal: true

module Caldav
  module Calendar
    class Proppatch
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'PROPPATCH' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          path = path.ensure_trailing_slash
          collection = DavCollection.find(path)

          if !collection
            [404, { 'content-type' => 'text/xml; charset=utf-8' }, ['Not Found']]
          else
            body = request.body.read
            updates = {}
            dn = Xml.extract_value(body, 'displayname')
            updates[:displayname] = dn if dn
            desc = Xml.extract_value(body, 'calendar-description')
            updates[:description] = desc if desc
            color = Xml.extract_value(body, 'calendar-color')
            updates[:color] = color if color

            # Handle d:remove
            if body.include?('<d:remove') || body.include?('<D:remove')
              updates[:displayname] = nil if body.match?(/<[^>]*remove[^>]*>.*displayname/m) && !dn
              updates[:description] = nil if body.match?(/<[^>]*remove[^>]*>.*calendar-description/m) && !desc
              updates[:color] = nil if body.match?(/<[^>]*remove[^>]*>.*calendar-color/m) && !color
            end

            collection.update(updates)

            result = Multistatus.new([<<~XML]).to_xml
              <d:response>
                <d:href>#{Xml.escape(path.to_s)}</d:href>
                <d:propstat>
                  <d:prop/>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            XML

            [207, { 'content-type' => 'text/xml; charset=utf-8' }, [result]]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  def self.normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    status, = mw.call(TM.env('PROPPATCH', '/addressbooks/admin/a/'))
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Proppatch, nil, user: nil)
    status, = mw.call(TM.env('PROPPATCH', '/calendars/admin/cal/', body: '<x/>'))
    status.should == 401
  end

  it "returns 404 for non-existent collection" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    status, = mw.call(TM.env('PROPPATCH', '/calendars/admin/nope/', body: '<x/>'))
    status.should == 404
  end

  it "updates displayname and returns full 207 response" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Old')
    body = <<~XML
      <d:propertyupdate xmlns:d="DAV:">
        <d:set><d:prop>
          <d:displayname>New</d:displayname>
        </d:prop></d:set>
      </d:propertyupdate>
    XML
    status, headers, resp = mw.call(TM.env('PROPPATCH', '/calendars/admin/cal/', body: body))
    status.should == 207
    headers['content-type'].should == 'text/xml; charset=utf-8'
    mw.storage.get_collection('/calendars/admin/cal/')[:displayname].should == 'New'
    normalize(resp.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/</d:href>
          <d:propstat>
            <d:prop/>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "removes displayname via d:remove and returns full 207 response" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'RemoveMe')
    body = <<~XML
      <d:propertyupdate xmlns:d="DAV:">
        <d:remove><d:prop>
          <d:displayname/>
        </d:prop></d:remove>
      </d:propertyupdate>
    XML
    status, _, resp = mw.call(TM.env('PROPPATCH', '/calendars/admin/cal/', body: body))
    status.should == 207
    mw.storage.get_collection('/calendars/admin/cal/')[:displayname].should.be.nil
    normalize(resp.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/</d:href>
          <d:propstat>
            <d:prop/>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "sets and removes properties in a single request" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Keep', description: 'Remove this')
    body = <<~XML
      <d:propertyupdate xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:x="http://apple.com/ns/ical/">
        <d:set><d:prop>
          <x:calendar-color>#00ff00</x:calendar-color>
        </d:prop></d:set>
        <d:remove><d:prop>
          <c:calendar-description/>
        </d:prop></d:remove>
      </d:propertyupdate>
    XML
    status, = mw.call(TM.env('PROPPATCH', '/calendars/admin/cal/', body: body))
    status.should == 207
    col = mw.storage.get_collection('/calendars/admin/cal/')
    col[:color].should == '#00ff00'
    col[:description].should.be.nil
    col[:displayname].should == 'Keep'
  end

  it "updates description and color" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Cal', description: 'Old desc', color: '#000000')
    body = <<~XML
      <d:propertyupdate xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:x="http://apple.com/ns/ical/">
        <d:set><d:prop>
          <c:calendar-description>New desc</c:calendar-description>
          <x:calendar-color>#ff0000</x:calendar-color>
        </d:prop></d:set>
      </d:propertyupdate>
    XML
    status, _, resp = mw.call(TM.env('PROPPATCH', '/calendars/admin/cal/', body: body))
    status.should == 207
    col = mw.storage.get_collection('/calendars/admin/cal/')
    col[:description].should == 'New desc'
    col[:color].should == '#ff0000'
    col[:displayname].should == 'Cal'
    normalize(resp.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/calendars/admin/cal/</d:href>
          <d:propstat>
            <d:prop/>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end
end
