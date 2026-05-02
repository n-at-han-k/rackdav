# frozen_string_literal: true

require "bundler/setup"
require "caldav"
require 'uri'

module Caldav
  class App2
    def initialize(storage:)
      @storage = storage
    end

    def call(env)
      env['caldav.storage'] = @storage
      request = Rack::Request.new(env)
      method = request.request_method
      path = Path.new(request.path_info, storage_class: @storage)

      # OPTIONS does not require auth
      return handle_options(path) if method == 'OPTIONS'

      user = env['dav.user']
      unless user.present?
        return [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
      end

      resource_type = resource_type_for(path)

      case method
      when 'PROPFIND'
        resource_type == :root ? handle_propfind_root(env, path, user) : handle_propfind(env, path)
      when 'PROPPATCH'
        resource_type == :root ? method_not_allowed : handle_proppatch(env, path, resource_type)
      when 'MKCALENDAR'
        handle_mkcalendar(env, path)
      when 'MKCOL'
        handle_mkcol(env, path)
      when 'GET'
        handle_get(env, path, resource_type)
      when 'HEAD'
        handle_head(env, path, resource_type)
      when 'PUT'
        resource_type == :root ? method_not_allowed : handle_put(env, path, resource_type)
      when 'DELETE'
        handle_delete(env, path, resource_type)
      when 'MOVE'
        resource_type == :root ? method_not_allowed : handle_move(env, path, resource_type)
      when 'REPORT'
        resource_type == :root ? method_not_allowed : handle_report(env, path, resource_type)
      else
        method_not_allowed
      end
    end

    private

    def resource_type_for(path)
      if path.start_with?('/calendars/')
        :calendar
      elsif path.start_with?('/addressbooks/')
        :addressbook
      else
        :root
      end
    end

    def method_not_allowed
      [405, { 'content-type' => 'text/plain' }, ['Method Not Allowed']]
    end

    # --- OPTIONS ---

    def handle_options(path)
      [200, DAV_HEADERS.merge('content-length' => '0'), []]
    end

    # --- PROPFIND ---

    def handle_propfind_root(env, path, user)
      depth = env['HTTP_DEPTH'] || '1'

      discovery_props = []
      discovery_props << "<d:current-user-principal><d:href>/#{user}/</d:href></d:current-user-principal>"
      discovery_props << "<c:calendar-home-set><d:href>/calendars/#{user}/</d:href></c:calendar-home-set>"
      discovery_props << "<cr:addressbook-home-set><d:href>/addressbooks/#{user}/</d:href></cr:addressbook-home-set>"

      response_xml = <<~XML
        <d:response>
          <d:href>#{Xml.escape(path.to_s)}</d:href>
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
        DavCollection.list(path).each do |col|
          responses << col.to_propfind_xml
        end
      end

      [207, { 'content-type' => 'text/xml; charset=utf-8' }, [Multistatus.new(responses).to_xml]]
    end

    def handle_propfind(env, path)
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

        [207, { 'content-type' => 'text/xml; charset=utf-8', 'cache-control' => 'no-store' }, [Multistatus.new(responses).to_xml]]
      end
    end

    # --- PROPPATCH ---

    def handle_proppatch(env, path, resource_type)
      path = path.ensure_trailing_slash
      collection = DavCollection.find(path)

      if !collection
        [404, { 'content-type' => 'text/xml; charset=utf-8' }, ['Not Found']]
      else
        body = Rack::Request.new(env).body&.read || ''
        updates = {}
        dn = Xml.extract_value(body, 'displayname')
        updates[:displayname] = dn if dn

        if resource_type == :calendar
          desc = Xml.extract_value(body, 'calendar-description')
          updates[:description] = desc if desc
          color = Xml.extract_value(body, 'calendar-color')
          updates[:color] = color if color
        end

        # Handle d:remove
        if body.include?('<d:remove') || body.include?('<D:remove')
          updates[:displayname] = nil if body.match?(/<[^>]*remove[^>]*>.*displayname/m) && !dn
          if resource_type == :calendar
            desc = Xml.extract_value(body, 'calendar-description')
            updates[:description] = nil if body.match?(/<[^>]*remove[^>]*>.*calendar-description/m) && !desc
            color = Xml.extract_value(body, 'calendar-color')
            updates[:color] = nil if body.match?(/<[^>]*remove[^>]*>.*calendar-color/m) && !color
          end
        end

        collection.update(updates)

        result = Multistatus.new([<<~XML]).to_xml
          <d:response>
            <d:href>#{Xml.escape(path.to_s)}</d:href>
            <d:propstat>
              <d:prop/>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML

        [207, { 'content-type' => 'text/xml; charset=utf-8' }, [result]]
      end
    end

    # --- MKCALENDAR / MKCOL ---

    def handle_mkcalendar(env, path)
      path = path.ensure_trailing_slash

      if DavCollection.exists?(path)
        [405, { 'content-type' => 'text/plain' }, ['Collection already exists']]
      elsif !path.parent_exists?
        [409, { 'content-type' => 'text/plain' }, ['Parent does not exist']]
      else
        body = Rack::Request.new(env).body&.read || ''
        displayname = Xml.extract_value(body, 'displayname')
        description = Xml.extract_value(body, 'calendar-description')
        color = Xml.extract_value(body, 'calendar-color')

        DavCollection.create(path,
          type: :calendar,
          displayname: displayname,
          description: description,
          color: color
        )

        [201, { 'content-type' => 'text/xml; charset=utf-8' }, ['']]
      end
    end

    def handle_mkcol(env, path)
      path = path.ensure_trailing_slash

      if DavCollection.exists?(path)
        [405, { 'content-type' => 'text/plain' }, ['Collection already exists']]
      elsif !path.parent_exists?
        [409, { 'content-type' => 'text/plain' }, ['Parent does not exist']]
      else
        body = Rack::Request.new(env).body&.read || ''
        displayname = Xml.extract_value(body, 'displayname')
        col_type = body.include?('addressbook') ? :addressbook : :collection

        DavCollection.create(path, type: col_type, displayname: displayname)

        [201, { 'content-type' => 'text/xml; charset=utf-8' }, ['']]
      end
    end

    # --- GET ---

    def handle_get(env, path, resource_type)
      if resource_type == :root
        if path.to_s == '/' || path.start_with?('/.well-known/')
          return [200, { 'content-type' => 'text/html' }, ['Caldav::App']]
        else
          return [404, { 'content-type' => 'text/plain' }, ['Not Found']]
        end
      end

      item = DavItem.find(path)
      collection = DavCollection.find(path)

      if item
        if env['HTTP_IF_NONE_MATCH'] == item.etag
          [304, { 'etag' => item.etag, 'cache-control' => 'private, no-cache' }, []]
        else
          [200, { 'content-type' => item.content_type, 'etag' => item.etag, 'cache-control' => 'private, no-cache' }, [item.body]]
        end
      elsif collection
        items = DavItem.list(path)
        bodies = items.map(&:body).join("\n")
        ct = resource_type == :calendar ? 'text/calendar; charset=utf-8' : 'text/vcard; charset=utf-8'
        [200, { 'content-type' => ct }, [bodies]]
      elsif path.depth <= 2
        [200, { 'content-type' => 'text/html' }, ['Caldav::App']]
      else
        [404, { 'content-type' => 'text/plain' }, ['Not Found']]
      end
    end

    # --- HEAD ---

    def handle_head(env, path, resource_type)
      env['REQUEST_METHOD'] = 'GET'
      status, headers, _body = handle_get(env, path, resource_type)
      [status, headers, []]
    end

    # --- PUT ---

    def handle_put(env, path, resource_type)
      body = Rack::Request.new(env).body&.read

      if body.nil? || body.strip.empty?
        return [400, { 'content-type' => 'text/plain' }, ['Empty body']]
      end

      if resource_type == :calendar && !body.strip.start_with?('BEGIN:VCALENDAR')
        return [400, { 'content-type' => 'text/plain' }, ['Invalid calendar data']]
      elsif resource_type == :addressbook && !body.strip.start_with?('BEGIN:VCARD')
        return [400, { 'content-type' => 'text/plain' }, ['Invalid vCard data']]
      end

      existing = DavItem.find(path)
      if_match = env['HTTP_IF_MATCH']
      if_none_match = env['HTTP_IF_NONE_MATCH']

      if if_match && (!existing || existing.etag != if_match)
        return [412, { 'content-type' => 'text/plain' }, ['If-Match precondition failed']]
      end

      if if_none_match == '*' && existing
        return [412, { 'content-type' => 'text/plain' }, ['If-None-Match precondition failed']]
      end

      # Check for duplicate UID in the collection
      uid_match = body.match(/^UID:(.+)$/i)
      if uid_match && !existing
        uid = uid_match[1].strip
        collection_path = path.parent.to_s
        if @storage.respond_to?(:list_items)
          @storage.list_items(collection_path).each do |item_path, item_data|
            next if item_path == path.to_s
            if item_data[:body].match?(/^UID:#{Regexp.escape(uid)}$/i)
              return [409, { 'content-type' => 'text/xml; charset=utf-8' }, ['UID conflict']]
            end
          end
        end
      end

      default_ct = resource_type == :calendar ? 'text/calendar' : 'text/vcard'
      content_type = Rack::Request.new(env).content_type || default_ct
      item = DavItem.create(path, body: body, content_type: content_type)

      [item.new? ? 201 : 204, { 'etag' => item.etag, 'content-type' => 'text/plain' }, ['']]
    end

    # --- DELETE ---

    def handle_delete(env, path, resource_type)
      if resource_type == :root
        # Current behavior for DELETE / is handled by calendar/contacts delete
        # which pass through to each other, ultimately hitting fallback (405)
        return method_not_allowed
      end

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

    # --- MOVE ---

    def handle_move(env, path, resource_type)
      destination = env['HTTP_DESTINATION']

      if !destination
        return [400, { 'content-type' => 'text/plain' }, ['Missing Destination header']]
      end

      to_path = Path.new(URI.parse(destination).path, storage_class: @storage)
      overwrite = env['HTTP_OVERWRITE'] != 'F'
      item = DavItem.find(path)

      if !item
        [404, { 'content-type' => 'text/plain' }, ['Not Found']]
      else
        existing = DavItem.find(to_path)

        if existing && !overwrite
          [412, { 'content-type' => 'text/plain' }, ['Precondition Failed']]
        else
          # Calendar MOVE checks for UID conflict in destination collection
          if resource_type == :calendar
            uid_match = item.body.match(/^UID:(.+)$/i)
            if uid_match && !existing
              uid = uid_match[1].strip
              dest_col = to_path.parent.to_s
              if @storage.respond_to?(:list_items)
                conflict = @storage.list_items(dest_col).any? do |ip, id|
                  ip != path.to_s && id[:body].match?(/^UID:#{Regexp.escape(uid)}$/i)
                end
                if conflict
                  return [409, { 'content-type' => 'text/xml; charset=utf-8' }, ['UID conflict']]
                end
              end
            end
          end

          item.move_to(to_path)
          [existing ? 204 : 201, {}, ['']]
        end
      end
    end

    # --- REPORT ---

    def handle_report(env, path, resource_type)
      body = Rack::Request.new(env).body&.read
      items = DavItem.list(path)

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

      [207, { 'content-type' => 'text/xml; charset=utf-8', 'cache-control' => 'no-store' }, [Multistatus.new(responses).to_xml]]
    end
  end
end
