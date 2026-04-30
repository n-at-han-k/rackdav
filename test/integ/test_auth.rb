# frozen_string_literal: true

# Integration tests for authentication.
#
# Equivalent to Radicale's integ_tests/test_scenes_login.py which tests:
#   - Login, logout, re-login cycle
#   - Wrong password shows error, then correct password works
#
# Translated to CalDAV protocol-level authentication:
#   - Unauthenticated requests return 401
#   - Wrong credentials return 401
#   - Correct credentials succeed
#   - Auth required for PROPFIND/PUT/DELETE operations

require_relative "integ_test_helper"

class TestAuth < Caldav::IntegrationTest
  # Radicale: test_login_wrong_password_shows_error
  # An unauthenticated PROPFIND should be challenged with 401.
  def test_unauthenticated_propfind_returns_401
    response = caldav_propfind("/", depth: "0", auth: false)

    assert_equal 401, response.status,
                 "Unauthenticated PROPFIND should return 401"
  end

  # Radicale: test_login_wrong_password_shows_error
  # Wrong credentials should be rejected.
  def test_wrong_credentials_returns_401
    header "HTTP_AUTHORIZATION", auth_header("admin", "wrongpassword")
    response = caldav_propfind("/", depth: "0", auth: false)

    assert_equal 401, response.status,
                 "PROPFIND with wrong credentials should return 401"
  end

  # Radicale: test_user_login_works / test_login_logout_login
  # Correct credentials should succeed.
  def test_correct_credentials_succeeds
    response = caldav_propfind("/", depth: "0", auth: true)

    assert_includes [200, 207], response.status,
                    "PROPFIND with correct credentials should succeed"
  end

  # Auth should be required for write operations too.
  def test_unauthenticated_mkcalendar_returns_401
    response = caldav_mkcalendar("/calendars/admin/unauth-cal/",
                                 displayname: "Unauth Cal", auth: false)

    assert_equal 401, response.status,
                 "Unauthenticated MKCALENDAR should return 401"
  end

  # Unauthenticated PUT should be rejected.
  def test_unauthenticated_put_returns_401
    response = caldav_put("/calendars/admin/somecal/event.ics",
                          sample_vcalendar, auth: false)

    assert_equal 401, response.status,
                 "Unauthenticated PUT should return 401"
  end

  # Unauthenticated DELETE should be rejected.
  def test_unauthenticated_delete_returns_401
    response = caldav_delete("/calendars/admin/somecal/", auth: false)

    assert_equal 401, response.status,
                 "Unauthenticated DELETE should return 401"
  end

  # OPTIONS may or may not require authentication, but it should at least
  # not error out. Many CalDAV servers allow unauthenticated OPTIONS for
  # discovery purposes.
  def test_options_without_auth_does_not_error
    response = caldav_options("/", auth: false)

    assert_includes [200, 401], response.status,
                    "OPTIONS should either succeed or request auth, never error"
  end

  # Radicale: test_login_logout_login
  # Sequential authenticated requests should each succeed independently
  # (stateless auth -- each request carries its own credentials).
  def test_sequential_authenticated_requests
    response1 = caldav_propfind("/", depth: "0", auth: true)
    response2 = caldav_propfind("/", depth: "0", auth: true)

    assert_includes [200, 207], response1.status
    assert_includes [200, 207], response2.status
  end

  # Different users should get isolated views (user A cannot see user B's
  # calendars without explicit sharing).
  def test_user_isolation
    # User A creates a calendar
    with_auth("alice", "alice")
    caldav_mkcalendar("/calendars/alice/private-cal/",
                      displayname: "Alice Private", auth: false)

    # User B should not see it in their namespace
    with_auth("bob", "bob")
    response = caldav_propfind("/calendars/bob/", depth: "1", auth: false)

    # Bob's listing should not contain Alice's calendar
    refute_includes response.body, "Alice Private",
                    "Bob should not see Alice's calendar"
  end
end
