# frozen_string_literal: true

require "bundler/setup"
require "caldav"

require 'uri'

module Caldav
  module Calendar
    class Move
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'MOVE' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          destination = env['HTTP_DESTINATION']

          if !destination
            [400, { 'content-type' => 'text/plain' }, ['Missing Destination header']]
          else
            to_path = Path.new(URI.parse(destination).path, storage_class: env['caldav.storage'])
            overwrite = env['HTTP_OVERWRITE'] != 'F'
            item = DavItem.find(path)

            if !item
              [404, { 'content-type' => 'text/plain' }, ['Not Found']]
            else
              existing = DavItem.find(to_path)

              if existing && !overwrite
                [412, { 'content-type' => 'text/plain' }, ['Precondition Failed']]
              else
                # Check UID conflict in destination collection
                uid_match = item.body.match(/^UID:(.+)$/i)
                if uid_match && !existing
                  uid = uid_match[1].strip
                  dest_col = to_path.parent.to_s
                  storage = env['caldav.storage']
                  if storage.respond_to?(:list_items)
                    conflict = storage.list_items(dest_col).any? do |ip, id|
                      ip != path.to_s && id[:body].match?(/^UID:#{Regexp.escape(uid)}$/i)
                    end
                    if conflict
                      return [409, { 'content-type' => 'text/xml; charset=utf-8' }, ['UID conflict']]
                    end
                  end
                end

                item.move_to(to_path)
                [existing ? 204 : 201, {}, ['']]
              end
            end
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "moves an item and returns 201" do
    mw = TM.new(Caldav::Calendar::Move)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/a.ics', 'data', 'text/calendar')
    env = TM.env('MOVE', '/calendars/admin/cal/a.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal/b.ics' })
    status, = mw.call(env)
    status.should == 201
    mw.storage.get_item('/calendars/admin/cal/a.ics').should.be.nil
    mw.storage.get_item('/calendars/admin/cal/b.ics').should.not.be.nil
  end

  it "returns 404 for missing source" do
    mw = TM.new(Caldav::Calendar::Move)
    env = TM.env('MOVE', '/calendars/admin/cal/nope.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal/b.ics' })
    status, = mw.call(env)
    status.should == 404
  end

  it "returns 400 without Destination header" do
    mw = TM.new(Caldav::Calendar::Move)
    mw.storage.put_item('/calendars/admin/cal/a.ics', 'data', 'text/calendar')
    env = TM.env('MOVE', '/calendars/admin/cal/a.ics')
    status, = mw.call(env)
    status.should == 400
  end

  it "returns 412 when Overwrite is F and destination exists" do
    mw = TM.new(Caldav::Calendar::Move)
    mw.storage.put_item('/calendars/admin/cal/a.ics', 'data-a', 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/b.ics', 'data-b', 'text/calendar')
    env = TM.env('MOVE', '/calendars/admin/cal/a.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal/b.ics',
                             'Overwrite' => 'F' })
    status, = mw.call(env)
    status.should == 412
    mw.storage.get_item('/calendars/admin/cal/a.ics').should.not.be.nil
    mw.storage.get_item('/calendars/admin/cal/b.ics')[:body].should == 'data-b'
  end

  it "returns 204 when overwriting an existing destination" do
    mw = TM.new(Caldav::Calendar::Move)
    mw.storage.put_item('/calendars/admin/cal/a.ics', 'data-a', 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/b.ics', 'data-b', 'text/calendar')
    env = TM.env('MOVE', '/calendars/admin/cal/a.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal/b.ics' })
    status, = mw.call(env)
    status.should == 204
    mw.storage.get_item('/calendars/admin/cal/a.ics').should.be.nil
    mw.storage.get_item('/calendars/admin/cal/b.ics')[:body].should == 'data-a'
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Move)
    env = TM.env('MOVE', '/addressbooks/admin/a/x.vcf')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Move, nil, user: nil)
    status, = mw.call(TM.env('MOVE', '/calendars/admin/cal/a.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal/b.ics' }))
    status.should == 401
  end

  it "source item no longer exists after move" do
    mw = TM.new(Caldav::Calendar::Move)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/src.ics', 'MOVED-DATA', 'text/calendar')
    env = TM.env('MOVE', '/calendars/admin/cal/src.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal/dst.ics' })
    status, = mw.call(env)
    status.should == 201
    mw.storage.get_item('/calendars/admin/cal/src.ics').should.be.nil
    mw.storage.get_item('/calendars/admin/cal/dst.ics')[:body].should == 'MOVED-DATA'
  end

  it "returns 409 when moving to collection with same UID" do
    mw = TM.new(Caldav::Calendar::Move)
    mw.storage.create_collection('/calendars/admin/cal1/', type: :calendar)
    mw.storage.create_collection('/calendars/admin/cal2/', type: :calendar)
    ev1 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:same-uid\nSUMMARY:A\nEND:VEVENT\nEND:VCALENDAR"
    ev2 = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:same-uid\nSUMMARY:B\nEND:VEVENT\nEND:VCALENDAR"
    mw.storage.put_item('/calendars/admin/cal1/ev1.ics', ev1, 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal2/ev2.ics', ev2, 'text/calendar')
    env = TM.env('MOVE', '/calendars/admin/cal1/ev1.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal2/ev1.ics' })
    status, = mw.call(env)
    status.should == 409
  end

  it "moves between different collections" do
    mw = TM.new(Caldav::Calendar::Move)
    mw.storage.create_collection('/calendars/admin/cal1/', type: :calendar)
    mw.storage.create_collection('/calendars/admin/cal2/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal1/ev.ics', 'CROSS-MOVE', 'text/calendar')
    env = TM.env('MOVE', '/calendars/admin/cal1/ev.ics',
                 headers: { 'Destination' => 'http://localhost/calendars/admin/cal2/ev.ics' })
    status, = mw.call(env)
    status.should == 201
    mw.storage.get_item('/calendars/admin/cal1/ev.ics').should.be.nil
    mw.storage.get_item('/calendars/admin/cal2/ev.ics')[:body].should == 'CROSS-MOVE'
  end
end
