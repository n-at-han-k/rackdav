# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Propfind
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'PROPFIND' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
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
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  def self.ctag(storage, path, displayname, description = nil, color = nil)
    item_etags = storage.list_items(path).map { |_, data| data[:etag] }.sort.join(":")
    Digest::SHA256.hexdigest("#{path}:#{displayname}:#{description}:#{color}:#{item_etags}")[0..15]
  end

  def self.etag(body)
    %("#{Digest::SHA256.hexdigest(body)[0..15]}")
  end

  def self.normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Propfind)
    status, = mw.call(TM.env('PROPFIND', '/calendars/admin/', headers: { 'Depth' => '0' }))
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Propfind, nil, user: nil)
    status, = mw.call(TM.env('PROPFIND', '/addressbooks/admin/', headers: { 'Depth' => '0' }))
    status.should == 401
  end

  it "returns 404 for non-existent deep path" do
    mw = TM.new(Caldav::Contacts::Propfind)
    status, = mw.call(TM.env('PROPFIND', '/addressbooks/admin/nope/deep/', headers: { 'Depth' => '0' }))
    status.should == 404
  end

  it "returns full 207 response for an addressbook at depth 0" do
    mw = TM.new(Caldav::Contacts::Propfind)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook, displayname: 'Addr')
    status, headers, body = mw.call(TM.env('PROPFIND', '/addressbooks/admin/addr/', headers: { 'Depth' => '0' }))
    status.should == 207
    headers['content-type'].should == 'text/xml; charset=utf-8'
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
              <d:displayname>Addr</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/addressbooks/admin/addr/', 'Addr')}</cs:getctag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns full 207 response for a single contact item at depth 0" do
    mw = TM.new(Caldav::Contacts::Propfind)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    card = 'BEGIN:VCARD'
    mw.storage.put_item('/addressbooks/admin/addr/c.vcf', card, 'text/vcard')
    status, _, body = mw.call(TM.env('PROPFIND', '/addressbooks/admin/addr/c.vcf', headers: { 'Depth' => '0' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/c.vcf</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(card))}</d:getetag>
              <d:getcontenttype>text/vcard</d:getcontenttype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns collection and child addressbooks at depth 1" do
    mw = TM.new(Caldav::Contacts::Propfind)
    mw.storage.create_collection('/addressbooks/admin/', type: :collection)
    mw.storage.create_collection('/addressbooks/admin/a1/', type: :addressbook, displayname: 'A1')
    mw.storage.create_collection('/addressbooks/admin/a2/', type: :addressbook, displayname: 'A2')
    status, _, body = mw.call(TM.env('PROPFIND', '/addressbooks/admin/', headers: { 'Depth' => '1' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/></d:resourcetype>
              <cs:getctag>#{ctag(mw.storage, '/addressbooks/admin/', nil)}</cs:getctag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/addressbooks/admin/a1/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
              <d:displayname>A1</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/addressbooks/admin/a1/', 'A1')}</cs:getctag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/addressbooks/admin/a2/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
              <d:displayname>A2</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/addressbooks/admin/a2/', 'A2')}</cs:getctag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns addressbook with child items at depth 1" do
    mw = TM.new(Caldav::Contacts::Propfind)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook, displayname: 'Solo')
    c1 = 'BEGIN:VCARD'
    c2 = 'BEGIN:VCARD'
    mw.storage.put_item('/addressbooks/admin/addr/c1.vcf', c1, 'text/vcard')
    mw.storage.put_item('/addressbooks/admin/addr/c2.vcf', c2, 'text/vcard')
    status, _, body = mw.call(TM.env('PROPFIND', '/addressbooks/admin/addr/', headers: { 'Depth' => '1' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
              <d:displayname>Solo</d:displayname>
              <cs:getctag>#{ctag(mw.storage, '/addressbooks/admin/addr/', 'Solo')}</cs:getctag>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/addressbooks/admin/addr/c1.vcf</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(c1))}</d:getetag>
              <d:getcontenttype>text/vcard</d:getcontenttype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/addressbooks/admin/addr/c2.vcf</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(c2))}</d:getetag>
              <d:getcontenttype>text/vcard</d:getcontenttype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns 207 for /addressbooks/ path fallback" do
    mw = TM.new(Caldav::Contacts::Propfind)
    status, _, body = mw.call(TM.env('PROPFIND', '/addressbooks/', headers: { 'Depth' => '0' }))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/</d:href>
          <d:propstat>
            <d:prop>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end
end
