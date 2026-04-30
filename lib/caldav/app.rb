# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  class App
    def initialize(storage:)
      @storage = storage
      @stack = build_stack
    end

    def call(env)
      env['caldav.storage'] = @storage
      @stack.call(env)
    end

    private

    def build_stack
      app = method(:fallback)

      # Contacts middlewares (innermost first, outermost last)
      app = Contacts::Report.new(app)
      app = Contacts::Move.new(app)
      app = Contacts::Delete.new(app)
      app = Contacts::Head.new(app)
      app = Contacts::Get.new(app)
      app = Contacts::Put.new(app)
      app = Contacts::Mkcol.new(app)
      app = Contacts::Proppatch.new(app)
      app = Contacts::Propfind.new(app)
      app = Contacts::Options.new(app)

      # Calendar middlewares
      app = Calendar::Report.new(app)
      app = Calendar::Move.new(app)
      app = Calendar::Delete.new(app)
      app = Calendar::Head.new(app)
      app = Calendar::Get.new(app)
      app = Calendar::Put.new(app)
      app = Calendar::Mkcalendar.new(app)
      app = Calendar::Proppatch.new(app)
      app = Calendar::Propfind.new(app)
      Calendar::Options.new(app)
    end

    def fallback(env)
      request = Rack::Request.new(env)
      path = Path.new(request.path_info, storage_class: @storage)

      if request.request_method == 'OPTIONS'
        [200, DAV_HEADERS.merge('content-length' => '0'), []]
      elsif !env['dav.user'].present?
        [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
      elsif request.request_method == 'PROPFIND'
        user = env['dav.user']
        depth = env['HTTP_DEPTH'] || '1'

        # Build discovery properties for root / well-known / principal paths
        discovery_props = []
        discovery_props << "<d:current-user-principal><d:href>/#{user}/</d:href></d:current-user-principal>"
        discovery_props << "<c:calendar-home-set><d:href>/calendars/#{user}/</d:href></c:calendar-home-set>"
        discovery_props << "<cr:addressbook-home-set><d:href>/addressbooks/#{user}/</d:href></cr:addressbook-home-set>"

        response_xml = <<~XML
          <d:response>
            <d:href>#{Xml.escape(path.to_s)}</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                #{discovery_props.join("\n              ")}
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML

        responses = [response_xml]

        if depth == '1'
          DavCollection.list(path).each do |col|
            responses << col.to_propfind_xml
          end
        end

        [207, { 'content-type' => 'text/xml; charset=utf-8' }, [Multistatus.new(responses).to_xml]]
      elsif request.request_method == 'GET'
        if path.to_s == '/' || path.start_with?('/.well-known/')
          [200, { 'content-type' => 'text/html' }, ['Caldav::App']]
        else
          [404, { 'content-type' => 'text/plain' }, ['Not Found']]
        end
      else
        [405, { 'content-type' => 'text/plain' }, ['Method Not Allowed']]
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "returns 200 for GET /" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('GET', '/')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 200
  end

  it "returns 207 for PROPFIND / with auth" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('PROPFIND', '/', headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 207
  end

  it "returns 401 for PROPFIND / without auth" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('PROPFIND', '/', headers: { 'Depth' => '0' })
    env['dav.user'] = nil
    status, = app.call(env)
    status.should == 401
  end

  it "returns 200 for OPTIONS / with DAV headers" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('OPTIONS', '/')
    status, headers, = app.call(env)
    status.should == 200
    headers['dav'].should.include 'calendar-access'
    headers['allow'].should.include 'PROPFIND'
  end

  it "full stack: MKCALENDAR then PROPFIND lists the calendar" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    body = <<~XML
      <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:set><d:prop>
          <d:displayname>Work</d:displayname>
        </d:prop></d:set>
      </c:mkcalendar>
    XML
    env = TM.env('MKCALENDAR', '/calendars/admin/work/', body: body)
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 201

    env = TM.env('PROPFIND', '/calendars/admin/', headers: { 'Depth' => '1' })
    env['dav.user'] = 'admin'
    status, _, body = app.call(env)
    status.should == 207
    body.first.should.include 'Work'
  end

  it "full stack: PUT event then GET retrieves it" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('PUT', '/calendars/admin/cal/event.ics', body: "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:ev1\r\nEND:VEVENT\r\nEND:VCALENDAR", content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    status, headers, = app.call(env)
    status.should == 201
    headers['etag'].should.not.be.nil

    env = TM.env('GET', '/calendars/admin/cal/event.ics')
    env['dav.user'] = 'admin'
    status, headers, body = app.call(env)
    status.should == 200
    headers['content-type'].should == 'text/calendar'
    body.first.should.include 'VEVENT'
  end

  it "full stack: PUT then DELETE then GET returns 404" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: 'BEGIN:VCALENDAR', content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('DELETE', '/calendars/admin/cal/ev.ics')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 204

    env = TM.env('GET', '/calendars/admin/cal/ev.ics')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 404
  end

  it "full stack: MKCOL addressbook then PROPFIND sees it" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    body = '<d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype><d:displayname>Contacts</d:displayname></d:prop></d:set></d:mkcol>'
    env = TM.env('MKCOL', '/addressbooks/admin/contacts/', body: body)
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 201

    env = TM.env('PROPFIND', '/addressbooks/admin/', headers: { 'Depth' => '1' })
    env['dav.user'] = 'admin'
    status, _, body = app.call(env)
    status.should == 207
    body.first.should.include 'Contacts'
  end

  it "full stack: PROPPATCH updates displayname visible in PROPFIND" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/', body: '<c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:set><d:prop><d:displayname>Old</d:displayname></d:prop></d:set></c:mkcalendar>')
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('PROPPATCH', '/calendars/admin/cal/', body: '<d:propertyupdate xmlns:d="DAV:"><d:set><d:prop><d:displayname>Updated</d:displayname></d:prop></d:set></d:propertyupdate>')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 207

    env = TM.env('PROPFIND', '/calendars/admin/cal/', headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, body = app.call(env)
    status.should == 207
    body.first.should.include 'Updated'
  end

  it "full stack: PUT contact then REPORT returns it" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    body = '<d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype></d:prop></d:set></d:mkcol>'
    env = TM.env('MKCOL', '/addressbooks/admin/addr/', body: body)
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('PUT', '/addressbooks/admin/addr/c.vcf', body: "BEGIN:VCARD\r\nUID:c1\r\nFN:Alice\r\nEND:VCARD", content_type: 'text/vcard')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 201

    env = TM.env('REPORT', '/addressbooks/admin/addr/')
    env['dav.user'] = 'admin'
    status, _, body = app.call(env)
    status.should == 207
    body.first.should.include 'Alice'
    body.first.should.include 'cr:address-data'
  end

  it "full stack: DELETE collection removes all items" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: 'BEGIN:VCALENDAR', content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('DELETE', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 204

    env = TM.env('GET', '/calendars/admin/cal/ev.ics')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 404
  end

  # --- Client discovery flow tests ---

  it "PROPFIND / returns current-user-principal" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    body = '<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>'
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    xml = resp.first
    xml.should.include 'current-user-principal'
    xml.should.include '/admin/'
  end

  it "PROPFIND user principal returns calendar-home-set" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    body = '<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>'
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    xml = resp.first
    xml.should.include 'calendar-home-set'
    xml.should.include '/calendars/admin/'
  end

  it "PROPFIND user principal returns addressbook-home-set" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    body = '<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav"><d:prop><cr:addressbook-home-set/></d:prop></d:propfind>'
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    xml = resp.first
    xml.should.include 'addressbook-home-set'
    xml.should.include '/addressbooks/admin/'
  end

  it "full discovery: current-user-principal -> calendar-home-set -> list calendars" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    # Step 1: Create a calendar
    env = TM.env('MKCALENDAR', '/calendars/admin/work/', body: '<c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:set><d:prop><d:displayname>Work</d:displayname></d:prop></d:set></c:mkcalendar>')
    env['dav.user'] = 'admin'
    app.call(env)

    # Step 2: Client discovers current-user-principal
    body = '<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>'
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    resp.first.should.include '/admin/'

    # Step 3: Client discovers calendar-home-set
    body = '<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>'
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    resp.first.should.include '/calendars/admin/'

    # Step 4: Client lists calendars at the home set
    body = '<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:resourcetype/><d:displayname/></d:prop></d:propfind>'
    env = TM.env('PROPFIND', '/calendars/admin/', body: body, headers: { 'Depth' => '1' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    xml = resp.first
    xml.should.include 'Work'
    xml.should.include 'c:calendar'
  end

  it "full discovery: current-user-principal -> addressbook-home-set -> list addressbooks" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    # Step 1: Create an addressbook
    body = '<d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype><d:displayname>Contacts</d:displayname></d:prop></d:set></d:mkcol>'
    env = TM.env('MKCOL', '/addressbooks/admin/contacts/', body: body)
    env['dav.user'] = 'admin'
    app.call(env)

    # Step 2: Client discovers addressbook-home-set
    body = '<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav"><d:prop><cr:addressbook-home-set/></d:prop></d:propfind>'
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    resp.first.should.include '/addressbooks/admin/'

    # Step 3: Client lists addressbooks
    body = '<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav"><d:prop><d:resourcetype/><d:displayname/></d:prop></d:propfind>'
    env = TM.env('PROPFIND', '/addressbooks/admin/', body: body, headers: { 'Depth' => '1' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    xml = resp.first
    xml.should.include 'Contacts'
    xml.should.include 'cr:addressbook'
  end

  it ".well-known/caldav returns useful response" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('PROPFIND', '/.well-known/caldav', headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, = app.call(env)
    # Should either redirect (301) or return 207 with discovery info
    [207, 301].should.include status
  end

  it ".well-known/carddav returns useful response" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('PROPFIND', '/.well-known/carddav', headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, = app.call(env)
    [207, 301].should.include status
  end
end
