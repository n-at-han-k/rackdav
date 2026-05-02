# frozen_string_literal: true

module Protocol
  module Caldav
    module Ical
      Component = Struct.new(:name, :properties, :components, keyword_init: true) do
        def initialize(name:, properties: [], components: [])
          super(name: name, properties: properties, components: components)
        end

        def find_property(prop_name)
          properties.find { |p| p.name.casecmp?(prop_name) }
        end

        def find_all_properties(prop_name)
          properties.select { |p| p.name.casecmp?(prop_name) }
        end

        def find_components(comp_name)
          components.select { |c| c.name.casecmp?(comp_name) }
        end
      end
    end
  end
end
