# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  class Storage < Protocol::Caldav::Storage
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
