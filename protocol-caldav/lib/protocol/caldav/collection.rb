# frozen_string_literal: true

module Protocol
  module Caldav
    class Collection
      attr_reader :path, :type, :displayname, :description, :color, :props

      def initialize(path:, type: :collection, displayname: nil, description: nil, color: nil, props: {})
        @path = path
        @type = type
        @displayname = displayname
        @description = description
        @color = color
        @props = props || {}
      end

      def update_attrs(updates)
        @displayname = updates[:displayname] if updates.key?(:displayname)
        @description = updates[:description] if updates.key?(:description)
        @color = updates[:color] if updates.key?(:color)
        @props = (@props || {}).merge(updates[:props]) if updates.key?(:props)
        self
      end

      def to_propfind_xml
        prop_lines = []

        if @type == :calendar
          prop_lines << '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>'
        elsif @type == :addressbook
          prop_lines << '<d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>'
        else
          prop_lines << '<d:resourcetype><d:collection/></d:resourcetype>'
        end

        prop_lines << "<d:displayname>#{Xml.escape(@displayname)}</d:displayname>" if @displayname
        prop_lines << "<c:calendar-description>#{Xml.escape(@description)}</c:calendar-description>" if @description
        prop_lines << "<x:calendar-color>#{Xml.escape(@color)}</x:calendar-color>" if @color

        item_etags = @path.storage_class.list_items(@path.to_s).map { |_, data| data[:etag] }
        ctag = CTag.compute(
          path: @path.to_s,
          displayname: @displayname,
          description: @description,
          color: @color,
          item_etags: item_etags
        )
        prop_lines << "<cs:getctag>#{ctag}</cs:getctag>"

        if @type == :calendar
          prop_lines << '<c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>'
        end

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
end
