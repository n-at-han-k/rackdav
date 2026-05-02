# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Head
        module_function

        def call(**opts)
          status, headers, _body = Get.call(**opts)
          [status, headers, []]
        end
      end
    end
  end
end

test do
  describe "Async::Caldav::Handlers::Head" do
    it "returns same status and headers as GET but empty body" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item('/cal/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      status, headers, body = Async::Caldav::Handlers::Head.call(
        path: Protocol::Caldav::Path.new('/cal/ev.ics', storage_class: s),
        storage: s
      )
      status.should.equal 200
      headers['content-type'].should.equal 'text/calendar'
      body.should.equal []
    end
  end
end
