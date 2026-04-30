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

      # CTag -- clients use this to detect changes without fetching everything
      ctag = Digest::SHA256.hexdigest("#{@path}:#{@displayname}:#{@description}:#{@color}")[0..15]
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

test do
  def self.ctag(path, displayname, description = nil, color = nil)
    Digest::SHA256.hexdigest("#{path}:#{displayname}:#{description}:#{color}")[0..15]
  end

  def self.normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  it "renders exact propfind XML for a plain collection" do
    s = Caldav::Storage::Mock.new
    s.create_collection('/col/', type: :collection, displayname: 'Plain')
    p = Caldav::Path.new('/col/', storage_class: s)
    col = Caldav::DavCollection.find(p)
    normalize(col.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/col/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/></d:resourcetype>
            <d:displayname>Plain</d:displayname>
            <cs:getctag>#{ctag('/col/', 'Plain')}</cs:getctag>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "renders exact propfind XML for a calendar" do
    s = Caldav::Storage::Mock.new
    s.create_collection('/cal/', type: :calendar, displayname: 'Work')
    p = Caldav::Path.new('/cal/', storage_class: s)
    col = Caldav::DavCollection.find(p)
    normalize(col.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/cal/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
            <d:displayname>Work</d:displayname>
            <cs:getctag>#{ctag('/cal/', 'Work')}</cs:getctag>
            <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "renders exact propfind XML for an addressbook" do
    s = Caldav::Storage::Mock.new
    s.create_collection('/addr/', type: :addressbook, displayname: 'Contacts')
    p = Caldav::Path.new('/addr/', storage_class: s)
    col = Caldav::DavCollection.find(p)
    normalize(col.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/addr/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
            <d:displayname>Contacts</d:displayname>
            <cs:getctag>#{ctag('/addr/', 'Contacts')}</cs:getctag>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "renders exact XML for a calendar with all properties" do
    s = Caldav::Storage::Mock.new
    s.create_collection('/calendars/admin/work/', type: :calendar, displayname: 'Work', description: 'Work events', color: '#ff0000')
    p = Caldav::Path.new('/calendars/admin/work/', storage_class: s)
    col = Caldav::DavCollection.find(p)
    normalize(col.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/calendars/admin/work/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
            <d:displayname>Work</d:displayname>
            <c:calendar-description>Work events</c:calendar-description>
            <x:calendar-color>#ff0000</x:calendar-color>
            <cs:getctag>#{ctag('/calendars/admin/work/', 'Work', 'Work events', '#ff0000')}</cs:getctag>
            <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "renders exact XML for an addressbook (no calendar-specific props)" do
    s = Caldav::Storage::Mock.new
    s.create_collection('/addressbooks/admin/contacts/', type: :addressbook, displayname: 'Contacts')
    p = Caldav::Path.new('/addressbooks/admin/contacts/', storage_class: s)
    col = Caldav::DavCollection.find(p)
    normalize(col.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/addressbooks/admin/contacts/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/><cr:addressbook/></d:resourcetype>
            <d:displayname>Contacts</d:displayname>
            <cs:getctag>#{ctag('/addressbooks/admin/contacts/', 'Contacts')}</cs:getctag>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "renders calendar without displayname when nil" do
    s = Caldav::Storage::Mock.new
    s.create_collection('/cal/', type: :calendar)
    p = Caldav::Path.new('/cal/', storage_class: s)
    col = Caldav::DavCollection.find(p)
    normalize(col.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/cal/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
            <cs:getctag>#{ctag('/cal/', nil)}</cs:getctag>
            <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end

  it "escapes special characters in displayname" do
    s = Caldav::Storage::Mock.new
    s.create_collection('/cal/', type: :calendar, displayname: 'Work & <Personal>')
    p = Caldav::Path.new('/cal/', storage_class: s)
    col = Caldav::DavCollection.find(p)
    normalize(col.to_propfind_xml).should == normalize(<<~XML)
      <d:response>
        <d:href>/cal/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
            <d:displayname>Work &amp; &lt;Personal&gt;</d:displayname>
            <cs:getctag>#{ctag('/cal/', 'Work & <Personal>')}</cs:getctag>
            <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/><c:comp name="VJOURNAL"/></c:supported-calendar-component-set>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    XML
  end
end
