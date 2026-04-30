# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Report
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'REPORT' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          responses = DavItem.list(path).map do |item|
            item.to_report_xml(data_tag: 'cr:address-data')
          end

          [207, { 'content-type' => 'text/xml; charset=utf-8' }, [Multistatus.new(responses).to_xml]]
        end
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "returns 207 with contact data for addressbook report" do
    mw = TM.new(Caldav::Contacts::Report)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/contact.vcf', 'BEGIN:VCARD', 'text/vcard')
    env = TM.env('REPORT', '/addressbooks/admin/addr/')
    status, headers, body = mw.call(env)
    status.should == 207
    headers['content-type'].should.include 'xml'
    body.first.should.include 'VCARD'
  end

  it "returns well-formed multistatus XML with d:response elements" do
    mw = TM.new(Caldav::Contacts::Report)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/c1.vcf', 'BEGIN:VCARD\nCONTACT1\nEND:VCARD', 'text/vcard')
    mw.storage.put_item('/addressbooks/admin/addr/c2.vcf', 'BEGIN:VCARD\nCONTACT2\nEND:VCARD', 'text/vcard')
    env = TM.env('REPORT', '/addressbooks/admin/addr/')
    status, _, body = mw.call(env)
    status.should == 207
    xml = body.first
    xml.should.include 'd:multistatus'
    xml.should.include 'd:response'
    xml.should.include 'd:href'
    xml.should.include 'cr:address-data'
    xml.should.include 'CONTACT1'
    xml.should.include 'CONTACT2'
  end

  it "returns empty multistatus for addressbook with no items" do
    mw = TM.new(Caldav::Contacts::Report)
    mw.storage.create_collection('/addressbooks/admin/empty/', type: :addressbook)
    env = TM.env('REPORT', '/addressbooks/admin/empty/')
    status, _, body = mw.call(env)
    status.should == 207
    xml = body.first
    xml.should.include 'd:multistatus'
    xml.should.not.include 'd:response'
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Report)
    env = TM.env('REPORT', '/calendars/admin/cal/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Report, nil, user: nil)
    status, = mw.call(TM.env('REPORT', '/addressbooks/admin/addr/'))
    status.should == 401
  end
end
