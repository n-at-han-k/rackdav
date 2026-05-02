# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  class Storage
    # Test-only storage backend. Stores everything in hashes.
    # Not for production use -- use Storage::Filesystem instead.
    class Mock < Storage
      def initialize
        @collections = {}
        @items = {}
      end

      # --- Collections ---

      def create_collection(path, props = {})
        col = {
          type: props[:type] || :collection,
          displayname: props[:displayname],
          description: props[:description],
          color: props[:color],
          props: props[:props] || {}
        }
        @collections[path] = col
        col
      end

      def get_collection(path)
        @collections[path]
      end

      def delete_collection(path)
        if @collections.delete(path)
          @items.delete_if { |k, _| k.start_with?(path) }
          true
        else
          false
        end
      end

      def list_collections(parent_path)
        parent = parent_path.end_with?('/') ? parent_path : "#{parent_path}/"
        @collections.select { |k, _| direct_child?(k, parent) }.to_a
      end

      def update_collection(path, props)
        col = @collections[path]
        if col
          col[:displayname] = props[:displayname] if props.key?(:displayname)
          col[:description] = props[:description] if props.key?(:description)
          col[:color] = props[:color] if props.key?(:color)
          col[:props] = (col[:props] || {}).merge(props[:props]) if props.key?(:props)
          col
        end
      end

      def collection_exists?(path)
        @collections.key?(path)
      end

      # --- Items ---

      def get_item(path)
        @items[path]
      end

      def put_item(path, body, content_type)
        etag = Protocol::Caldav::ETag.compute(body)
        is_new = !@items.key?(path)
        item = { body: body, content_type: content_type, etag: etag }
        @items[path] = item
        [item, is_new]
      end

      def delete_item(path)
        !!@items.delete(path)
      end

      def list_items(collection_path)
        prefix = collection_path.end_with?('/') ? collection_path : "#{collection_path}/"
        @items.select { |k, _| k.start_with?(prefix) && k != collection_path }.to_a
      end

      def move_item(from_path, to_path)
        item = @items.delete(from_path)
        if item
          @items[to_path] = item
          item
        end
      end

      def get_multi(paths)
        paths.map { |p| [p, @items[p]] }
      end

      # --- General ---

      def exists?(path)
        @items.key?(path) || @collections.key?(path)
      end

      def etag(path)
        item = @items[path]
        item ? item[:etag] : nil
      end

      private

      def direct_child?(child, parent)
        if child.start_with?(parent)
          remainder = child[parent.length..]
          remainder.chomp('/').count('/').zero? && !remainder.chomp('/').empty?
        else
          false
        end
      end
    end
  end
end

test do
  it "creates and retrieves a collection" do
    s = Caldav::Storage::Mock.new
    s.create_collection("/calendars/admin/cal1/", type: :calendar, displayname: "Cal 1")
    col = s.get_collection("/calendars/admin/cal1/")
    col.should.not.be.nil
    col[:displayname].should == "Cal 1"
    col[:type].should == :calendar
  end

  it "deletes a collection and its items" do
    s = Caldav::Storage::Mock.new
    s.create_collection("/calendars/admin/cal/")
    s.put_item("/calendars/admin/cal/event.ics", "VCALENDAR", "text/calendar")
    s.delete_collection("/calendars/admin/cal/")
    s.get_collection("/calendars/admin/cal/").should.be.nil
    s.get_item("/calendars/admin/cal/event.ics").should.be.nil
  end

  it "lists direct child collections" do
    s = Caldav::Storage::Mock.new
    s.create_collection("/calendars/admin/a/")
    s.create_collection("/calendars/admin/b/")
    list = s.list_collections("/calendars/admin/")
    list.length.should == 2
  end

  it "updates collection properties" do
    s = Caldav::Storage::Mock.new
    s.create_collection("/calendars/admin/cal/", displayname: "Old")
    s.update_collection("/calendars/admin/cal/", displayname: "New")
    s.get_collection("/calendars/admin/cal/")[:displayname].should == "New"
  end

  it "puts and retrieves an item with etag" do
    s = Caldav::Storage::Mock.new
    item, is_new = s.put_item("/cal/event.ics", "BEGIN:VCALENDAR", "text/calendar")
    is_new.should.be.true
    item[:etag].should.not.be.nil
    s.get_item("/cal/event.ics")[:body].should == "BEGIN:VCALENDAR"
  end

  it "deletes an item" do
    s = Caldav::Storage::Mock.new
    s.put_item("/cal/event.ics", "data", "text/calendar")
    s.delete_item("/cal/event.ics").should.be.true
    s.get_item("/cal/event.ics").should.be.nil
    s.delete_item("/cal/event.ics").should.be.false
  end

  it "moves an item" do
    s = Caldav::Storage::Mock.new
    s.put_item("/cal/a.ics", "data", "text/calendar")
    s.move_item("/cal/a.ics", "/cal/b.ics")
    s.get_item("/cal/a.ics").should.be.nil
    s.get_item("/cal/b.ics")[:body].should == "data"
  end

  it "reports existence correctly" do
    s = Caldav::Storage::Mock.new
    s.exists?("/nope").should.be.false
    s.create_collection("/col/")
    s.exists?("/col/").should.be.true
    s.put_item("/col/x.ics", "d", "text/calendar")
    s.exists?("/col/x.ics").should.be.true
  end
end
