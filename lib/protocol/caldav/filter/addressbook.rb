# frozen_string_literal: true

require "bundler/setup"
require "scampi"

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


test do
  describe "Protocol::Caldav::Filter::Addressbook" do
    it "Filter defaults test to anyof" do
      f = Protocol::Caldav::Filter::Addressbook::Filter.new
      f.test.should.equal "anyof"
      f.prop_filters.should.equal []
    end

    it "Filter accepts allof" do
      f = Protocol::Caldav::Filter::Addressbook::Filter.new(test: "allof")
      f.test.should.equal "allof"
    end

    it "PropFilter defaults" do
      pf = Protocol::Caldav::Filter::Addressbook::PropFilter.new(name: "FN")
      pf.name.should.equal "FN"
      pf.is_not_defined.should.equal false
      pf.text_match.should.be.nil
    end

    it "no comp-filter or time-range in addressbook" do
      pf = Protocol::Caldav::Filter::Addressbook::PropFilter.new(name: "FN")
      pf.should.not.respond_to(:time_range)
      pf.should.not.respond_to(:comp_filters)
    end
  end
end
