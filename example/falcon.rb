# frozen_string_literal: true

# Falcon production configuration.
#
# Usage:
#   cd example && bundle exec falcon host
#
# falcon host reads this file and starts the managed service.

require "falcon/environment/rack"

service "caldav" do
  include Falcon::Environment::Rack

  # The root directory for the application (where config.ru lives).
  def root
    __dir__
  end

  # Bind to all interfaces on port 9292 over plain HTTP.
  # TLS termination is expected to happen at the reverse proxy layer.
  def url
    "http://0.0.0.0:9292"
  end

  # Number of worker processes. Defaults to Async::Container.processor_count.
  # Uncomment to override:
  # def count
  #   4
  # end
end
