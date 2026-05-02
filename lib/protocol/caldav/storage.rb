# frozen_string_literal: true

require "bundler/setup"
require "scampi"

module Protocol
  module Caldav
    class Storage
      # --- Collections ---

      def create_collection(path, props = {})
        raise NotImplementedError
      end

      def get_collection(path)
        raise NotImplementedError
      end

      def delete_collection(path)
        raise NotImplementedError
      end

      def list_collections(parent_path)
        raise NotImplementedError
      end

      def update_collection(path, props)
        raise NotImplementedError
      end

      def collection_exists?(path)
        raise NotImplementedError
      end

      # --- Items ---

      def get_item(path)
        raise NotImplementedError
      end

      def put_item(path, body, content_type)
        raise NotImplementedError
      end

      def delete_item(path)
        raise NotImplementedError
      end

      def list_items(collection_path)
        raise NotImplementedError
      end

      def move_item(from_path, to_path)
        raise NotImplementedError
      end

      def get_multi(paths)
        raise NotImplementedError
      end

      # --- General ---

      def exists?(path)
        raise NotImplementedError
      end

      def etag(path)
        raise NotImplementedError
      end

      # --- Sync ---

      # Snapshot the current item state for a collection and return a sync token.
      # Subsequent calls to sync_changes with this token return the diff.
      def snapshot_sync(collection_path)
        raise NotImplementedError
      end

      # Return [new_token, changes] where changes is an array of [path, status]
      # status is :modified (200) or :deleted (404).
      # Returns nil if the token is invalid/unknown.
      def sync_changes(collection_path, token)
        raise NotImplementedError
      end
    end
  end
end


test do
  describe "Protocol::Caldav::Storage" do
    it "every method raises NotImplementedError" do
      s = Protocol::Caldav::Storage.new
      methods = %i[create_collection get_collection delete_collection list_collections
                   update_collection collection_exists? get_item put_item delete_item
                   list_items move_item get_multi exists? etag snapshot_sync sync_changes]
      three_arg = %i[put_item]
      two_arg = %i[update_collection move_item sync_changes]
      methods.each do |m|
        if three_arg.include?(m)
          lambda { s.send(m, "/x", "body", "ct") }.should.raise NotImplementedError
        elsif two_arg.include?(m)
          lambda { s.send(m, "/x", {}) }.should.raise NotImplementedError
        else
          lambda { s.send(m, "/x") }.should.raise NotImplementedError
        end
      end
    end

    it "can be subclassed with partial implementation" do
      klass = Class.new(Protocol::Caldav::Storage) do
        def exists?(path)
          true
        end
      end
      klass.new.exists?("/x").should.equal true
      lambda { klass.new.get_item("/x") }.should.raise NotImplementedError
    end
  end
end
