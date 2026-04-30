# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Put
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'PUT' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          body = request.body.read

          if body.nil? || body.strip.empty?
            [400, { 'content-type' => 'text/plain' }, ['Empty body']]
          else
            content_type = request.content_type || 'text/vcard'
            item = DavItem.create(path, body: body, content_type: content_type)

            [item.new? ? 201 : 204, { 'etag' => item.etag, 'content-type' => 'text/plain' }, ['']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "creates a new vcard and returns 201 with etag" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('PUT', '/addressbooks/admin/addr/contact.vcf',
                 body: 'BEGIN:VCARD\nEND:VCARD', content_type: 'text/vcard; charset=utf-8')
    status, headers, = mw.call(env)
    status.should == 201
    headers['etag'].should.not.be.nil
  end

  it "rejects empty body with 400" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('PUT', '/addressbooks/admin/addr/contact.vcf')
    status, = mw.call(env)
    status.should == 400
  end

  it "updates an existing contact and returns 204" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/contact.vcf', 'BEGIN:VCARD\nVERSION:1\nEND:VCARD', 'text/vcard')
    env = TM.env('PUT', '/addressbooks/admin/addr/contact.vcf',
                 body: 'BEGIN:VCARD\nVERSION:2\nEND:VCARD', content_type: 'text/vcard')
    status, headers, = mw.call(env)
    status.should == 204
    headers['etag'].should.not.be.nil
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Put)
    env = TM.env('PUT', '/calendars/admin/cal/event.ics', body: 'data')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Put, nil, user: nil)
    status, = mw.call(TM.env('PUT', '/addressbooks/admin/addr/contact.vcf', body: 'data'))
    status.should == 401
  end
end
