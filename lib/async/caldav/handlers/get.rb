# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Get
        module_function

        def call(path:, storage:, headers: {}, **)
          item = storage.get_item(path.to_s)
          col_path = path.ensure_trailing_slash.to_s

          if item
            if headers['if-none-match'] == item[:etag]
              [304, { 'etag' => item[:etag], 'cache-control' => 'private, no-cache' }, []]
            else
              [200, { 'content-type' => item[:content_type], 'etag' => item[:etag], 'cache-control' => 'private, no-cache' }, [item[:body]]]
            end
          elsif storage.collection_exists?(col_path)
            items = storage.list_items(col_path)
            body = items.map { |_, data| data[:body] }.join("\n")
            [200, { 'content-type' => 'text/plain' }, [body]]
          elsif path.depth <= 2
            [200, { 'content-type' => 'text/html' }, ['<html><body>CalDAV</body></html>']]
          else
            [404, { 'content-type' => 'text/plain' }, ['Not Found']]
          end
        end
      end
    end
  end
end

test do
  describe "Async::Caldav::Handlers::Get" do
    def call(**opts)
      Async::Caldav::Handlers::Get.call(**opts)
    end

    def path(p, s)
      Protocol::Caldav::Path.new(p, storage_class: s)
    end

    it "returns item body with 200" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item('/cal/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      status, headers, body = call(path: path('/cal/ev.ics', s), storage: s)
      status.should.equal 200
      headers['content-type'].should.equal 'text/calendar'
      body[0].should.equal 'BEGIN:VCALENDAR'
    end

    it "returns 304 on If-None-Match hit" do
      s = Async::Caldav::Storage::Mock.new
      item, = s.put_item('/cal/ev.ics', 'data', 'text/calendar')
      status, = call(path: path('/cal/ev.ics', s), storage: s, headers: { 'if-none-match' => item[:etag] })
      status.should.equal 304
    end

    it "returns collection contents" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/')
      s.put_item('/cal/a.ics', 'A', 'text/calendar')
      s.put_item('/cal/b.ics', 'B', 'text/calendar')
      status, _, body = call(path: path('/cal/', s), storage: s)
      status.should.equal 200
      body[0].should.include 'A'
      body[0].should.include 'B'
    end

    it "returns 404 for deep non-existent path" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: path('/calendars/admin/nope/item.ics', s), storage: s)
      status.should.equal 404
    end

    it "returns 200 for shallow path" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: path('/calendars/admin/', s), storage: s)
      status.should.equal 200
    end
  end
end
