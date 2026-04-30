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
  TM = Caldav::Storage::TestMiddleware

  it "updates displayname and returns 207" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Old')
    body = '<d:propertyupdate xmlns:d="DAV:"><d:set><d:prop><d:displayname>New</d:displayname></d:prop></d:set></d:propertyupdate>'
    env = TM.env('PROPPATCH', '/calendars/admin/cal/', body: body)
    status, = mw.call(env)
    status.should == 207
    mw.storage.get_collection('/calendars/admin/cal/')[:displayname].should == 'New'
  end

  it "updates description and color" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Cal', description: 'Old desc', color: '#000000')
    body = '<d:propertyupdate xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:x="http://apple.com/ns/ical/"><d:set><d:prop><c:calendar-description>New desc</c:calendar-description><x:calendar-color>#ff0000</x:calendar-color></d:prop></d:set></d:propertyupdate>'
    env = TM.env('PROPPATCH', '/calendars/admin/cal/', body: body)
    status, = mw.call(env)
    status.should == 207
    col = mw.storage.get_collection('/calendars/admin/cal/')
    col[:description].should == 'New desc'
    col[:color].should == '#ff0000'
    col[:displayname].should == 'Cal'
  end

  it "returns 404 for non-existent collection" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    env = TM.env('PROPPATCH', '/calendars/admin/nope/', body: '<x/>')
    status, = mw.call(env)
    status.should == 404
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Proppatch)
    env = TM.env('PROPPATCH', '/addressbooks/admin/a/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Proppatch, nil, user: nil)
    status, = mw.call(TM.env('PROPPATCH', '/calendars/admin/cal/', body: '<x/>'))
    status.should == 401
  end
end
