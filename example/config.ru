# frozen_string_literal: true


require "scampi"
require_relative "../lib/caldav"

# --- Auth middleware ---
# Accepts any username/password and sets env['dav.user'] to the username.
# This is for testing only. Replace with real auth in production.
class RequestLogger
  def initialize(app)
    @app = app
  end

  def call(env)
    method = env['REQUEST_METHOD']
    path = env['PATH_INFO']
    user = env['dav.user'] || '-'
    depth = env['HTTP_DEPTH'] || '-'

    # Buffer the request body so downstream middleware can read it.
    # Falcon's streaming input doesn't support rewind, so we replace
    # rack.input with a StringIO containing the full body.
    input = env['rack.input']
    if input
      req_body = input.read
      env['rack.input'] = StringIO.new(req_body || '')
    else
      req_body = nil
    end

    $stderr.puts ">>> #{method} #{path} user=#{user} depth=#{depth}"
    $stderr.puts req_body if req_body && !req_body.empty?

    status, headers, body = @app.call(env)

    # Collect response body
    resp_body = []
    body.each { |chunk| resp_body << chunk }
    body.close if body.respond_to?(:close)

    $stderr.puts "<<< #{status}"
    $stderr.puts resp_body.join unless resp_body.join.empty?
    $stderr.puts ""

    [status, headers, resp_body]
  end
end

class BasicAuth
  def initialize(app)
    @app = app
  end

  def call(env)
    auth = env['HTTP_AUTHORIZATION']

    if auth && auth.start_with?('Basic ')
      decoded = Base64.decode64(auth.sub('Basic ', ''))
      user, _pass = decoded.split(':', 2)
      env['dav.user'] = user unless user.to_s.empty?
    end

    @app.call(env)
  end
end

# --- Storage ---
storage = Caldav::Storage::Filesystem.new("/data")

# --- Rack app ---
app = Caldav::App.new(storage: storage)

use BasicAuth
use RequestLogger
run app
