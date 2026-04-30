# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Report
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'REPORT' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          responses = DavItem.list(path).map do |item|
            item.to_report_xml(data_tag: 'c:calendar-data')
          end

          [207, { 'content-type' => 'text/xml; charset=utf-8' }, [Multistatus.new(responses).to_xml]]
        end
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "returns 207 with item data for calendar report" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/event.ics', 'BEGIN:VCALENDAR', 'text/calendar')
    env = TM.env('REPORT', '/calendars/admin/cal/')
    status, headers, body = mw.call(env)
    status.should == 207
    headers['content-type'].should.include 'xml'
    body.first.should.include 'VCALENDAR'
  end

  it "returns well-formed multistatus XML with d:response elements" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/ev1.ics', 'BEGIN:VCALENDAR\nEVENT1\nEND:VCALENDAR', 'text/calendar')
    mw.storage.put_item('/calendars/admin/cal/ev2.ics', 'BEGIN:VCALENDAR\nEVENT2\nEND:VCALENDAR', 'text/calendar')
    env = TM.env('REPORT', '/calendars/admin/cal/')
    status, _, body = mw.call(env)
    status.should == 207
    xml = body.first
    xml.should.include 'd:multistatus'
    xml.should.include 'd:response'
    xml.should.include 'd:href'
    xml.should.include 'c:calendar-data'
    xml.should.include 'EVENT1'
    xml.should.include 'EVENT2'
  end

  it "returns empty multistatus for collection with no items" do
    mw = TM.new(Caldav::Calendar::Report)
    mw.storage.create_collection('/calendars/admin/empty/', type: :calendar)
    env = TM.env('REPORT', '/calendars/admin/empty/')
    status, _, body = mw.call(env)
    status.should == 207
    xml = body.first
    xml.should.include 'd:multistatus'
    xml.should.not.include 'd:response'
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Report)
    env = TM.env('REPORT', '/addressbooks/admin/a/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Report, nil, user: nil)
    status, = mw.call(TM.env('REPORT', '/calendars/admin/cal/'))
    status.should == 401
  end
end
