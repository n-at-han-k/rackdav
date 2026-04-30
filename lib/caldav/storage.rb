# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  # Abstract base class for storage backends.
  #
  # Subclass this and override every method to implement a custom backend
  # (filesystem, database, etc.). The default in-memory implementation is
  # Caldav::Storage::Memory.
  #
  # Collections are returned as DavCollection instances.
  # Items are returned as DavItem instances.
  class Storage
    # --- Collections ---

    # Create a collection at +path+.
    # Returns a DavCollection.
    def create_collection(path, props = {})
      raise NotImplementedError
    end

    # Return the DavCollection at +path+, or nil.
    def get_collection(path)
      raise NotImplementedError
    end

    # Delete the collection at +path+ and all its child items.
    def delete_collection(path)
      raise NotImplementedError
    end

    # Return an array of [path, DavCollection] for direct children of +parent_path+.
    def list_collections(parent_path)
      raise NotImplementedError
    end

    # Update properties on an existing collection. Returns the updated DavCollection.
    def update_collection(path, props)
      raise NotImplementedError
    end

    # Return true if a collection exists at +path+.
    def collection_exists?(path)
      raise NotImplementedError
    end

    # --- Items ---

    # Return the DavItem at +path+, or nil.
    def get_item(path)
      raise NotImplementedError
    end

    # Store an item at +path+. Returns [DavItem, is_new].
    def put_item(path, body, content_type)
      raise NotImplementedError
    end

    # Delete the item at +path+. Returns true if it existed, false otherwise.
    def delete_item(path)
      raise NotImplementedError
    end

    # Return an array of [path, DavItem] for all items in +collection_path+.
    def list_items(collection_path)
      raise NotImplementedError
    end

    # Move an item from +from_path+ to +to_path+. Returns the DavItem.
    def move_item(from_path, to_path)
      raise NotImplementedError
    end

    # Return an array of [path, DavItem|nil] for the given +paths+.
    def get_multi(paths)
      raise NotImplementedError
    end

    # --- General ---

    # Return true if an item OR collection exists at +path+.
    def exists?(path)
      raise NotImplementedError
    end

    # Return the etag for the resource at +path+, or nil.
    def etag(path)
      raise NotImplementedError
    end
  end
end

test do
  it "raises NotImplementedError for all abstract methods" do
    s = Caldav::Storage.new
    lambda { s.create_collection('/x') }.should.raise(NotImplementedError)
    lambda { s.get_collection('/x') }.should.raise(NotImplementedError)
    lambda { s.delete_collection('/x') }.should.raise(NotImplementedError)
    lambda { s.list_collections('/x') }.should.raise(NotImplementedError)
    lambda { s.update_collection('/x', {}) }.should.raise(NotImplementedError)
    lambda { s.collection_exists?('/x') }.should.raise(NotImplementedError)
    lambda { s.get_item('/x') }.should.raise(NotImplementedError)
    lambda { s.put_item('/x', '', '') }.should.raise(NotImplementedError)
    lambda { s.delete_item('/x') }.should.raise(NotImplementedError)
    lambda { s.list_items('/x') }.should.raise(NotImplementedError)
    lambda { s.move_item('/x', '/y') }.should.raise(NotImplementedError)
    lambda { s.get_multi(['/x']) }.should.raise(NotImplementedError)
    lambda { s.exists?('/x') }.should.raise(NotImplementedError)
    lambda { s.etag('/x') }.should.raise(NotImplementedError)
  end
end
