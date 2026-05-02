# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module Storage
      class Mock < Protocol::Caldav::Storage
        def initialize
          @collections = {}
          @items = {}
          @sync_snapshots = {}  # token => { collection_path => { item_path => etag } }
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

        # --- Sync ---

        def snapshot_sync(collection_path)
          items = list_items(collection_path)
          snapshot = {}
          items.each { |path, data| snapshot[path] = data[:etag] }

          # Compute a token from the current state
          item_etags = items.map { |_, data| data[:etag] }
          col = @collections[collection_path] || {}
          ctag = Protocol::Caldav::CTag.compute(
            path: collection_path,
            displayname: col[:displayname],
            description: col[:description],
            color: col[:color],
            item_etags: item_etags
          )
          token = "http://caldav.local/sync/#{ctag}"

          @sync_snapshots[token] = { collection_path => snapshot }
          token
        end

        def sync_changes(collection_path, token)
          old_snapshot_entry = @sync_snapshots[token]
          return nil unless old_snapshot_entry

          old_snapshot = old_snapshot_entry[collection_path] || {}

          # Take new snapshot
          new_token = snapshot_sync(collection_path)
          current_items = list_items(collection_path)
          current = {}
          current_items.each { |path, data| current[path] = data[:etag] }

          changes = []

          # Items that are new or modified
          current.each do |path, etag|
            if !old_snapshot.key?(path) || old_snapshot[path] != etag
              changes << [path, :modified]
            end
          end

          # Items that were deleted
          old_snapshot.each_key do |path|
            unless current.key?(path)
              changes << [path, :deleted]
            end
          end

          [new_token, changes]
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
end


