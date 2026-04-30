# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Calendar
    class Delete
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'DELETE' || !path.start_with?('/calendars/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          item = DavItem.find(path)

          if item
            item.delete
            [204, {}, ['']]
          elsif DavCollection.exists?(path.ensure_trailing_slash)
            DavCollection.find(path.ensure_trailing_slash).delete
            [204, {}, ['']]
          else
            [404, { 'content-type' => 'text/plain' }, ['Not Found']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "deletes an item and returns 204" do
    mw = TM.new(Caldav::Calendar::Delete)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    mw.storage.put_item('/calendars/admin/cal/event.ics', 'data', 'text/calendar')
    env = TM.env('DELETE', '/calendars/admin/cal/event.ics')
    status, = mw.call(env)
    status.should == 204
    mw.storage.get_item('/calendars/admin/cal/event.ics').should.be.nil
  end

  it "deletes a collection and returns 204" do
    mw = TM.new(Caldav::Calendar::Delete)
    mw.storage.create_collection('/calendars/admin/cal/', type: :calendar)
    env = TM.env('DELETE', '/calendars/admin/cal/')
    status, = mw.call(env)
    status.should == 204
    mw.storage.collection_exists?('/calendars/admin/cal/').should.be.false
  end

  it "returns 404 for non-existent resource" do
    mw = TM.new(Caldav::Calendar::Delete)
    env = TM.env('DELETE', '/calendars/admin/nope/')
    status, = mw.call(env)
    status.should == 404
  end

  it "passes through for non-calendar path" do
    mw = TM.new(Caldav::Calendar::Delete)
    env = TM.env('DELETE', '/addressbooks/admin/a/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Calendar::Delete, nil, user: nil)
    status, = mw.call(TM.env('DELETE', '/calendars/admin/cal/event.ics'))
    status.should == 401
  end
end
