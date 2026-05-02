# frozen_string_literal: true

require "bundler/setup"
require "scampi"

require "protocol/caldav"

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
        prop_lines << "<d:sync-token>http://caldav.local/sync/#{ctag}</d:sync-token>"

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

      def to_propname_xml
        names = ['<d:resourcetype/>']
        names << '<d:displayname/>' if @displayname
        names << '<c:calendar-description/>' if @description
        names << '<x:calendar-color/>' if @color
        names << '<cs:getctag/>'
        names << '<d:sync-token/>'
        names << '<c:supported-calendar-component-set/>' if @type == :calendar

        <<~XML
          <d:response>
            <d:href>#{Xml.escape(@path.to_s)}</d:href>
            <d:propstat>
              <d:prop>
                #{names.join("\n          ")}
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML
      end
    end
  end
end

test do
  def normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  # Minimal mock storage for Collection tests
  class MockStorageForCollection < Protocol::Caldav::Storage
    def list_items(_path)
      []
    end
  end

  describe "Protocol::Caldav::Collection" do
    def make_collection(type: :calendar, displayname: "Work", **opts)
      storage = MockStorageForCollection.new
      path = Protocol::Caldav::Path.new("/calendars/admin/work/", storage_class: storage)
      Protocol::Caldav::Collection.new(path: path, type: type, displayname: displayname, **opts)
    end

    it "renders calendar resourcetype" do
      xml = make_collection(type: :calendar).to_propfind_xml
      xml.should.include "<c:calendar/>"
    end

    it "renders addressbook resourcetype" do
      xml = make_collection(type: :addressbook).to_propfind_xml
      xml.should.include "<cr:addressbook/>"
    end

    it "includes displayname when set" do
      xml = make_collection(displayname: "Work").to_propfind_xml
      xml.should.include "<d:displayname>Work</d:displayname>"
    end

    it "omits displayname when nil" do
      xml = make_collection(displayname: nil).to_propfind_xml
      xml.should.not.include "displayname"
    end

    it "includes ctag" do
      xml = make_collection.to_propfind_xml
      xml.should.include "<cs:getctag>"
    end

    it "includes supported-calendar-component-set for calendars" do
      xml = make_collection(type: :calendar).to_propfind_xml
      xml.should.include "supported-calendar-component-set"
    end

    it "omits supported-calendar-component-set for addressbooks" do
      xml = make_collection(type: :addressbook).to_propfind_xml
      xml.should.not.include "supported-calendar-component-set"
    end

    it "escapes special characters in displayname" do
      xml = make_collection(displayname: "Work & <Personal>").to_propfind_xml
      xml.should.include "Work &amp; &lt;Personal&gt;"
    end

    it "update_attrs modifies named fields" do
      col = make_collection(displayname: "Old")
      col.update_attrs(displayname: "New")
      col.displayname.should.equal "New"
    end

    it "update_attrs leaves unmentioned fields alone" do
      col = make_collection(displayname: "Work", description: "Desc")
      col.update_attrs(displayname: "New")
      col.description.should.equal "Desc"
    end
  end
end
