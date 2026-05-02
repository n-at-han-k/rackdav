# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Handlers
      module Report
        module_function

        def call(path:, body:, storage:, resource_type: nil, **)
          # Detect sync-collection report
          if body&.include?('sync-collection')
            return handle_sync_collection(path: path, body: body, storage: storage)
          end
          col_path = path.ensure_trailing_slash
          items = storage.list_items(col_path.to_s)

          data_tag = resource_type == :addressbook ? 'cr:address-data' : 'c:calendar-data'

          # Parse expand-property if present
          expand_range = parse_expand(body)

          # Parse filter if present (multiget requests have no filter — ignore parse errors)
          filter = begin
            if resource_type == :addressbook
              Protocol::Caldav::Filter::Parser.parse_addressbook(body)
            else
              Protocol::Caldav::Filter::Parser.parse_calendar(body)
            end
          rescue Protocol::Caldav::ParseError
            nil
          end

          # Check for multiget (href list)
          hrefs = extract_hrefs(body)

          if hrefs && !hrefs.empty?
            # Calendar-multiget / addressbook-multiget
            multi = storage.get_multi(hrefs)
            items = multi.select { |_, data| data }
          end

          responses = items.filter_map do |item_path, data|
            next unless data

            # Apply filter
            if filter
              if resource_type == :addressbook
                card = Protocol::Caldav::Vcard::Parser.parse(data[:body])
                next unless card && Protocol::Caldav::Filter::Match.addressbook?(filter, card)
              else
                component = Protocol::Caldav::Ical::Parser.parse(data[:body])
                next unless component && Protocol::Caldav::Filter::Match.calendar?(filter, component)
              end
            end

            item_body = data[:body]

            # Apply expand if requested (calendar items only)
            if expand_range && resource_type != :addressbook
              component = Protocol::Caldav::Ical::Parser.parse(item_body)
              if component
                item_body = Protocol::Caldav::Ical::Expand.expand(
                  component,
                  range_start: expand_range[:start],
                  range_end: expand_range[:end]
                )
              end
            end

            item_p = Protocol::Caldav::Path.new(item_path, storage_class: storage)
            item = Protocol::Caldav::Item.new(
              path: item_p,
              body: item_body,
              content_type: data[:content_type],
              etag: data[:etag]
            )
            item.to_report_xml(data_tag: data_tag)
          end

          xml = Protocol::Caldav::Multistatus.new(responses).to_xml
          [207, Protocol::Caldav::Constants::DAV_HEADERS, [xml]]
        end

        def handle_sync_collection(path:, body:, storage:)
          col_path = path.ensure_trailing_slash.to_s

          # Extract sync-token from request
          token_match = body.match(/<[^>]*sync-token[^>]*>(?:<!\[CDATA\[)?([^<\]]*?)(?:\]\]>)?</)
          old_token = token_match ? token_match[1].strip : nil
          old_token = nil if old_token&.empty?

          if old_token
            # Incremental sync
            result = storage.sync_changes(col_path, old_token)
            unless result
              # Invalid token
              error_xml = <<~XML
                <?xml version="1.0" encoding="UTF-8"?>
                <d:error xmlns:d="DAV:">
                  <d:valid-sync-token/>
                </d:error>
              XML
              return [403, { 'content-type' => 'application/xml' }, [error_xml]]
            end

            new_token, changes = result
            responses = changes.map do |item_path, status|
              if status == :deleted
                <<~XML
                  <d:response>
                    <d:href>#{Protocol::Caldav::Xml.escape(item_path)}</d:href>
                    <d:status>HTTP/1.1 404 Not Found</d:status>
                  </d:response>
                XML
              else
                etag = storage.etag(item_path)
                <<~XML
                  <d:response>
                    <d:href>#{Protocol::Caldav::Xml.escape(item_path)}</d:href>
                    <d:propstat>
                      <d:prop>
                        <d:getetag>#{Protocol::Caldav::Xml.escape(etag)}</d:getetag>
                      </d:prop>
                      <d:status>HTTP/1.1 200 OK</d:status>
                    </d:propstat>
                  </d:response>
                XML
              end
            end
          else
            # Initial sync — return all items
            new_token = storage.snapshot_sync(col_path)
            items = storage.list_items(col_path)
            responses = items.map do |item_path, data|
              <<~XML
                <d:response>
                  <d:href>#{Protocol::Caldav::Xml.escape(item_path)}</d:href>
                  <d:propstat>
                    <d:prop>
                      <d:getetag>#{Protocol::Caldav::Xml.escape(data[:etag])}</d:getetag>
                    </d:prop>
                    <d:status>HTTP/1.1 200 OK</d:status>
                  </d:propstat>
                </d:response>
              XML
            end
          end

          xml = <<~XML
            <?xml version="1.0" encoding="UTF-8"?>
            <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
            #{responses.join}
            <d:sync-token>#{Protocol::Caldav::Xml.escape(new_token)}</d:sync-token>
            </d:multistatus>
          XML

          [207, Protocol::Caldav::Constants::DAV_HEADERS, [xml]]
        end

        def parse_expand(body)
          return nil unless body
          match = body.match(/<[^>]*expand[^>]*start\s*=\s*["']([^"']+)["'][^>]*end\s*=\s*["']([^"']+)["']/)
          return nil unless match
          start_time = Protocol::Caldav::Filter::Match.send(:parse_datetime_string, match[1])
          end_time = Protocol::Caldav::Filter::Match.send(:parse_datetime_string, match[2])
          return nil unless start_time && end_time
          { start: start_time, end: end_time }
        end

        def extract_hrefs(body)
          return nil unless body
          body.scan(/<[^>]*href[^>]*>([^<]+)</).map { |m| m[0].strip }
        end

        private_class_method :extract_hrefs, :handle_sync_collection, :parse_expand
      end
    end
  end
