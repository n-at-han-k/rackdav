# frozen_string_literal: true

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
