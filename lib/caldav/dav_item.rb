# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  class DavItem < Protocol::Caldav::Item
    # --- Class methods (storage integration) ---

    def self.find(path)
      data = path.storage_class.get_item(path.to_s)
      if data
        new(path: path, body: data[:body], content_type: data[:content_type], etag: data[:etag])
      end
    end

    def self.create(path, body:, content_type:)
      data, is_new = path.storage_class.put_item(path.to_s, body, content_type)
      new(path: path, body: data[:body], content_type: data[:content_type], etag: data[:etag], new_record: is_new)
    end

    def self.list(path)
      path.storage_class.list_items(path.to_s).map do |item_path_str, data|
        item_path = Path.new(item_path_str, storage_class: path.storage_class)
        new(path: item_path, body: data[:body], content_type: data[:content_type], etag: data[:etag])
      end
    end

    def self.multi(paths)
      return [] if paths.empty?

      storage = paths.first.storage_class
      storage.get_multi(paths.map(&:to_s)).map do |path_str, data|
        p = Path.new(path_str, storage_class: storage)
        if data
          [p, new(path: p, body: data[:body], content_type: data[:content_type], etag: data[:etag])]
        else
          [p, nil]
        end
      end
    end

    # --- Instance methods (storage integration) ---

    def delete
      @path.storage_class.delete_item(@path.to_s)
    end

    def move_to(new_path)
      data = @path.storage_class.move_item(@path.to_s, new_path.to_s)
      if data
        @path = new_path
        @body = data[:body]
        @content_type = data[:content_type]
        @etag = data[:etag]
        self
      end
    end
  end
end

test do
  def self.etag(body)
    %("#{Digest::SHA256.hexdigest(body)[0..15]}")
  end

  def self.normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  it "renders exact propfind XML for an item" do
    s = Caldav::Storage::Mock.new
    body = 'BEGIN:VCALENDAR'
    s.put_item('/calendars/admin/cal/ev.ics', body, 'text/calendar')
    p = Caldav::Path.new('/calendars/admin/cal/ev.ics', storage_class: s)
    item = Caldav::DavItem.find(p)
    normalize(item.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/calendars/admin/cal/ev.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>#{Caldav::Xml.escape(etag(body))}</d:getetag>
            <d:getcontenttype>text/calendar</d:getcontenttype>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "renders exact report XML for a calendar item" do
    s = Caldav::Storage::Mock.new
    body = "BEGIN:VCALENDAR\r\nEND:VCALENDAR"
    s.put_item('/cal/ev.ics', body, 'text/calendar')
    p = Caldav::Path.new('/cal/ev.ics', storage_class: s)
    item = Caldav::DavItem.find(p)
    normalize(item.to_report_xml(data_tag: 'c:calendar-data')).should == normalize(<<~XML)
      <d:response>
        <d:href>/cal/ev.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>#{Caldav::Xml.escape(etag(body))}</d:getetag>
            <c:calendar-data>#{Caldav::Xml.escape(body)}</c:calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "renders exact report XML for a contact" do
    s = Caldav::Storage::Mock.new
    body = "BEGIN:VCARD\r\nFN:Alice\r\nEND:VCARD"
    s.put_item('/addr/c.vcf', body, 'text/vcard')
    p = Caldav::Path.new('/addr/c.vcf', storage_class: s)
    item = Caldav::DavItem.find(p)
    normalize(item.to_report_xml(data_tag: 'cr:address-data')).should == normalize(<<~XML)
      <d:response>
        <d:href>/addr/c.vcf</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>#{Caldav::Xml.escape(etag(body))}</d:getetag>
            <cr:address-data>#{Caldav::Xml.escape(body)}</cr:address-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "etag is quoted in propfind XML" do
    s = Caldav::Storage::Mock.new
    body = 'data'
    s.put_item('/cal/ev.ics', body, 'text/calendar')
    p = Caldav::Path.new('/cal/ev.ics', storage_class: s)
    item = Caldav::DavItem.find(p)
    normalize(item.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/cal/ev.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>#{Caldav::Xml.escape(etag(body))}</d:getetag>
            <d:getcontenttype>text/calendar</d:getcontenttype>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end
end
