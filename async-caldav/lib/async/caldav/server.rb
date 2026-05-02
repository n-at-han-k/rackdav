# frozen_string_literal: true

require 'protocol/http/middleware'
require 'protocol/http/response'
require 'protocol/caldav'
require 'uri'

module Async
  module Caldav
    class Server < Protocol::HTTP::Middleware
      def initialize(delegate, storage:)
        super(delegate)
        @storage = storage
      end

      def call(request)
        method = request.method
        path = Protocol::Caldav::Path.new(request.path, storage_class: @storage)

        return handle_options(path) if method == 'OPTIONS'

        user = header_value(request, 'remote-user')
        unless user && !user.empty?
          return respond(401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, 'Unauthorized')
        end

        resource_type = resource_type_for(path)

        case method
        when 'PROPFIND'
          resource_type == :root ? handle_propfind_root(request, path, user) : handle_propfind(request, path)
        when 'PROPPATCH'
          resource_type == :root ? method_not_allowed : handle_proppatch(request, path, resource_type)
        when 'MKCALENDAR'
          handle_mkcalendar(request, path)
        when 'MKCOL'
          handle_mkcol(request, path)
        when 'GET'
          handle_get(request, path, resource_type)
        when 'HEAD'
          handle_head(request, path, resource_type)
        when 'PUT'
          resource_type == :root ? method_not_allowed : handle_put(request, path, resource_type)
        when 'DELETE'
          handle_delete(request, path, resource_type)
        when 'MOVE'
          resource_type == :root ? method_not_allowed : handle_move(request, path, resource_type)
        when 'REPORT'
          resource_type == :root ? method_not_allowed : handle_report(request, path, resource_type)
        else
          method_not_allowed
        end
      end

      private

      def header_value(request, name)
        val = request.headers[name]
        val.is_a?(Array) ? val.first : val
      end

      def resource_type_for(path)
        if path.start_with?('/calendars/')
          :calendar
        elsif path.start_with?('/addressbooks/')
          :addressbook
        else
          :root
        end
      end

      def respond(status, headers, body = '')
        h = Protocol::HTTP::Headers.new
        headers.each { |k, v| h.add(k, v) }
        Protocol::HTTP::Response[status, h, [body]]
      end

      def method_not_allowed
        respond(405, { 'content-type' => 'text/plain' }, 'Method Not Allowed')
      end

      # Lazy-load these to avoid circular deps at require time
      def dav_collection
        ::Caldav::DavCollection
      end

      def dav_item
        ::Caldav::DavItem
      end

      # --- OPTIONS ---

      def handle_options(path)
        headers = Protocol::Caldav::Constants::DAV_HEADERS.merge('content-length' => '0')
        respond(200, headers)
      end

      # --- PROPFIND ---

      def handle_propfind_root(request, path, user)
        depth = header_value(request, 'depth') || '1'

        discovery_props = []
        discovery_props << "<d:current-user-principal><d:href>/#{user}/</d:href></d:current-user-principal>"
        discovery_props << "<c:calendar-home-set><d:href>/calendars/#{user}/</d:href></c:calendar-home-set>"
        discovery_props << "<cr:addressbook-home-set><d:href>/addressbooks/#{user}/</d:href></cr:addressbook-home-set>"

        response_xml = <<~XML
          <d:response>
            <d:href>#{Protocol::Caldav::Xml.escape(path.to_s)}</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                #{discovery_props.join("\n              ")}
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML

        responses = [response_xml]

        if depth == '1'
          dav_collection.list(path).each do |col|
            responses << col.to_propfind_xml
          end
        end

        respond(207, { 'content-type' => 'text/xml; charset=utf-8' }, Protocol::Caldav::Multistatus.new(responses).to_xml)
      end

      def handle_propfind(request, path)
        depth = header_value(request, 'depth') || '1'
        collection = dav_collection.find(path)
        item = dav_item.find(path)

        if !collection && !item && path.depth > 2
          return respond(404, { 'content-type' => 'text/xml; charset=utf-8' }, 'Not Found')
        end

        responses = []
        if collection
          responses << collection.to_propfind_xml
        elsif item
          responses << item.to_propfind_xml
        else
          responses << path.to_propfind_xml
        end

        if depth == '1'
          dav_collection.list(path).each { |col| responses << col.to_propfind_xml }
          dav_item.list(path).each { |itm| responses << itm.to_propfind_xml }
        end

        respond(207, { 'content-type' => 'text/xml; charset=utf-8', 'cache-control' => 'no-store' }, Protocol::Caldav::Multistatus.new(responses).to_xml)
      end

      # --- PROPPATCH ---

      def handle_proppatch(request, path, resource_type)
        path = path.ensure_trailing_slash
        collection = dav_collection.find(path)
        return respond(404, { 'content-type' => 'text/xml; charset=utf-8' }, 'Not Found') unless collection

        body = request.read || ''
        updates = {}
        dn = Protocol::Caldav::Xml.extract_value(body, 'displayname')
        updates[:displayname] = dn if dn

        if resource_type == :calendar
          desc = Protocol::Caldav::Xml.extract_value(body, 'calendar-description')
          updates[:description] = desc if desc
          color = Protocol::Caldav::Xml.extract_value(body, 'calendar-color')
          updates[:color] = color if color
        end

        if body.include?('<d:remove') || body.include?('<D:remove')
          updates[:displayname] = nil if body.match?(/<[^>]*remove[^>]*>.*displayname/m) && !dn
          if resource_type == :calendar
            desc = Protocol::Caldav::Xml.extract_value(body, 'calendar-description')
            updates[:description] = nil if body.match?(/<[^>]*remove[^>]*>.*calendar-description/m) && !desc
            color = Protocol::Caldav::Xml.extract_value(body, 'calendar-color')
            updates[:color] = nil if body.match?(/<[^>]*remove[^>]*>.*calendar-color/m) && !color
          end
        end

        collection.update(updates)

        result = Protocol::Caldav::Multistatus.new([<<~XML]).to_xml
          <d:response>
            <d:href>#{Protocol::Caldav::Xml.escape(path.to_s)}</d:href>
            <d:propstat>
              <d:prop/>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML

        respond(207, { 'content-type' => 'text/xml; charset=utf-8' }, result)
      end

      # --- MKCALENDAR / MKCOL ---

      def handle_mkcalendar(request, path)
        path = path.ensure_trailing_slash
        return respond(405, { 'content-type' => 'text/plain' }, 'Collection already exists') if dav_collection.exists?(path)
        return respond(409, { 'content-type' => 'text/plain' }, 'Parent does not exist') unless path.parent_exists?

        body = request.read || ''
        dav_collection.create(path,
          type: :calendar,
          displayname: Protocol::Caldav::Xml.extract_value(body, 'displayname'),
          description: Protocol::Caldav::Xml.extract_value(body, 'calendar-description'),
          color: Protocol::Caldav::Xml.extract_value(body, 'calendar-color')
        )
        respond(201, { 'content-type' => 'text/xml; charset=utf-8' })
      end

      def handle_mkcol(request, path)
        path = path.ensure_trailing_slash
        return respond(405, { 'content-type' => 'text/plain' }, 'Collection already exists') if dav_collection.exists?(path)
        return respond(409, { 'content-type' => 'text/plain' }, 'Parent does not exist') unless path.parent_exists?

        body = request.read || ''
        col_type = body.include?('addressbook') ? :addressbook : :collection
        dav_collection.create(path, type: col_type, displayname: Protocol::Caldav::Xml.extract_value(body, 'displayname'))
        respond(201, { 'content-type' => 'text/xml; charset=utf-8' })
      end

      # --- GET ---

      def handle_get(request, path, resource_type)
        if resource_type == :root
          if path.to_s == '/' || path.start_with?('/.well-known/')
            return respond(200, { 'content-type' => 'text/html' }, 'Caldav::App')
          else
            return respond(404, { 'content-type' => 'text/plain' }, 'Not Found')
          end
        end

        item = dav_item.find(path)
        collection = dav_collection.find(path)

        if item
          if_none_match = header_value(request, 'if-none-match')
          if if_none_match == item.etag
            respond(304, { 'etag' => item.etag, 'cache-control' => 'private, no-cache' })
          else
            respond(200, { 'content-type' => item.content_type, 'etag' => item.etag, 'cache-control' => 'private, no-cache' }, item.body)
          end
        elsif collection
          items = dav_item.list(path)
          bodies = items.map(&:body).join("\n")
          ct = resource_type == :calendar ? 'text/calendar; charset=utf-8' : 'text/vcard; charset=utf-8'
          respond(200, { 'content-type' => ct }, bodies)
        elsif path.depth <= 2
          respond(200, { 'content-type' => 'text/html' }, 'Caldav::App')
        else
          respond(404, { 'content-type' => 'text/plain' }, 'Not Found')
        end
      end

      # --- HEAD ---

      def handle_head(request, path, resource_type)
        response = handle_get(request, path, resource_type)
        Protocol::HTTP::Response[response.status, response.headers, []]
      end

      # --- PUT ---

      def handle_put(request, path, resource_type)
        body = request.read

        if body.nil? || body.strip.empty?
          return respond(400, { 'content-type' => 'text/plain' }, 'Empty body')
        end

        if resource_type == :calendar && !body.strip.start_with?('BEGIN:VCALENDAR')
          return respond(400, { 'content-type' => 'text/plain' }, 'Invalid calendar data')
        elsif resource_type == :addressbook && !body.strip.start_with?('BEGIN:VCARD')
          return respond(400, { 'content-type' => 'text/plain' }, 'Invalid vCard data')
        end

        existing = dav_item.find(path)
        if_match = header_value(request, 'if-match')
        if_none_match = header_value(request, 'if-none-match')

        if if_match && (!existing || existing.etag != if_match)
          return respond(412, { 'content-type' => 'text/plain' }, 'If-Match precondition failed')
        end

        if if_none_match == '*' && existing
          return respond(412, { 'content-type' => 'text/plain' }, 'If-None-Match precondition failed')
        end

        uid_match = body.match(/^UID:(.+)$/i)
        if uid_match && !existing
          uid = uid_match[1].strip
          collection_path = path.parent.to_s
          @storage.list_items(collection_path).each do |item_path, item_data|
            next if item_path == path.to_s
            if item_data[:body].match?(/^UID:#{Regexp.escape(uid)}$/i)
              return respond(409, { 'content-type' => 'text/xml; charset=utf-8' }, 'UID conflict')
            end
          end
        end

        default_ct = resource_type == :calendar ? 'text/calendar' : 'text/vcard'
        content_type = header_value(request, 'content-type') || default_ct
        item = dav_item.create(path, body: body, content_type: content_type)

        respond(item.new? ? 201 : 204, { 'etag' => item.etag, 'content-type' => 'text/plain' })
      end

      # --- DELETE ---

      def handle_delete(request, path, resource_type)
        return method_not_allowed if resource_type == :root

        item = dav_item.find(path)
        if item
          item.delete
          respond(204, {})
        elsif dav_collection.exists?(path.ensure_trailing_slash)
          dav_collection.find(path.ensure_trailing_slash).delete
          respond(204, {})
        else
          respond(404, { 'content-type' => 'text/plain' }, 'Not Found')
        end
      end

      # --- MOVE ---

      def handle_move(request, path, resource_type)
        destination = header_value(request, 'destination')
        return respond(400, { 'content-type' => 'text/plain' }, 'Missing Destination header') unless destination

        to_path = Protocol::Caldav::Path.new(URI.parse(destination).path, storage_class: @storage)
        overwrite = header_value(request, 'overwrite') != 'F'
        item = dav_item.find(path)

        return respond(404, { 'content-type' => 'text/plain' }, 'Not Found') unless item

        existing = dav_item.find(to_path)
        return respond(412, { 'content-type' => 'text/plain' }, 'Precondition Failed') if existing && !overwrite

        if resource_type == :calendar
          uid_match = item.body.match(/^UID:(.+)$/i)
          if uid_match && !existing
            uid = uid_match[1].strip
            dest_col = to_path.parent.to_s
            conflict = @storage.list_items(dest_col).any? do |ip, id|
              ip != path.to_s && id[:body].match?(/^UID:#{Regexp.escape(uid)}$/i)
            end
            return respond(409, { 'content-type' => 'text/xml; charset=utf-8' }, 'UID conflict') if conflict
          end
        end

        item.move_to(to_path)
        respond(existing ? 204 : 201, {})
      end

      # --- REPORT ---

      def handle_report(request, path, resource_type)
        body = request.read
        items = dav_item.list(path)

        if body && !body.empty?
          if resource_type == :calendar
            filter = Protocol::Caldav::Filter::Parser.parse_calendar(body)
            if filter
              items = items.select do |item|
                component = Protocol::Caldav::Ical::Parser.parse(item.body)
                component && Protocol::Caldav::Filter::Match.calendar?(filter, component)
              end
            end
          elsif resource_type == :addressbook
            filter = Protocol::Caldav::Filter::Parser.parse_addressbook(body)
            if filter
              items = items.select do |item|
                card = Protocol::Caldav::Vcard::Parser.parse(item.body)
                card && Protocol::Caldav::Filter::Match.addressbook?(filter, card)
              end
            end
          end
        end

        data_tag = resource_type == :calendar ? 'c:calendar-data' : 'cr:address-data'
        responses = items.map { |item| item.to_report_xml(data_tag: data_tag) }

        respond(207, { 'content-type' => 'text/xml; charset=utf-8', 'cache-control' => 'no-store' }, Protocol::Caldav::Multistatus.new(responses).to_xml)
      end
    end
  end
end
