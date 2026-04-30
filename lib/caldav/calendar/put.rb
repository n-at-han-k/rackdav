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
          elsif !body.strip.start_with?('BEGIN:VCALENDAR')
            [400, { 'content-type' => 'text/plain' }, ['Invalid calendar data']]
          else
            existing = DavItem.find(path)
            if_match = env['HTTP_IF_MATCH']
            if_none_match = env['HTTP_IF_NONE_MATCH']

            if if_match && (!existing || existing.etag != if_match)
              return [412, { 'content-type' => 'text/plain' }, ['If-Match precondition failed']]
            end

            if if_none_match == '*' && existing
              return [412, { 'content-type' => 'text/plain' }, ['If-None-Match precondition failed']]
            end

            # Check for duplicate UID in the collection
            uid_match = body.match(/^UID:(.+)$/i)
            if uid_match && !existing
              uid = uid_match[1].strip
              collection_path = path.parent.to_s
              storage = env['caldav.storage']
              if storage.respond_to?(:list_items)
                storage.list_items(collection_path).each do |item_path, item_data|
                  next if item_path == path.to_s
                  if item_data[:body].match?(/^UID:#{Regexp.escape(uid)}$/i)
                    return [409, { 'content-type' => 'text/xml; charset=utf-8' }, ['UID conflict']]
                  end
                end
              end
            end

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
    mw.storage.put_item('/calendars/admin/cal/ev.ics', "BEGIN:VCALENDAR\nV1\nEND:VCALENDAR", 'text/calendar')
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: "BEGIN:VCALENDAR\nV2\nEND:VCALENDAR", content_type: 'text/calendar')
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

  # --- ETag precondition tests ---

  it "returns 412 when If-Match does not match existing etag" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    old = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev.ics', old, 'text/calendar')
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: "BEGIN:VCALENDAR\nNEW\nEND:VCALENDAR", content_type: 'text/calendar',
                 headers: { 'If-Match' => '"wrong-etag"' })
    status, = mw.call(env)
    status.should == 412
    mw.storage.get_item('/calendars/admin/cal/ev.ics')[:body].should == old
  end

  it "returns 204 when If-Match matches existing etag" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    old = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev.ics', old, 'text/calendar')
    real_etag = mw.storage.get_item('/calendars/admin/cal/ev.ics')[:etag]
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: "BEGIN:VCALENDAR\nNEW\nEND:VCALENDAR", content_type: 'text/calendar',
                 headers: { 'If-Match' => real_etag })
    status, = mw.call(env)
    status.should == 204
  end

  it "returns 412 when If-Match set but item does not exist" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('PUT', '/calendars/admin/cal/new.ics', body: "BEGIN:VCALENDAR\nEND:VCALENDAR", content_type: 'text/calendar',
                 headers: { 'If-Match' => '"some-etag"' })
    status, = mw.call(env)
    status.should == 412
  end

  it "returns 412 when If-None-Match is * and item exists" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    old = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev.ics', old, 'text/calendar')
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: "BEGIN:VCALENDAR\nNEW\nEND:VCALENDAR", content_type: 'text/calendar',
                 headers: { 'If-None-Match' => '*' })
    status, = mw.call(env)
    status.should == 412
    mw.storage.get_item('/calendars/admin/cal/ev.ics')[:body].should == old
  end

  it "returns 201 when If-None-Match is * and item does not exist" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('PUT', '/calendars/admin/cal/new.ics', body: "BEGIN:VCALENDAR\nEND:VCALENDAR", content_type: 'text/calendar',
                 headers: { 'If-None-Match' => '*' })
    status, = mw.call(env)
    status.should == 201
  end

  # --- Body validation tests ---

  it "rejects body that does not start with BEGIN:VCALENDAR" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: 'NOT A CALENDAR', content_type: 'text/calendar')
    status, = mw.call(env)
    status.should == 400
  end

  it "accepts body starting with BEGIN:VCALENDAR" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: "BEGIN:VCALENDAR\r\nEND:VCALENDAR", content_type: 'text/calendar')
    status, = mw.call(env)
    status.should == 201
  end

  it "stores the body exactly as sent" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    body = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Test\r\nEND:VEVENT\r\nEND:VCALENDAR"
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: body, content_type: 'text/calendar')
    mw.call(env)
    mw.storage.get_item('/calendars/admin/cal/ev.ics')[:body].should == body
  end

  # --- Duplicate UID tests ---

  it "rejects PUT with duplicate UID in same collection" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev1 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:same-uid-123\nSUMMARY:First\nEND:VEVENT\nEND:VCALENDAR"
    ev2 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:same-uid-123\nSUMMARY:Second\nEND:VEVENT\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev1.ics', ev1, 'text/calendar')
    env = TM.env('PUT', '/calendars/admin/cal/ev2.ics', body: ev2, content_type: 'text/calendar')
    status, = mw.call(env)
    status.should == 409
  end

  it "allows PUT with same UID to same path (update)" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev1 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:uid-1\nSUMMARY:First\nEND:VEVENT\nEND:VCALENDAR"
    ev2 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:uid-1\nSUMMARY:Updated\nEND:VEVENT\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev.ics', ev1, 'text/calendar')
    env = TM.env('PUT', '/calendars/admin/cal/ev.ics', body: ev2, content_type: 'text/calendar')
    status, = mw.call(env)
    status.should == 204
  end

  it "allows PUT with different UID to different path" do
    mw = TM.new(Caldav::Calendar::Put)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    ev1 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:uid-1\nEND:VEVENT\nEND:VCALENDAR"
    ev2 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:uid-2\nEND:VEVENT\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal/ev1.ics', ev1, 'text/calendar')
    env = TM.env('PUT', '/calendars/admin/cal/ev2.ics', body: ev2, content_type: 'text/calendar')
    status, = mw.call(env)
    status.should == 201
  end
end
