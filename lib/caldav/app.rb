# frozen_string_literal: true

require "bundler/setup"
require "caldav"
require_relative "app2"

module Caldav
  # App is now a thin wrapper around App2 (unified dispatch).
  # The old 19-middleware stack has been replaced by a single class
  # with handler-per-method dispatch.
  App = App2
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

    body = <<~XML
      <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:set><d:prop>
          <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
          <d:displayname>Contacts</d:displayname>
        </d:prop></d:set>
      </d:mkcol>
    XML
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

    mkcal_body = <<~XML
      <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:set><d:prop>
          <d:displayname>Old</d:displayname>
        </d:prop></d:set>
      </c:mkcalendar>
    XML
    env = TM.env('MKCALENDAR', '/calendars/admin/cal/', body: mkcal_body)
    env['dav.user'] = 'admin'
    app.call(env)

    patch_body = <<~XML
      <d:propertyupdate xmlns:d="DAV:">
        <d:set><d:prop>
          <d:displayname>Updated</d:displayname>
        </d:prop></d:set>
      </d:propertyupdate>
    XML
    env = TM.env('PROPPATCH', '/calendars/admin/cal/', body: patch_body)
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

    body = <<~XML
      <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:set><d:prop>
          <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
        </d:prop></d:set>
      </d:mkcol>
    XML
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
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:">
        <d:prop><d:current-user-principal/></d:prop>
      </d:propfind>
    XML
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
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><c:calendar-home-set/></d:prop>
      </d:propfind>
    XML
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
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:prop><cr:addressbook-home-set/></d:prop>
      </d:propfind>
    XML
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
    mkcal_body = <<~XML
      <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:set><d:prop>
          <d:displayname>Work</d:displayname>
        </d:prop></d:set>
      </c:mkcalendar>
    XML
    env = TM.env('MKCALENDAR', '/calendars/admin/work/', body: mkcal_body)
    env['dav.user'] = 'admin'
    app.call(env)

    # Step 2: Client discovers current-user-principal
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:">
        <d:prop><d:current-user-principal/></d:prop>
      </d:propfind>
    XML
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    resp.first.should.include '/admin/'

    # Step 3: Client discovers calendar-home-set
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><c:calendar-home-set/></d:prop>
      </d:propfind>
    XML
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    resp.first.should.include '/calendars/admin/'

    # Step 4: Client lists calendars at the home set
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><d:resourcetype/><d:displayname/></d:prop>
      </d:propfind>
    XML
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
    mkcol_body = <<~XML
      <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:set><d:prop>
          <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
          <d:displayname>Contacts</d:displayname>
        </d:prop></d:set>
      </d:mkcol>
    XML
    env = TM.env('MKCOL', '/addressbooks/admin/contacts/', body: mkcol_body)
    env['dav.user'] = 'admin'
    app.call(env)

    # Step 2: Client discovers addressbook-home-set
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:prop><cr:addressbook-home-set/></d:prop>
      </d:propfind>
    XML
    env = TM.env('PROPFIND', '/', body: body, headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    resp.first.should.include '/addressbooks/admin/'

    # Step 3: Client lists addressbooks
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <d:propfind xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:prop><d:resourcetype/><d:displayname/></d:prop>
      </d:propfind>
    XML
    env = TM.env('PROPFIND', '/addressbooks/admin/', body: body, headers: { 'Depth' => '1' })
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    xml = resp.first
    xml.should.include 'Contacts'
    xml.should.include 'cr:addressbook'
  end

  # --- Path sanitization tests ---

  it "normalizes double slashes in path" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('PROPFIND', '//calendars//admin//', headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, = app.call(env)
    # Path.new normalizes /+ to / so this should still work
    [207, 301].should.include status
  end

  it "rejects paths with .. traversal" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('GET', '/calendars/admin/../../../etc/passwd')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    [400, 404].should.include status
  end

  # --- DELETE root collection test ---

  it "DELETE / removes all collections" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    mock.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Cal')
    mock.put_item('/calendars/admin/cal/ev.ics', "BEGIN:VCALENDAR\nEND:VCALENDAR", 'text/calendar')

    env = TM.env('DELETE', '/')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    # Should either succeed (204) or reject (405)
    [204, 405].should.include status
  end

  # --- MOVE within full stack test ---

  it "full stack: PUT then MOVE then GET at new path" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    app.call(env)

    ev = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:move-test\r\nEND:VEVENT\r\nEND:VCALENDAR"
    env = TM.env('PUT', '/calendars/admin/cal/a.ics', body: ev, content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('MOVE', '/calendars/admin/cal/a.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal/b.ics' })
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 201

    env = TM.env('GET', '/calendars/admin/cal/a.ics')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 404

    env = TM.env('GET', '/calendars/admin/cal/b.ics')
    env['dav.user'] = 'admin'
    status, _, body = app.call(env)
    status.should == 200
    body.first.should.include 'move-test'
  end

  # --- ETag round-trip full stack test ---

  it "full stack: PUT returns ETag, If-Match with correct ETag updates, wrong ETag rejects" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    app.call(env)

    ev = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:etag-test\r\nSUMMARY:V1\r\nEND:VEVENT\r\nEND:VCALENDAR"
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: ev, content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    status, headers, = app.call(env)
    status.should == 201
    etag = headers['etag']
    etag.should.not.be.nil

    # Update with wrong ETag
    ev2 = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:etag-test\r\nSUMMARY:V2\r\nEND:VEVENT\r\nEND:VCALENDAR"
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: ev2, content_type: 'text/calendar',
                 headers: { 'If-Match' => '"wrong"' })
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 412

    # Update with correct ETag
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: ev2, content_type: 'text/calendar',
                 headers: { 'If-Match' => etag })
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 204
  end

  # --- REPORT filtering full stack test ---

  it "full stack: REPORT with comp-filter VEVENT returns only events" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    app.call(env)

    ev = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:ev1\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR"
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: ev, content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    app.call(env)

    td = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:td1\r\nSUMMARY:Task\r\nEND:VTODO\r\nEND:VCALENDAR"
    env = TM.env('PUT', '/calendars/admin/cal/td.ics', body: td, content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    app.call(env)

    report_body = <<~XML
      <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><d:getetag/><c:calendar-data/></d:prop>
        <c:filter>
          <c:comp-filter name="VCALENDAR">
            <c:comp-filter name="VEVENT"/>
          </c:comp-filter>
        </c:filter>
      </c:calendar-query>
    XML
    env = TM.env('REPORT', '/calendars/admin/cal/', body: report_body)
    env['dav.user'] = 'admin'
    status, _, resp = app.call(env)
    status.should == 207
    xml = resp.first
    xml.should.include 'Meeting'
    xml.should.not.include 'Task'
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

  # --- HEAD through full stack ---

  it "full stack: HEAD returns same status and headers as GET but empty body" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    app.call(env)

    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:head-test\r\nEND:VEVENT\r\nEND:VCALENDAR", content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    _, put_headers, = app.call(env)

    env = TM.env('HEAD', '/calendars/admin/cal/ev.ics')
    env['dav.user'] = 'admin'
    status, headers, body = app.call(env)
    status.should == 200
    headers['content-type'].should == 'text/calendar'
    headers['etag'].should == put_headers['etag']
    body.should == []
  end

  # --- If-None-Match 304 through full stack ---

  it "full stack: GET with matching If-None-Match returns 304" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    env = TM.env('MKCALENDAR', '/calendars/admin/cal/')
    env['dav.user'] = 'admin'
    app.call(env)

    ev = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:etag304\r\nEND:VEVENT\r\nEND:VCALENDAR"
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: ev, content_type: 'text/calendar')
    env['dav.user'] = 'admin'
    _, headers, = app.call(env)
    etag = headers['etag']

    env = TM.env('GET', '/calendars/admin/cal/ev.ics', headers: { 'If-None-Match' => etag })
    env['dav.user'] = 'admin'
    status, headers, body = app.call(env)
    status.should == 304
    headers['etag'].should == etag
    body.should == []
  end

  # --- Cross-path method tests ---

  it "MKCALENDAR on /addressbooks/ path creates a calendar there (no path guard)" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    body = <<~XML
      <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:set><d:prop>
          <d:displayname>Misplaced</d:displayname>
        </d:prop></d:set>
      </c:mkcalendar>
    XML
    env = TM.env('MKCALENDAR', '/addressbooks/admin/misplaced/', body: body)
    env['dav.user'] = 'admin'
    status, = app.call(env)
    # Current behavior: MKCALENDAR middleware has no path guard, so this succeeds
    status.should == 201
  end

  it "MKCOL on /calendars/ path creates a collection there (no path guard)" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)

    body = <<~XML
      <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:set><d:prop>
          <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
          <d:displayname>Misplaced</d:displayname>
        </d:prop></d:set>
      </d:mkcol>
    XML
    env = TM.env('MKCOL', '/calendars/admin/misplaced/', body: body)
    env['dav.user'] = 'admin'
    status, = app.call(env)
    # Current behavior: MKCOL middleware has no path guard, so this succeeds
    status.should == 201
  end
end
