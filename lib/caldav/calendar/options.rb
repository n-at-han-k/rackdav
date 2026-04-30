# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Options
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info)

        if request.request_method == 'OPTIONS' && path.start_with?('/calendars/')
          [200, DAV_HEADERS.merge('content-length' => '0'), []]
        else
          @app.call(env)
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "returns 200 with DAV headers for /calendars/ path" do
    mw = TM.new(Caldav::Calendar::Options)
    status, headers, = mw.call(TM.env('OPTIONS', '/calendars/admin/cal/'))
    status.should == 200
    headers['dav'].should.include 'calendar-access'
    headers['allow'].should.include 'PROPFIND'
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Options)
    status, = mw.call(TM.env('OPTIONS', '/addressbooks/admin/'))
    status.should == 999
  end
end
