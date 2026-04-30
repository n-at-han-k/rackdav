# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Proppatch
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'PROPPATCH' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          path = path.ensure_trailing_slash
          collection = DavCollection.find(path)

          if !collection
            [404, { 'content-type' => 'text/xml; charset=utf-8' }, ['Not Found']]
          else
            body = request.body.read
            updates = {}
            dn = Xml.extract_value(body, 'displayname')
            updates[:displayname] = dn if dn

            if body.include?('<d:remove') || body.include?('<D:remove')
              updates[:displayname] = nil if body.match?(/<[^>]*remove[^>]*>.*displayname/m) && !dn
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
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  def self.normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    status, = mw.call(TM.env('PROPPATCH', '/calendars/admin/cal/'))
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Proppatch, nil, user: nil)
    status, = mw.call(TM.env('PROPPATCH', '/addressbooks/admin/addr/', body: '<x/>'))
    status.should == 401
  end

  it "returns 404 for non-existent addressbook" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    status, = mw.call(TM.env('PROPPATCH', '/addressbooks/admin/nope/', body: '<x/>'))
    status.should == 404
  end

  it "updates displayname and returns full 207 response" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook, displayname: 'Old')
    body = <<~XML
      <d:propertyupdate xmlns:d="DAV:">
        <d:set><d:prop>
          <d:displayname>New</d:displayname>
        </d:prop></d:set>
      </d:propertyupdate>
    XML
    status, headers, resp = mw.call(TM.env('PROPPATCH', '/addressbooks/admin/addr/', body: body))
    status.should == 207
    headers['content-type'].should == 'text/xml; charset=utf-8'
    mw.storage.get_collection('/addressbooks/admin/addr/')[:displayname].should == 'New'
    normalize(resp.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/</d:href>
          <d:propstat>
            <d:prop/>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "removes displayname via d:remove" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook, displayname: 'RemoveMe')
    body = <<~XML
      <d:propertyupdate xmlns:d="DAV:">
        <d:remove><d:prop>
          <d:displayname/>
        </d:prop></d:remove>
      </d:propertyupdate>
    XML
    status, _, resp = mw.call(TM.env('PROPPATCH', '/addressbooks/admin/addr/', body: body))
    status.should == 207
    mw.storage.get_collection('/addressbooks/admin/addr/')[:displayname].should.be.nil
    normalize(resp.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/</d:href>
          <d:propstat>
            <d:prop/>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "preserves unmodified properties when updating displayname only" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook, displayname: 'Old Name')
    body = <<~XML
      <d:propertyupdate xmlns:d="DAV:">
        <d:set><d:prop>
          <d:displayname>New Name</d:displayname>
        </d:prop></d:set>
      </d:propertyupdate>
    XML
    status, _, resp = mw.call(TM.env('PROPPATCH', '/addressbooks/admin/addr/', body: body))
    status.should == 207
    col = mw.storage.get_collection('/addressbooks/admin/addr/')
    col[:displayname].should == 'New Name'
    col[:type].should == :addressbook
    normalize(resp.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/</d:href>
          <d:propstat>
            <d:prop/>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end
end
