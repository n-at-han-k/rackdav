# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Options
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info)

        if request.request_method == 'OPTIONS' && path.start_with?('/addressbooks/')
          [200, DAV_HEADERS.merge('content-length' => '0'), []]
        else
          @app.call(env)
        end
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "returns 200 with DAV headers for /addressbooks/ path" do
    mw = TM.new(Caldav::Contacts::Options)
    env = TM.env('OPTIONS', '/addressbooks/admin/')
    status, headers, = mw.call(env)
    status.should == 200
    headers['dav'].should.include 'calendar-access'
    headers['allow'].should.include 'PROPFIND'
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Options)
    env = TM.env('OPTIONS', '/calendars/admin/')
    status, = mw.call(env)
    status.should == 999
  end
end
