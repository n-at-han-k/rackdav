# frozen_string_literal: true

require 'rack'
require 'base64'
require 'digest'

module Caldav
  class App
    # In-memory store shared across requests within one App instance.
    # collections: { path => { type:, displayname:, description:, color:, props: {} } }
    # items:       { path => { body:, content_type:, etag: } }
    def initialize
      @collections = {}
      @items = {}
    end

    def call(env)
      request = Rack::Request.new(env)

      # OPTIONS does not require auth
      return [200, dav_headers.merge('content-length' => '0'), []] if request.request_method == 'OPTIONS'

      # Authenticate all other requests
      auth_result = authenticate(env)
      return auth_result unless auth_result.nil?

      case request.request_method
      when 'PROPFIND'
        handle_propfind(request)
      when 'MKCALENDAR'
        handle_mkcalendar(request)
      when 'MKCOL'
        handle_mkcol(request)
      when 'PUT'
        handle_put(request)
      when 'GET'
        handle_get(request)
      when 'DELETE'
        handle_delete(request)
      when 'PROPPATCH'
        handle_proppatch(request)
      when 'REPORT'
        handle_report(request)
      else
        [405, { 'content-type' => 'text/plain' }, ['Method Not Allowed']]
      end
    end

    private

    # ---------------------------------------------------------------------------
    # Authentication
    # ---------------------------------------------------------------------------

    def authenticate(env)
      auth = env['HTTP_AUTHORIZATION'] || env['HTTP_HTTP_AUTHORIZATION']
      return unauthorized_response unless auth

      scheme, credentials = auth.split(' ', 2)
      return unauthorized_response unless scheme&.downcase == 'basic' && credentials

      decoded = Base64.decode64(credentials)
      username, password = decoded.split(':', 2)

      # Simple auth: password must equal username
      return unauthorized_response unless username && password && username == password

      nil # auth OK
    end

    def unauthorized_response
      [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
    end

    # ---------------------------------------------------------------------------
    # DAV headers
    # ---------------------------------------------------------------------------

    def dav_headers
      {
        'dav' => '1, 2, 3, calendar-access, addressbook',
        'allow' => 'OPTIONS, GET, PUT, DELETE, PROPFIND, PROPPATCH, MKCALENDAR, MKCOL, REPORT',
        'content-type' => 'text/xml; charset=utf-8'
      }
    end

    # ---------------------------------------------------------------------------
    # Path helpers
    # ---------------------------------------------------------------------------

    def normalize_path(path)
      # Ensure trailing slash for collection-like paths (no file extension)
      p = path.gsub(%r{/+}, '/')
      p = "/#{p}" unless p.start_with?('/')
      p
    end

    def parent_path(path)
      parts = path.chomp('/').split('/')
      return '/' if parts.length <= 1

      "#{parts[0..-2].join('/')}/"
    end

    def parent_exists?(path)
      parent = parent_path(path)
      # Root and first two levels always "exist" (e.g., /, /calendars/, /calendars/admin/)
      depth = parent.chomp('/').split('/').reject(&:empty?).length
      return true if depth <= 2

      @collections.key?(parent)
    end

    # ---------------------------------------------------------------------------
    # PROPFIND
    # ---------------------------------------------------------------------------

    def handle_propfind(request)
      path = normalize_path(request.path_info)
      depth = request.env['HTTP_DEPTH'] || '1'

      # Check if this is a known resource
      is_root = path == '/'
      depth_parts = path.chomp('/').split('/').reject(&:empty?).length
      is_user_namespace = depth_parts <= 2 # e.g., /calendars/ or /calendars/admin/
      is_collection = @collections.key?(path)
      is_item = @items.key?(path)

      unless is_root || is_user_namespace || is_collection || is_item
        return [404, { 'content-type' => 'text/xml; charset=utf-8' }, ['Not Found']]
      end

      responses = []

      # The resource itself
      if is_collection
        col = @collections[path]
        responses << propfind_response_for_collection(path, col)
      elsif is_item
        item = @items[path]
        responses << propfind_response_for_item(path, item)
      else
        responses << propfind_response_for_path(path)
      end

      # Depth 1: list children
      if depth == '1'
        # Child collections
        @collections.each do |col_path, col|
          next if col_path == path

          responses << propfind_response_for_collection(col_path, col) if child_of?(col_path, path)
        end

        # Child items
        @items.each do |item_path, item|
          responses << propfind_response_for_item(item_path, item) if child_of?(item_path, path)
        end
      end

      body = multistatus_xml(responses)
      [207, { 'content-type' => 'text/xml; charset=utf-8' }, [body]]
    end

    def child_of?(child, parent)
      parent_normalized = parent.end_with?('/') ? parent : "#{parent}/"
      return false unless child.start_with?(parent_normalized)

      remainder = child[parent_normalized.length..]
      # Direct child: no more slashes (or just a trailing one)
      remainder.chomp('/').count('/').zero? && !remainder.chomp('/').empty?
    end

    def propfind_response_for_path(path)
      <<~XML
        <d:response>
          <d:href>#{escape_xml(path)}</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      XML
    end

    def propfind_response_for_collection(path, col)
      props = []
      props << '<d:resourcetype><d:collection/></d:resourcetype>'

      if col[:type] == :calendar
        props << '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>'
      elsif col[:type] == :addressbook
        props << '<d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>'
      end

      props << "<d:displayname>#{escape_xml(col[:displayname])}</d:displayname>" if col[:displayname]
      props << "<c:calendar-description>#{escape_xml(col[:description])}</c:calendar-description>" if col[:description]
      props << "<x:calendar-color>#{escape_xml(col[:color])}</x:calendar-color>" if col[:color]

      # Include any extra props set via PROPPATCH
      (col[:props] || {}).each do |key, value|
        props << "<#{key}>#{escape_xml(value)}</#{key}>"
      end

      <<~XML
        <d:response>
          <d:href>#{escape_xml(path)}</d:href>
          <d:propstat>
            <d:prop>
              #{props.join("\n          ")}
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      XML
    end

    def propfind_response_for_item(path, item)
      <<~XML
        <d:response>
          <d:href>#{escape_xml(path)}</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{escape_xml(item[:etag])}</d:getetag>
              <d:getcontenttype>#{escape_xml(item[:content_type])}</d:getcontenttype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      XML
    end

    # ---------------------------------------------------------------------------
    # MKCALENDAR
    # ---------------------------------------------------------------------------

    def handle_mkcalendar(request)
      path = normalize_path(request.path_info)
      path = "#{path}/" unless path.end_with?('/')

      # Check if already exists
      return [405, { 'content-type' => 'text/plain' }, ['Collection already exists']] if @collections.key?(path)

      # Check parent exists
      return [409, { 'content-type' => 'text/plain' }, ['Parent does not exist']] unless parent_exists?(path)

      # Parse properties from request body
      body = request.body.read
      displayname = extract_xml_value(body, 'displayname')
      description = extract_xml_value(body, 'calendar-description')
      color = extract_xml_value(body, 'calendar-color')

      @collections[path] = {
        type: :calendar,
        displayname: displayname,
        description: description,
        color: color,
        props: {}
      }

      [201, { 'content-type' => 'text/xml; charset=utf-8' }, ['']]
    end

    # ---------------------------------------------------------------------------
    # MKCOL
    # ---------------------------------------------------------------------------

    def handle_mkcol(request)
      path = normalize_path(request.path_info)
      path = "#{path}/" unless path.end_with?('/')

      return [405, { 'content-type' => 'text/plain' }, ['Collection already exists']] if @collections.key?(path)
      return [409, { 'content-type' => 'text/plain' }, ['Parent does not exist']] unless parent_exists?(path)

      body = request.body.read
      displayname = extract_xml_value(body, 'displayname')

      col_type = if body.include?('addressbook')
                   :addressbook
                 else
                   :collection
                 end

      @collections[path] = {
        type: col_type,
        displayname: displayname,
        description: nil,
        color: nil,
        props: {}
      }

      [201, { 'content-type' => 'text/xml; charset=utf-8' }, ['']]
    end

    # ---------------------------------------------------------------------------
    # PUT
    # ---------------------------------------------------------------------------

    def handle_put(request)
      path = normalize_path(request.path_info)
      body = request.body.read

      # Reject empty body
      return [400, { 'content-type' => 'text/plain' }, ['Empty body']] if body.nil? || body.strip.empty?

      etag = "\"#{Digest::SHA256.hexdigest(body)[0..15]}\""
      content_type = request.content_type || 'text/calendar'

      is_new = !@items.key?(path)

      @items[path] = {
        body: body,
        content_type: content_type,
        etag: etag
      }

      status = is_new ? 201 : 204
      [status, { 'etag' => etag, 'content-type' => 'text/plain' }, ['']]
    end

    # ---------------------------------------------------------------------------
    # GET
    # ---------------------------------------------------------------------------

    def handle_get(request)
      path = normalize_path(request.path_info)

      # Check for an individual item first
      if @items.key?(path)
        item = @items[path]
        return [200, { 'content-type' => item[:content_type], 'etag' => item[:etag] }, [item[:body]]]
      end

      # Check for a collection
      if @collections.key?(path)
        col = @collections[path]
        # Return aggregated content for collection
        children = @items.select { |k, _| k.start_with?(path) && k != path }

        if col[:type] == :calendar
          bodies = children.values.map { |i| i[:body] }.join("\n")
          return [200, { 'content-type' => 'text/calendar; charset=utf-8' }, [bodies]]
        elsif col[:type] == :addressbook
          bodies = children.values.map { |i| i[:body] }.join("\n")
          return [200, { 'content-type' => 'text/vcard; charset=utf-8' }, [bodies]]
        else
          return [200, { 'content-type' => 'text/plain' }, ['Collection']]
        end
      end

      # Root or well-known paths
      depth = path.chomp('/').split('/').reject(&:empty?).length
      return [200, { 'content-type' => 'text/html' }, ['Caldav::App']] if path == '/' || depth <= 2

      # Well-known
      return [200, { 'content-type' => 'text/plain' }, ['well-known']] if path.start_with?('/.well-known/')

      [404, { 'content-type' => 'text/plain' }, ['Not Found']]
    end

    # ---------------------------------------------------------------------------
    # DELETE
    # ---------------------------------------------------------------------------

    def handle_delete(request)
      path = normalize_path(request.path_info)

      # Try as item
      return [204, {}, ['']] if @items.delete(path)

      # Try as collection (with trailing slash)
      col_path = path.end_with?('/') ? path : "#{path}/"
      if @collections.delete(col_path)
        # Also remove all items within the collection
        @items.delete_if { |k, _| k.start_with?(col_path) }
        return [204, {}, ['']]
      end

      # Not found
      [404, { 'content-type' => 'text/plain' }, ['Not Found']]
    end

    # ---------------------------------------------------------------------------
    # PROPPATCH
    # ---------------------------------------------------------------------------

    def handle_proppatch(request)
      path = normalize_path(request.path_info)
      path = "#{path}/" unless path.end_with?('/')

      col = @collections[path]
      return [404, { 'content-type' => 'text/xml; charset=utf-8' }, ['Not Found']] unless col

      body = request.body.read

      # Update known properties
      dn = extract_xml_value(body, 'displayname')
      col[:displayname] = dn if dn

      desc = extract_xml_value(body, 'calendar-description')
      col[:description] = desc if desc

      color = extract_xml_value(body, 'calendar-color')
      col[:color] = color if color

      result_body = multistatus_xml([
                                      <<~XML
                                        <d:response>
                                          <d:href>#{escape_xml(path)}</d:href>
                                          <d:propstat>
                                            <d:prop/>
                                            <d:status>HTTP/1.1 200 OK</d:status>
                                          </d:propstat>
                                        </d:response>
                                      XML
                                    ])

      [207, { 'content-type' => 'text/xml; charset=utf-8' }, [result_body]]
    end

    # ---------------------------------------------------------------------------
    # REPORT
    # ---------------------------------------------------------------------------

    def handle_report(request)
      path = normalize_path(request.path_info)

      responses = []
      @items.each do |item_path, item|
        next unless item_path.start_with?(path)

        responses << <<~XML
          <d:response>
            <d:href>#{escape_xml(item_path)}</d:href>
            <d:propstat>
              <d:prop>
                <d:getetag>#{escape_xml(item[:etag])}</d:getetag>
                <c:calendar-data>#{escape_xml(item[:body])}</c:calendar-data>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML
      end

      body = multistatus_xml(responses)
      [207, { 'content-type' => 'text/xml; charset=utf-8' }, [body]]
    end

    # ---------------------------------------------------------------------------
    # XML helpers
    # ---------------------------------------------------------------------------

    def multistatus_xml(responses)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:x="http://apple.com/ns/ical/">
        #{responses.join}
        </d:multistatus>
      XML
    end

    def extract_xml_value(xml, tag)
      # Simple regex extraction -- sufficient for test fixtures
      match = xml.match(/<[^>]*#{Regexp.escape(tag)}[^>]*>([^<]*)</)
      match ? match[1] : nil
    end

    def escape_xml(str)
      return '' unless str

      str.to_s
         .gsub('&', '&amp;')
         .gsub('<', '&lt;')
         .gsub('>', '&gt;')
         .gsub('"', '&quot;')
    end
  end
end
