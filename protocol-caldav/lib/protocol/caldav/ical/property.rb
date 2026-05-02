# frozen_string_literal: true

module Protocol
  module Caldav
    module Ical
      Property = Struct.new(:name, :params, :value, keyword_init: true) do
        def param(key)
          params[key.upcase]
        end
      end
    end
  end
end
