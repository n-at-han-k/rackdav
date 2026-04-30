# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Propfind
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'PROPFIND' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          depth = env['HTTP_DEPTH'] || '1'
          collection = DavCollection.find(path)
          item = DavItem.find(path)

          if !collection && !item && path.depth > 2
            [404, { 'content-type' => 'text/xml; charset=utf-8' }, ['Not Found']]
          else
            responses = []

            if collection
              responses << collection.to_propfind_xml
            elsif item
              responses << item.to_propfind_xml
            else
              responses << path.to_propfind_xml
            end

            if depth == '1'
              DavCollection.list(path).each do |col|
                responses << col.to_propfind_xml
              end

              DavItem.list(path).each do |itm|
                responses << itm.to_propfind_xml
              end
            end

            [207, { 'content-type' => 'text/xml; charset=utf-8' }, [Multistatus.new(responses).to_xml]]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "returns 207 for an existing collection" do
    mw = TM.new(Caldav::Calendar::Propfind)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Test')
    status, headers, = mw.call(TM.env('PROPFIND', '/calendars/admin/cal/', headers: { 'Depth' => '0' }))
    status.should == 207
    headers['content-type'].should.include 'xml'
  end

  it "returns 404 for non-existent deep path" do
    mw = TM.new(Caldav::Calendar::Propfind)
    status, = mw.call(TM.env('PROPFIND', '/calendars/admin/nope/nothing/', headers: { 'Depth' => '0' }))
    status.should == 404
  end

  it "lists child collections and items at depth 1" do
    mw = TM.new(Caldav::Calendar::Propfind)
    mw.storage.create_collection('/calendars/admin/', type: :collection)
    mw.storage.create_collection('/calendars/admin/cal1/', type: :calendar, displayname: 'Cal1')
    mw.storage.create_collection('/calendars/admin/cal2/', type: :calendar, displayname: 'Cal2')
    mw.storage.put_item('/calendars/admin/cal1/event.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    status, _, body = mw.call(TM.env('PROPFIND', '/calendars/admin/', headers: { 'Depth' => '1' }))
    status.should == 207
    xml = body.first
    xml.should.include 'Cal1'
    xml.should.include 'Cal2'
  end

  it "returns propfind xml for a single item" do
    mw = TM.new(Caldav::Calendar::Propfind)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    status, _, body = mw.call(TM.env('PROPFIND', '/calendars/admin/cal/ev.ics', headers: { 'Depth' => '0' }))
    status.should == 207
    body.first.should.include 'getetag'
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Propfind)
    status, = mw.call(TM.env('PROPFIND', '/addressbooks/admin/'))
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Propfind, nil, user: nil)
    status, = mw.call(TM.env('PROPFIND', '/calendars/admin/', headers: { 'Depth' => '0' }))
    status.should == 401
  end
end
