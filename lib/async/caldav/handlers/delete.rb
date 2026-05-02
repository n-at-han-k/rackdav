# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Delete
        module_function

        def call(path:, storage:, **)
          item = storage.get_item(path.to_s)

          if item
            storage.delete_item(path.to_s)
            [204, {}, ['']]
          elsif storage.collection_exists?(path.ensure_trailing_slash.to_s)
            storage.delete_collection(path.ensure_trailing_slash.to_s)
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
  describe "Async::Caldav::Handlers::Delete" do
    def call(**opts)
      Async::Caldav::Handlers::Delete.call(**opts)
    end

    it "deletes an item and returns 204" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/cal/', type: :calendar)
      s.put_item('/calendars/admin/cal/event.ics', 'data', 'text/calendar')
      status, = call(path: Protocol::Caldav::Path.new('/calendars/admin/cal/event.ics', storage_class: s), storage: s)
      status.should.equal 204
      s.get_item('/calendars/admin/cal/event.ics').should.be.nil
    end

    it "deletes a collection and returns 204" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/cal/', type: :calendar)
      status, = call(path: Protocol::Caldav::Path.new('/calendars/admin/cal/', storage_class: s), storage: s)
      status.should.equal 204
      s.collection_exists?('/calendars/admin/cal/').should.equal false
    end

    it "returns 404 for non-existent resource" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: Protocol::Caldav::Path.new('/calendars/admin/nope/', storage_class: s), storage: s)
      status.should.equal 404
    end
  end
end
