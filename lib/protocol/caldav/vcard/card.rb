# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "protocol/caldav"

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

test do
  describe "Protocol::Caldav::Vcard::Card" do
    def prop(name, value)
      Protocol::Caldav::Ical::Property.new(name: name, params: {}, value: value)
    end

    it "find_property returns the first matching property" do
      card = Protocol::Caldav::Vcard::Card.new(properties: [prop("FN", "John"), prop("FN", "Jane")])
      card.find_property("FN").value.should.equal "John"
    end

    it "find_property is case-insensitive" do
      card = Protocol::Caldav::Vcard::Card.new(properties: [prop("FN", "John")])
      card.find_property("fn").value.should.equal "John"
    end

    it "find_property returns nil when absent" do
      card = Protocol::Caldav::Vcard::Card.new(properties: [])
      card.find_property("FN").should.be.nil
    end

    it "has no sub-component finder (vCards don't nest)" do
      card = Protocol::Caldav::Vcard::Card.new
      card.should.not.respond_to(:find_components)
    end

    it "find_all_properties returns all matching" do
      card = Protocol::Caldav::Vcard::Card.new(properties: [prop("TEL", "123"), prop("EMAIL", "x"), prop("TEL", "456")])
      card.find_all_properties("TEL").length.should.equal 2
    end
  end
end
