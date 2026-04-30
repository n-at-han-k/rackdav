# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  # Test-only middleware that injects dav.user and caldav.storage into the
  # rack env, exactly the way a real auth + storage middleware would in
  # production.  Wrap the middleware under test with this, then call it
  # with plain rack env hashes -- no need to set dav.user yourself.
  #
  #   mw = TestMiddleware.new(Calendar::Put, mock, user: 'admin')
  #   status, headers, body = mw.call(env)
  #
  class TestMiddleware
    attr_reader :storage

    def initialize(middleware_class, storage = nil, user: 'admin')
      @storage = storage || Storage::Mock.new
      @user = user
      passthrough = ->(_env) { [999, {}, ['passthrough']] }
      @app = middleware_class.new(passthrough)
    end

    def call(env)
      env['dav.user'] = @user
      env['caldav.storage'] = @storage
      env['rack.input'] ||= StringIO.new('')
      @app.call(env)
    end

    # Build a minimal rack env hash. Only set what you need --
    # dav.user, caldav.storage, and rack.input are injected by call().
    def self.env(method, path, body: '', headers: {}, content_type: nil)
      e = {
        'REQUEST_METHOD' => method,
        'PATH_INFO' => path,
        'rack.input' => StringIO.new(body)
      }
      e['CONTENT_TYPE'] = content_type if content_type
      headers.each { |k, v| e["HTTP_#{k.upcase.tr('-', '_')}"] = v }
      e
    end
  end
end
