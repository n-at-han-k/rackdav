# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  class DavCollection
    attr_reader :path, :type, :displayname, :description, :color, :props

    def initialize(path:, type: :collection, displayname: nil, description: nil, color: nil, props: {})
      @path = path
      @type = type
      @displayname = displayname
      @description = description
      @color = color
      @props = props || {}
    end

    # --- Class methods ---

    def self.find(path)
      data = path.storage_class.get_collection(path.to_s)
      if data
        new(
          path: path,
          type: data[:type],
          displayname: data[:displayname],
          description: data[:description],
          color: data[:color],
          props: data[:props] || {}
        )
      end
    end

    def self.create(path, type: :collection, displayname: nil, description: nil, color: nil, props: {})
      data = path.storage_class.create_collection(path.to_s, {
        type: type,
        displayname: displayname,
        description: description,
        color: color,
        props: props
      })
      new(
        path: path,
        type: data[:type],
        displayname: data[:displayname],
        description: data[:description],
        color: data[:color],
        props: data[:props] || {}
      )
    end

    def self.exists?(path)
      path.storage_class.collection_exists?(path.to_s)
    end

    def self.list(path)
      path.storage_class.list_collections(path.to_s).map do |col_path_str, data|
        col_path = Path.new(col_path_str, storage_class: path.storage_class)
        new(
          path: col_path,
          type: data[:type],
          displayname: data[:displayname],
          description: data[:description],
          color: data[:color],
          props: data[:props] || {}
        )
      end
    end

    # --- Instance methods ---

    def update(updates)
      data = @path.storage_class.update_collection(@path.to_s, updates)
      if data
        @displayname = data[:displayname]
        @description = data[:description]
        @color = data[:color]
        @props = data[:props] || {}
        self
      end
    end

    def delete
      @path.storage_class.delete_collection(@path.to_s)
    end

    # --- XML rendering ---

    def to_propfind_xml
      prop_lines = []
      prop_lines << '<d:resourcetype><d:collection/></d:resourcetype>'

      if @type == :calendar
        prop_lines << '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>'
      elsif @type == :addressbook
        prop_lines << '<d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>'
      end

      prop_lines << "<d:displayname>#{Xml.escape(@displayname)}</d:displayname>" if @displayname
      prop_lines << "<c:calendar-description>#{Xml.escape(@description)}</c:calendar-description>" if @description
      prop_lines << "<x:calendar-color>#{Xml.escape(@color)}</x:calendar-color>" if @color

      @props.each do |key, value|
        prop_lines << "<#{key}>#{Xml.escape(value)}</#{key}>"
      end

      <<~XML
        <d:response>
          <d:href>#{Xml.escape(@path.to_s)}</d:href>
          <d:propstat>
            <d:prop>
              #{prop_lines.join("\n          ")}
            </d:prop>
            <d:status>HTTP/1.1 200 OK</d:status>
          </d:propstat>
        </d:response>
      XML
    end
  end
end
