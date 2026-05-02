# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Mkcol
        module_function

        # method: 'MKCALENDAR' or 'MKCOL'
        def call(path:, body:, storage:, method: 'MKCOL', resource_type: nil, **)
          col_path = path.ensure_trailing_slash

          if storage.collection_exists?(col_path.to_s)
            return [405, { 'content-type' => 'text/plain' }, ['Collection already exists']]
          end

          unless col_path.parent_exists?
            return [409, { 'content-type' => 'text/plain' }, ['Parent collection does not exist']]
          end

          displayname = Protocol::Caldav::Xml.extract_value(body, 'displayname')
          description = Protocol::Caldav::Xml.extract_value(body, 'calendar-description')
          color = Protocol::Caldav::Xml.extract_value(body, 'calendar-color')

          type = if method == 'MKCALENDAR'
            :calendar
          elsif body && body.include?('addressbook')
            :addressbook
          else
            resource_type || :collection
          end

          storage.create_collection(col_path.to_s, type: type, displayname: displayname, description: description, color: color)
          [201, {}, ['']]
        end
      end
    end
  end
end

test do
  describe "Async::Caldav::Handlers::Mkcol" do
    def call(**opts)
      Async::Caldav::Handlers::Mkcol.call(**opts)
    end

    def path(p, s)
      Protocol::Caldav::Path.new(p, storage_class: s)
    end

    it "creates a calendar and returns 201" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/')
      status, = call(
        path: path('/calendars/admin/work', s), storage: s,
        body: '<d:displayname>Work</d:displayname>', method: 'MKCALENDAR'
      )
      status.should.equal 201
      col = s.get_collection('/calendars/admin/work/')
      col[:type].should.equal :calendar
      col[:displayname].should.equal 'Work'
    end

    it "creates an addressbook via MKCOL" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/addressbooks/admin/')
      status, = call(
        path: path('/addressbooks/admin/contacts', s), storage: s,
        body: '<resourcetype><addressbook/></resourcetype>', method: 'MKCOL'
      )
      status.should.equal 201
      s.get_collection('/addressbooks/admin/contacts/')[:type].should.equal :addressbook
    end

    it "returns 405 if collection exists" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/')
      status, = call(path: path('/cal/', s), storage: s, body: '', method: 'MKCALENDAR')
      status.should.equal 405
    end

    it "returns 409 if parent does not exist" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(
        path: path('/calendars/admin/deep/nested/cal', s), storage: s,
        body: '', method: 'MKCALENDAR'
      )
      status.should.equal 409
    end
  end
end
