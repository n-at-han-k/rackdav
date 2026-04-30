# frozen_string_literal: true

# Falcon native configuration for the CalDAV server.
#
# Usage:
#   cd example && bundle exec falcon host falcon.rb
#
# Or with docker-compose:
#   docker-compose up

require_relative "../lib/caldav"

service "caldav" do
  url "http://0.0.0.0:9292"

  endpoint do |bound_endpoint|
    Async::HTTP::Endpoint.new(bound_endpoint.url)
  end

  app Caldav::App.new
end
