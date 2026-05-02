# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Get
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'GET' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          item = DavItem.find(path)
          collection = DavCollection.find(path)

          if item
            if env['HTTP_IF_NONE_MATCH'] == item.etag
              [304, { 'etag' => item.etag, 'cache-control' => 'private, no-cache' }, []]
            else
              [200, { 'content-type' => item.content_type, 'etag' => item.etag, 'cache-control' => 'private, no-cache' }, [item.body]]
            end
          elsif collection
            items = DavItem.list(path)
            bodies = items.map(&:body).join("\n")
            [200, { 'content-type' => 'text/calendar; charset=utf-8' }, [bodies]]
          elsif path.depth <= 2
            [200, { 'content-type' => 'text/html' }, ['Caldav::App']]
          else
            [404, { 'content-type' => 'text/plain' }, ['Not Found']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "returns item body and content-type" do
    mw = TM.new(Caldav::Calendar::Get)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/event.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    env = TM.env('GET', '/calendars/admin/cal/event.ics')
    status, headers, body = mw.call(env)
    status.should == 200
    headers['content-type'].should == 'text/calendar'
    body.first.should.include 'VCALENDAR'
  end

  it "returns concatenated items for a collection GET" do
    mw = TM.new(Caldav::Calendar::Get)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/ev1.ics', 'EVENT1', 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/ev2.ics', 'EVENT2', 'text/calendar')
    env = TM.env('GET', '/calendars/admin/cal/')
    status, headers, body = mw.call(env)
    status.should == 200
    headers['content-type'].should == 'text/calendar; charset=utf-8'
    body.first.should.include 'EVENT1'
    body.first.should.include 'EVENT2'
  end

  it "returns 404 for missing item" do
    mw = TM.new(Caldav::Calendar::Get)
    env = TM.env('GET', '/calendars/admin/cal/nope.ics')
    status, = mw.call(env)
    status.should == 404
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Get)
    env = TM.env('GET', '/addressbooks/admin/a/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Get, nil, user: nil)
    status, = mw.call(TM.env('GET', '/calendars/admin/cal/event.ics'))
    status.should == 401
  end

  it "returns 304 when If-None-Match matches etag" do
    mw = TM.new(Caldav::Calendar::Get)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    item_data, = mw.storage.put_item('/calendars/admin/cal/event.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    etag = item_data[:etag]
    env = TM.env('GET', '/calendars/admin/cal/event.ics', headers: { 'If-None-Match' => etag })
    status, headers, body = mw.call(env)
    status.should == 304
    headers['etag'].should == etag
    body.should == []
  end

  it "returns 200 when If-None-Match does not match etag" do
    mw = TM.new(Caldav::Calendar::Get)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/event.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    env = TM.env('GET', '/calendars/admin/cal/event.ics', headers: { 'If-None-Match' => '"stale"' })
    status, _, body = mw.call(env)
    status.should == 200
    body.first.should.include 'VCALENDAR'
  end
end
