# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Propfind
        module_function

        def call(path:, storage:, user:, headers: {}, body: nil, **)
          depth = headers['depth'] || '1'
          propname = body&.include?('propname')

          col_path = path.ensure_trailing_slash
          collection = storage.get_collection(col_path.to_s)
          item_data = storage.get_item(path.to_s)

          # Non-existent deep path
          if !collection && !item_data && path.depth > 2
            return [404, { 'content-type' => 'text/plain' }, ['Not Found']]
          end

          responses = []

          if collection
            col = Protocol::Caldav::Collection.new(
              path: col_path,
              type: collection[:type],
              displayname: collection[:displayname],
              description: collection[:description],
              color: collection[:color],
              props: collection[:props]
            )
            responses << (propname ? col.to_propname_xml : col.to_propfind_xml)

            if depth != '0'
              # Child collections
              storage.list_collections(col_path.to_s).each do |child_path, child_data|
                child_p = Protocol::Caldav::Path.new(child_path, storage_class: storage)
                child_col = Protocol::Caldav::Collection.new(
                  path: child_p,
                  type: child_data[:type],
                  displayname: child_data[:displayname],
                  description: child_data[:description],
                  color: child_data[:color],
                  props: child_data[:props]
                )
                responses << (propname ? child_col.to_propname_xml : child_col.to_propfind_xml)
              end

              # Child items
              storage.list_items(col_path.to_s).each do |item_path, data|
                item_p = Protocol::Caldav::Path.new(item_path, storage_class: storage)
                item = Protocol::Caldav::Item.new(
                  path: item_p,
                  body: data[:body],
                  content_type: data[:content_type],
                  etag: data[:etag]
                )
                responses << (propname ? item.to_propname_xml : item.to_propfind_xml)
              end
            end
          elsif item_data
            item = Protocol::Caldav::Item.new(
              path: path,
              body: item_data[:body],
              content_type: item_data[:content_type],
              etag: item_data[:etag]
            )
            responses << (propname ? item.to_propname_xml : item.to_propfind_xml)
          else
            # Shallow path with no collection — return basic discovery info
            responses << build_discovery_xml(path, user)

            # Still list child collections/items for depth=1
            if depth != '0'
              storage.list_collections(col_path.to_s).each do |child_path, child_data|
                child_p = Protocol::Caldav::Path.new(child_path, storage_class: storage)
                child_col = Protocol::Caldav::Collection.new(
                  path: child_p,
                  type: child_data[:type],
                  displayname: child_data[:displayname],
                  description: child_data[:description],
                  color: child_data[:color],
                  props: child_data[:props]
                )
                responses << (propname ? child_col.to_propname_xml : child_col.to_propfind_xml)
              end
            end
          end

          xml = Protocol::Caldav::Multistatus.new(responses).to_xml
          [207, Protocol::Caldav::Constants::DAV_HEADERS, [xml]]
        end

        def build_discovery_xml(path, user)
          <<~XML
            <d:response>
              <d:href>#{Protocol::Caldav::Xml.escape(path.to_s)}</d:href>
              <d:propstat>
                <d:prop>
                  <d:resourcetype><d:collection/></d:resourcetype>
                  <d:current-user-principal><d:href>/#{user}/</d:href></d:current-user-principal>
                  <c:calendar-home-set><d:href>/calendars/#{user}/</d:href></c:calendar-home-set>
                  <cr:addressbook-home-set><d:href>/addressbooks/#{user}/</d:href></cr:addressbook-home-set>
                </d:prop>
                <d:status>HTTP/1.1 200 OK</d:status>
              </d:propstat>
            </d:response>
          XML
        end

        private_class_method :build_discovery_xml
      end
    end
  end
end

test do
  def normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  describe "Async::Caldav::Handlers::Propfind" do
    def call(**opts)
      Async::Caldav::Handlers::Propfind.call(**opts)
    end

    def path(p, s)
      Protocol::Caldav::Path.new(p, storage_class: s)
    end

    it "returns 207 with collection properties" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work')
      status, _, body = call(path: path('/calendars/admin/work/', s), storage: s, user: 'admin', headers: { 'depth' => '0' })
      status.should.equal 207
      body[0].should.include 'Work'
      body[0].should.include 'calendar'
    end

    it "depth=1 includes child items" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work')
      s.put_item('/calendars/admin/work/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      _, _, body = call(path: path('/calendars/admin/work/', s), storage: s, user: 'admin', headers: { 'depth' => '1' })
      body[0].should.include 'ev.ics'
    end

    it "returns 404 for deep non-existent path" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: path('/calendars/admin/nope/deep/', s), storage: s, user: 'admin')
      status.should.equal 404
    end

    it "returns discovery info for shallow path" do
      s = Async::Caldav::Storage::Mock.new
      status, _, body = call(path: path('/', s), storage: s, user: 'admin')
      status.should.equal 207
      body[0].should.include 'current-user-principal'
      body[0].should.include '/admin/'
      body[0].should.include 'calendar-home-set'
    end

    it "propname request returns property names without values" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work')
      s.put_item('/calendars/admin/work/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      propname_body = '<d:propfind xmlns:d="DAV:"><d:propname/></d:propfind>'
      status, _, body = call(path: path('/calendars/admin/work/', s), storage: s, user: 'admin',
        headers: { 'depth' => '1' }, body: propname_body)
      status.should.equal 207
      body[0].should.include '<d:resourcetype/>'
      body[0].should.include '<d:getetag/>'
    end

    it "allprop request returns all properties with values" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work')
      s.put_item('/calendars/admin/work/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      allprop_body = '<d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>'
      status, _, body = call(path: path('/calendars/admin/work/', s), storage: s, user: 'admin',
        headers: { 'depth' => '1' }, body: allprop_body)
      status.should.equal 207
      body[0].should.include 'displayname'
      body[0].should.include 'Work'
      body[0].should.include 'getetag'
    end

    it "returns item propfind for a single item" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item('/calendars/admin/work/ev.ics', 'BEGIN:VCALENDAR', 'text/calendar')
      status, _, body = call(path: path('/calendars/admin/work/ev.ics', s), storage: s, user: 'admin')
      status.should.equal 207
      body[0].should.include 'getetag'
    end
  end
end
