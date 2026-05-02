# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Proppatch
        module_function

        def call(path:, body:, storage:, **)
          col_path = path.ensure_trailing_slash
          col = storage.get_collection(col_path.to_s)

          return [404, { 'content-type' => 'text/plain' }, ['Not Found']] unless col

          updates = {}

          # Check for removals
          is_remove = body&.match?(/<[^>]*remove[^>]*>/m)

          dn = Protocol::Caldav::Xml.extract_value(body, 'displayname')
          desc = Protocol::Caldav::Xml.extract_value(body, 'calendar-description')
          color = Protocol::Caldav::Xml.extract_value(body, 'calendar-color')

          if is_remove
            updates[:displayname] = nil if body.match?(/displayname/i) && !dn
            updates[:description] = nil if body.match?(/calendar-description/i) && !desc
            updates[:color] = nil if body.match?(/calendar-color/i) && !color
          end

          updates[:displayname] = dn if dn
          updates[:description] = desc if desc
          updates[:color] = color if color

          storage.update_collection(col_path.to_s, updates)

          response_xml = <<~XML
            <d:response>
              <d:href>#{Protocol::Caldav::Xml.escape(col_path.to_s)}</d:href>
              <d:propstat>
                <d:prop/>
                <d:status>HTTP/1.1 200 OK</d:status>
              </d:propstat>
            </d:response>
          XML

          xml = Protocol::Caldav::Multistatus.new([response_xml]).to_xml
          [207, Protocol::Caldav::Constants::DAV_HEADERS, [xml]]
        end
      end
    end
  end
end

test do
  describe "Async::Caldav::Handlers::Proppatch" do
    def call(**opts)
      Async::Caldav::Handlers::Proppatch.call(**opts)
    end

    def path(p, s)
      Protocol::Caldav::Path.new(p, storage_class: s)
    end

    it "updates displayname and returns 207" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/', displayname: 'Old')
      status, = call(
        path: path('/cal/', s), storage: s,
        body: '<d:set><d:prop><d:displayname>New</d:displayname></d:prop></d:set>'
      )
      status.should.equal 207
      s.get_collection('/cal/')[:displayname].should.equal 'New'
    end

    it "returns 404 for non-existent collection" do
      s = Async::Caldav::Storage::Mock.new
      status, = call(path: path('/nope/', s), storage: s, body: '')
      status.should.equal 404
    end

    it "updates multiple properties at once" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/', displayname: 'Old', description: 'OldDesc')
      status, = call(
        path: path('/cal/', s), storage: s,
        body: '<d:set><d:prop><d:displayname>New</d:displayname><c:calendar-description>NewDesc</c:calendar-description></d:prop></d:set>'
      )
      status.should.equal 207
      col = s.get_collection('/cal/')
      col[:displayname].should.equal 'New'
      col[:description].should.equal 'NewDesc'
    end

    it "handles mixed set and remove in one request" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/', displayname: 'Keep', description: 'Remove', color: '#ff0000')
      call(
        path: path('/cal/', s), storage: s,
        body: '<d:set><d:prop><d:displayname>Updated</d:displayname></d:prop></d:set><d:remove><d:prop><c:calendar-description/></d:prop></d:remove>'
      )
      col = s.get_collection('/cal/')
      col[:displayname].should.equal 'Updated'
      col[:description].should.be.nil
      col[:color].should.equal '#ff0000'
    end

    it "removes a property" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/', displayname: 'Work')
      call(
        path: path('/cal/', s), storage: s,
        body: '<d:remove><d:prop><d:displayname/></d:prop></d:remove>'
      )
      s.get_collection('/cal/')[:displayname].should.be.nil
    end
  end
end