end

test do
  def normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  describe "Async::Caldav::Handlers::Report" do
    def call(**opts)
      Async::Caldav::Handlers::Report.call(**opts)
    end

    def path(p, s)
      Protocol::Caldav::Path.new(p, storage_class: s)
    end

    it "returns 207 with all items when no filter" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/')
      s.put_item('/cal/a.ics', "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:A\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      s.put_item('/cal/b.ics', "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:B\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      status, _, body = call(path: path('/cal/', s), storage: s, body: '', resource_type: :calendar)
      status.should.equal 207
      body[0].should.include 'a.ics'
      body[0].should.include 'b.ics'
    end

    it "filters items by comp-filter" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/')
      s.put_item('/cal/ev.ics', "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR", 'text/calendar')
      s.put_item('/cal/td.ics', "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nSUMMARY:Task\r\nEND:VTODO\r\nEND:VCALENDAR", 'text/calendar')

      filter_xml = <<~XML
        <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
          <c:comp-filter name="VCALENDAR">
            <c:comp-filter name="VEVENT"/>
          </c:comp-filter>
        </c:filter>
      XML

      _, _, body = call(path: path('/cal/', s), storage: s, body: filter_xml, resource_type: :calendar)
      body[0].should.include 'ev.ics'
      body[0].should.not.include 'td.ics'
    end

    it "uses c:calendar-data tag for calendars" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/')
      s.put_item('/cal/ev.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')
      _, _, body = call(path: path('/cal/', s), storage: s, body: '', resource_type: :calendar)
      body[0].should.include 'c:calendar-data'
    end

    it "uses cr:address-data tag for addressbooks" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/addr/')
      s.put_item('/addr/c.vcf', "BEGIN:VCARD\r\nFN:John\r\nEND:VCARD", 'text/vcard')
      _, _, body = call(path: path('/addr/', s), storage: s, body: '', resource_type: :addressbook)
      body[0].should.include 'cr:address-data'
    end

    it "handles calendar-multiget with hrefs" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection('/cal/')
      s.put_item('/cal/a.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')
      s.put_item('/cal/b.ics', "BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'text/calendar')

      multiget_body = '<d:href>/cal/a.ics</d:href>'
      _, _, body = call(path: path('/cal/', s), storage: s, body: multiget_body, resource_type: :calendar)
      body[0].should.include 'a.ics'
      body[0].should.not.include 'b.ics'
    end
  end
end
