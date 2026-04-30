# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)

require 'caldav'
require 'minitest/autorun'
require 'rack/test'
require 'base64'

module Caldav
  # Base class for CalDAV integration tests.
  #
  # Provides Rack::Test helpers and CalDAV-specific request methods
  # that mirror the operations tested in Radicale's integration suite.
  class IntegrationTest < Minitest::Test
    include Rack::Test::Methods

    def app
      self.class.shared_app
    end

    # Share a single App instance per test class so order-dependent
    # tests accumulate state (collections, items, tickets, bindings).
    def self.shared_app
      @shared_app ||= Caldav::App.new
    end

    private

    # ---------------------------------------------------------------------------
    # Auth helpers
    # ---------------------------------------------------------------------------

    def auth_header(username = 'admin', password = 'admin')
      "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
    end

    def with_auth(username = 'admin', password = 'admin')
      header 'HTTP_AUTHORIZATION', auth_header(username, password)
    end

    # ---------------------------------------------------------------------------
    # CalDAV request helpers
    # ---------------------------------------------------------------------------

    # WebDAV PROPFIND
    def caldav_propfind(path, depth: '1', properties: nil, auth: true)
      with_auth if auth

      body = if properties && !properties.empty?
               propfind_xml(properties)
             else
               allprop_xml
             end

      request(path, method: 'PROPFIND', input: body, 'HTTP_DEPTH' => depth,
                    'CONTENT_TYPE' => 'text/xml; charset=utf-8')
      last_response
    end

    # CalDAV MKCALENDAR
    def caldav_mkcalendar(path, displayname: nil, description: nil, color: nil, auth: true)
      with_auth if auth

      body = mkcalendar_xml(displayname: displayname, description: description, color: color)
      request(path, method: 'MKCALENDAR', input: body,
                    'CONTENT_TYPE' => 'text/xml; charset=utf-8')
      last_response
    end

    # WebDAV MKCOL (used for addressbooks)
    def caldav_mkcol(path, resourcetype: 'addressbook', displayname: nil, auth: true)
      with_auth if auth

      body = mkcol_xml(resourcetype: resourcetype, displayname: displayname)
      request(path, method: 'MKCOL', input: body,
                    'CONTENT_TYPE' => 'text/xml; charset=utf-8')
      last_response
    end

    # HTTP PUT for uploading calendar/contact items
    def caldav_put(path, body, content_type: 'text/calendar; charset=utf-8', auth: true)
      with_auth if auth

      request(path, method: 'PUT', input: body,
                    'CONTENT_TYPE' => content_type)
      last_response
    end

    # HTTP GET
    def caldav_get(path, auth: true)
      with_auth if auth

      get path
      last_response
    end

    # HTTP DELETE
    def caldav_delete(path, auth: true)
      with_auth if auth

      delete path
      last_response
    end

    # WebDAV PROPPATCH
    def caldav_proppatch(path, properties, auth: true)
      with_auth if auth

      body = proppatch_xml(properties)
      request(path, method: 'PROPPATCH', input: body,
                    'CONTENT_TYPE' => 'text/xml; charset=utf-8')
      last_response
    end

    # CalDAV REPORT
    def caldav_report(path, body, auth: true)
      with_auth if auth

      request(path, method: 'REPORT', input: body,
                    'CONTENT_TYPE' => 'text/xml; charset=utf-8')
      last_response
    end

    # WebDAV BIND
    def caldav_bind(path, segment:, href:, ticket: nil, auth: true, username: 'admin', password: 'admin')
      with_auth(username, password) if auth

      body = bind_xml(segment: segment, href: href)
      headers = { 'CONTENT_TYPE' => 'text/xml; charset=utf-8' }
      headers['HTTP_TICKET'] = ticket if ticket
      request(path, method: 'BIND', input: body, **headers)
      last_response
    end

    # WebDAV MKTICKET
    def caldav_mkticket(path, privileges: %w[read write], timeout: 'Second-3600', auth: true, username: 'admin',
                        password: 'admin')
      with_auth(username, password) if auth

      body = mkticket_xml(privileges: privileges, timeout: timeout)
      request(path, method: 'MKTICKET', input: body,
                    'CONTENT_TYPE' => 'text/xml; charset=utf-8')
      last_response
    end

    # HTTP OPTIONS
    def caldav_options(path, auth: true)
      with_auth if auth

      options path
      last_response
    end

    # Use Rack::Test's request method for arbitrary HTTP methods
    def request(uri, opts = {})
      method = opts.delete(:method) || 'GET'
      input = opts.delete(:input)

      env = {
        'REQUEST_METHOD' => method,
        'PATH_INFO' => uri,
        'rack.input' => StringIO.new(input || '')
      }
      env.merge!(opts)

      current_session.request(uri, method: method, input: input, **opts)
    end

    # ---------------------------------------------------------------------------
    # XML body builders
    # ---------------------------------------------------------------------------

    def allprop_xml
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:allprop/>
        </d:propfind>
      XML
    end

    def propfind_xml(properties)
      props = properties.map { |p| "    <d:#{p}/>" }.join("\n")
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
          <d:prop>
        #{props}
          </d:prop>
        </d:propfind>
      XML
    end

    def mkcalendar_xml(displayname: nil, description: nil, color: nil)
      props = []
      props << "<d:displayname>#{displayname}</d:displayname>" if displayname
      props << "<c:calendar-description>#{description}</c:calendar-description>" if description
      props << "<x:calendar-color>#{color}</x:calendar-color>" if color

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:x="http://apple.com/ns/ical/">
          <d:set>
            <d:prop>
              #{props.join("\n          ")}
            </d:prop>
          </d:set>
        </c:mkcalendar>
      XML
    end

    def mkcol_xml(resourcetype: 'addressbook', displayname: nil)
      rt = case resourcetype
           when 'addressbook'
             '<d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>'
           else
             '<d:resourcetype><d:collection/></d:resourcetype>'
           end

      dn = displayname ? "<d:displayname>#{displayname}</d:displayname>" : ''

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
          <d:set>
            <d:prop>
              #{rt}
              #{dn}
            </d:prop>
          </d:set>
        </d:mkcol>
      XML
    end

    def proppatch_xml(properties)
      props = properties.map do |ns_prop, value|
        ns, prop = ns_prop.split(':', 2)
        case ns
        when 'd', 'DAV'
          "<d:#{prop}>#{value}</d:#{prop}>"
        when 'c', 'caldav'
          "<c:#{prop}>#{value}</c:#{prop}>"
        when 'x', 'apple'
          "<x:#{prop}>#{value}</x:#{prop}>"
        else
          "<#{ns_prop}>#{value}</#{ns_prop}>"
        end
      end

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propertyupdate xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:x="http://apple.com/ns/ical/">
          <d:set>
            <d:prop>
              #{props.join("\n          ")}
            </d:prop>
          </d:set>
        </d:propertyupdate>
      XML
    end

    def bind_xml(segment:, href:)
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <bind xmlns="DAV:">
           <segment>#{segment}</segment>
           <href>#{href}</href>
        </bind>
      XML
    end

    def mkticket_xml(privileges: %w[read write], timeout: 'Second-3600')
      privs = privileges.map { |p| "<D:#{p}/>" }.join
      <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <D:ticketinfo xmlns:D="DAV:" >
          <D:privilege>
            #{privs}
          </D:privilege>
          <D:timeout>#{timeout}</D:timeout>
        </D:ticketinfo>
      XML
    end

    def sync_collection_xml(sync_token: nil)
      token = sync_token ? "<D:sync-token>#{sync_token}</D:sync-token>" : '<D:sync-token/>'
      <<~XML
        <?xml version="1.0" encoding="utf-8" ?>
        <D:sync-collection xmlns:D="DAV:">
          #{token}
          <D:prop>
            <D:getetag/>
          </D:prop>
        </D:sync-collection>
      XML
    end

    def multiget_xml(hrefs)
      href_elements = hrefs.map { |h| "<D:href>#{h}</D:href>" }.join("\n  ")
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <calendar-multiget xmlns:D="DAV:" xmlns="urn:ietf:params:xml:ns:caldav">
          <D:prop>
            <D:getetag/>
            <calendar-data/>
          </D:prop>
          #{href_elements}
        </calendar-multiget>
      XML
    end

    def calendar_query_timerange_xml(start_time:, end_time:, expand: false)
      expand_elem = expand ? %(<expand start="#{start_time}" end="#{end_time}"/>) : ''
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <calendar-query xmlns:D="DAV:" xmlns="urn:ietf:params:xml:ns:caldav">
          <D:prop>
            <calendar-data>
              #{expand_elem}
            </calendar-data>
          </D:prop>
          <filter>
            <comp-filter name="VCALENDAR">
              <comp-filter name="VEVENT">
                <time-range start="#{start_time}" end="#{end_time}"/>
              </comp-filter>
            </comp-filter>
          </filter>
        </calendar-query>
      XML
    end

    # ---------------------------------------------------------------------------
    # Test data: iCalendar / vCard fixtures
    # ---------------------------------------------------------------------------

    def sample_vcalendar(uid: 'test-event-1', summary: 'Test Event')
      <<~ICAL
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Caldav Gem//Test//EN
        BEGIN:VEVENT
        UID:#{uid}
        DTSTART:20260101T120000Z
        DTEND:20260101T130000Z
        SUMMARY:#{summary}
        END:VEVENT
        END:VCALENDAR
      ICAL
    end

    def sample_vtodo(uid: 'test-todo-1', summary: 'Test Todo')
      <<~ICAL
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Caldav Gem//Test//EN
        BEGIN:VTODO
        UID:#{uid}
        SUMMARY:#{summary}
        STATUS:NEEDS-ACTION
        END:VTODO
        END:VCALENDAR
      ICAL
    end

    def sample_vcard(uid: 'test-contact-1', fn: 'Jane Doe')
      <<~VCARD
        BEGIN:VCARD
        VERSION:3.0
        UID:#{uid}
        FN:#{fn}
        N:Doe;Jane;;;
        EMAIL:jane@example.com
        END:VCARD
      VCARD
    end

    def calendar_report_xml(uid: nil)
      filter = if uid
                 <<~FILTER
                   <c:filter>
                     <c:comp-filter name="VCALENDAR">
                       <c:comp-filter name="VEVENT">
                         <c:prop-filter name="UID">
                           <c:text-match>#{uid}</c:text-match>
                         </c:prop-filter>
                       </c:comp-filter>
                     </c:comp-filter>
                   </c:filter>
                 FILTER
               else
                 '<c:filter><c:comp-filter name="VCALENDAR"/></c:filter>'
               end

      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag/>
            <c:calendar-data/>
          </d:prop>
          #{filter}
        </c:calendar-query>
      XML
    end
  end
end
