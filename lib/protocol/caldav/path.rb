# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "protocol/caldav"

module Protocol
  module Caldav
    class Path
      attr_reader :to_s, :storage_class

      def initialize(raw, storage_class: nil)
        p = raw.to_s.gsub(%r{/+}, '/')
        p = "/#{p}" unless p.start_with?('/')
        @to_s = p
        @storage_class = storage_class
      end

      def parent
        parts = @to_s.chomp('/').split('/')
        if parts.length <= 1
          self.class.new('/', storage_class: @storage_class)
        else
          self.class.new("#{parts[0..-2].join('/')}/", storage_class: @storage_class)
        end
      end

      def depth
        @to_s.chomp('/').split('/').reject(&:empty?).length
      end

      def child_of?(other)
        parent_str = other.to_s
        parent_str = "#{parent_str}/" unless parent_str.end_with?('/')
        if @to_s.start_with?(parent_str)
          remainder = @to_s[parent_str.length..]
          remainder.chomp('/').count('/').zero? && !remainder.chomp('/').empty?
        else
          false
        end
      end

      def parent_exists?
        raise ArgumentError, "storage_class required for parent_exists?" unless @storage_class

        if parent.depth <= 2
          true
        else
          @storage_class.collection_exists?(parent.to_s)
        end
      end

      def ensure_trailing_slash
        if @to_s.end_with?('/')
          self
        else
          self.class.new("#{@to_s}/", storage_class: @storage_class)
        end
      end

      def start_with?(prefix)
        @to_s.start_with?(prefix)
      end

      def ==(other)
        to_s == other.to_s
      end

      def to_propfind_xml
        <<~XML
          <d:response>
            <d:href>#{Xml.escape(@to_s)}</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        XML
      end
    end
  end
end


test do
  describe "Protocol::Caldav::Path" do
    it "normalizes // to /" do
      Protocol::Caldav::Path.new("//foo//bar").to_s.should.equal "/foo/bar"
    end

    it "normalizes leading ///foo to /foo" do
      Protocol::Caldav::Path.new("///foo").to_s.should.equal "/foo"
    end

    it "adds leading / if missing" do
      Protocol::Caldav::Path.new("foo/bar").to_s.should.equal "/foo/bar"
    end

    describe "#parent" do
      it "parent of /a/b/c/ is /a/b/" do
        Protocol::Caldav::Path.new("/a/b/c/").parent.to_s.should.equal "/a/b/"
      end

      it "parent of /a/ is /" do
        Protocol::Caldav::Path.new("/a/").parent.to_s.should.equal "/"
      end

      it "parent of / is / (idempotent)" do
        Protocol::Caldav::Path.new("/").parent.to_s.should.equal "/"
      end
    end

    describe "#depth" do
      it "depth of / is 0" do
        Protocol::Caldav::Path.new("/").depth.should.equal 0
      end

      it "depth of /a/ is 1" do
        Protocol::Caldav::Path.new("/a/").depth.should.equal 1
      end

      it "depth of /a/b is 2 (trailing-slash-insensitive)" do
        Protocol::Caldav::Path.new("/a/b").depth.should.equal 2
      end
    end

    describe "#child_of?" do
      it "returns true for direct child" do
        child = Protocol::Caldav::Path.new("/a/b/")
        parent = Protocol::Caldav::Path.new("/a/")
        child.child_of?(parent).should.equal true
      end

      it "returns false for grandchild" do
        grandchild = Protocol::Caldav::Path.new("/a/b/c/")
        grandparent = Protocol::Caldav::Path.new("/a/")
        grandchild.child_of?(grandparent).should.equal false
      end

      it "returns false for sibling" do
        a = Protocol::Caldav::Path.new("/a/b/")
        b = Protocol::Caldav::Path.new("/a/c/")
        a.child_of?(b).should.equal false
      end

      it "returns false for self" do
        a = Protocol::Caldav::Path.new("/a/")
        a.child_of?(a).should.equal false
      end
    end

    describe "#ensure_trailing_slash" do
      it "is idempotent on a slashed path" do
        Protocol::Caldav::Path.new("/a/").ensure_trailing_slash.to_s.should.equal "/a/"
      end

      it "adds slash to unslashed" do
        Protocol::Caldav::Path.new("/a").ensure_trailing_slash.to_s.should.equal "/a/"
      end
    end

    describe "#start_with?" do
      it "delegates to string semantics" do
        Protocol::Caldav::Path.new("/calendars/admin/").start_with?("/calendars/").should.equal true
        Protocol::Caldav::Path.new("/addressbooks/admin/").start_with?("/calendars/").should.equal false
      end
    end

    describe "#==" do
      it "paths with same string are equal" do
        a = Protocol::Caldav::Path.new("/a/")
        b = Protocol::Caldav::Path.new("/a/")
        (a == b).should.equal true
      end

      it "paths from different storage_class but same string compare equal" do
        a = Protocol::Caldav::Path.new("/a/", storage_class: Object.new)
        b = Protocol::Caldav::Path.new("/a/", storage_class: Object.new)
        (a == b).should.equal true
      end
    end
  end
end
