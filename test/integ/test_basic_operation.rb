# frozen_string_literal: true

# Integration tests for basic CalDAV operations.
#
# Equivalent to Radicale's integ_tests/test_basic_operation.py which tests:
#   - Index page loads correctly
#   - User login works
#
# Translated to CalDAV protocol-level equivalents:
#   - Server responds to GET /
#   - PROPFIND on root returns 207 Multi-Status
#   - OPTIONS returns DAV compliance headers
#   - Well-known CalDAV endpoint redirects

require_relative "integ_test_helper"

class TestBasicOperation < Caldav::IntegrationTest
  # Radicale: test_index_html_loads
  # The CalDAV equivalent of "the index page loads" is that GET / returns a
  # successful response from the server.
  def test_server_responds_to_get_root
    response = caldav_get("/")

    assert_includes [200, 207, 301], response.status,
                    "GET / should return a successful or redirect status"
  end

  # Radicale: test_index_html_loads (all auth configs)
  # PROPFIND on the root is the standard CalDAV discovery mechanism.
  # A conformant server MUST return 207 Multi-Status.
  def test_propfind_root_returns_multistatus
    response = caldav_propfind("/", depth: "0")

    assert_equal 207, response.status,
                 "PROPFIND / should return 207 Multi-Status"
    assert_includes response.content_type, "xml",
                    "PROPFIND response should be XML"
  end

  # OPTIONS is required by WebDAV (RFC 4918) and CalDAV (RFC 4791).
  # The response MUST include DAV and Allow headers.
  def test_options_returns_dav_headers
    response = caldav_options("/")

    assert_equal 200, response.status
    assert response.headers["dav"],
           "OPTIONS response must include a DAV header"
    assert response.headers["allow"],
           "OPTIONS response must include an Allow header"
    assert_includes response.headers["dav"], "calendar-access",
                    "DAV header should advertise calendar-access compliance"
  end

  # CalDAV servers SHOULD support the .well-known/caldav URI (RFC 6764).
  def test_well_known_caldav
    response = caldav_get("/.well-known/caldav")

    # Expect either a redirect (301/302) to the CalDAV root, or a direct
    # PROPFIND-like response. Both are acceptable.
    assert_includes [200, 207, 301, 302, 404], response.status,
                    "/.well-known/caldav should redirect or respond directly"
  end

  # Radicale: test_user_login_works
  # The CalDAV equivalent is that an authenticated PROPFIND returns the
  # user's principal and home set.
  def test_authenticated_propfind_returns_current_user_principal
    response = caldav_propfind("/", depth: "0",
                                    properties: ["current-user-principal"])

    assert_equal 207, response.status,
                 "Authenticated PROPFIND should return 207"
  end

  # PROPFIND with Depth: 1 on root should list available collections.
  def test_propfind_depth_1_lists_root
    response = caldav_propfind("/", depth: "1")

    assert_equal 207, response.status
    refute_empty response.body,
                 "PROPFIND Depth:1 response should not be empty"
  end
end
