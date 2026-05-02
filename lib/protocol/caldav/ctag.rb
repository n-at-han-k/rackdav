# frozen_string_literal: true

require "bundler/setup"
require "scampi"

require 'digest'

module Protocol
  module Caldav
    module CTag
      module_function

      def compute(path:, displayname:, description: nil, color: nil, item_etags: [])
        sorted = item_etags.sort.join(":")
        Digest::SHA256.hexdigest("#{path}:#{displayname}:#{description}:#{color}:#{sorted}")[0..15]
      end
    end
  end
end


test do
  describe "Protocol::Caldav::CTag" do
    it "is stable for the same collection state" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work")
      b = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work")
      a.should.equal b
    end

    it "changes when displayname changes" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work")
      b = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Personal")
      a.should.not.equal b
    end

    it "changes when description changes" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", description: "desc1")
      b = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", description: "desc2")
      a.should.not.equal b
    end

    it "changes when color changes" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", color: "#ff0000")
      b = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", color: "#00ff00")
      a.should.not.equal b
    end

    it "changes when an item is added" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", item_etags: ["etag1"])
      b = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", item_etags: ["etag1", "etag2"])
      a.should.not.equal b
    end

    it "changes when an item etag changes" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", item_etags: ["etag1"])
      b = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", item_etags: ["etag2"])
      a.should.not.equal b
    end

    it "changes when an item is removed" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", item_etags: ["etag1", "etag2"])
      b = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", item_etags: ["etag1"])
      a.should.not.equal b
    end

    it "does not depend on item_etags order" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", item_etags: ["b", "a"])
      b = Protocol::Caldav::CTag.compute(path: "/cal/", displayname: "Work", item_etags: ["a", "b"])
      a.should.equal b
    end

    it "same state on different paths produces different ctags" do
      a = Protocol::Caldav::CTag.compute(path: "/cal/a/", displayname: "Work")
      b = Protocol::Caldav::CTag.compute(path: "/cal/b/", displayname: "Work")
      a.should.not.equal b
    end
  end
end
