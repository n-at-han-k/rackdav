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
  TM = Caldav::TestMiddleware

  def self.etag(body)
    %("#{Digest::SHA256.hexdigest(body)[0..15]}")
  end

  def self.normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Report)
    status, = mw.call(TM.env('REPORT', '/calendars/admin/cal/'))
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Report, nil, user: nil)
    status, = mw.call(TM.env('REPORT', '/addressbooks/admin/addr/'))
    status.should == 401
  end

  it "returns full 207 report for a single contact" do
    mw = TM.new(Caldav::Contacts::Report)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    card = 'BEGIN:VCARD'
    mw.storage.put_item('/addressbooks/admin/addr/c.vcf', card, 'text/vcard')
    status, headers, body = mw.call(TM.env('REPORT', '/addressbooks/admin/addr/'))
    status.should == 207
    headers['content-type'].should == 'text/xml; charset=utf-8'
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/c.vcf</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(card))}</d:getetag>
              <cr:address-data>#{Caldav::Xml.escape(card)}</cr:address-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns full 207 report for multiple contacts" do
    mw = TM.new(Caldav::Contacts::Report)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    alice = 'ALICE'
    bob = 'BOB'
    mw.storage.put_item('/addressbooks/admin/addr/a.vcf', alice, 'text/vcard')
    mw.storage.put_item('/addressbooks/admin/addr/b.vcf', bob, 'text/vcard')
    status, _, body = mw.call(TM.env('REPORT', '/addressbooks/admin/addr/'))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/a.vcf</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(alice))}</d:getetag>
              <cr:address-data>#{Caldav::Xml.escape(alice)}</cr:address-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
        <d:response>
          <d:href>/addressbooks/admin/addr/b.vcf</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(bob))}</d:getetag>
              <cr:address-data>#{Caldav::Xml.escape(bob)}</cr:address-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns empty multistatus for addressbook with no items" do
    mw = TM.new(Caldav::Contacts::Report)
    mw.storage.create_collection('/addressbooks/admin/empty/', type: :addressbook)
    status, _, body = mw.call(TM.env('REPORT', '/addressbooks/admin/empty/'))
    status.should == 207
    normalize(body.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
      </d:multistatus>
    XML
  end
end
