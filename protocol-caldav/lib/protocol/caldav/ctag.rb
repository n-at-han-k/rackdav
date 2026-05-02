# frozen_string_literal: true

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
