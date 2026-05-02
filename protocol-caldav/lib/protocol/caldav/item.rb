# frozen_string_literal: true

module Protocol
  module Caldav
    class Item
      attr_reader :path, :body, :content_type, :etag

      def initialize(path:, body:, content_type:, etag:, new_record: false)
        @path = path
        @body = body
        @content_type = content_type
        @etag = etag
        @new_record = new_record
      end

      def new?
        @new_record
      end

      def to_propfind_xml
        <<~XML
          <d:response>
            <d:href>#{Xml.escape(@path.to_s)}</d:href>
            <d:propstat>
              <d:prop>
                <d:getetag>#{Xml.escape(@etag)}</d:getetag>
                <d:getcontenttype>#{Xml.escape(@content_type)}</d:getcontenttype>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML
      end

      def to_report_xml(data_tag:)
        <<~XML
          <d:response>
            <d:href>#{Xml.escape(@path.to_s)}</d:href>
            <d:propstat>
              <d:prop>
                <d:getetag>#{Xml.escape(@etag)}</d:getetag>
                <#{data_tag}>#{Xml.escape(@body)}</#{data_tag}>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML
      end
    end
  end
end
