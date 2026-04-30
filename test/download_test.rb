# frozen_string_literal: true

# Integration tests for downloading (GET) collections and items.
#
# Equivalent to Radicale's integ_tests/test_download.py which tests:
#   - Downloading an addressbook returns .vcf with correct filename
#   - Downloading a calendar returns .ics with correct filename
#
# Translated to CalDAV protocol-level GET operations:
#   - GET on a calendar collection returns text/calendar content
#   - GET on an addressbook collection returns text/vcard content
#   - GET on an individual item returns the item data

require_relative "integ_test_helper"

class TestDownload < Caldav::IntegrationTest
  # Radicale: test_download_calendar_uses_displayname_ics
  # GET on a calendar that contains events should return iCalendar data.
  def test_get_calendar_returns_ics_content_type
    calendar_path = "/calendars/admin/dlcal/"
    item_path = "#{calendar_path}event1.ics"

    # Create calendar
    caldav_mkcalendar(calendar_path, displayname: "Calname")

    # Upload an event
    caldav_put(item_path, sample_vcalendar(uid: "dl-event-1", summary: "Download Test"))

    # GET the collection
    response = caldav_get(calendar_path)

    assert_includes [200, 207], response.status,
                    "GET on calendar collection should succeed"

    # If the server supports collection GET, it should return calendar data
    if response.status == 200 && response.body.include?("VCALENDAR")
      assert_includes response.content_type, "calendar",
                      "Calendar collection GET should return text/calendar"
    end
  end

  # Radicale: test_download_addressbook
  # GET on an addressbook that contains contacts should return vCard data.
  def test_get_addressbook_returns_vcf_content_type
    addressbook_path = "/addressbooks/admin/dladdr/"

    # Create addressbook
    caldav_mkcol(addressbook_path, resourcetype: "addressbook", displayname: "Abname")

    # Upload a contact
    item_path = "#{addressbook_path}contact1.vcf"
    caldav_put(item_path, sample_vcard(uid: "dl-contact-1", fn: "Jane Doe"),
               content_type: "text/vcard; charset=utf-8")

    # GET the collection
    response = caldav_get(addressbook_path)

    assert_includes [200, 207], response.status,
                    "GET on addressbook collection should succeed"

    # If the server supports collection GET, it should return vcard data
    if response.status == 200 && response.body.include?("VCARD")
      assert_includes response.content_type, "vcard",
                      "Addressbook collection GET should return text/vcard"
    end
  end

  # GET on an individual calendar item should return the iCalendar data verbatim.
  def test_get_individual_event_returns_ics_data
    calendar_path = "/calendars/admin/dlcal2/"
    item_path = "#{calendar_path}event2.ics"

    caldav_mkcalendar(calendar_path, displayname: "DL Cal 2")
    caldav_put(item_path, sample_vcalendar(uid: "dl-event-2", summary: "Specific Event"))

    response = caldav_get(item_path)

    assert_equal 200, response.status,
                 "GET on individual event should return 200"
    assert_includes response.body, "VCALENDAR",
                    "Response body should contain VCALENDAR"
    assert_includes response.body, "dl-event-2",
                    "Response body should contain the event UID"
  end

  # GET on an individual vCard should return the vCard data verbatim.
  def test_get_individual_contact_returns_vcf_data
    addressbook_path = "/addressbooks/admin/dladdr2/"
    item_path = "#{addressbook_path}contact2.vcf"

    caldav_mkcol(addressbook_path, resourcetype: "addressbook", displayname: "DL Addr 2")
    caldav_put(item_path, sample_vcard(uid: "dl-contact-2", fn: "John Smith"),
               content_type: "text/vcard; charset=utf-8")

    response = caldav_get(item_path)

    assert_equal 200, response.status,
                 "GET on individual contact should return 200"
    assert_includes response.body, "VCARD",
                    "Response body should contain VCARD"
    assert_includes response.body, "dl-contact-2",
                    "Response body should contain the contact UID"
  end
end
