# frozen_string_literal: true

require "test_helper"

class CaldavTest < Minitest::Test
  def test_version
    refute_nil Caldav::VERSION
  end
end
