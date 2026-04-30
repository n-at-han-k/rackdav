# frozen_string_literal: true

# Integration tests for editing (PROPPATCH) collection properties.
#
# Equivalent to Radicale's integ_tests/test_edit.py which tests:
#   - Editing and saving a collection's title/description
#   - Editing and cancelling preserves original values
#
# Translated to CalDAV protocol-level PROPPATCH + PROPFIND:
#   - PROPPATCH to update displayname, verify with PROPFIND
#   - PROPPATCH to update description, verify with PROPFIND
#   - PROPPATCH to update color, verify with PROPFIND
#   - Original properties unchanged when no PROPPATCH is issued

require_relative "integ_test_helper"

class TestEdit < Caldav::IntegrationTest
  # Radicale: test_edit_save (displayname part)
  # PROPPATCH the displayname of a calendar, then PROPFIND to verify.
  def test_proppatch_displayname
    calendar_path = "/calendars/admin/editdn/"

    caldav_mkcalendar(calendar_path, displayname: "Original Name")

    # Update displayname
    response = caldav_proppatch(calendar_path, {
      "d:displayname" => "Updated Name"
    })

    assert_equal 207, response.status,
                 "PROPPATCH should return 207 Multi-Status"

    # Verify the update via PROPFIND
    propfind = caldav_propfind(calendar_path, depth: "0",
                                              properties: ["displayname"])

    assert_equal 207, propfind.status
    assert_includes propfind.body, "Updated Name",
                    "PROPFIND should reflect the updated displayname"
  end

  # Radicale: test_edit_save (description part)
  # PROPPATCH the calendar-description, then PROPFIND to verify.
  def test_proppatch_description
    calendar_path = "/calendars/admin/editdesc/"

    caldav_mkcalendar(calendar_path, displayname: "Edit Desc Test",
                                     description: "Original Description")

    # Update description
    response = caldav_proppatch(calendar_path, {
      "c:calendar-description" => "Updated Description"
    })

    assert_equal 207, response.status,
                 "PROPPATCH should return 207 Multi-Status"

    # Verify
    propfind = caldav_propfind(calendar_path, depth: "0",
                                              properties: ["calendar-description"])

    assert_equal 207, propfind.status
    assert_includes propfind.body, "Updated Description",
                    "PROPFIND should reflect the updated description"
  end

  # PROPPATCH the calendar color (Apple extension), then PROPFIND to verify.
  def test_proppatch_color
    calendar_path = "/calendars/admin/editcolor/"

    caldav_mkcalendar(calendar_path, displayname: "Edit Color Test",
                                     color: "#ff0000")

    # Update color
    response = caldav_proppatch(calendar_path, {
      "x:calendar-color" => "#00ff00"
    })

    assert_equal 207, response.status,
                 "PROPPATCH should return 207 Multi-Status"

    # Verify
    propfind = caldav_propfind(calendar_path, depth: "0",
                                              properties: ["calendar-color"])

    assert_equal 207, propfind.status
    assert_includes propfind.body, "#00ff00",
                    "PROPFIND should reflect the updated color"
  end

  # Radicale: test_edit_cancel
  # If no PROPPATCH is sent, the original properties remain intact.
  def test_properties_unchanged_without_proppatch
    calendar_path = "/calendars/admin/editnoop/"

    caldav_mkcalendar(calendar_path, displayname: "Unchanged Name",
                                     description: "Unchanged Description")

    # Just PROPFIND without any PROPPATCH -- properties should be original
    propfind = caldav_propfind(calendar_path, depth: "0",
                                              properties: %w[displayname calendar-description])

    assert_equal 207, propfind.status
    assert_includes propfind.body, "Unchanged Name",
                    "Displayname should remain original without PROPPATCH"
  end

  # PROPPATCH multiple properties in a single request.
  def test_proppatch_multiple_properties_at_once
    calendar_path = "/calendars/admin/editmulti/"

    caldav_mkcalendar(calendar_path, displayname: "Multi Before")

    response = caldav_proppatch(calendar_path, {
      "d:displayname" => "Multi After",
      "c:calendar-description" => "New Multi Description"
    })

    assert_equal 207, response.status

    propfind = caldav_propfind(calendar_path, depth: "0")

    assert_equal 207, propfind.status
    assert_includes propfind.body, "Multi After",
                    "Displayname should be updated"
    assert_includes propfind.body, "New Multi Description",
                    "Description should be updated"
  end
end
