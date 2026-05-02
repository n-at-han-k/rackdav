# frozen_string_literal: true

require 'protocol/caldav'
require_relative 'caldav/version'
require_relative 'caldav/forward_auth'
require_relative 'caldav/storage/mock'
require_relative 'caldav/storage/filesystem'
require_relative 'caldav/handlers/options'
require_relative 'caldav/handlers/get'
require_relative 'caldav/handlers/head'
require_relative 'caldav/handlers/put'
require_relative 'caldav/handlers/delete'
require_relative 'caldav/handlers/move'
require_relative 'caldav/handlers/mkcol'
require_relative 'caldav/handlers/propfind'
require_relative 'caldav/handlers/proppatch'
require_relative 'caldav/handlers/report'
require_relative 'caldav/server'

module Async
  module Caldav
  end
end
