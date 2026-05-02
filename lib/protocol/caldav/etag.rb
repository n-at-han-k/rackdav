# frozen_string_literal: true

require "bundler/setup"
require "scampi"

require 'digest'

module Protocol
  module Caldav
    module ETag
      module_function

      def compute(body)
        %("#{Digest::SHA256.hexdigest(body)[0..15]}")
      end
    end
  end
end


test do
  describe "Protocol::Caldav::ETag" do
    it "is stable: same body produces same etag" do
      a = Protocol::Caldav::ETag.compute("hello")
      b = Protocol::Caldav::ETag.compute("hello")
      a.should.equal b
    end

    it "different bodies produce different etags" do
      a = Protocol::Caldav::ETag.compute("hello")
      b = Protocol::Caldav::ETag.compute("world")
      a.should.not.equal b
    end

    it "is double-quoted per RFC 7232" do
      etag = Protocol::Caldav::ETag.compute("test")
      etag.should.match(/\A"[0-9a-f]+"/)
    end

    it "truncates to consistent length" do
      etag = Protocol::Caldav::ETag.compute("test")
      inner = etag[1..-2] # strip quotes
      inner.length.should.equal 16
    end

    it "is binary-safe: body with null bytes produces an etag" do
      etag = Protocol::Caldav::ETag.compute("hello\x00world")
      etag.should.match(/\A"[0-9a-f]+"/)
    end
  end
end
