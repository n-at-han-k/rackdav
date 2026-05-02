# frozen_string_literal: true

module Protocol
  module Caldav
    module Vcard
      Card = Struct.new(:properties, keyword_init: true) do
        def initialize(properties: [])
          super(properties: properties)
        end

        def find_property(prop_name)
          properties.find { |p| p.name.casecmp?(prop_name) }
        end

        def find_all_properties(prop_name)
          properties.select { |p| p.name.casecmp?(prop_name) }
        end
      end
    end
  end
end
