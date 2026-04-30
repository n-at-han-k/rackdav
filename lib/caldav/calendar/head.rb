# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Head
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info)

        if request.request_method != 'HEAD' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          env['REQUEST_METHOD'] = 'GET'
          status, headers, _body = Caldav::Calendar::Get.new(@app).call(env)
          [status, headers, []]
        end
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "returns same status and headers as GET but empty body" do
    mw = TM.new(Caldav::Calendar::Head)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/event.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    env = TM.env('HEAD', '/calendars/admin/cal/event.ics')
    status, headers, body = mw.call(env)
    status.should == 200
    headers['content-type'].should == 'text/calendar'
    body.should == []
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Head)
    env = TM.env('HEAD', '/addressbooks/admin/a/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Head, nil, user: nil)
    status, = mw.call(TM.env('HEAD', '/calendars/admin/cal/event.ics'))
    status.should == 401
  end
end
