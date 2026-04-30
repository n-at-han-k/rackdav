# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Put
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'PUT' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          body = request.body.read

          if body.nil? || body.strip.empty?
            [400, { 'content-type' => 'text/plain' }, ['Empty body']]
          else
            content_type = request.content_type || 'text/calendar'
            item = DavItem.create(path, body: body, content_type: content_type)

            [item.new? ? 201 : 204, { 'etag' => item.etag, 'content-type' => 'text/plain' }, ['']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "creates a new item and returns 201 with etag" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('PUT', '/calendars/admin/cal/event.ics',
                 body: 'BEGIN:VCALENDAR\nEND:VCALENDAR',
                 content_type: 'text/calendar; charset=utf-8')
    status, headers, = mw.call(env)
    status.should == 201
    headers['etag'].should.not.be.nil
  end

  it "rejects empty body with 400" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('PUT', '/calendars/admin/cal/event.ics')
    status, = mw.call(env)
    status.should == 400
  end

  it "updates an existing item and returns 204" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/event.ics', 'BEGIN:VCALENDAR\nVERSION:1\nEND:VCALENDAR', 'text/calendar')
    env = TM.env('PUT', '/calendars/admin/cal/event.ics',
                 body: 'BEGIN:VCALENDAR\nVERSION:2\nEND:VCALENDAR',
                 content_type: 'text/calendar')
    status, headers, = mw.call(env)
    status.should == 204
    headers['etag'].should.not.be.nil
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Put)
    env = TM.env('PUT', '/addressbooks/admin/a/c.vcf', body: 'data')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Put, nil, user: nil)
    status, = mw.call(TM.env('PUT', '/calendars/admin/cal/event.ics', body: 'data'))
    status.should == 401
  end

  it "returns etag header on 201 create" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('PUT', '/calendars/admin/cal/new.ics', body: 'BEGIN:VCALENDAR', content_type: 'text/calendar')
    status, headers, = mw.call(env)
    status.should == 201
    headers['etag'].should.not.be.nil
    headers['etag'].should.include '"'
  end

  it "returns etag header on 204 update" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/ev.ics', 'OLD', 'text/calendar')
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: 'NEW', content_type: 'text/calendar')
    status, headers, = mw.call(env)
    status.should == 204
    headers['etag'].should.not.be.nil
    headers['etag'].should.include '"'
  end

  it "defaults content-type to text/calendar when not provided" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: 'BEGIN:VCALENDAR')
    status, = mw.call(env)
    status.should == 201
    mw.storage.get_item('/calendars/admin/cal/ev.ics')[:body].should == 'BEGIN:VCALENDAR'
  end

  it "stores the body exactly as sent" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    body = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Test\r\nEND:VEVENT\r\nEND:VCALENDAR"
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: body, content_type: 'text/calendar')
    mw.call(env)
    mw.storage.get_item('/calendars/admin/cal/ev.ics')[:body].should == body
  end
end
