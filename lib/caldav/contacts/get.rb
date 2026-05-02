# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Get
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'GET' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
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
            [200, { 'content-type' => 'text/vcard; charset=utf-8' }, [bodies]]
          elsif path.depth <= 2
            [200, { 'content-type' => 'text/html' }, ['Caldav::App']]
          else
            [404, { 'content-type' => 'text/plain' }, ['Not Found']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "returns item body and content-type" do
    mw = TM.new(Caldav::Contacts::Get)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/contact.vcf', 'BEGIN:VCARD', 'text/vcard')
    env = TM.env('GET', '/addressbooks/admin/addr/contact.vcf')
    status, headers, body = mw.call(env)
    status.should == 200
    headers['content-type'].should == 'text/vcard'
    body.first.should.include 'VCARD'
  end

  it "returns concatenated items for a collection GET" do
    mw = TM.new(Caldav::Contacts::Get)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/c1.vcf', 'CONTACT1', 'text/vcard')
    mw.storage.put_item('/addressbooks/admin/addr/c2.vcf', 'CONTACT2', 'text/vcard')
    env = TM.env('GET', '/addressbooks/admin/addr/')
    status, headers, body = mw.call(env)
    status.should == 200
    headers['content-type'].should == 'text/vcard; charset=utf-8'
    body.first.should.include 'CONTACT1'
    body.first.should.include 'CONTACT2'
  end

  it "returns 404 for missing contact" do
    mw = TM.new(Caldav::Contacts::Get)
    env = TM.env('GET', '/addressbooks/admin/addr/nope.vcf')
    status, = mw.call(env)
    status.should == 404
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Get)
    env = TM.env('GET', '/calendars/admin/cal/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Get, nil, user: nil)
    status, = mw.call(TM.env('GET', '/addressbooks/admin/addr/contact.vcf'))
    status.should == 401
  end

  it "returns 304 when If-None-Match matches etag" do
    mw = TM.new(Caldav::Contacts::Get)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    item_data, = mw.storage.put_item('/addressbooks/admin/addr/contact.vcf', 'BEGIN:VCARD', 'text/vcard')
    etag = item_data[:etag]
    env = TM.env('GET', '/addressbooks/admin/addr/contact.vcf', headers: { 'If-None-Match' => etag })
    status, headers, body = mw.call(env)
    status.should == 304
    headers['etag'].should == etag
    body.should == []
  end

  it "returns 200 when If-None-Match does not match etag" do
    mw = TM.new(Caldav::Contacts::Get)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/contact.vcf', 'BEGIN:VCARD', 'text/vcard')
    env = TM.env('GET', '/addressbooks/admin/addr/contact.vcf', headers: { 'If-None-Match' => '"stale"' })
    status, _, body = mw.call(env)
    status.should == 200
    body.first.should.include 'VCARD'
  end
end
