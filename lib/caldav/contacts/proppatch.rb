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
  TM = Caldav::Storage::TestMiddleware

  it "updates displayname and returns 207" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook, displayname: 'Old')
    body = '<d:propertyupdate xmlns:d="DAV:"><d:set><d:prop><d:displayname>New</d:displayname></d:prop></d:set></d:propertyupdate>'
    env = TM.env('PROPPATCH', '/addressbooks/admin/addr/', body: body)
    status, = mw.call(env)
    status.should == 207
    mw.storage.get_collection('/addressbooks/admin/addr/')[:displayname].should == 'New'
  end

  it "preserves unmodified properties when updating displayname only" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook, displayname: 'Old Name')
    body = '<d:propertyupdate xmlns:d="DAV:"><d:set><d:prop><d:displayname>New Name</d:displayname></d:prop></d:set></d:propertyupdate>'
    env = TM.env('PROPPATCH', '/addressbooks/admin/addr/', body: body)
    status, _, body_out = mw.call(env)
    status.should == 207
    col = mw.storage.get_collection('/addressbooks/admin/addr/')
    col[:displayname].should == 'New Name'
    col[:type].should == :addressbook
    body_out.first.should.include 'd:multistatus'
    body_out.first.should.include '/addressbooks/admin/addr/'
  end

  it "returns 404 for non-existent addressbook" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    env = TM.env('PROPPATCH', '/addressbooks/admin/nope/', body: '<x/>')
    status, = mw.call(env)
    status.should == 404
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Proppatch)
    env = TM.env('PROPPATCH', '/calendars/admin/cal/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Proppatch, nil, user: nil)
    status, = mw.call(TM.env('PROPPATCH', '/addressbooks/admin/addr/', body: '<x/>'))
    status.should == 401
  end
end
