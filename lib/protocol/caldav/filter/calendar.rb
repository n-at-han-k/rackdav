# frozen_string_literal: true

require "bundler/setup"
require "scampi"

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


test do
  describe "Protocol::Caldav::Filter::Calendar" do
    it "CompFilter accepts documented fields" do
      cf = Protocol::Caldav::Filter::Calendar::CompFilter.new(name: "VCALENDAR")
      cf.name.should.equal "VCALENDAR"
      cf.is_not_defined.should.equal false
      cf.time_range.should.be.nil
      cf.prop_filters.should.equal []
      cf.comp_filters.should.equal []
    end

    it "PropFilter defaults" do
      pf = Protocol::Caldav::Filter::Calendar::PropFilter.new(name: "SUMMARY")
      pf.name.should.equal "SUMMARY"
      pf.is_not_defined.should.equal false
      pf.text_match.should.be.nil
      pf.param_filters.should.equal []
    end

    it "TextMatch defaults" do
      tm = Protocol::Caldav::Filter::Calendar::TextMatch.new(value: "test")
      tm.collation.should.equal "i;ascii-casemap"
      tm.match_type.should.equal "contains"
      tm.negate_condition.should.equal false
    end

    it "TimeRange holds start and end" do
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      tr.start_time.should.equal "20260101T000000Z"
      tr.end_time.should.equal "20260201T000000Z"
    end

    it "CompFilter with is_not_defined and other fields is valid" do
      cf = Protocol::Caldav::Filter::Calendar::CompFilter.new(
        name: "VTODO",
        is_not_defined: true,
        prop_filters: [Protocol::Caldav::Filter::Calendar::PropFilter.new(name: "X")]
      )
      cf.is_not_defined.should.equal true
      cf.prop_filters.length.should.equal 1
    end
  end
end
