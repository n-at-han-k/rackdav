# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Head
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info)

        if request.request_method != 'HEAD' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          env['REQUEST_METHOD'] = 'GET'
          status, headers, _body = Caldav::Contacts::Get.new(@app).call(env)
          [status, headers, []]
        end
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "returns same status and headers as GET but empty body" do
    mw = TM.new(Caldav::Contacts::Head)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/contact.vcf', 'BEGIN:VCARD', 'text/vcard')
    env = TM.env('HEAD', '/addressbooks/admin/addr/contact.vcf')
    status, headers, body = mw.call(env)
    status.should == 200
    headers['content-type'].should == 'text/vcard'
    body.should == []
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Head)
    env = TM.env('HEAD', '/calendars/admin/cal/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Head, nil, user: nil)
    status, = mw.call(TM.env('HEAD', '/addressbooks/admin/addr/contact.vcf'))
    status.should == 401
  end
end
