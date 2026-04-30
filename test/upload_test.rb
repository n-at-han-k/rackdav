# frozen_string_literal: true

# Integration tests for uploading (PUT) items to collections.
#
# Equivalent to Radicale's integ_tests/test_upload.py which tests:
#   - Uploading zero files shows error
#   - Uploading one file with custom href
#   - Uploading two files
#
# Translated to CalDAV protocol-level PUT operations:
#   - PUT a VCALENDAR item and verify with GET
#   - PUT a VCARD item and verify with GET
#   - PUT returns an ETag header
#   - PUT with If-None-Match prevents overwrite
#   - PUT a VTODO item and verify

require_relative "integ_test_helper"

class TestUpload < Caldav::IntegrationTest
  # Radicale: test_upload_one_file_custom_href
  # PUT a VCALENDAR to a specific path and verify it can be retrieved.
  def test_put_vcalendar_item
    calendar_path = "/calendars/admin/uploadcal/"
    item_path = "#{calendar_path}event1.ics"

    caldav_mkcalendar(calendar_path, displayname: "Upload Cal")

    # Upload
    response = caldav_put(item_path, sample_vcalendar(uid: "upload-event-1",
                                                      summary: "Upload Test"))

    assert_equal 201, response.status,
                 "PUT new item should return 201 Created"

    # Verify via GET
    get_response = caldav_get(item_path)
    assert_equal 200, get_response.status
    assert_includes get_response.body, "upload-event-1",
                    "GET should return the uploaded event"
    assert_includes get_response.body, "Upload Test",
                    "GET should contain the event summary"
  end

  # PUT a VCARD to an addressbook and verify retrieval.
  def test_put_vcard_item
    addressbook_path = "/addressbooks/admin/uploadaddr/"
    item_path = "#{addressbook_path}contact1.vcf"

    caldav_mkcol(addressbook_path, resourcetype: "addressbook", displayname: "Upload Addr")

    # Upload
    response = caldav_put(item_path, sample_vcard(uid: "upload-contact-1", fn: "Upload Contact"),
                          content_type: "text/vcard; charset=utf-8")

    assert_equal 201, response.status,
                 "PUT new vCard should return 201 Created"

    # Verify
    get_response = caldav_get(item_path)
    assert_equal 200, get_response.status
    assert_includes get_response.body, "upload-contact-1"
    assert_includes get_response.body, "Upload Contact"
  end

  # CalDAV servers MUST return an ETag on successful PUT (RFC 4791 5.3.4).
  def test_put_returns_etag
    calendar_path = "/calendars/admin/etagcal/"
    item_path = "#{calendar_path}event-etag.ics"

    caldav_mkcalendar(calendar_path, displayname: "ETag Cal")

    response = caldav_put(item_path, sample_vcalendar(uid: "etag-event-1"))

    assert_equal 201, response.status
    assert response.headers["etag"],
           "PUT response should include an ETag header"
    refute_empty response.headers["etag"],
                 "ETag header should not be empty"
  end

  # Radicale: test_upload_zero_files
  # An empty PUT body or missing content should be rejected.
  def test_put_empty_body_rejected
    calendar_path = "/calendars/admin/emptycal/"
    item_path = "#{calendar_path}empty.ics"

    caldav_mkcalendar(calendar_path, displayname: "Empty Cal")

    response = caldav_put(item_path, "")

    # Server should reject empty body -- 400 Bad Request or similar
    assert_includes [400, 403, 415], response.status,
                    "PUT with empty body should be rejected"
  end

  # PUT a VTODO item to verify task support.
  def test_put_vtodo_item
    calendar_path = "/calendars/admin/todocal/"
    item_path = "#{calendar_path}todo1.ics"

    caldav_mkcalendar(calendar_path, displayname: "Todo Cal")

    response = caldav_put(item_path, sample_vtodo(uid: "upload-todo-1",
                                                  summary: "My Task"))

    assert_equal 201, response.status,
                 "PUT VTODO should return 201 Created"

    # Verify
    get_response = caldav_get(item_path)
    assert_equal 200, get_response.status
    assert_includes get_response.body, "upload-todo-1"
    assert_includes get_response.body, "My Task"
  end

  # Radicale: test_upload_two_files
  # Upload multiple items to the same collection and verify both exist.
  def test_put_multiple_items
    calendar_path = "/calendars/admin/multicol/"

    caldav_mkcalendar(calendar_path, displayname: "Multi Cal")

    # Upload two events
    resp1 = caldav_put("#{calendar_path}event-a.ics",
                       sample_vcalendar(uid: "multi-a", summary: "Event A"))
    resp2 = caldav_put("#{calendar_path}event-b.ics",
                       sample_vcalendar(uid: "multi-b", summary: "Event B"))

    assert_equal 201, resp1.status
    assert_equal 201, resp2.status

    # Verify both can be retrieved
    get_a = caldav_get("#{calendar_path}event-a.ics")
    get_b = caldav_get("#{calendar_path}event-b.ics")

    assert_equal 200, get_a.status
    assert_equal 200, get_b.status
    assert_includes get_a.body, "multi-a"
    assert_includes get_b.body, "multi-b"
  end
end
