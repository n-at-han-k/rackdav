# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Mkcalendar
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'MKCALENDAR'
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          path = path.ensure_trailing_slash

          if DavCollection.exists?(path)
            [405, { 'content-type' => 'text/plain' }, ['Collection already exists']]
          elsif !path.parent_exists?
            [409, { 'content-type' => 'text/plain' }, ['Parent does not exist']]
          else
            body = request.body&.read || ''
            displayname = Xml.extract_value(body, 'displayname')
            description = Xml.extract_value(body, 'calendar-description')
            color = Xml.extract_value(body, 'calendar-color')

            DavCollection.create(path,
              type: :calendar,
              displayname: displayname,
              description: description,
              color: color
            )

            [201, { 'content-type' => 'text/xml; charset=utf-8' }, ['']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "creates a calendar collection and returns 201" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    body = <<~XML
      <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:set><d:prop>
          <d:displayname>New</d:displayname>
        </d:prop></d:set>
      </c:mkcalendar>
    XML
    env = TM.env('MKCALENDAR', '/calendars/admin/newcal/', body: body)
    status, = mw.call(env)
    status.should == 201
    mw.storage.collection_exists?('/calendars/admin/newcal/').should.be.true
  end

  it "stores displayname, description, and color from XML body" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    body = <<~XML
      <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:x="http://apple.com/ns/ical/">
        <d:set><d:prop>
          <d:displayname>Work</d:displayname>
          <c:calendar-description>Work events</c:calendar-description>
          <x:calendar-color>#0000ff</x:calendar-color>
        </d:prop></d:set>
      </c:mkcalendar>
    XML
    env = TM.env('MKCALENDAR', '/calendars/admin/work/', body: body)
    status, = mw.call(env)
    status.should == 201
    col = mw.storage.get_collection('/calendars/admin/work/')
    col[:displayname].should == 'Work'
    col[:description].should == 'Work events'
    col[:color].should == '#0000ff'
    col[:type].should == :calendar
  end

  it "returns 405 when collection already exists" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    mw.storage.create_collection('/calendars/admin/dup/', type: :calendar)
    env = TM.env('MKCALENDAR', '/calendars/admin/dup/')
    status, = mw.call(env)
    status.should == 405
  end

  it "returns 409 when parent does not exist" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    env = TM.env('MKCALENDAR', '/calendars/admin/no/parent/deep/cal/')
    status, = mw.call(env)
    status.should == 409
  end

  it "passes through for non-MKCALENDAR requests" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    env = TM.env('GET', '/calendars/admin/cal/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Mkcalendar, nil, user: nil)
    status, = mw.call(TM.env('MKCALENDAR', '/calendars/admin/newcal/'))
    status.should == 401
  end

  it "creates calendar with only displayname (no description or color)" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    body = <<~XML
      <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:set><d:prop>
          <d:displayname>Simple</d:displayname>
        </d:prop></d:set>
      </c:mkcalendar>
    XML
    env = TM.env('MKCALENDAR', '/calendars/admin/simple/', body: body)
    status, = mw.call(env)
    status.should == 201
    col = mw.storage.get_collection('/calendars/admin/simple/')
    col[:displayname].should == 'Simple'
    col[:description].should.be.nil
    col[:color].should.be.nil
  end

  it "always sets type to calendar" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    env = TM.env('MKCALENDAR', '/calendars/admin/typed/')
    status, = mw.call(env)
    status.should == 201
    mw.storage.get_collection('/calendars/admin/typed/')[:type].should == :calendar
  end

  it "creates calendar with empty body" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    env = TM.env('MKCALENDAR', '/calendars/admin/empty/')
    status, = mw.call(env)
    status.should == 201
    mw.storage.collection_exists?('/calendars/admin/empty/').should.be.true
  end

  it "adds trailing slash to path" do
    mw = TM.new(Caldav::Calendar::Mkcalendar)
    env = TM.env('MKCALENDAR', '/calendars/admin/noslash')
    status, = mw.call(env)
    status.should == 201
    mw.storage.collection_exists?('/calendars/admin/noslash/').should.be.true
  end
end
