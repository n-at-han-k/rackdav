# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  class DavItem
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

    # --- Class methods ---

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

    # --- Instance methods ---

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

    # --- XML rendering ---

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
