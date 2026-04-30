# frozen_string_literal: true

require "scampi"
require_relative "../lib/caldav"

use Caldav::ForwardAuth::Middleware

storage = Caldav::Storage::Filesystem.new("/data")
app = Caldav::App.new(storage: storage)

run app
