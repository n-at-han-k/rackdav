# frozen_string_literal: true

require "bundler/setup"
require "active_support/all"
require "caldav/version"
require "rack"
require "base64"
require 'digest'
require 'stringio'
require 'uri'

module Caldav
  DAV_HEADERS = {
    'dav' => '1, 2, 3, calendar-access, addressbook, extended-mkcol',
    'allow' => 'OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCALENDAR, MKCOL, MOVE, REPORT',
    'content-type' => 'text/xml; charset=utf-8'
  }.freeze
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

Dir.glob("#{__dir__}/caldav/{calendar,contacts}/**/*.rb").sort.each do |path|
  require path
end

require_relative "caldav/app"
