# frozen_string_literal: true

require "bundler/setup"
require "async/caldav"

# Rack middleware: copies Remote-User header into dav.user
class ForwardAuthMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    env['dav.user'] = env['HTTP_REMOTE_USER']
    @app.call(env)
  end
end

storage = Async::Caldav::Storage::Filesystem.new("/data")

# Pre-create parent collections
%w[/calendars/ /calendars/admin/ /addressbooks/ /addressbooks/admin/].each do |p|
  storage.create_collection(p) unless storage.get_collection(p)
end

use ForwardAuthMiddleware
run Async::Caldav::Server.new(storage: storage)
