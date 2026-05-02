# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"
require 'json'
require 'fileutils'

module Async
  module Caldav
    module Storage
      class Filesystem < Protocol::Caldav::Storage
        def initialize(root)
          @root = root
          @sync_snapshots = {}
          FileUtils.mkdir_p(@root)
        end

        # --- Collections ---

        def create_collection(path, props = {})
          dir = full_path(path)
          FileUtils.mkdir_p(dir)
          meta = {
            "type" => (props[:type] || :collection).to_s,
            "displayname" => props[:displayname],
            "description" => props[:description],
            "color" => props[:color],
            "props" => props[:props] || {}
          }
          File.write(File.join(dir, ".collection.json"), JSON.pretty_generate(meta))
          symbolize(meta)
        end

        def get_collection(path)
          meta_file = File.join(full_path(path), ".collection.json")
          return nil unless File.exist?(meta_file)
          symbolize(JSON.parse(File.read(meta_file)))
        end

        def delete_collection(path)
          dir = full_path(path)
          if File.directory?(dir)
            FileUtils.rm_rf(dir)
            true
          else
            false
          end
        end

        def list_collections(parent_path)
          dir = full_path(parent_path)
          return [] unless File.directory?(dir)

          Dir.children(dir).filter_map do |name|
            child_dir = File.join(dir, name)
            meta_file = File.join(child_dir, ".collection.json")
            next unless File.directory?(child_dir) && File.exist?(meta_file)

            child_path = File.join(parent_path, name).sub(%r{/*$}, "/")
            [child_path, symbolize(JSON.parse(File.read(meta_file)))]
          end
        end

        def update_collection(path, props)
          col = get_collection(path)
          return nil unless col

          col[:displayname] = props[:displayname] if props.key?(:displayname)
          col[:description] = props[:description] if props.key?(:description)
          col[:color] = props[:color] if props.key?(:color)
          col[:props] = (col[:props] || {}).merge(props[:props]) if props.key?(:props)

          meta = {
            "type" => col[:type].to_s,
            "displayname" => col[:displayname],
            "description" => col[:description],
            "color" => col[:color],
            "props" => col[:props] || {}
          }
          File.write(File.join(full_path(path), ".collection.json"), JSON.pretty_generate(meta))
          col
        end

        def collection_exists?(path)
          File.exist?(File.join(full_path(path), ".collection.json"))
        end

        # --- Items ---

        def get_item(path)
          file = full_path(path)
          return nil unless File.file?(file)

          body = File.read(file)
          content_type = guess_content_type(path)
          etag = Protocol::Caldav::ETag.compute(body)
          { body: body, content_type: content_type, etag: etag }
        end

        def put_item(path, body, content_type)
          file = full_path(path)
          is_new = !File.exist?(file)
          FileUtils.mkdir_p(File.dirname(file))
          File.write(file, body)
          etag = Protocol::Caldav::ETag.compute(body)
          item = { body: body, content_type: content_type, etag: etag }
          [item, is_new]
        end

        def delete_item(path)
          file = full_path(path)
          if File.file?(file)
            File.delete(file)
            true
          else
            false
          end
        end

        def list_items(collection_path)
          dir = full_path(collection_path)
          return [] unless File.directory?(dir)

          Dir.children(dir).filter_map do |name|
            next if name.start_with?(".")
            file = File.join(dir, name)
            next unless File.file?(file)

            item_path = File.join(collection_path, name)
            body = File.read(file)
            content_type = guess_content_type(name)
            etag = Protocol::Caldav::ETag.compute(body)
            [item_path, { body: body, content_type: content_type, etag: etag }]
          end
        end

        def move_item(from_path, to_path)
          src = full_path(from_path)
          dst = full_path(to_path)
          return nil unless File.file?(src)

          FileUtils.mkdir_p(File.dirname(dst))
          FileUtils.mv(src, dst)
          get_item(to_path)
        end

        def get_multi(paths)
          paths.map { |p| [p, get_item(p)] }
        end

        # --- General ---

        def exists?(path)
          fp = full_path(path)
          File.exist?(fp) || collection_exists?(path)
        end

        def etag(path)
          item = get_item(path)
          item ? item[:etag] : nil
        end

        # --- Sync ---

        def snapshot_sync(collection_path)
          items = list_items(collection_path)
          snapshot = {}
          items.each { |path, data| snapshot[path] = data[:etag] }

          col = get_collection(collection_path) || {}
          item_etags = items.map { |_, data| data[:etag] }
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
          new_token = snapshot_sync(collection_path)
          current_items = list_items(collection_path)
          current = {}
          current_items.each { |path, data| current[path] = data[:etag] }

          changes = []
          current.each do |path, etag|
            if !old_snapshot.key?(path) || old_snapshot[path] != etag
              changes << [path, :modified]
            end
          end
          old_snapshot.each_key do |path|
            changes << [path, :deleted] unless current.key?(path)
          end

          [new_token, changes]
        end

        private

        def full_path(path)
          File.join(@root, path)
        end

        def guess_content_type(path)
          case File.extname(path).downcase
          when ".ics" then "text/calendar"
          when ".vcf" then "text/vcard"
          else "application/octet-stream"
          end
        end

        def symbolize(hash)
          {
            type: hash["type"]&.to_sym || :collection,
            displayname: hash["displayname"],
            description: hash["description"],
            color: hash["color"],
            props: hash["props"] || {}
          }
        end
      end
    end
  end
end

require 'tmpdir'

test do
  describe "Async::Caldav::Storage::Filesystem" do
    it "creates and retrieves a collection" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.create_collection("/cal/", type: :calendar, displayname: "Cal")
        col = s.get_collection("/cal/")
        col[:displayname].should.equal "Cal"
        col[:type].should.equal :calendar
      end
    end

    it "deletes collection and its items" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.create_collection("/cal/")
        s.put_item("/cal/ev.ics", "data", "text/calendar")
        s.delete_collection("/cal/")
        s.get_collection("/cal/").should.be.nil
        s.get_item("/cal/ev.ics").should.be.nil
      end
    end

    it "lists direct child collections" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.create_collection("/admin/a/")
        s.create_collection("/admin/b/")
        s.list_collections("/admin/").length.should.equal 2
      end
    end

    it "updates collection properties" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.create_collection("/cal/", displayname: "Old")
        s.update_collection("/cal/", displayname: "New")
        s.get_collection("/cal/")[:displayname].should.equal "New"
      end
    end

    it "puts and retrieves an item with etag" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        item, is_new = s.put_item("/cal/ev.ics", "BEGIN:VCALENDAR", "text/calendar")
        is_new.should.equal true
        item[:etag].should.not.be.nil
        s.get_item("/cal/ev.ics")[:body].should.equal "BEGIN:VCALENDAR"
      end
    end

    it "persists across instances" do
      Dir.mktmpdir do |dir|
        s1 = Async::Caldav::Storage::Filesystem.new(dir)
        s1.create_collection("/cal/", type: :calendar, displayname: "Persist")
        s1.put_item("/cal/ev.ics", "body", "text/calendar")

        s2 = Async::Caldav::Storage::Filesystem.new(dir)
        s2.get_collection("/cal/")[:displayname].should.equal "Persist"
        s2.get_item("/cal/ev.ics")[:body].should.equal "body"
      end
    end

    it "list_items excludes hidden files" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.create_collection("/cal/")
        s.put_item("/cal/ev.ics", "EVENT", "text/calendar")
        items = s.list_items("/cal/")
        items.map(&:first).any? { |p| p.include?(".collection.json") }.should.equal false
        items.map(&:first).any? { |p| p.include?("ev.ics") }.should.equal true
      end
    end

    it "deletes an item" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.put_item("/cal/ev.ics", "data", "text/calendar")
        s.delete_item("/cal/ev.ics").should.equal true
        s.get_item("/cal/ev.ics").should.be.nil
        s.delete_item("/cal/ev.ics").should.equal false
      end
    end

    it "moves an item" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.put_item("/cal/a.ics", "data", "text/calendar")
        s.move_item("/cal/a.ics", "/cal/b.ics")
        s.get_item("/cal/a.ics").should.be.nil
        s.get_item("/cal/b.ics")[:body].should.equal "data"
      end
    end

    it "reports existence correctly" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.exists?("/nope").should.equal false
        s.create_collection("/col/")
        s.exists?("/col/").should.equal true
        s.put_item("/col/x.ics", "d", "text/calendar")
        s.exists?("/col/x.ics").should.equal true
      end
    end

    it "get_multi returns items and nils" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.put_item("/cal/a.ics", "A", "text/calendar")
        result = s.get_multi(["/cal/a.ics", "/cal/nope.ics"])
        result.length.should.equal 2
        result[0][1][:body].should.equal "A"
        result[1][1].should.be.nil
      end
    end

    it "guesses content types from extension" do
      Dir.mktmpdir do |dir|
        s = Async::Caldav::Storage::Filesystem.new(dir)
        s.put_item("/cal/ev.ics", "cal", "text/calendar")
        s.put_item("/addr/c.vcf", "card", "text/vcard")
        s.get_item("/cal/ev.ics")[:content_type].should.equal "text/calendar"
        s.get_item("/addr/c.vcf")[:content_type].should.equal "text/vcard"
      end
    end

    it "same body produces same etag across backends" do
      body = "BEGIN:VCALENDAR\r\nEND:VCALENDAR"
      mock = Async::Caldav::Storage::Mock.new
      mock.put_item("/a.ics", body, "text/calendar")
      Dir.mktmpdir do |dir|
        fs = Async::Caldav::Storage::Filesystem.new(dir)
        fs.put_item("/a.ics", body, "text/calendar")
        mock.etag("/a.ics").should.equal fs.etag("/a.ics")
      end
    end
  end
end