test do
  describe "Async::Caldav::Storage::Mock" do
    it "creates and retrieves a collection" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/calendars/admin/cal1/", type: :calendar, displayname: "Cal 1")
      col = s.get_collection("/calendars/admin/cal1/")
      col.should.not.be.nil
      col[:displayname].should.equal "Cal 1"
      col[:type].should.equal :calendar
    end

    it "deletes a collection and its items" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/calendars/admin/cal/")
      s.put_item("/calendars/admin/cal/event.ics", "VCALENDAR", "text/calendar")
      s.delete_collection("/calendars/admin/cal/")
      s.get_collection("/calendars/admin/cal/").should.be.nil
      s.get_item("/calendars/admin/cal/event.ics").should.be.nil
    end

    it "delete_collection does not affect siblings" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/calendars/admin/a/")
      s.create_collection("/calendars/admin/b/")
      s.delete_collection("/calendars/admin/a/")
      s.get_collection("/calendars/admin/b/").should.not.be.nil
    end

    it "delete_collection returns true/false" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/col/")
      s.delete_collection("/col/").should.equal true
      s.delete_collection("/col/").should.equal false
    end

    it "lists direct child collections only" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/calendars/admin/a/")
      s.create_collection("/calendars/admin/b/")
      s.create_collection("/calendars/admin/a/nested/")
      list = s.list_collections("/calendars/admin/")
      list.length.should.equal 2
    end

    it "list_collections returns empty on no children" do
      s = Async::Caldav::Storage::Mock.new
      s.list_collections("/nope/").should.equal []
    end

    it "updates collection properties, leaves others untouched" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/cal/", displayname: "Old", description: "Desc")
      s.update_collection("/cal/", displayname: "New")
      col = s.get_collection("/cal/")
      col[:displayname].should.equal "New"
      col[:description].should.equal "Desc"
    end

    it "update_collection returns nil for nonexistent" do
      s = Async::Caldav::Storage::Mock.new
      s.update_collection("/nope/", displayname: "X").should.be.nil
    end

    it "put_item returns is_new true for new, false for existing" do
      s = Async::Caldav::Storage::Mock.new
      _, is_new1 = s.put_item("/cal/ev.ics", "body1", "text/calendar")
      is_new1.should.equal true
      _, is_new2 = s.put_item("/cal/ev.ics", "body2", "text/calendar")
      is_new2.should.equal false
    end

    it "put_item overwrites the body" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item("/cal/ev.ics", "old", "text/calendar")
      s.put_item("/cal/ev.ics", "new", "text/calendar")
      s.get_item("/cal/ev.ics")[:body].should.equal "new"
    end

    it "get_item returns nil for nonexistent" do
      s = Async::Caldav::Storage::Mock.new
      s.get_item("/nope").should.be.nil
    end

    it "delete_item returns true/false" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item("/cal/ev.ics", "d", "text/calendar")
      s.delete_item("/cal/ev.ics").should.equal true
      s.delete_item("/cal/ev.ics").should.equal false
    end

    it "list_items returns only items, not collections" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/cal/")
      s.put_item("/cal/ev.ics", "data", "text/calendar")
      items = s.list_items("/cal/")
      items.length.should.equal 1
      items[0][0].should.equal "/cal/ev.ics"
    end

    it "list_items on empty collection returns empty" do
      s = Async::Caldav::Storage::Mock.new
      s.list_items("/empty/").should.equal []
    end

    it "move_item removes source, creates destination" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item("/cal/a.ics", "data", "text/calendar")
      s.move_item("/cal/a.ics", "/cal/b.ics")
      s.get_item("/cal/a.ics").should.be.nil
      s.get_item("/cal/b.ics")[:body].should.equal "data"
    end

    it "move_item returns nil when source missing" do
      s = Async::Caldav::Storage::Mock.new
      s.move_item("/nope", "/dest").should.be.nil
    end

    it "get_multi returns results in input order with nils for missing" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item("/cal/a.ics", "A", "text/calendar")
      result = s.get_multi(["/cal/a.ics", "/cal/nope.ics"])
      result.length.should.equal 2
      result[0][1][:body].should.equal "A"
      result[1][1].should.be.nil
    end

    it "get_multi with empty input returns empty" do
      s = Async::Caldav::Storage::Mock.new
      s.get_multi([]).should.equal []
    end

    it "exists? for items, collections, and nonexistent" do
      s = Async::Caldav::Storage::Mock.new
      s.exists?("/nope").should.equal false
      s.create_collection("/col/")
      s.exists?("/col/").should.equal true
      s.put_item("/col/x.ics", "d", "text/calendar")
      s.exists?("/col/x.ics").should.equal true
    end

    it "etag returns item etag, nil for nonexistent" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item("/cal/ev.ics", "body", "text/calendar")
      s.etag("/cal/ev.ics").should.not.be.nil
      s.etag("/nope").should.be.nil
    end

    it "etag changes when body changes" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item("/cal/ev.ics", "body1", "text/calendar")
      e1 = s.etag("/cal/ev.ics")
      s.put_item("/cal/ev.ics", "body2", "text/calendar")
      e2 = s.etag("/cal/ev.ics")
      e1.should.not.equal e2
    end

    it "snapshot_sync returns a token" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/cal/", type: :calendar)
      s.put_item("/cal/ev.ics", "body", "text/calendar")
      token = s.snapshot_sync("/cal/")
      token.should.not.be.nil
      token.should.include "http://caldav.local/sync/"
    end

    it "sync_changes returns empty changes when nothing changed" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/cal/", type: :calendar)
      s.put_item("/cal/ev.ics", "body", "text/calendar")
      token = s.snapshot_sync("/cal/")
      new_token, changes = s.sync_changes("/cal/", token)
      changes.should.equal []
      new_token.should.equal token
    end

    it "sync_changes detects added items" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/cal/", type: :calendar)
      token = s.snapshot_sync("/cal/")
      s.put_item("/cal/new.ics", "body", "text/calendar")
      _, changes = s.sync_changes("/cal/", token)
      changes.length.should.equal 1
      changes[0][0].should.equal "/cal/new.ics"
      changes[0][1].should.equal :modified
    end

    it "sync_changes detects deleted items" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/cal/", type: :calendar)
      s.put_item("/cal/ev.ics", "body", "text/calendar")
      token = s.snapshot_sync("/cal/")
      s.delete_item("/cal/ev.ics")
      _, changes = s.sync_changes("/cal/", token)
      changes.length.should.equal 1
      changes[0][0].should.equal "/cal/ev.ics"
      changes[0][1].should.equal :deleted
    end

    it "sync_changes detects modified items" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/cal/", type: :calendar)
      s.put_item("/cal/ev.ics", "body1", "text/calendar")
      token = s.snapshot_sync("/cal/")
      s.put_item("/cal/ev.ics", "body2", "text/calendar")
      _, changes = s.sync_changes("/cal/", token)
      changes.length.should.equal 1
      changes[0][1].should.equal :modified
    end

    it "sync_changes returns nil for invalid token" do
      s = Async::Caldav::Storage::Mock.new
      s.create_collection("/cal/", type: :calendar)
      s.sync_changes("/cal/", "bogus-token").should.be.nil
    end

    it "same body produces same etag" do
      s = Async::Caldav::Storage::Mock.new
      s.put_item("/a.ics", "same", "text/calendar")
      s.put_item("/b.ics", "same", "text/calendar")
      s.etag("/a.ics").should.equal s.etag("/b.ics")
    end
  end
end
