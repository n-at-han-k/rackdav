# frozen_string_literal: true

require "bundler/setup"
require "scampi"

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


test do
  describe "Protocol::Caldav::Ical::Property" do
    it "exposes name, params, value" do
      p = Protocol::Caldav::Ical::Property.new(name: "SUMMARY", params: {}, value: "Hello")
      p.name.should.equal "SUMMARY"
      p.params.should.equal({})
      p.value.should.equal "Hello"
    end

    it "param lookup is case-insensitive on parameter names" do
      p = Protocol::Caldav::Ical::Property.new(name: "DTSTART", params: {"TZID" => "UTC"}, value: "x")
      p.param("tzid").should.equal "UTC"
      p.param("TZID").should.equal "UTC"
    end

    it "value is the raw string, no type coercion" do
      p = Protocol::Caldav::Ical::Property.new(name: "DTSTART", params: {}, value: "20260101T090000Z")
      p.value.should.equal "20260101T090000Z"
    end
  end
end
