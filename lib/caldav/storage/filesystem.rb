# frozen_string_literal: true

require "bundler/setup"
require "caldav"
require "json"
require "digest"
require "fileutils"

module Caldav
  class Storage
    # Persistent filesystem-backed storage.
    #
    # Layout:
    #   <root>/
    #     calendars/
    #       admin/
    #         cal1/
    #           .collection.json   # collection metadata
    #           event1.ics
    #           event2.ics
    #     contacts/
    #       admin/
    #         addressbook/
    #           .collection.json
    #           contact1.vcf
    class Filesystem < Storage
      def initialize(root)
        @root = root
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
        etag = compute_etag(body)
        { body: body, content_type: content_type, etag: etag }
      end

      def put_item(path, body, content_type)
        file = full_path(path)
        is_new = !File.exist?(file)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, body)
        etag = compute_etag(body)
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
          etag = compute_etag(body)
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

      private

      def full_path(path)
        File.join(@root, path)
      end

      def compute_etag(body)
        %("#{Digest::SHA256.hexdigest(body)[0..15]}")
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

test do
  require 'tmpdir'

  it "creates and retrieves a collection" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.create_collection("/calendars/admin/cal1/", type: :calendar, displayname: "Cal 1")
      col = s.get_collection("/calendars/admin/cal1/")
      col.should.not.be.nil
      col[:displayname].should == "Cal 1"
      col[:type].should == :calendar
    end
  end

  it "deletes a collection and its items" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.create_collection("/calendars/admin/cal/")
      s.put_item("/calendars/admin/cal/event.ics", "VCALENDAR", "text/calendar")
      s.delete_collection("/calendars/admin/cal/")
      s.get_collection("/calendars/admin/cal/").should.be.nil
      s.get_item("/calendars/admin/cal/event.ics").should.be.nil
    end
  end

  it "lists direct child collections" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.create_collection("/calendars/admin/a/")
      s.create_collection("/calendars/admin/b/")
      list = s.list_collections("/calendars/admin/")
      list.length.should == 2
    end
  end

  it "updates collection properties" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.create_collection("/calendars/admin/cal/", displayname: "Old")
      s.update_collection("/calendars/admin/cal/", displayname: "New")
      s.get_collection("/calendars/admin/cal/")[:displayname].should == "New"
    end
  end

  it "puts and retrieves an item with etag" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      item, is_new = s.put_item("/cal/event.ics", "BEGIN:VCALENDAR", "text/calendar")
      is_new.should.be.true
      item[:etag].should.not.be.nil
      s.get_item("/cal/event.ics")[:body].should == "BEGIN:VCALENDAR"
    end
  end

  it "deletes an item" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.put_item("/cal/event.ics", "data", "text/calendar")
      s.delete_item("/cal/event.ics").should.be.true
      s.get_item("/cal/event.ics").should.be.nil
      s.delete_item("/cal/event.ics").should.be.false
    end
  end

  it "moves an item" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.put_item("/cal/a.ics", "data", "text/calendar")
      s.move_item("/cal/a.ics", "/cal/b.ics")
      s.get_item("/cal/a.ics").should.be.nil
      s.get_item("/cal/b.ics")[:body].should == "data"
    end
  end

  it "reports existence correctly" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.exists?("/nope").should.be.false
      s.create_collection("/col/")
      s.exists?("/col/").should.be.true
      s.put_item("/col/x.ics", "d", "text/calendar")
      s.exists?("/col/x.ics").should.be.true
    end
  end

  it "persists data across instances" do
    Dir.mktmpdir do |dir|
      s1 = Caldav::Storage::Filesystem.new(dir)
      s1.create_collection("/cal/", type: :calendar, displayname: "Persist")
      s1.put_item("/cal/ev.ics", "BEGIN:VCALENDAR", "text/calendar")

      s2 = Caldav::Storage::Filesystem.new(dir)
      s2.get_collection("/cal/")[:displayname].should == "Persist"
      s2.get_item("/cal/ev.ics")[:body].should == "BEGIN:VCALENDAR"
    end
  end

  it "lists items excluding hidden files" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.create_collection("/cal/")
      s.put_item("/cal/ev.ics", "EVENT", "text/calendar")
      items = s.list_items("/cal/")
      paths = items.map(&:first)
      paths.any? { |p| p.include?(".collection.json") }.should.be.false
      paths.any? { |p| p.include?("ev.ics") }.should.be.true
    end
  end

  it "guesses content types from extension" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.put_item("/cal/ev.ics", "cal", "text/calendar")
      s.put_item("/addr/c.vcf", "card", "text/vcard")
      s.get_item("/cal/ev.ics")[:content_type].should == "text/calendar"
      s.get_item("/addr/c.vcf")[:content_type].should == "text/vcard"
    end
  end

  it "returns nil for non-existent collection and item" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.get_collection("/nope/").should.be.nil
      s.get_item("/nope/x.ics").should.be.nil
    end
  end

  it "get_multi returns items and nils" do
    Dir.mktmpdir do |dir|
      s = Caldav::Storage::Filesystem.new(dir)
      s.put_item("/cal/a.ics", "A", "text/calendar")
      result = s.get_multi(["/cal/a.ics", "/cal/nope.ics"])
      result.length.should == 2
      result[0][1][:body].should == "A"
      result[1][1].should.be.nil
    end
  end
end
