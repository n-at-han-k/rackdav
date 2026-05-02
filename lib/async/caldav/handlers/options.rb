# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Options
        module_function

        def call(path:, storage:, **)
          [200, Protocol::Caldav::Constants::DAV_HEADERS.merge('content-length' => '0'), []]
        end
      end
    end
  end
end

test do
  describe "Async::Caldav::Handlers::Options" do
    it "returns 200 with DAV headers" do
      status, headers, = Async::Caldav::Handlers::Options.call(
        path: Protocol::Caldav::Path.new("/calendars/admin/cal/"),
        storage: Async::Caldav::Storage::Mock.new
      )
      status.should.equal 200
      headers['dav'].should.include 'calendar-access'
      headers['allow'].should.include 'PROPFIND'
      headers['content-length'].should.equal '0'
    end
  end
end
