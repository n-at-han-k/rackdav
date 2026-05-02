# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Put
        module_function

        def call(path:, body:, storage:, headers: {}, resource_type: nil, **)
          return [400, { 'content-type' => 'text/plain' }, ['Empty body']] if body.nil? || body.strip.empty?

          # Validate body format
          if resource_type == :calendar
            return [400, { 'content-type' => 'text/plain' }, ['Invalid calendar data']] unless body.start_with?('BEGIN:VCALENDAR')
            content_type = headers['content-type'] || 'text/calendar'
          elsif resource_type == :addressbook
            return [400, { 'content-type' => 'text/plain' }, ['Invalid vCard data']] unless body.start_with?('BEGIN:VCARD')
            content_type = headers['content-type'] || 'text/vcard'
          else
            content_type = headers['content-type'] || 'application/octet-stream'
          end

          existing = storage.get_item(path.to_s)

          # Precondition checks
          if_match = headers['if-match']
          if_none_match = headers['if-none-match']

          if if_match && (!existing || existing[:etag] != if_match)
            return [412, { 'content-type' => 'text/plain' }, ['Precondition Failed']]
          end

          if if_none_match == '*' && existing
            return [412, { 'content-type' => 'text/plain' }, ['Precondition Failed']]
          end

          # UID conflict check for new items
          if !existing
            uid = extract_uid(body)
            if uid
              collection_path = path.parent.to_s
              items = storage.list_items(collection_path)
              items.each do |item_path, item_data|
                next if item_path == path.to_s
                if extract_uid(item_data[:body]) == uid
                  return [409, { 'content-type' => 'text/plain' }, ['UID conflict']]
                end
              end
            end
          end

          item, is_new = storage.put_item(path.to_s, body, content_type)

          if is_new
            [201, { 'etag' => item[:etag], 'content-type' => 'text/plain' }, ['']]
          else
            [204, { 'etag' => item[:etag] }, ['']]
          end
        end

        def extract_uid(body)
          return nil unless body
          match = body.match(/^UID:(.+)/i)
          match ? match[1].strip : nil
        end

        private_class_method :extract_uid
      end
    end
  end
end

test do
  describe "Async::Caldav::Handlers::Put" do
    def call(**opts)
      Async::Caldav::Handlers::Put.call(**opts)
    end

    def path(p, s)
      Protocol::Caldav::Path.new(p, storage_class: s)
    end

    it "creates a new calendar item and returns 201" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/cal/')
      status, headers, = call(
        path: path('/calendars/admin/cal/ev.ics', s), storage: s,
        body: "BEGIN:VCALENDAR\r\nUID:123\r\nEND:VCALENDAR",
        resource_type: :calendar
      )
      status.should.equal 201
      headers['etag'].should.not.be.nil
    end

    it "updates an existing item and returns 204" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/cal/')
      s.put_item('/calendars/admin/cal/ev.ics', "BEGIN:VCALENDAR\r\nUID:123\r\nEND:VCALENDAR", 'text/calendar')
      status, = call(
        path: path('/calendars/admin/cal/ev.ics', s), storage: s,
        body: "BEGIN:VCALENDAR\r\nUID:123\r\nSUMMARY:Updated\r\nEND:VCALENDAR",
        resource_type: :calendar
      )
      status.should.equal 204
    end

    it "returns 400 for empty body" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: path('/cal/ev.ics', s), storage: s, body: "")
      status.should.equal 400
    end

    it "returns 400 for invalid calendar data" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: path('/cal/ev.ics', s), storage: s, body: "NOT ICAL", resource_type: :calendar)
      status.should.equal 400
    end

    it "returns 400 for invalid vCard data" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: path('/addr/c.vcf', s), storage: s, body: "NOT VCARD", resource_type: :addressbook)
      status.should.equal 400
    end

    it "returns 412 on If-Match mismatch" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item('/cal/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      status, = call(
        path: path('/cal/ev.ics', s), storage: s,
        body: "BEGIN:VCALENDAR\r\nNEW", resource_type: :calendar,
        headers: { 'if-match' => '"wrong"' }
      )
      status.should.equal 412
    end

    it "returns 412 on If-None-Match=* when item exists" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item('/cal/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      status, = call(
        path: path('/cal/ev.ics', s), storage: s,
        body: "BEGIN:VCALENDAR\r\nNEW", resource_type: :calendar,
        headers: { 'if-none-match' => '*' }
      )
      status.should.equal 412
    end

    it "returns 409 on UID conflict" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/')
      s.put_item('/cal/a.ics', "BEGIN:VCALENDAR\r\nUID:same\r\nEND:VCALENDAR", 'text/calendar')
      status, = call(
        path: path('/cal/b.ics', s), storage: s,
        body: "BEGIN:VCALENDAR\r\nUID:same\r\nEND:VCALENDAR",
        resource_type: :calendar
      )
      status.should.equal 409
    end
  end
end
