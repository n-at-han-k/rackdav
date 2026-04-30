# frozen_string_literal: true

# Integration tests for DELETE operations.
#
# Equivalent to Radicale's integ_tests/test_delete.py which tests:
#   - Deleting with wrong confirmation shows error
#   - Deleting with correct confirmation removes the collection
#
# Translated to CalDAV protocol-level DELETE operations:
#   - DELETE on non-existent resource returns 404
#   - DELETE on a collection removes it
#   - DELETE on an individual item removes it
#   - Deleted resources no longer appear in PROPFIND

require_relative "integ_test_helper"

class TestDelete < Caldav::IntegrationTest
  # Radicale: test_delete_wrong_confirmation
  # At the protocol level, there is no "confirmation" -- a DELETE on a
  # non-existent resource should return 404.
  def test_delete_nonexistent_returns_404
    response = caldav_delete("/calendars/admin/nonexistent/")

    assert_equal 404, response.status,
                 "DELETE on non-existent collection should return 404"
  end

  # Radicale: test_delete_correct_confirmation
  # Create a calendar, then delete it, then verify it's gone via PROPFIND.
  def test_delete_collection
    calendar_path = "/calendars/admin/deleteme/"

    # Create
    create_response = caldav_mkcalendar(calendar_path, displayname: "Delete Me")
    assert_equal 201, create_response.status, "MKCALENDAR should return 201"

    # Delete
    delete_response = caldav_delete(calendar_path)
    assert_includes [200, 204], delete_response.status,
                    "DELETE on existing collection should return 200 or 204"

    # Verify it's gone
    propfind_response = caldav_propfind(calendar_path, depth: "0")
    assert_equal 404, propfind_response.status,
                 "PROPFIND on deleted collection should return 404"
  end

  # Delete an individual calendar item (VEVENT).
  def test_delete_item
    calendar_path = "/calendars/admin/testcal/"
    item_path = "#{calendar_path}event1.ics"

    # Create calendar
    caldav_mkcalendar(calendar_path, displayname: "Test Cal")

    # Upload an event
    put_response = caldav_put(item_path, sample_vcalendar(uid: "delete-event-1"))
    assert_equal 201, put_response.status, "PUT should return 201"

    # Delete the event
    delete_response = caldav_delete(item_path)
    assert_includes [200, 204], delete_response.status,
                    "DELETE on existing item should return 200 or 204"

    # Verify the item is gone
    get_response = caldav_get(item_path)
    assert_equal 404, get_response.status,
                 "GET on deleted item should return 404"
  end

  # After deleting a collection, it should no longer appear in the parent's
  # PROPFIND listing.
  def test_deleted_collection_not_in_propfind_listing
    parent_path = "/calendars/admin/"
    calendar_path = "#{parent_path}listed-then-deleted/"

    # Create
    caldav_mkcalendar(calendar_path, displayname: "Listed Then Deleted")

    # Verify it appears in listing
    listing_before = caldav_propfind(parent_path, depth: "1")
    assert_equal 207, listing_before.status
    assert_includes listing_before.body, "listed-then-deleted",
                    "Calendar should appear in PROPFIND listing"

    # Delete
    caldav_delete(calendar_path)

    # Verify it no longer appears
    listing_after = caldav_propfind(parent_path, depth: "1")
    refute_includes listing_after.body, "listed-then-deleted",
                    "Deleted calendar should not appear in PROPFIND listing"
  end
end
