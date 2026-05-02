# frozen_string_literal: true

module Protocol
  module Caldav
    module Filter
      module Calendar
        CompFilter = Struct.new(:name, :is_not_defined, :time_range, :prop_filters, :comp_filters, keyword_init: true) do
          def initialize(name:, is_not_defined: false, time_range: nil, prop_filters: [], comp_filters: [])
            super
          end
        end

        PropFilter = Struct.new(:name, :is_not_defined, :time_range, :text_match, :param_filters, keyword_init: true) do
          def initialize(name:, is_not_defined: false, time_range: nil, text_match: nil, param_filters: [])
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

        TimeRange = Struct.new(:start_time, :end_time, keyword_init: true)
      end
    end
  end
end
