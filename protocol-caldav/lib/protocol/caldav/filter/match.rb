# frozen_string_literal: true

module Protocol
  module Caldav
    module Filter
      module Match
        module_function

        # --- Calendar (RFC 4791 §9.7) ---

        def calendar?(filter, component)
          return false unless component
          comp_filter_matches?(filter, component)
        end

        # --- Addressbook (RFC 6352 §10.5) ---

        def addressbook?(filter, card)
          return false unless card
          return true if filter.prop_filters.empty?

          if filter.test == 'allof'
            filter.prop_filters.all? { |pf| card_prop_filter_matches?(pf, card) }
          else
            filter.prop_filters.any? { |pf| card_prop_filter_matches?(pf, card) }
          end
        end

        # --- Private: Calendar matching ---

        def comp_filter_matches?(filter, component)
          return false unless component.name.casecmp?(filter.name)
          return false if filter.is_not_defined

          # All nested prop-filters must match (AND)
          return false unless filter.prop_filters.all? { |pf| prop_filter_matches?(pf, component) }

          # All nested comp-filters must match
          filter.comp_filters.all? do |cf|
            children = component.find_components(cf.name)
            if cf.is_not_defined
              children.empty?
            else
              children.any? { |child| comp_filter_matches?(cf, child) }
            end
          end
        end

        def prop_filter_matches?(filter, component)
          properties = component.find_all_properties(filter.name)

          if filter.is_not_defined
            return properties.empty?
          end

          return false if properties.empty?

          properties.any? do |prop|
            next false if filter.text_match && !text_match_matches?(filter.text_match, prop.value)
            filter.param_filters.all? { |pf| param_filter_matches?(pf, prop) }
          end
        end

        def param_filter_matches?(filter, property)
          param_value = property.param(filter.name)

          if filter.is_not_defined
            return param_value.nil?
          end

          return false if param_value.nil?

          if filter.text_match
            text_match_matches?(filter.text_match, param_value)
          else
            true
          end
        end

        def text_match_matches?(matcher, value)
          result = case matcher.match_type
          when 'equals'      then collate_equal?(matcher.collation, value, matcher.value)
          when 'starts-with' then collate_starts?(matcher.collation, value, matcher.value)
          when 'ends-with'   then collate_ends?(matcher.collation, value, matcher.value)
          else                    collate_contains?(matcher.collation, value, matcher.value)
          end
          matcher.negate_condition ? !result : result
        end

        def collate_contains?(collation, haystack, needle)
          if collation == 'i;octet'
            haystack.include?(needle)
          else
            haystack.downcase.include?(needle.downcase)
          end
        end

        def collate_equal?(collation, a, b)
          if collation == 'i;octet'
            a == b
          else
            a.casecmp?(b)
          end
        end

        def collate_starts?(collation, haystack, needle)
          if collation == 'i;octet'
            haystack.start_with?(needle)
          else
            haystack.downcase.start_with?(needle.downcase)
          end
        end

        def collate_ends?(collation, haystack, needle)
          if collation == 'i;octet'
            haystack.end_with?(needle)
          else
            haystack.downcase.end_with?(needle.downcase)
          end
        end

        # --- Private: Addressbook matching ---

        def card_prop_filter_matches?(filter, card)
          properties = card.find_all_properties(filter.name)

          if filter.is_not_defined
            return properties.empty?
          end

          return false if properties.empty?

          properties.any? do |prop|
            next false if filter.text_match && !text_match_matches?(filter.text_match, prop.value)
            filter.param_filters.all? { |pf| param_filter_matches?(pf, prop) }
          end
        end

        private_class_method :comp_filter_matches?, :prop_filter_matches?,
                             :param_filter_matches?, :text_match_matches?,
                             :collate_contains?, :collate_equal?,
                             :collate_starts?, :collate_ends?,
                             :card_prop_filter_matches?
      end
    end
  end
end
