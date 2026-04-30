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
            [200, { 'content-type' => item.content_type, 'etag' => item.etag }, [item.body]]
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
end
