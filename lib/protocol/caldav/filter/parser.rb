# frozen_string_literal: true

require "bundler/setup"
require "scampi"

require 'rexml/document'
require "protocol/caldav"

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

    class ParseError < StandardError; end
  end
end


test do
  describe "Protocol::Caldav::Filter::Parser" do
    describe "calendar parser" do
      it "parses a single comp-filter" do
        xml = '<c:filter xmlns:c="urn:ietf:params:xml:ns:caldav"><c:comp-filter name="VCALENDAR"/></c:filter>'
        f = Protocol::Caldav::Filter::Parser.parse_calendar(xml)
        f.name.should.equal "VCALENDAR"
      end

      it "parses nested comp-filters" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT"/>
            </c:comp-filter>
          </c:filter>
        XML
        f = Protocol::Caldav::Filter::Parser.parse_calendar(xml)
        f.comp_filters.length.should.equal 1
        f.comp_filters[0].name.should.equal "VEVENT"
      end

      it "parses is-not-defined" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VTODO"><c:is-not-defined/></c:comp-filter>
            </c:comp-filter>
          </c:filter>
        XML
        f = Protocol::Caldav::Filter::Parser.parse_calendar(xml)
        f.comp_filters[0].is_not_defined.should.equal true
      end

      it "parses prop-filter with no children as defined-only check" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:prop-filter name="SUMMARY"/>
            </c:comp-filter>
          </c:filter>
        XML
        f = Protocol::Caldav::Filter::Parser.parse_calendar(xml)
        f.prop_filters.length.should.equal 1
        f.prop_filters[0].name.should.equal "SUMMARY"
        f.prop_filters[0].text_match.should.be.nil
      end

      it "parses text-match with default collation and match-type" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:prop-filter name="SUMMARY">
                <c:text-match>Meeting</c:text-match>
              </c:prop-filter>
            </c:comp-filter>
          </c:filter>
        XML
        f = Protocol::Caldav::Filter::Parser.parse_calendar(xml)
        tm = f.prop_filters[0].text_match
        tm.value.should.equal "Meeting"
        tm.collation.should.equal "i;ascii-casemap"
        tm.match_type.should.equal "contains"
      end

      it "parses text-match with explicit attributes" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:prop-filter name="SUMMARY">
                <c:text-match collation="i;octet" match-type="equals">X</c:text-match>
              </c:prop-filter>
            </c:comp-filter>
          </c:filter>
        XML
        tm = Protocol::Caldav::Filter::Parser.parse_calendar(xml).prop_filters[0].text_match
        tm.collation.should.equal "i;octet"
        tm.match_type.should.equal "equals"
      end

      it "parses negate-condition" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:prop-filter name="SUMMARY">
                <c:text-match negate-condition="yes">X</c:text-match>
              </c:prop-filter>
            </c:comp-filter>
          </c:filter>
        XML
        tm = Protocol::Caldav::Filter::Parser.parse_calendar(xml).prop_filters[0].text_match
        tm.negate_condition.should.equal true
      end

      it "parses time-range with start and end" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="20260101T000000Z" end="20260201T000000Z"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        XML
        tr = Protocol::Caldav::Filter::Parser.parse_calendar(xml).comp_filters[0].time_range
        tr.start_time.should.equal "20260101T000000Z"
        tr.end_time.should.equal "20260201T000000Z"
      end

      it "parses time-range with only start" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:time-range start="20260101T000000Z"/>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        XML
        tr = Protocol::Caldav::Filter::Parser.parse_calendar(xml).comp_filters[0].time_range
        tr.start_time.should.equal "20260101T000000Z"
        tr.end_time.should.be.nil
      end

      it "returns nil for missing filter element" do
        Protocol::Caldav::Filter::Parser.parse_calendar('<d:propfind xmlns:d="DAV:"/>').should.be.nil
      end

      it "returns nil for empty filter" do
        Protocol::Caldav::Filter::Parser.parse_calendar('<c:filter xmlns:c="urn:ietf:params:xml:ns:caldav"/>').should.be.nil
      end

      it "returns nil for nil input" do
        Protocol::Caldav::Filter::Parser.parse_calendar(nil).should.be.nil
      end

      it "accepts any namespace prefix bound to caldav NS" do
        xml = '<cal:filter xmlns:cal="urn:ietf:params:xml:ns:caldav"><cal:comp-filter name="VCALENDAR"/></cal:filter>'
        f = Protocol::Caldav::Filter::Parser.parse_calendar(xml)
        f.name.should.equal "VCALENDAR"
      end

      it "parses param-filter inside prop-filter" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:prop-filter name="ATTENDEE">
                  <c:param-filter name="PARTSTAT">
                    <c:text-match>ACCEPTED</c:text-match>
                  </c:param-filter>
                </c:prop-filter>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        XML
        f = Protocol::Caldav::Filter::Parser.parse_calendar(xml)
        pf = f.comp_filters[0].prop_filters[0]
        pf.name.should.equal "ATTENDEE"
        pf.param_filters.length.should.equal 1
        pf.param_filters[0].name.should.equal "PARTSTAT"
        pf.param_filters[0].text_match.value.should.equal "ACCEPTED"
      end

      it "parses param-filter with is-not-defined" do
        xml = <<~XML
          <c:filter xmlns:c="urn:ietf:params:xml:ns:caldav">
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VEVENT">
                <c:prop-filter name="ATTENDEE">
                  <c:param-filter name="PARTSTAT">
                    <c:is-not-defined/>
                  </c:param-filter>
                </c:prop-filter>
              </c:comp-filter>
            </c:comp-filter>
          </c:filter>
        XML
        f = Protocol::Caldav::Filter::Parser.parse_calendar(xml)
        pf = f.comp_filters[0].prop_filters[0].param_filters[0]
        pf.is_not_defined.should.equal true
      end

      it "raises on comp-filter with no name attribute" do
        xml = '<c:filter xmlns:c="urn:ietf:params:xml:ns:caldav"><c:comp-filter/></c:filter>'
        lambda { Protocol::Caldav::Filter::Parser.parse_calendar(xml) }.should.raise Protocol::Caldav::ParseError
      end
    end

    describe "addressbook parser" do
      it "parses a prop-filter" do
        xml = '<cr:filter xmlns:cr="urn:ietf:params:xml:ns:carddav"><cr:prop-filter name="FN"/></cr:filter>'
        f = Protocol::Caldav::Filter::Parser.parse_addressbook(xml)
        f.prop_filters.length.should.equal 1
        f.prop_filters[0].name.should.equal "FN"
      end

      it "parses test attribute on filter" do
        xml = '<cr:filter xmlns:cr="urn:ietf:params:xml:ns:carddav" test="allof"><cr:prop-filter name="FN"/></cr:filter>'
        f = Protocol::Caldav::Filter::Parser.parse_addressbook(xml)
        f.test.should.equal "allof"
      end

      it "defaults test to anyof" do
        xml = '<cr:filter xmlns:cr="urn:ietf:params:xml:ns:carddav"><cr:prop-filter name="FN"/></cr:filter>'
        f = Protocol::Caldav::Filter::Parser.parse_addressbook(xml)
        f.test.should.equal "anyof"
      end

      it "returns nil for nil input" do
        Protocol::Caldav::Filter::Parser.parse_addressbook(nil).should.be.nil
      end
    end
  end
end
