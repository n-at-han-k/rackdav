# frozen_string_literal: true

# Integration tests for collection lifecycle (create, list, delete).
#
# Equivalent to Radicale's integ_tests/test_scenes.py which tests:
#   - Navigation: create collection cancel/submit
#   - Navigation: delete collection cancel/confirm
#   - Refresh button
#   - Browser history (back/forward)
#
# Translated to CalDAV protocol-level collection management:
#   - MKCALENDAR creates a calendar collection
#   - MKCOL creates an addressbook collection
#   - PROPFIND lists collections
#   - DELETE removes a collection from listing
#   - Nested collection creation behavior

require_relative "integ_test_helper"

class TestCollections < Caldav::IntegrationTest
  # Radicale: test_navigation_create_collection_submit
  # MKCALENDAR creates a calendar collection, verifiable via PROPFIND.
  def test_mkcalendar_creates_collection
    calendar_path = "/calendars/admin/newcal/"

    response = caldav_mkcalendar(calendar_path, displayname: "New Calendar")

    assert_equal 201, response.status,
                 "MKCALENDAR should return 201 Created"

    # Verify it exists
    propfind = caldav_propfind(calendar_path, depth: "0")
    assert_equal 207, propfind.status,
                 "PROPFIND on new calendar should return 207"
  end

  # MKCOL with addressbook resourcetype creates an addressbook.
  def test_mkcol_creates_addressbook
    addressbook_path = "/addressbooks/admin/newaddr/"

    response = caldav_mkcol(addressbook_path, resourcetype: "addressbook",
                                              displayname: "New Addressbook")

    assert_equal 201, response.status,
                 "MKCOL should return 201 Created"

    # Verify
    propfind = caldav_propfind(addressbook_path, depth: "0")
    assert_equal 207, propfind.status,
                 "PROPFIND on new addressbook should return 207"
  end

  # Radicale: test_navigation_create_collection_submit (then lists)
  # PROPFIND Depth:1 on the parent should list the created collection.
  def test_propfind_lists_created_collections
    parent_path = "/calendars/admin/"
    caldav_mkcalendar("#{parent_path}listed-cal-1/", displayname: "Listed Cal 1")
    caldav_mkcalendar("#{parent_path}listed-cal-2/", displayname: "Listed Cal 2")

    response = caldav_propfind(parent_path, depth: "1")

    assert_equal 207, response.status
    assert_includes response.body, "listed-cal-1",
                    "First calendar should appear in listing"
    assert_includes response.body, "listed-cal-2",
                    "Second calendar should appear in listing"
  end

  # Radicale: test_navigation_delete_collection_confirm
  # Delete a collection and verify it's removed from the PROPFIND listing.
  def test_delete_removes_collection_from_listing
    parent_path = "/calendars/admin/"
    calendar_path = "#{parent_path}removeme/"

    caldav_mkcalendar(calendar_path, displayname: "Remove Me")

    # Verify it's listed
    listing = caldav_propfind(parent_path, depth: "1")
    assert_includes listing.body, "removeme"

    # Delete
    caldav_delete(calendar_path)

    # Verify it's gone from listing
    listing_after = caldav_propfind(parent_path, depth: "1")
    refute_includes listing_after.body, "removeme",
                    "Deleted collection should not appear in listing"
  end

  # Radicale: test_navigation_create_collection_cancel
  # At the protocol level, if MKCALENDAR is never sent, the collection
  # should not exist. This verifies PROPFIND returns 404 for a path that
  # was never created.
  def test_nonexistent_collection_returns_404
    response = caldav_propfind("/calendars/admin/never-created/", depth: "0")

    assert_equal 404, response.status,
                 "PROPFIND on non-existent collection should return 404"
  end

  # Attempting to create a collection at a deeply nested path where the
  # parent does not exist should fail (409 Conflict per RFC 4918 9.3.1).
  def test_mkcalendar_at_nonexistent_parent_fails
    response = caldav_mkcalendar("/calendars/admin/noparent/nested/deep/cal/")

    assert_includes [403, 409], response.status,
                    "MKCALENDAR at non-existent parent should return 403 or 409"
  end

  # MKCALENDAR on an already-existing collection should fail
  # (405 Method Not Allowed per RFC 4918 9.3.1).
  def test_mkcalendar_on_existing_collection_fails
    calendar_path = "/calendars/admin/existingcal/"

    # Create once
    caldav_mkcalendar(calendar_path, displayname: "Existing")

    # Try to create again
    response = caldav_mkcalendar(calendar_path, displayname: "Duplicate")

    assert_includes [405, 409], response.status,
                    "MKCALENDAR on existing collection should fail"
  end

  # Radicale: test_navigation_refresh_button
  # At the protocol level, a "refresh" is just re-issuing PROPFIND.
  # The response should be consistent.
  def test_propfind_is_idempotent
    calendar_path = "/calendars/admin/idempotent/"

    caldav_mkcalendar(calendar_path, displayname: "Idempotent Cal")

    response1 = caldav_propfind(calendar_path, depth: "0")
    response2 = caldav_propfind(calendar_path, depth: "0")

    assert_equal response1.status, response2.status,
                 "Repeated PROPFIND should return the same status"
    assert_equal response1.body, response2.body,
                 "Repeated PROPFIND should return the same body"
  end
end
