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
          body = request.body&.read
          items = DavItem.list(path)

          # Apply prop-filter/text-match if present
          if body && !body.empty?
            prop_name = Xml.extract_attr(body, 'prop-filter', 'name')
            if prop_name
              text_match = Xml.extract_value(body, 'text-match')
              if text_match
                items = items.select { |item| item.body.include?(text_match) }
              else
                items = items.select { |item| item.body.include?(prop_name) }
              end
            end
          end

          responses = items.map do |item|
            item.to_report_xml(data_tag: 'cr:address-data')
          end

          [207, { 'content-type' => 'text/xml; charset=utf-8', 'cache-control' => 'no-store' }, [Multistatus.new(responses).to_xml]]
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

  # --- Filtering tests (prop-filter, text-match) ---

  it "returns contacts matching prop-filter text-match on FN" do
    mw = TM.new(Caldav::Contacts::Report)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    alice = "BEGIN:VCARD\nFN:Alice Smith\nEND:VCARD"
    bob = "BEGIN:VCARD\nFN:Bob Jones\nEND:VCARD"
    mw.storage.put_item('/addressbooks/admin/addr/alice.vcf', alice, 'text/vcard')
    mw.storage.put_item('/addressbooks/admin/addr/bob.vcf', bob, 'text/vcard')
    body = <<~XML
      <cr:addressbook-query xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:prop><d:getetag/><cr:address-data/></d:prop>
        <cr:filter>
          <cr:prop-filter name="FN">
            <cr:text-match>Alice</cr:text-match>
          </cr:prop-filter>
        </cr:filter>
      </cr:addressbook-query>
    XML
    status, _, resp = mw.call(TM.env('REPORT', '/addressbooks/admin/addr/', body: body))
    status.should == 207
    normalize(resp.first).should == normalize(<<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cr="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/" xmlns:x="http://apple.com/ns/ical/">
        <d:response>
          <d:href>/addressbooks/admin/addr/alice.vcf</d:href>
          <d:propstat>
            <d:prop>
              <d:getetag>#{Caldav::Xml.escape(etag(alice))}</d:getetag>
              <cr:address-data>#{Caldav::Xml.escape(alice)}</cr:address-data>
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  it "returns all contacts with empty filter" do
    mw = TM.new(Caldav::Contacts::Report)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    alice = "BEGIN:VCARD\nFN:Alice\nEND:VCARD"
    bob = "BEGIN:VCARD\nFN:Bob\nEND:VCARD"
    mw.storage.put_item('/addressbooks/admin/addr/alice.vcf', alice, 'text/vcard')
    mw.storage.put_item('/addressbooks/admin/addr/bob.vcf', bob, 'text/vcard')
    body = <<~XML
      <cr:addressbook-query xmlns:d="DAV:" xmlns:cr="urn:ietf:params:xml:ns:carddav">
        <d:prop><d:getetag/><cr:address-data/></d:prop>
        <cr:filter/>
      </cr:addressbook-query>
    XML
    status, _, resp = mw.call(TM.env('REPORT', '/addressbooks/admin/addr/', body: body))
    status.should == 207
    xml = normalize(resp.first)
    xml.should.include 'alice.vcf'
    xml.should.include 'bob.vcf'
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
