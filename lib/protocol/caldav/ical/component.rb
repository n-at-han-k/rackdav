# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "protocol/caldav"

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

test do
  describe "Protocol::Caldav::Ical::Component" do
    def prop(name, value, params: {})
      Protocol::Caldav::Ical::Property.new(name: name, params: params, value: value)
    end

    def comp(name, properties: [], components: [])
      Protocol::Caldav::Ical::Component.new(name: name, properties: properties, components: components)
    end

    it "find_property returns the first property with that name" do
      c = comp("VEVENT", properties: [prop("SUMMARY", "First"), prop("SUMMARY", "Second")])
      c.find_property("SUMMARY").value.should.equal "First"
    end

    it "find_property is case-insensitive" do
      c = comp("VEVENT", properties: [prop("SUMMARY", "Hello")])
      c.find_property("summary").value.should.equal "Hello"
    end

    it "find_property returns nil when absent" do
      c = comp("VEVENT", properties: [])
      c.find_property("SUMMARY").should.be.nil
    end

    it "find_components returns all matching children" do
      c = comp("VCALENDAR", components: [comp("VEVENT"), comp("VTODO"), comp("VEVENT")])
      c.find_components("VEVENT").length.should.equal 2
    end

    it "find_components returns empty array when none match" do
      c = comp("VCALENDAR", components: [comp("VEVENT")])
      c.find_components("VTODO").should.equal []
    end

    it "find_components does not recurse into grandchildren" do
      inner = comp("VALARM")
      vevent = comp("VEVENT", components: [inner])
      vcal = comp("VCALENDAR", components: [vevent])
      vcal.find_components("VALARM").should.equal []
    end

    it "a component with no properties or sub-components is valid" do
      c = comp("VEVENT")
      c.properties.should.equal []
      c.components.should.equal []
    end

    it "find_all_properties returns all matching" do
      c = comp("VEVENT", properties: [prop("ATTENDEE", "a"), prop("SUMMARY", "x"), prop("ATTENDEE", "b")])
      c.find_all_properties("ATTENDEE").length.should.equal 2
    end
  end
end
