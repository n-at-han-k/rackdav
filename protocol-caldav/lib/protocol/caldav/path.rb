# frozen_string_literal: true

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
