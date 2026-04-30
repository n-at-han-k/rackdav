# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Mkcol
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'MKCOL'
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          path = path.ensure_trailing_slash

          if DavCollection.exists?(path)
            [405, { 'content-type' => 'text/plain' }, ['Collection already exists']]
          elsif !path.parent_exists?
            [409, { 'content-type' => 'text/plain' }, ['Parent does not exist']]
          else
            body = request.body&.read || ''
            displayname = Xml.extract_value(body, 'displayname')
            col_type = body.include?('addressbook') ? :addressbook : :collection

            DavCollection.create(path, type: col_type, displayname: displayname)

            [201, { 'content-type' => 'text/xml; charset=utf-8' }, ['']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "creates an addressbook and returns 201" do
    mw = TM.new(Caldav::Contacts::Mkcol)
    body = <<~XML
      <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:set><d:prop>
          <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
          <d:displayname>Contacts</d:displayname>
        </d:prop></d:set>
      </d:mkcol>
    XML
    env = TM.env('MKCOL', '/addressbooks/admin/contacts/', body: body)
    status, = mw.call(env)
    status.should == 201
    mw.storage.collection_exists?('/addressbooks/admin/contacts/').should.be.true
  end

  it "stores displayname and detects addressbook type from XML body" do
    mw = TM.new(Caldav::Contacts::Mkcol)
    body = <<~XML
      <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:set><d:prop>
          <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
          <d:displayname>My Contacts</d:displayname>
        </d:prop></d:set>
      </d:mkcol>
    XML
    env = TM.env('MKCOL', '/addressbooks/admin/mycon/', body: body)
    status, = mw.call(env)
    status.should == 201
    col = mw.storage.get_collection('/addressbooks/admin/mycon/')
    col[:displayname].should == 'My Contacts'
    col[:type].should == :addressbook
  end

  it "returns 405 when addressbook already exists" do
    mw = TM.new(Caldav::Contacts::Mkcol)
    mw.storage.create_collection('/addressbooks/admin/dup/', type: :addressbook)
    env = TM.env('MKCOL', '/addressbooks/admin/dup/')
    status, = mw.call(env)
    status.should == 405
  end

  it "returns 409 when parent does not exist" do
    mw = TM.new(Caldav::Contacts::Mkcol)
    env = TM.env('MKCOL', '/addressbooks/admin/no/parent/deep/')
    status, = mw.call(env)
    status.should == 409
  end

  it "passes through for non-MKCOL requests" do
    mw = TM.new(Caldav::Contacts::Mkcol)
    env = TM.env('GET', '/addressbooks/admin/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Mkcol, nil, user: nil)
    status, = mw.call(TM.env('MKCOL', '/addressbooks/admin/newaddr/'))
    status.should == 401
  end

  it "sets type to addressbook when body contains addressbook" do
    mw = TM.new(Caldav::Contacts::Mkcol)
    body = <<~XML
      <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:set><d:prop>
          <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
        </d:prop></d:set>
      </d:mkcol>
    XML
    env = TM.env('MKCOL', '/addressbooks/admin/typed/', body: body)
    status, = mw.call(env)
    status.should == 201
    mw.storage.get_collection('/addressbooks/admin/typed/')[:type].should == :addressbook
  end

  it "creates collection without body" do
    mw = TM.new(Caldav::Contacts::Mkcol)
    env = TM.env('MKCOL', '/addressbooks/admin/plain/')
    status, = mw.call(env)
    status.should == 201
    mw.storage.collection_exists?('/addressbooks/admin/plain/').should.be.true
  end

  it "adds trailing slash to path" do
    mw = TM.new(Caldav::Contacts::Mkcol)
    body = <<~XML
      <d:mkcol xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:set><d:prop>
          <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
          <d:displayname>Slash</d:displayname>
        </d:prop></d:set>
      </d:mkcol>
    XML
    env = TM.env('MKCOL', '/addressbooks/admin/noslash', body: body)
    status, = mw.call(env)
    status.should == 201
    mw.storage.collection_exists?('/addressbooks/admin/noslash/').should.be.true
  end
end
