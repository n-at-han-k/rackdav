# frozen_string_literal: true

require 'rexml/document'

module Protocol
  module Caldav
    module Filter
      module Parser
        CALDAV_NS  = Constants::CALDAV_NS
        CARDDAV_NS = Constants::CARDDAV_NS

        module_function

        def parse_calendar(xml_string)
          return nil if xml_string.nil? || xml_string.strip.empty?

          doc = REXML::Document.new(xml_string)
          ns = { 'c' => CALDAV_NS }

          filter_el = REXML::XPath.first(doc, './/c:filter', ns)
          return nil unless filter_el

          comp_el = REXML::XPath.first(filter_el, 'c:comp-filter', ns)
          return nil unless comp_el

          parse_comp_filter(comp_el, ns)
        rescue REXML::ParseException => e
          raise ParseError, "Malformed XML: #{e.message}"
        end

        def parse_addressbook(xml_string)
          return nil if xml_string.nil? || xml_string.strip.empty?

          doc = REXML::Document.new(xml_string)
          ns = { 'cr' => CARDDAV_NS }

          filter_el = REXML::XPath.first(doc, './/cr:filter', ns)
          return nil unless filter_el

          test = filter_el.attributes['test'] || 'anyof'
          prop_filters = REXML::XPath.match(filter_el, 'cr:prop-filter', ns).map do |el|
            parse_addressbook_prop_filter(el, ns)
          end

          Addressbook::Filter.new(test: test, prop_filters: prop_filters)
        rescue REXML::ParseException => e
          raise ParseError, "Malformed XML: #{e.message}"
        end

        # --- Private helpers ---

        def parse_comp_filter(el, ns)
          name = el.attributes['name']
          raise ParseError, "comp-filter missing required 'name' attribute" unless name

          is_not_defined = REXML::XPath.first(el, 'c:is-not-defined', ns) != nil
          time_range = parse_time_range(REXML::XPath.first(el, 'c:time-range', ns))

          prop_filters = REXML::XPath.match(el, 'c:prop-filter', ns).map do |pf_el|
            parse_prop_filter(pf_el, ns)
          end

          comp_filters = REXML::XPath.match(el, 'c:comp-filter', ns).map do |cf_el|
            parse_comp_filter(cf_el, ns)
          end

          Calendar::CompFilter.new(
            name: name,
            is_not_defined: is_not_defined,
            time_range: time_range,
            prop_filters: prop_filters,
            comp_filters: comp_filters
          )
        end

        def parse_prop_filter(el, ns)
          name = el.attributes['name']
          raise ParseError, "prop-filter missing required 'name' attribute" unless name

          is_not_defined = REXML::XPath.first(el, 'c:is-not-defined', ns) != nil
          time_range = parse_time_range(REXML::XPath.first(el, 'c:time-range', ns))
          text_match = parse_text_match(REXML::XPath.first(el, 'c:text-match', ns))

          param_filters = REXML::XPath.match(el, 'c:param-filter', ns).map do |pf_el|
            parse_param_filter(pf_el, ns)
          end

          Calendar::PropFilter.new(
            name: name,
            is_not_defined: is_not_defined,
            time_range: time_range,
            text_match: text_match,
            param_filters: param_filters
          )
        end

        def parse_param_filter(el, ns)
          name = el.attributes['name']
          is_not_defined = REXML::XPath.first(el, 'c:is-not-defined', ns) != nil
          text_match = parse_text_match(REXML::XPath.first(el, 'c:text-match', ns))

          Calendar::ParamFilter.new(name: name, is_not_defined: is_not_defined, text_match: text_match)
        end

        def parse_text_match(el)
          return nil unless el

          Calendar::TextMatch.new(
            value: el.text&.strip || '',
            collation: el.attributes['collation'] || 'i;ascii-casemap',
            match_type: el.attributes['match-type'] || 'contains',
            negate_condition: el.attributes['negate-condition'] == 'yes'
          )
        end

        def parse_time_range(el)
          return nil unless el

          Calendar::TimeRange.new(
            start_time: el.attributes['start'],
            end_time: el.attributes['end']
          )
        end

        def parse_addressbook_prop_filter(el, ns)
          name = el.attributes['name']
          raise ParseError, "prop-filter missing required 'name' attribute" unless name

          is_not_defined = REXML::XPath.first(el, 'cr:is-not-defined', ns) != nil
          text_match_el = REXML::XPath.first(el, 'cr:text-match', ns)
          text_match = if text_match_el
            Addressbook::TextMatch.new(
              value: text_match_el.text&.strip || '',
              collation: text_match_el.attributes['collation'] || 'i;ascii-casemap',
              match_type: text_match_el.attributes['match-type'] || 'contains',
              negate_condition: text_match_el.attributes['negate-condition'] == 'yes'
            )
          end

          param_filters = REXML::XPath.match(el, 'cr:param-filter', ns).map do |pf_el|
            pf_name = pf_el.attributes['name']
            pf_is_not_defined = REXML::XPath.first(pf_el, 'cr:is-not-defined', ns) != nil
            pf_text_match_el = REXML::XPath.first(pf_el, 'cr:text-match', ns)
            pf_text_match = if pf_text_match_el
              Addressbook::TextMatch.new(
                value: pf_text_match_el.text&.strip || '',
                collation: pf_text_match_el.attributes['collation'] || 'i;ascii-casemap',
                match_type: pf_text_match_el.attributes['match-type'] || 'contains',
                negate_condition: pf_text_match_el.attributes['negate-condition'] == 'yes'
              )
            end
            Addressbook::ParamFilter.new(name: pf_name, is_not_defined: pf_is_not_defined, text_match: pf_text_match)
          end

          Addressbook::PropFilter.new(
            name: name,
            is_not_defined: is_not_defined,
            text_match: text_match,
            param_filters: param_filters
          )
        end

        private_class_method :parse_comp_filter, :parse_prop_filter, :parse_param_filter,
                             :parse_text_match, :parse_time_range, :parse_addressbook_prop_filter
      end
    end
  end
end
