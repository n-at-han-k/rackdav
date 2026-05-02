# frozen_string_literal: true

require "bundler/setup"
require "active_support/all"
require "caldav/version"
require "rack"
require "base64"
require 'digest'
require 'stringio'
require 'uri'

$LOAD_PATH.unshift(File.expand_path('../protocol-caldav/lib', __dir__)) unless $LOAD_PATH.any? { |p| p.end_with?('protocol-caldav/lib') }
require 'protocol/caldav'

module Caldav
  DAV_HEADERS = Protocol::Caldav::Constants::DAV_HEADERS
end

# Load order matters: foundational classes first, then middlewares
%w[
  caldav/xml
  caldav/multistatus
  caldav/path
  caldav/storage
  caldav/storage/mock
  caldav/storage/filesystem
  caldav/forward_auth
  caldav/test_middleware
  caldav/dav_collection
  caldav/dav_item
].each { |f| require_relative f }

require_relative "caldav/app"
