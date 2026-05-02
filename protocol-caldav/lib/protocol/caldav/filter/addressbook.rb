# frozen_string_literal: true

module Protocol
  module Caldav
    module Filter
      module Addressbook
        Filter = Struct.new(:test, :prop_filters, keyword_init: true) do
          def initialize(test: 'anyof', prop_filters: [])
            super
          end
        end

        PropFilter = Struct.new(:name, :is_not_defined, :text_match, :param_filters, keyword_init: true) do
          def initialize(name:, is_not_defined: false, text_match: nil, param_filters: [])
            super
          end
        end

        ParamFilter = Struct.new(:name, :is_not_defined, :text_match, keyword_init: true) do
          def initialize(name:, is_not_defined: false, text_match: nil)
            super
          end
        end

        TextMatch = Struct.new(:value, :collation, :match_type, :negate_condition, keyword_init: true) do
          def initialize(value:, collation: 'i;ascii-casemap', match_type: 'contains', negate_condition: false)
            super
          end
        end
      end
    end
  end
end
