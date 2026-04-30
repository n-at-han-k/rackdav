# frozen_string_literal: true

require_relative "../lib/caldav"

# --- Auth middleware ---
# Accepts any username/password and sets env['dav.user'] to the username.
# This is for testing only. Replace with real auth in production.
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
storage = Caldav::Storage::Mock.new

# --- Rack app ---
app = Caldav::App.new(storage: storage)

use BasicAuth
run app
