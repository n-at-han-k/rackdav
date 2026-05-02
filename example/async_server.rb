#!/usr/bin/env ruby
# frozen_string_literal: true

# Native async CalDAV server -- no Rack adapter layer.
# Run with: ruby example/async_server.rb

$LOAD_PATH.unshift(File.expand_path('../protocol-caldav/lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('../async-caldav/lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'async'
require 'async/http/server'
require 'async/http/endpoint'
require 'async/caldav'
require 'caldav/storage/filesystem'

storage = Caldav::Storage::Filesystem.new(ENV.fetch('CALDAV_DATA_DIR', './data'))
endpoint = Async::HTTP::Endpoint.parse("http://0.0.0.0:9292")

app = Async::Caldav::ForwardAuth.new(
  Async::Caldav::Server.new(
    Protocol::HTTP::Middleware::NotFound,
    storage: storage
  )
)

server = Async::HTTP::Server.new(app, endpoint)

puts "CalDAV server (async-native) listening on http://0.0.0.0:9292"

Async do
  server.run
end
