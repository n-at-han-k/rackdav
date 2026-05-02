# frozen_string_literal: true

require 'protocol/http/middleware'
require 'protocol/http/response'

module Async
  module Caldav
    class ForwardAuth < Protocol::HTTP::Middleware
      def call(request)
        user = request.headers['remote-user']
        user = user.first if user.is_a?(Array)

        if user && !user.empty?
          super(request)
        else
          Protocol::HTTP::Response[401,
            Protocol::HTTP::Headers[['content-type', 'text/plain'], ['www-authenticate', 'Basic realm="caldav"']],
            ["Unauthorized"]]
        end
      end
    end
  end
end
