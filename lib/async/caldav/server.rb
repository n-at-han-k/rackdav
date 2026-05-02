# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"
require 'securerandom'

module Async
  module Caldav
    class Server
      def initialize(storage:)
        @storage = storage
      end

      def call(env)
        method = env['REQUEST_METHOD']
        raw_path = env['PATH_INFO'] || '/'
        path = Protocol::Caldav::Path.new(raw_path, storage_class: @storage)

        # OPTIONS doesn't require auth
        return Handlers::Options.call(path: path, storage: @storage) if method == 'OPTIONS'

        # Auth check
        user = env['dav.user']
        unless user && !user.to_s.empty?
          return [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        end

        # Path sanitization
        if raw_path.include?('..')
          return [400, { 'content-type' => 'text/plain' }, ['Bad Request']]
        end

        resource_type = resource_type_for(path)
        body = read_body(env)
        headers = extract_headers(env)

        dispatch(method, path: path, body: body, storage: @storage, user: user,
                 headers: headers, resource_type: resource_type)
      end

      private

      def dispatch(method, **ctx)
        case method
        when 'PROPFIND'   then Handlers::Propfind.call(**ctx)
        when 'PROPPATCH'  then Handlers::Proppatch.call(**ctx)
        when 'MKCALENDAR' then Handlers::Mkcol.call(method: 'MKCALENDAR', **ctx)
        when 'MKCOL'      then Handlers::Mkcol.call(method: 'MKCOL', **ctx)
        when 'GET'        then Handlers::Get.call(**ctx)
        when 'HEAD'       then Handlers::Head.call(**ctx)
        when 'PUT'        then handle_put(**ctx)
        when 'DELETE'     then Handlers::Delete.call(**ctx)
        when 'MOVE'       then Handlers::Move.call(**ctx)
        when 'REPORT'     then Handlers::Report.call(**ctx)
        else
          [405, { 'content-type' => 'text/plain' }, ['Method Not Allowed']]
        end
      end

      def handle_put(path:, body:, storage:, resource_type: nil, **ctx)
        col_path = path.to_s
        col_path_slash = col_path.end_with?('/') ? col_path : "#{col_path}/"
        collection = storage.get_collection(col_path_slash)

        if collection || col_path.end_with?('/')
          # Whole calendar/addressbook PUT
          return put_whole_collection(path: col_path_slash, body: body, storage: storage, resource_type: resource_type)
        end

        Handlers::Put.call(path: path, body: body, storage: storage, resource_type: resource_type, **ctx)
      end

      def put_whole_collection(path:, body:, storage:, resource_type:)
        return [400, { 'content-type' => 'text/plain' }, ['Empty body']] if body.nil? || body.strip.empty?

        # Delete existing items in this collection
        storage.list_items(path).each { |item_path, _| storage.delete_item(item_path) }

        # Ensure collection exists
        unless storage.get_collection(path)
          type = resource_type || :collection
          storage.create_collection(path, type: type)
        end

        if resource_type == :addressbook || body.start_with?('BEGIN:VCARD')
          items = split_vcards(body)
          items.each do |uid, vcard_body|
            item_path = "#{path}#{uid}.vcf"
            storage.put_item(item_path, vcard_body, 'text/vcard')
          end
        else
          items = split_vcalendar(body)
          items.each do |uid, cal_body|
            item_path = "#{path}#{uid}.ics"
            storage.put_item(item_path, cal_body, 'text/calendar')
          end
        end

        [201, { 'content-type' => 'text/plain' }, ['']]
      end

      def split_vcalendar(body)
        # Extract preamble (VCALENDAR properties before first component)
        lines = body.gsub("\r\n", "\n").split("\n")
        preamble = []
        components = []
        current = nil
        depth = 0

        lines.each do |line|
          if line =~ /^BEGIN:(VEVENT|VTODO|VJOURNAL|VFREEBUSY)/i
            current = [line]
            depth = 1
          elsif current
            current << line
            depth += 1 if line =~ /^BEGIN:/i
            depth -= 1 if line =~ /^END:/i
            if depth == 0
              components << current
              current = nil
            end
          else
            preamble << line unless line =~ /^END:VCALENDAR/i
          end
        end

        # Group by UID
        grouped = {}
        components.each do |comp_lines|
          uid_line = comp_lines.find { |l| l =~ /^UID:/i }
          uid = uid_line ? uid_line.sub(/^UID:/i, '').strip : SecureRandom.uuid
          grouped[uid] ||= []
          grouped[uid] << comp_lines
        end

        # If any components had no UID, ensure UID is injected
        grouped.map do |uid, comp_groups|
          comp_body_parts = comp_groups.map do |comp_lines|
            unless comp_lines.any? { |l| l =~ /^UID:/i }
              # Insert UID after first BEGIN line
              comp_lines.insert(1, "UID:#{uid}")
            end
            comp_lines.join("\r\n")
          end
          cal_body = preamble.join("\r\n") + "\r\n" + comp_body_parts.join("\r\n") + "\r\nEND:VCALENDAR"
          [uid, cal_body]
        end
      end

      def split_vcards(body)
        cards = body.scan(/BEGIN:VCARD.*?END:VCARD/mi)
        cards.map do |card|
          uid_match = card.match(/^UID:(.+)/i)
          uid = uid_match ? uid_match[1].strip : SecureRandom.uuid
          unless uid_match
            # Inject UID
            card = card.sub("BEGIN:VCARD\r\n", "BEGIN:VCARD\r\nUID:#{uid}\r\n")
          end
          [uid, card]
        end
      end

      def resource_type_for(path)
        if path.start_with?('/calendars/')
          :calendar
        elsif path.start_with?('/addressbooks/')
          :addressbook
        else
          nil
        end
      end

      def read_body(env)
        input = env['rack.input']
        return '' unless input
        input.rewind if input.respond_to?(:rewind)
        input.read || ''
      end

      def extract_headers(env)
        h = {}
        h['depth'] = env['HTTP_DEPTH'] if env['HTTP_DEPTH']
        h['if-match'] = env['HTTP_IF_MATCH'] if env['HTTP_IF_MATCH']
        h['if-none-match'] = env['HTTP_IF_NONE_MATCH'] if env['HTTP_IF_NONE_MATCH']
        h['destination'] = env['HTTP_DESTINATION'] if env['HTTP_DESTINATION']
        h['overwrite'] = env['HTTP_OVERWRITE'] if env['HTTP_OVERWRITE']
        h['content-type'] = env['CONTENT_TYPE'] if env['CONTENT_TYPE']
        h
      end
    end
  end
end

require 'stringio'

test do
  def make_server
    s = Async::Caldav::Storage::Mock.new
    [Async::Caldav::Server.new(storage: s), s]
  end

  def env(method, path, body: '', user: 'admin', headers: {})
    e = {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'rack.input' => StringIO.new(body),
      'dav.user' => user
    }
    headers.each { |k, v| e["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    e
  end

  describe "Async::Caldav::Server" do
    it "OPTIONS returns 200 without auth" do
      server, = make_server
      status, headers, = server.call(env('OPTIONS', '/calendars/admin/', user: nil))
      status.should.equal 200
      headers['dav'].should.include 'calendar-access'
    end

    it "returns 401 without auth for non-OPTIONS" do
      server, = make_server
      status, = server.call(env('PROPFIND', '/', user: nil))
      status.should.equal 401
    end

    it "MKCALENDAR + PROPFIND round-trip" do
      server, storage = make_server
      status, = server.call(env('MKCALENDAR', '/calendars/admin/work/', body: '<d:displayname>Work</d:displayname>'))
      status.should.equal 201

      status, _, body = server.call(env('PROPFIND', '/calendars/admin/work/', headers: { 'Depth' => '0' }))
      status.should.equal 207
      body[0].should.include 'Work'
    end

    it "PUT + GET round-trip" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Test\r\nEND:VEVENT\r\nEND:VCALENDAR"
      status, headers, = server.call(env('PUT', '/calendars/admin/cal/ev.ics', body: ical))
      status.should.equal 201
      headers['etag'].should.not.be.nil

      status, _, body = server.call(env('GET', '/calendars/admin/cal/ev.ics'))
      status.should.equal 200
      body[0].should.include 'VEVENT'
    end

    it "PUT + DELETE + GET returns 404" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      server.call(env('PUT', '/calendars/admin/cal/ev.ics', body: "BEGIN:VCALENDAR\r\nEND:VCALENDAR"))
      server.call(env('DELETE', '/calendars/admin/cal/ev.ics'))
      status, = server.call(env('GET', '/calendars/admin/cal/ev.ics'))
      status.should.equal 404
    end

    it "PROPFIND on root returns discovery info" do
      server, = make_server
      status, _, body = server.call(env('PROPFIND', '/'))
      status.should.equal 207
      body[0].should.include 'current-user-principal'
      body[0].should.include 'calendar-home-set'
    end

    it "PROPPATCH updates collection properties" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Old')
      status, = server.call(env('PROPPATCH', '/calendars/admin/cal/',
        body: '<d:set><d:prop><d:displayname>New</d:displayname></d:prop></d:set>'))
      status.should.equal 207
      storage.get_collection('/calendars/admin/cal/')[:displayname].should.equal 'New'
    end

    it "REPORT returns filtered items" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/ev.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      storage.put_item('/calendars/admin/cal/td.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nSUMMARY:Task\r\nEND:VTODO\r\nEND:VCALENDAR", 'text/calendar')

      filter_xml = <<~XML
        <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
          <c:comp-filter name="VCALENDAR">
            <c:comp-filter name="VEVENT"/>
          </c:comp-filter>
        </c:filter>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: filter_xml))
      status.should.equal 207
      body[0].should.include 'ev.ics'
      body[0].should.not.include 'td.ics'
    end

    it "MOVE relocates an item" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/a.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')

      status, = server.call(env('MOVE', '/calendars/admin/cal/a.ics',
        headers: { 'Destination' => 'http://localhost/calendars/admin/cal/b.ics' }))
      status.should.equal 201
      storage.get_item('/calendars/admin/cal/a.ics').should.be.nil
      storage.get_item('/calendars/admin/cal/b.ics').should.not.be.nil
    end

    it "rejects path traversal" do
      server, = make_server
      status, = server.call(env('GET', '/calendars/../etc/passwd'))
      status.should.equal 400
    end

    it "HEAD returns empty body" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/ev.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')

      status, headers, body = server.call(env('HEAD', '/calendars/admin/cal/ev.ics'))
      status.should.equal 200
      headers['content-type'].should.equal 'text/calendar'
      body.should.equal []
    end

    it "unknown method returns 405" do
      server, = make_server
      status, = server.call(env('PATCH', '/calendars/admin/cal/'))
      status.should.equal 405
    end

    it "MKCOL creates addressbook collection" do
      server, storage = make_server
      storage.create_collection('/addressbooks/admin/')
      status, = server.call(env('MKCOL', '/addressbooks/admin/contacts/',
        body: '<resourcetype><addressbook/></resourcetype>'))
      status.should.equal 201
      storage.get_collection('/addressbooks/admin/contacts/')[:type].should.equal :addressbook
    end

    it "DELETE collection removes all items" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/ev.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')

      status, = server.call(env('DELETE', '/calendars/admin/cal/'))
      status.should.equal 204

      status, = server.call(env('GET', '/calendars/admin/cal/ev.ics'))
      status.should.equal 404
    end

    it "PROPFIND / returns current-user-principal with user path" do
      server, = make_server
      status, _, body = server.call(env('PROPFIND', '/', headers: { 'Depth' => '0' }))
      status.should.equal 207
      body[0].should.include 'current-user-principal'
      body[0].should.include '/admin/'
    end

    it "PROPFIND / returns calendar-home-set" do
      server, = make_server
      status, _, body = server.call(env('PROPFIND', '/', headers: { 'Depth' => '0' }))
      status.should.equal 207
      body[0].should.include 'calendar-home-set'
      body[0].should.include '/calendars/admin/'
    end

    it "PROPFIND / returns addressbook-home-set" do
      server, = make_server
      status, _, body = server.call(env('PROPFIND', '/', headers: { 'Depth' => '0' }))
      status.should.equal 207
      body[0].should.include 'addressbook-home-set'
      body[0].should.include '/addressbooks/admin/'
    end

    it "full discovery: current-user-principal -> calendar-home-set -> list calendars" do
      server, = make_server
      server.call(env('MKCALENDAR', '/calendars/admin/work/', body: '<d:displayname>Work</d:displayname>'))

      status, _, body = server.call(env('PROPFIND', '/', headers: { 'Depth' => '0' }))
      status.should.equal 207
      body[0].should.include '/admin/'
      body[0].should.include '/calendars/admin/'

      status, _, body = server.call(env('PROPFIND', '/calendars/admin/', headers: { 'Depth' => '1' }))
      status.should.equal 207
      body[0].should.include 'Work'
      body[0].should.include 'c:calendar'
    end

    it "full discovery: current-user-principal -> addressbook-home-set -> list addressbooks" do
      server, storage = make_server
      storage.create_collection('/addressbooks/admin/')
      server.call(env('MKCOL', '/addressbooks/admin/contacts/', body: '<resourcetype><addressbook/></resourcetype><d:displayname>Contacts</d:displayname>'))

      status, _, body = server.call(env('PROPFIND', '/', headers: { 'Depth' => '0' }))
      status.should.equal 207
      body[0].should.include '/addressbooks/admin/'

      status, _, body = server.call(env('PROPFIND', '/addressbooks/admin/', headers: { 'Depth' => '1' }))
      status.should.equal 207
      body[0].should.include 'Contacts'
      body[0].should.include 'cr:addressbook'
    end

    it "normalizes double slashes in path" do
      server, = make_server
      status, = server.call(env('PROPFIND', '//calendars//admin//', headers: { 'Depth' => '0' }))
      [207, 301].should.include status
    end

    it "PUT returns ETag, If-Match with correct ETag updates, wrong ETag rejects" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      ev = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:etag-test\r\nSUMMARY:V1\r\nEND:VEVENT\r\nEND:VCALENDAR"
      status, headers, = server.call(env('PUT', '/calendars/admin/cal/ev.ics', body: ev))
      status.should.equal 201
      etag = headers['etag']
      etag.should.not.be.nil

      ev2 = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:etag-test\r\nSUMMARY:V2\r\nEND:VEVENT\r\nEND:VCALENDAR"
      status, = server.call(env('PUT', '/calendars/admin/cal/ev.ics', body: ev2, headers: { 'If-Match' => '"wrong"' }))
      status.should.equal 412

      status, = server.call(env('PUT', '/calendars/admin/cal/ev.ics', body: ev2, headers: { 'If-Match' => etag }))
      status.should.equal 204
    end

    it ".well-known/caldav returns useful response" do
      server, = make_server
      status, = server.call(env('PROPFIND', '/.well-known/caldav', headers: { 'Depth' => '0' }))
      [207, 301].should.include status
    end

    it ".well-known/carddav returns useful response" do
      server, = make_server
      status, = server.call(env('PROPFIND', '/.well-known/carddav', headers: { 'Depth' => '0' }))
      [207, 301].should.include status
    end

    it "MKCALENDAR on /addressbooks/ path creates a calendar there (no path guard)" do
      server, storage = make_server
      storage.create_collection('/addressbooks/admin/')
      status, = server.call(env('MKCALENDAR', '/addressbooks/admin/misplaced/', body: '<d:displayname>Misplaced</d:displayname>'))
      status.should.equal 201
    end

    it "MKCOL on /calendars/ path creates a collection there (no path guard)" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/')
      status, = server.call(env('MKCOL', '/calendars/admin/misplaced/', body: '<resourcetype><addressbook/></resourcetype>'))
      status.should.equal 201
    end

    it "PUT contact then REPORT returns it with cr:address-data" do
      server, storage = make_server
      storage.create_collection('/addressbooks/admin/')
      server.call(env('MKCOL', '/addressbooks/admin/addr/', body: '<resourcetype><addressbook/></resourcetype>'))

      status, = server.call(env('PUT', '/addressbooks/admin/addr/c.vcf', body: "BEGIN:VCARD\r\nUID:c1\r\nFN:Alice\r\nEND:VCARD"))
      status.should.equal 201

      status, _, body = server.call(env('REPORT', '/addressbooks/admin/addr/'))
      status.should.equal 207
      body[0].should.include 'Alice'
      body[0].should.include 'cr:address-data'
    end

    it "PUT VTODO and REPORT returns it" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      todo = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:todo-1\r\nSUMMARY:Buy groceries\r\nEND:VTODO\r\nEND:VCALENDAR"
      status, = server.call(env('PUT', '/calendars/admin/cal/todo.ics', body: todo))
      status.should.equal 201

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/'))
      status.should.equal 207
      body[0].should.include 'Buy groceries'
    end

    it "REPORT filters VTODO from VEVENT" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      storage.put_item('/calendars/admin/cal/ev.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      storage.put_item('/calendars/admin/cal/td.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nSUMMARY:Task\r\nEND:VTODO\r\nEND:VCALENDAR", 'text/calendar')

      filter_xml = <<~XML
        <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
          <c:comp-filter name="VCALENDAR">
            <c:comp-filter name="VTODO"/>
          </c:comp-filter>
        </c:filter>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: filter_xml))
      status.should.equal 207
      body[0].should.include 'td.ics'
      body[0].should.not.include 'ev.ics'
    end

    it "MOVE between collections" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal1/', type: :calendar)
      storage.create_collection('/calendars/admin/cal2/', type: :calendar)
      storage.put_item('/calendars/admin/cal1/ev.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:move-me\r\nSUMMARY:Cross\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      status, = server.call(env('MOVE', '/calendars/admin/cal1/ev.ics',
        headers: { 'Destination' => 'http://localhost/calendars/admin/cal2/ev.ics' }))
      status.should.equal 201

      storage.get_item('/calendars/admin/cal1/ev.ics').should.be.nil
      storage.get_item('/calendars/admin/cal2/ev.ics').should.not.be.nil
    end

    it "MOVE between collections rejects UID conflict" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal1/', type: :calendar)
      storage.create_collection('/calendars/admin/cal2/', type: :calendar)
      storage.put_item('/calendars/admin/cal1/a.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:same-uid\r\nSUMMARY:A\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      storage.put_item('/calendars/admin/cal2/b.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:same-uid\r\nSUMMARY:B\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      status, = server.call(env('MOVE', '/calendars/admin/cal1/a.ics',
        headers: { 'Destination' => 'http://localhost/calendars/admin/cal2/a.ics' }))
      status.should.equal 409
    end

    it "REPORT with time-range filter on recurring event" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/rec.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=30\r\nSUMMARY:Daily\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      storage.put_item('/calendars/admin/cal/one.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260301T090000Z\r\nDTEND:20260301T100000Z\r\nSUMMARY:March\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      filter_xml = <<~XML
        <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
          <c:comp-filter name="VCALENDAR">
            <c:comp-filter name="VEVENT">
              <c:time-range start="20260115T000000Z" end="20260116T000000Z"/>
            </c:comp-filter>
          </c:comp-filter>
        </c:filter>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: filter_xml))
      status.should.equal 207
      body[0].should.include 'rec.ics'
      body[0].should.not.include 'one.ics'
    end

    it "REPORT with param-filter matches ATTENDEE;PARTSTAT" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/accepted.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:alice@x.com\r\nSUMMARY:Yes\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      storage.put_item('/calendars/admin/cal/declined.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nATTENDEE;PARTSTAT=DECLINED:mailto:bob@x.com\r\nSUMMARY:No\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      filter_xml = <<~XML
        <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
          <c:comp-filter name="VCALENDAR">
            <c:comp-filter name="VEVENT">
              <c:prop-filter name="ATTENDEE">
                <c:param-filter name="PARTSTAT">
                  <c:text-match>ACCEPTED</c:text-match>
                </c:param-filter>
              </c:prop-filter>
            </c:comp-filter>
          </c:comp-filter>
        </c:filter>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: filter_xml))
      status.should.equal 207
      body[0].should.include 'accepted.ics'
      body[0].should.not.include 'declined.ics'
    end

    it "PROPFIND propname returns property names only" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar, displayname: 'Work')
      status, _, body = server.call(env('PROPFIND', '/calendars/admin/cal/',
        body: '<d:propfind xmlns:d="DAV:"><d:propname/></d:propfind>',
        headers: { 'Depth' => '0' }))
      status.should.equal 207
      body[0].should.include '<d:resourcetype/>'
      body[0].should.not.include 'Work'
    end

    it "MOVE with URL-encoded @ in destination" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal%40dom/', type: :calendar)
      storage.put_item('/calendars/admin/cal%40dom/ev.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:at-test\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      status, = server.call(env('MOVE', '/calendars/admin/cal%40dom/ev.ics',
        headers: { 'Destination' => 'http://localhost/calendars/admin/cal%40dom/moved.ics' }))
      status.should.equal 201
      storage.get_item('/calendars/admin/cal%40dom/moved.ics').should.not.be.nil
    end

    it "sync-collection REPORT: initial sync returns all items" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/ev.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:sync1\r\nSUMMARY:Test\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token/>
        </d:sync-collection>
      XML
      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 207
      body[0].should.include 'ev.ics'
      body[0].should.include 'd:sync-token'
    end

    it "sync-collection REPORT: no changes returns empty with same token" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/ev.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:sync2\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token/>
        </d:sync-collection>
      XML
      _, _, body1 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      token = body1[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      report_body2 = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token>#{token}</d:sync-token>
        </d:sync-collection>
      XML
      status, _, body2 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body2))
      status.should.equal 207
      body2[0].should.not.include 'ev.ics'
      body2[0].should.include 'd:sync-token'
    end

    it "sync-collection REPORT: added item appears in diff" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token/>
        </d:sync-collection>
      XML
      _, _, body1 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      token = body1[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      storage.put_item('/calendars/admin/cal/new.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:new1\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body2 = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token>#{token}</d:sync-token>
        </d:sync-collection>
      XML
      status, _, body2 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body2))
      status.should.equal 207
      body2[0].should.include 'new.ics'
    end

    it "sync-collection REPORT: deleted item returns 404 status" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/del.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:del1\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token/>
        </d:sync-collection>
      XML
      _, _, body1 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      token = body1[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      storage.delete_item('/calendars/admin/cal/del.ics')

      report_body2 = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token>#{token}</d:sync-token>
        </d:sync-collection>
      XML
      status, _, body2 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body2))
      status.should.equal 207
      body2[0].should.include 'del.ics'
      body2[0].should.include '404'
    end

    it "sync-collection REPORT: modified item appears in diff" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/mod.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:mod1\r\nSUMMARY:V1\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token/>
        </d:sync-collection>
      XML
      _, _, body1 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      token = body1[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      storage.put_item('/calendars/admin/cal/mod.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:mod1\r\nSUMMARY:V2\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body2 = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token>#{token}</d:sync-token>
        </d:sync-collection>
      XML
      status, _, body2 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body2))
      status.should.equal 207
      body2[0].should.include 'mod.ics'
    end

    it "sync-collection REPORT: invalid token returns 403" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token>http://caldav.local/sync/INVALID</d:sync-token>
        </d:sync-collection>
      XML
      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 403
      body[0].should.include 'valid-sync-token'
    end

    it "PROPFIND sync-token changes after item add" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      _, _, body1 = server.call(env('PROPFIND', '/calendars/admin/cal/', headers: { 'Depth' => '0' }))
      token1 = body1[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      storage.put_item('/calendars/admin/cal/ev.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:st1\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      _, _, body2 = server.call(env('PROPFIND', '/calendars/admin/cal/', headers: { 'Depth' => '0' }))
      token2 = body2[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      token1.should.not.equal token2
    end

    it "PROPFIND sync-token matches sync-collection initial token" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/ev.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:match1\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      _, _, pf_body = server.call(env('PROPFIND', '/calendars/admin/cal/', headers: { 'Depth' => '0' }))
      pf_token = pf_body[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token/>
        </d:sync-collection>
      XML
      _, _, sc_body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      sc_token = sc_body[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      pf_token.should.equal sc_token
    end

    it "sync-collection REPORT: move shows old path deleted and new path added" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/ev1.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:mvs\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token/>
        </d:sync-collection>
      XML
      _, _, body1 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      token = body1[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      server.call(env('MOVE', '/calendars/admin/cal/ev1.ics',
        headers: { 'Destination' => 'http://localhost/calendars/admin/cal/ev2.ics' }))

      report_body2 = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token>#{token}</d:sync-token>
        </d:sync-collection>
      XML
      status, _, body2 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body2))
      status.should.equal 207
      body2[0].should.include 'ev1.ics'
      body2[0].should.include 'ev2.ics'
      body2[0].should.include '404'
    end

    it "sync-collection REPORT: create and delete item shows 404" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      report_body = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token/>
        </d:sync-collection>
      XML
      _, _, body1 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      token = body1[0].match(/<d:sync-token>([^<]+)<\/d:sync-token>/)[1]

      storage.put_item('/calendars/admin/cal/tmp.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:tmp1\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      storage.delete_item('/calendars/admin/cal/tmp.ics')

      report_body2 = <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <d:sync-collection xmlns:d="DAV:">
          <d:prop><d:getetag/></d:prop>
          <d:sync-token>#{token}</d:sync-token>
        </d:sync-collection>
      XML
      status, _, body2 = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body2))
      status.should.equal 207
      # Empty collection, same as initial empty — no items reported
      body2[0].should.not.include 'tmp.ics'
    end

    it "PUT whole calendar splits into individual items" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      whole_cal = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:ev1\r\nSUMMARY:Event 1\r\nEND:VEVENT\r\nBEGIN:VTODO\r\nUID:td1\r\nSUMMARY:Todo 1\r\nEND:VTODO\r\nEND:VCALENDAR"
      status, = server.call(env('PUT', '/calendars/admin/cal/', body: whole_cal))
      status.should.equal 201

      items = storage.list_items('/calendars/admin/cal/')
      items.length.should.equal 2
    end

    it "PUT whole calendar overwrites existing items" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/old.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:old\r\nSUMMARY:Old\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      whole_cal = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:new1\r\nSUMMARY:New1\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:new2\r\nSUMMARY:New2\r\nEND:VEVENT\r\nEND:VCALENDAR"
      status, = server.call(env('PUT', '/calendars/admin/cal/', body: whole_cal))
      status.should.equal 201

      storage.get_item('/calendars/admin/cal/old.ics').should.be.nil
      items = storage.list_items('/calendars/admin/cal/')
      items.length.should.equal 2
    end

    it "PUT whole calendar generates UIDs for items without them" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      whole_cal = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:No UID\r\nEND:VEVENT\r\nEND:VCALENDAR"
      status, = server.call(env('PUT', '/calendars/admin/cal/', body: whole_cal))
      status.should.equal 201

      items = storage.list_items('/calendars/admin/cal/')
      items.length.should.equal 1
      items[0][1][:body].should.include 'UID:'
    end

    it "PUT whole addressbook splits vcards into individual items" do
      server, storage = make_server
      storage.create_collection('/addressbooks/admin/')
      server.call(env('MKCOL', '/addressbooks/admin/addr/', body: '<resourcetype><addressbook/></resourcetype>'))

      whole_ab = "BEGIN:VCARD\r\nUID:c1\r\nFN:Alice\r\nEND:VCARD\r\nBEGIN:VCARD\r\nUID:c2\r\nFN:Bob\r\nEND:VCARD"
      status, = server.call(env('PUT', '/addressbooks/admin/addr/', body: whole_ab))
      status.should.equal 201

      items = storage.list_items('/addressbooks/admin/addr/')
      items.length.should.equal 2
    end

    it "PUT whole calendar: multiple events with same UID go to one item" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)

      whole_cal = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:recurring\r\nSUMMARY:Main\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:recurring\r\nRECURRENCE-ID:20260102T090000Z\r\nSUMMARY:Override\r\nEND:VEVENT\r\nEND:VCALENDAR"
      status, = server.call(env('PUT', '/calendars/admin/cal/', body: whole_cal))
      status.should.equal 201

      items = storage.list_items('/calendars/admin/cal/')
      items.length.should.equal 1
      items[0][1][:body].scan('BEGIN:VEVENT').length.should.equal 2
    end

    it "REPORT with expand-property returns expanded occurrences" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/rec.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\nUID:expand-int\r\nSUMMARY:Daily\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:">
          <d:prop>
            <c:calendar-data>
              <c:expand start="20260103T000000Z" end="20260105T000000Z"/>
            </c:calendar-data>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="20260103T000000Z" end="20260105T000000Z"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 207
      body[0].should.include 'RECURRENCE-ID'
      body[0].should.not.include 'RRULE'
    end

    it "REPORT with expand on non-recurring event returns it unchanged" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/single.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260103T090000Z\r\nDTEND:20260103T100000Z\r\nUID:single-expand\r\nSUMMARY:Once\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:">
          <d:prop>
            <c:calendar-data>
              <c:expand start="20260101T000000Z" end="20260201T000000Z"/>
            </c:calendar-data>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT"/>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 207
      body[0].should.include 'SUMMARY:Once'
      body[0].should.not.include 'RECURRENCE-ID'
    end

    it "REPORT with expand on event with override includes override" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nUID:ovr\r\nSUMMARY:Base\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nDTSTART:20260102T140000Z\r\nDTEND:20260102T150000Z\r\nRECURRENCE-ID:20260102T090000Z\r\nUID:ovr\r\nSUMMARY:Override\r\nEND:VEVENT\r\nEND:VCALENDAR"
      storage.put_item('/calendars/admin/cal/ovr.ics', ical, 'text/calendar')

      report_body = <<~XML
        <c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:">
          <d:prop>
            <c:calendar-data>
              <c:expand start="20260101T000000Z" end="20260104T000000Z"/>
            </c:calendar-data>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT"/>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 207
      body[0].should.include 'SUMMARY:Override'
      body[0].should.include 'SUMMARY:Base'
    end

    it "REPORT with expand + time-range returns only matching expanded events" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/rec.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=30\r\nUID:tr-expand\r\nSUMMARY:Daily\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      storage.put_item('/calendars/admin/cal/far.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260601T090000Z\r\nDTEND:20260601T100000Z\r\nUID:far-away\r\nSUMMARY:Far\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:">
          <d:prop>
            <c:calendar-data>
              <c:expand start="20260110T000000Z" end="20260112T000000Z"/>
            </c:calendar-data>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="20260110T000000Z" end="20260112T000000Z"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 207
      body[0].should.include 'rec.ics'
      body[0].should.not.include 'far.ics'
      body[0].should.include 'RECURRENCE-ID'
    end

    it "REPORT with expand respects EXDATE" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/ex.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\nEXDATE:20260102T090000Z\r\nUID:exd\r\nSUMMARY:Skip2\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:">
          <d:prop>
            <c:calendar-data>
              <c:expand start="20260101T000000Z" end="20260106T000000Z"/>
            </c:calendar-data>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT"/>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 207
      # 5 occurrences - 1 EXDATE = 4
      body[0].scan('RECURRENCE-ID').length.should.equal 4
    end

    it "REPORT with expand returns empty when range misses all occurrences" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/rec.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nUID:miss\r\nSUMMARY:Miss\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:">
          <d:prop>
            <c:calendar-data>
              <c:expand start="20260601T000000Z" end="20260701T000000Z"/>
            </c:calendar-data>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="20260601T000000Z" end="20260701T000000Z"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 207
      body[0].should.not.include 'rec.ics'
    end

    it "REPORT with expand on mixed recurring + non-recurring returns both" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      storage.put_item('/calendars/admin/cal/rec.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=30\r\nUID:mixed-rec\r\nSUMMARY:Recurring\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      storage.put_item('/calendars/admin/cal/once.ics',
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260110T120000Z\r\nDTEND:20260110T130000Z\r\nUID:mixed-once\r\nSUMMARY:Single\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')

      report_body = <<~XML
        <c:calendar-query xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:d="DAV:">
          <d:prop>
            <c:calendar-data>
              <c:expand start="20260110T000000Z" end="20260111T000000Z"/>
            </c:calendar-data>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="20260110T000000Z" end="20260111T000000Z"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
      XML

      status, _, body = server.call(env('REPORT', '/calendars/admin/cal/', body: report_body))
      status.should.equal 207
      body[0].should.include 'rec.ics'
      body[0].should.include 'once.ics'
    end

    it "ETag round-trip: GET returns etag, conditional GET returns 304" do
      server, storage = make_server
      storage.create_collection('/calendars/admin/cal/', type: :calendar)
      server.call(env('PUT', '/calendars/admin/cal/ev.ics', body: "BEGIN:VCALENDAR\r\nEND:VCALENDAR"))

      _, headers, = server.call(env('GET', '/calendars/admin/cal/ev.ics'))
      etag = headers['etag']
      etag.should.not.be.nil

      status, = server.call(env('GET', '/calendars/admin/cal/ev.ics', headers: { 'If-None-Match' => etag }))
      status.should.equal 304
    end
  end
end
