# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  class App
    def initialize(storage:)
      @storage = storage
      @stack = build_stack
    end

    def call(env)
      env['caldav.storage'] = @storage
      @stack.call(env)
    end

    private

    def build_stack
      app = method(:fallback)

      # Contacts middlewares (innermost first, outermost last)
      app = Contacts::Report.new(app)
      app = Contacts::Move.new(app)
      app = Contacts::Delete.new(app)
      app = Contacts::Head.new(app)
      app = Contacts::Get.new(app)
      app = Contacts::Put.new(app)
      app = Contacts::Mkcol.new(app)
      app = Contacts::Proppatch.new(app)
      app = Contacts::Propfind.new(app)
      app = Contacts::Options.new(app)

      # Calendar middlewares
      app = Calendar::Report.new(app)
      app = Calendar::Move.new(app)
      app = Calendar::Delete.new(app)
      app = Calendar::Head.new(app)
      app = Calendar::Get.new(app)
      app = Calendar::Put.new(app)
      app = Calendar::Mkcalendar.new(app)
      app = Calendar::Proppatch.new(app)
      app = Calendar::Propfind.new(app)
      Calendar::Options.new(app)
    end

    def fallback(env)
      request = Rack::Request.new(env)
      path = Path.new(request.path_info, storage_class: @storage)

      if request.request_method == 'OPTIONS'
        [200, DAV_HEADERS.merge('content-length' => '0'), []]
      elsif !env['dav.user'].present?
        [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
      elsif request.request_method == 'PROPFIND'
        depth = env['HTTP_DEPTH'] || '1'
        responses = [path.to_propfind_xml]

        if depth == '1'
          DavCollection.list(path).each do |col|
            responses << col.to_propfind_xml
          end
        end

        [207, { 'content-type' => 'text/xml; charset=utf-8' }, [Multistatus.new(responses).to_xml]]
      elsif request.request_method == 'GET'
        if path.to_s == '/' || path.start_with?('/.well-known/')
          [200, { 'content-type' => 'text/html' }, ['Caldav::App']]
        else
          [404, { 'content-type' => 'text/plain' }, ['Not Found']]
        end
      else
        [405, { 'content-type' => 'text/plain' }, ['Method Not Allowed']]
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "returns 200 for GET /" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('GET', '/')
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 200
  end

  it "returns 207 for PROPFIND / with auth" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('PROPFIND', '/', headers: { 'Depth' => '0' })
    env['dav.user'] = 'admin'
    status, = app.call(env)
    status.should == 207
  end

  it "returns 401 for PROPFIND / without auth" do
    mock = Caldav::Storage::Mock.new
    app = Caldav::App.new(storage: mock)
    env = TM.env('PROPFIND', '/', headers: { 'Depth' => '0' })
    env['dav.user'] = nil
    status, = app.call(env)
    status.should == 401
  end
end
