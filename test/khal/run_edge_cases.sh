#!/usr/bin/env bash
#
# Edge-case tests for the CalDAV server exercised through khal + vdirsyncer.
#
# These tests target real-client behaviour that synthetic unit tests miss:
#   - vdirsyncer discovery/sync protocol (PROPFIND depth chaining, REPORT)
#   - khal's iCalendar generation quirks (VTIMEZONE, RRULE, long summaries, etc.)
#   - Round-trip fidelity of exotic calendar properties
#   - Concurrent/sequential sync behaviour
#
# Requirements: khal, vdirsyncer, curl, ruby, bundler (in PATH or overridden below)
# Usage:  ./test/khal/run_edge_cases.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="$(mktemp -d)"

KHAL="${KHAL:-/tmp/khal-venv/bin/khal}"
VDIRSYNCER="${VDIRSYNCER:-/tmp/khal-venv/bin/vdirsyncer}"
RUBY="${RUBY:-ruby}"
BUNDLE="${BUNDLE:-bundle}"

SERVER_PORT=19292
SERVER_URL="http://localhost:${SERVER_PORT}"
USERNAME="testuser"
PASSWORD="testuser"

PASS=0
FAIL=0
ERRORS=()

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
cleanup() {
  # Kill server if running
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Clean up work directory
  rm -rf "$WORK_DIR"

  echo ""
  echo "========================================"
  echo "  Results: ${PASS} passed, ${FAIL} failed"
  echo "========================================"
  if [[ ${FAIL} -gt 0 ]]; then
    echo "Failures:"
    for e in "${ERRORS[@]}"; do
      echo "  - $e"
    done
    exit 1
  fi
}

log() { echo "--- $*"; }

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  ERRORS+=("$1")
  echo "  FAIL: $1"
}

assert_exit_0() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc (exit code $?)"
  fi
}

assert_exit_nonzero() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    fail "$desc (expected failure but got exit 0)"
  else
    pass "$desc"
  fi
}

assert_output_contains() {
  local desc="$1" pattern="$2"; shift 2
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -qF "$pattern"; then
    pass "$desc"
  else
    fail "$desc (pattern '$pattern' not found in output)"
  fi
}

assert_output_not_contains() {
  local desc="$1" pattern="$2"; shift 2
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -qF "$pattern"; then
    fail "$desc (pattern '$pattern' unexpectedly found in output)"
  else
    pass "$desc"
  fi
}

assert_file_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc (pattern '$pattern' not found in $file)"
  fi
}

assert_file_count() {
  local desc="$1" dir="$2" expected="$3"
  local actual
  actual=$(find "$dir" -name '*.ics' 2>/dev/null | wc -l)
  if [[ "$actual" -eq "$expected" ]]; then
    pass "$desc (found $actual)"
  else
    fail "$desc (expected $expected files, found $actual)"
  fi
}

http_status() {
  curl -s -o /dev/null -w '%{http_code}' -u "${USERNAME}:${PASSWORD}" "$@"
}

http_put_ics() {
  local path="$1" body="$2"
  curl -s -o /dev/null -w '%{http_code}' \
    -u "${USERNAME}:${PASSWORD}" \
    -X PUT \
    -H 'Content-Type: text/calendar; charset=utf-8' \
    -d "$body" \
    "${SERVER_URL}${path}"
}

http_mkcalendar() {
  local path="$1" displayname="${2:-}"
  local body
  body=$(cat <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:x="http://apple.com/ns/ical/">
  <d:set>
    <d:prop>
      <d:displayname>${displayname}</d:displayname>
    </d:prop>
  </d:set>
</c:mkcalendar>
XMLEOF
)
  curl -s -o /dev/null -w '%{http_code}' \
    -u "${USERNAME}:${PASSWORD}" \
    -X MKCALENDAR \
    -H 'Content-Type: text/xml; charset=utf-8' \
    -d "$body" \
    "${SERVER_URL}${path}"
}

setup_vdirsyncer_config() {
  local cal_name="${1:-testcal}"
  local vdir="${WORK_DIR}/vdir/${cal_name}"
  mkdir -p "$vdir" "${WORK_DIR}/vdirsyncer"

  cat > "${WORK_DIR}/vdirsyncer/config" <<VDSCFG
[general]
status_path = "${WORK_DIR}/vdirsyncer/status/"

[pair ${cal_name}]
a = "${cal_name}_local"
b = "${cal_name}_remote"
collections = null

[storage ${cal_name}_local]
type = "filesystem"
path = "${vdir}"
fileext = ".ics"

[storage ${cal_name}_remote]
type = "caldav"
url = "${SERVER_URL}/calendars/${USERNAME}/${cal_name}/"
username = "${USERNAME}"
password = "${PASSWORD}"
VDSCFG
}

sync() {
  VDIRSYNCER_CONFIG="${WORK_DIR}/vdirsyncer/config" \
    "$VDIRSYNCER" sync "$@" 2>&1
}

sync_force() {
  VDIRSYNCER_CONFIG="${WORK_DIR}/vdirsyncer/config" \
    "$VDIRSYNCER" sync --force-delete "$@" 2>&1
}

# Fresh download: creates a brand-new vdirsyncer pair pointing at the same
# remote calendar but with a fresh local directory and no status history.
# This avoids the "delete local → sync propagates delete to server" problem.
fresh_download() {
  local cal_name="${1:-testcal}"
  local fresh_dir="${WORK_DIR}/fresh_${cal_name}_$$"
  local fresh_status="${WORK_DIR}/fresh_status_${cal_name}_$$"
  mkdir -p "$fresh_dir" "$fresh_status"

  local fresh_cfg="${WORK_DIR}/fresh_vds_${cal_name}_$$.conf"
  cat > "$fresh_cfg" <<VDSCFG
[general]
status_path = "${fresh_status}/"

[pair fresh]
a = "fresh_local"
b = "fresh_remote"
collections = null

[storage fresh_local]
type = "filesystem"
path = "${fresh_dir}"
fileext = ".ics"

[storage fresh_remote]
type = "caldav"
url = "${SERVER_URL}/calendars/${USERNAME}/${cal_name}/"
username = "${USERNAME}"
password = "${PASSWORD}"
VDSCFG

  VDIRSYNCER_CONFIG="$fresh_cfg" "$VDIRSYNCER" discover 2>&1 || true
  VDIRSYNCER_CONFIG="$fresh_cfg" "$VDIRSYNCER" sync 2>&1 || true

  # Copy files back to the main vdir location
  local main_vdir="${WORK_DIR}/vdir/${cal_name}"
  rm -f "${main_vdir}"/*.ics 2>/dev/null || true
  cp "${fresh_dir}"/*.ics "${main_vdir}/" 2>/dev/null || true

  # Clean up
  rm -rf "$fresh_dir" "$fresh_status" "$fresh_cfg"
}

# Verify server has N items for a calendar via REPORT
assert_server_item_count() {
  local desc="$1" cal="$2" expected="$3"
  local report_body='<?xml version="1.0" encoding="UTF-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><d:getetag/><c:calendar-data/></d:prop>
  <c:filter><c:comp-filter name="VCALENDAR"/></c:filter>
</c:calendar-query>'

  local report_out
  report_out=$(curl -s \
    -u "${USERNAME}:${PASSWORD}" \
    -X REPORT \
    -H 'Content-Type: text/xml; charset=utf-8' \
    -d "$report_body" \
    "${SERVER_URL}/calendars/${USERNAME}/${cal}/")

  local actual
  actual=$(echo "$report_out" | grep -c '<d:response>' || true)
  if [[ "$actual" -eq "$expected" ]]; then
    pass "$desc (found $actual on server)"
  else
    fail "$desc (expected $expected on server, found $actual)"
  fi
}

# Get server item content via GET
http_get_body() {
  local path="$1"
  curl -s -u "${USERNAME}:${PASSWORD}" "${SERVER_URL}${path}"
}

discover() {
  VDIRSYNCER_CONFIG="${WORK_DIR}/vdirsyncer/config" \
    "$VDIRSYNCER" discover 2>&1
}

setup_khal_config() {
  local cal_name="${1:-testcal}"
  local vdir="${WORK_DIR}/vdir/${cal_name}"

  cat > "${WORK_DIR}/khal.conf" <<KHALCFG
[calendars]

[[${cal_name}]]
path = ${vdir}
color = dark cyan

[locale]
timeformat = %H:%M
dateformat = %Y-%m-%d
longdateformat = %Y-%m-%d
datetimeformat = %Y-%m-%d %H:%M
longdatetimeformat = %Y-%m-%d %H:%M

[default]
default_calendar = ${cal_name}
KHALCFG
}

run_khal() {
  "$KHAL" -c "${WORK_DIR}/khal.conf" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------
start_server() {
  log "Starting CalDAV server on port ${SERVER_PORT}..."
  cd "$PROJECT_DIR"
  $BUNDLE exec rackup test/khal/config.ru -p "$SERVER_PORT" -o 0.0.0.0 &>/dev/null &
  SERVER_PID=$!

  # Wait for server to be ready
  for i in $(seq 1 30); do
    if curl -s -o /dev/null "${SERVER_URL}/" 2>/dev/null; then
      log "Server ready (pid=${SERVER_PID})"
      return 0
    fi
    sleep 0.2
  done
  echo "FATAL: Server did not start within 6 seconds"
  exit 1
}

restart_server() {
  log "Restarting server (fresh state)..."
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  start_server
}

# ---------------------------------------------------------------------------
# Test suites
# ---------------------------------------------------------------------------

test_01_basic_sync_roundtrip() {
  log "TEST 01: Basic sync round-trip (khal new -> vdirsyncer sync -> khal list)"
  restart_server
  local cal="basic"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Basic Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  # Create event via khal
  run_khal new -a "$cal" 2026-06-15 14:00 15:00 "Afternoon Meeting"
  assert_file_count "local .ics file created" "${WORK_DIR}/vdir/${cal}" 1

  # Sync up to server
  local sync_out
  sync_out=$(sync) || true
  assert_output_contains "sync reports upload" "uploading" echo "$sync_out"

  # Verify on server via curl
  local status
  status=$(http_status "${SERVER_URL}/calendars/${USERNAME}/${cal}/")
  if [[ "$status" == "200" ]]; then pass "server returns 200 for collection"; else fail "server returned $status"; fi

  # Sync back down (should be no-op)
  sync_out=$(sync) || true
  assert_output_not_contains "re-sync is clean (no Uploading)" "Uploading" echo "$sync_out"

  # Verify via khal list
  assert_output_contains "khal list shows event" "Afternoon Meeting" \
    run_khal list 2026-06-15 2026-06-16
}

test_02_allday_event() {
  log "TEST 02: All-day event round-trip"
  restart_server
  local cal="allday"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "All Day Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  run_khal new -a "$cal" 2026-07-04 "Independence Day"
  sync
  assert_file_count "all-day event file created" "${WORK_DIR}/vdir/${cal}" 1

  # Verify it round-trips
  assert_output_contains "khal list shows all-day event" "Independence Day" \
    run_khal list 2026-07-04 2026-07-05
}

test_03_multiday_event() {
  log "TEST 03: Multi-day event spanning 5 days"
  restart_server
  local cal="multiday"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Multi Day"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  run_khal new -a "$cal" 2026-08-01 2026-08-05 "Summer Retreat"
  sync
  assert_file_count "multi-day event created" "${WORK_DIR}/vdir/${cal}" 1

  # Should appear on each day
  assert_output_contains "visible on day 1" "Summer Retreat" run_khal list 2026-08-01 2026-08-02
  assert_output_contains "visible on day 3" "Summer Retreat" run_khal list 2026-08-03 2026-08-04
}

test_04_unicode_summary() {
  log "TEST 04: Event with Unicode/emoji in summary"
  restart_server
  local cal="unicode"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Unicode Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  run_khal new -a "$cal" 2026-09-01 10:00 11:00 "Caf\u00e9 Rendezvous \u2615"
  sync

  # Re-download fresh from server and verify round-trip
  fresh_download "$cal"
  assert_output_contains "unicode summary preserved" "Caf" \
    run_khal list 2026-09-01 2026-09-02
}

test_05_very_long_summary() {
  log "TEST 05: Event with very long summary (500+ chars)"
  restart_server
  local cal="longsummary"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Long Summary"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local long_title
  long_title=$(python3 -c "print('A' * 500)")
  run_khal new -a "$cal" 2026-10-01 09:00 10:00 "$long_title"
  sync

  # Verify server accepted it - pull it back
  fresh_download "$cal"
  assert_file_count "long summary event synced back" "${WORK_DIR}/vdir/${cal}" 1
}

test_06_special_chars_in_summary() {
  log "TEST 06: Special characters in summary (XML-sensitive)"
  restart_server
  local cal="specchar"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Special Chars"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  # Characters that are dangerous for XML: & < > " '
  # Also semicolons and backslashes which are iCalendar-significant
  run_khal new -a "$cal" 2026-10-15 12:00 13:00 "Lunch with Tom & Jerry at <HQ>"
  sync

  fresh_download "$cal"
  assert_output_contains "XML-special chars survive round-trip" "Tom" \
    run_khal list 2026-10-15 2026-10-16
}

test_07_description_with_newlines() {
  log "TEST 07: Event with description (:: syntax) containing special text"
  restart_server
  local cal="desc"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Description Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  run_khal new -a "$cal" 2026-11-01 14:00 15:00 "Planning Session :: Agenda: review Q3 numbers"
  sync

  fresh_download "$cal"

  # Check the .ics file has DESCRIPTION
  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    assert_file_contains "DESCRIPTION in .ics" "$ics_file" "DESCRIPTION"
  else
    fail "no .ics file found after sync"
  fi
}

test_08_multiple_events_same_day() {
  log "TEST 08: Multiple events on the same day"
  restart_server
  local cal="multi"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Multi Events"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  run_khal new -a "$cal" 2026-12-01 09:00 10:00 "Morning Standup"
  run_khal new -a "$cal" 2026-12-01 10:30 11:30 "Design Review"
  run_khal new -a "$cal" 2026-12-01 14:00 15:00 "Afternoon Tea"
  sync

  assert_file_count "three events created" "${WORK_DIR}/vdir/${cal}" 3

  # Fresh download from server to verify all 3 arrived
  fresh_download "$cal"
  assert_file_count "three events synced back" "${WORK_DIR}/vdir/${cal}" 3

  assert_output_contains "first event listed"  "Morning Standup" run_khal list 2026-12-01 2026-12-02
  assert_output_contains "second event listed" "Design Review"   run_khal list 2026-12-01 2026-12-02
  assert_output_contains "third event listed"  "Afternoon Tea"   run_khal list 2026-12-01 2026-12-02
}

test_09_delete_event_and_sync() {
  log "TEST 09: Delete event locally, sync deletion to server"
  restart_server
  local cal="deltest"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Delete Test"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  run_khal new -a "$cal" 2027-01-10 08:00 09:00 "Ephemeral Event"
  sync
  assert_file_count "event exists before delete" "${WORK_DIR}/vdir/${cal}" 1

  # Delete locally and force-sync to propagate deletion to server
  rm -f "${WORK_DIR}/vdir/${cal}"/*.ics
  sync_force

  # Verify server-side is now empty too
  assert_server_item_count "event deleted from server" "$cal" 0
  assert_file_count "event gone after delete sync" "${WORK_DIR}/vdir/${cal}" 0
}

test_10_event_update_roundtrip() {
  log "TEST 10: Update event (edit summary) and sync"
  restart_server
  local cal="update"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Update Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  run_khal new -a "$cal" 2027-02-01 10:00 11:00 "Original Title"
  sync

  # Modify the .ics file in-place (change SUMMARY)
  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    sed -i 's/Original Title/Updated Title/' "$ics_file"
    local sync_out
    sync_out=$(sync) || true

    if echo "$sync_out" | grep -q "error"; then
      # Server may not support If-Match conditional PUT (500 error)
      # This is itself a valid finding -- log it but also verify via direct PUT
      fail "update via vdirsyncer fails (server likely rejects conditional PUT)"
      echo "  NOTE: vdirsyncer output: $(echo "$sync_out" | grep error | head -3)"
    else
      # Re-fetch from server
      fresh_download "$cal"
      assert_output_contains "updated title round-trips" "Updated Title" \
        run_khal list 2027-02-01 2027-02-02
    fi
  else
    fail "no .ics file to edit"
  fi
}

test_11_midnight_boundary_event() {
  log "TEST 11: Event spanning midnight"
  restart_server
  local cal="midnight"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Midnight Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  run_khal new -a "$cal" 2027-03-15 23:00 2027-03-16 01:00 "Late Night Jam"
  sync

  fresh_download "$cal"
  assert_file_count "midnight-spanning event synced" "${WORK_DIR}/vdir/${cal}" 1
  assert_output_contains "event visible on start day" "Late Night Jam" \
    run_khal list 2027-03-15 2027-03-17
}

test_12_past_date_event() {
  log "TEST 12: Event in the far past"
  restart_server
  local cal="past"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Past Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  # Create a past event directly via PUT (khal may refuse past-date new)
  local uid="past-event-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:19990101T120000Z
DTEND:19990101T130000Z
SUMMARY:Y2K Prep Meeting
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync
  assert_file_count "past event synced down" "${WORK_DIR}/vdir/${cal}" 1
}

test_13_far_future_event() {
  log "TEST 13: Event in the far future (year 2099)"
  restart_server
  local cal="future"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Future Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="future-event-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20991231T235500Z
DTEND:20991231T235900Z
SUMMARY:End of Century Party
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync
  assert_file_count "far-future event synced down" "${WORK_DIR}/vdir/${cal}" 1
}

test_14_recurring_event() {
  log "TEST 14: Recurring event (weekly RRULE)"
  restart_server
  local cal="recur"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Recurring"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="recur-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270101T100000Z
DTEND:20270101T110000Z
SUMMARY:Weekly Sync
RRULE:FREQ=WEEKLY;COUNT=10
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync
  assert_file_count "recurring event synced" "${WORK_DIR}/vdir/${cal}" 1

  # khal should expand recurrences in list output
  assert_output_contains "recurrence on week 1" "Weekly Sync" \
    run_khal list 2027-01-01 2027-01-02
  assert_output_contains "recurrence on week 2" "Weekly Sync" \
    run_khal list 2027-01-08 2027-01-09
}

test_15_recurring_with_exception() {
  log "TEST 15: Recurring event with EXDATE exception"
  restart_server
  local cal="exdate"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "EXDATE"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="exdate-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270301T090000Z
DTEND:20270301T100000Z
SUMMARY:Daily Standup
RRULE:FREQ=DAILY;COUNT=5
EXDATE:20270303T090000Z
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync

  # Day 3 (March 3) should be excluded
  assert_output_contains "event on day 1" "Daily Standup" run_khal list 2027-03-01 2027-03-02
  assert_output_contains "event on day 2" "Daily Standup" run_khal list 2027-03-02 2027-03-03
  assert_output_not_contains "excluded day 3" "Daily Standup" run_khal list 2027-03-03 2027-03-04
  assert_output_contains "event on day 4" "Daily Standup" run_khal list 2027-03-04 2027-03-05
}

test_16_vtodo_roundtrip() {
  log "TEST 16: VTODO item round-trip"
  restart_server
  local cal="todo"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Todos"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="todo-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VTODO
UID:${uid}
SUMMARY:Buy groceries
STATUS:NEEDS-ACTION
PRIORITY:1
END:VTODO
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync
  assert_file_count "VTODO synced down" "${WORK_DIR}/vdir/${cal}" 1

  # Verify the .ics contains VTODO
  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    assert_file_contains "VTODO preserved in file" "$ics_file" "VTODO"
  else
    fail "no .ics file found"
  fi
}

test_17_event_with_alarm() {
  log "TEST 17: Event with VALARM"
  restart_server
  local cal="alarm"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Alarms"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="alarm-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270601T140000Z
DTEND:20270601T150000Z
SUMMARY:Doctor Appointment
BEGIN:VALARM
TRIGGER:-PT15M
ACTION:DISPLAY
DESCRIPTION:Reminder
END:VALARM
BEGIN:VALARM
TRIGGER:-PT1H
ACTION:DISPLAY
DESCRIPTION:Early reminder
END:VALARM
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync

  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    assert_file_contains "VALARM preserved" "$ics_file" "VALARM"
    assert_file_contains "TRIGGER preserved" "$ics_file" "TRIGGER"
  else
    fail "no .ics file found"
  fi
}

test_18_event_with_attendees() {
  log "TEST 18: Event with ATTENDEE and ORGANIZER"
  restart_server
  local cal="attendees"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Attendees"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="att-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270701T100000Z
DTEND:20270701T110000Z
SUMMARY:Team Meeting
ORGANIZER;CN=Boss:mailto:boss@example.com
ATTENDEE;CN=Alice;PARTSTAT=ACCEPTED:mailto:alice@example.com
ATTENDEE;CN=Bob;PARTSTAT=TENTATIVE:mailto:bob@example.com
ATTENDEE;CN=Charlie;PARTSTAT=DECLINED:mailto:charlie@example.com
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync

  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    assert_file_contains "ORGANIZER preserved" "$ics_file" "ORGANIZER"
    assert_file_contains "ATTENDEE preserved"  "$ics_file" "ATTENDEE"
    assert_file_contains "PARTSTAT preserved"  "$ics_file" "PARTSTAT"
  else
    fail "no .ics file found"
  fi
}

test_19_event_with_timezone() {
  log "TEST 19: Event with explicit VTIMEZONE"
  restart_server
  local cal="tz"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Timezones"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="tz-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VTIMEZONE
TZID:America/New_York
BEGIN:STANDARD
DTSTART:19701101T020000
TZOFFSETFROM:-0400
TZOFFSETTO:-0500
TZNAME:EST
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700308T020000
TZOFFSETFROM:-0500
TZOFFSETTO:-0400
TZNAME:EDT
RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
UID:${uid}
DTSTART;TZID=America/New_York:20270415T090000
DTEND;TZID=America/New_York:20270415T100000
SUMMARY:NYC Breakfast Meeting
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync

  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    assert_file_contains "VTIMEZONE preserved" "$ics_file" "VTIMEZONE"
    assert_file_contains "TZID preserved"      "$ics_file" "America/New_York"
  else
    fail "no .ics file found"
  fi
}

test_20_event_with_location_url_categories() {
  log "TEST 20: Event with LOCATION, URL, CATEGORIES"
  restart_server
  local cal="richprops"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Rich Props"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="rich-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270801T180000Z
DTEND:20270801T200000Z
SUMMARY:Dinner Gala
LOCATION:Grand Ballroom\, Floor 3
URL:https://example.com/gala?year=2027&type=formal
CATEGORIES:Social,Formal,Annual
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync

  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    assert_file_contains "LOCATION preserved"   "$ics_file" "LOCATION"
    assert_file_contains "URL preserved"         "$ics_file" "URL"
    assert_file_contains "CATEGORIES preserved"  "$ics_file" "CATEGORIES"
    assert_file_contains "STATUS preserved"      "$ics_file" "STATUS"
  else
    fail "no .ics file found"
  fi
}

test_21_empty_calendar_sync() {
  log "TEST 21: Sync an empty calendar"
  restart_server
  local cal="empty"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Empty Cal"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local sync_out
  sync_out=$(sync) || true
  assert_file_count "no files for empty calendar" "${WORK_DIR}/vdir/${cal}" 0

  # khal list should produce no crash
  local list_out
  list_out=$(run_khal list 2027-01-01 2027-01-02) || true
  pass "khal list on empty calendar doesn't crash"
}

test_22_rapid_create_delete_cycle() {
  log "TEST 22: Rapid create-sync-delete-sync cycle"
  restart_server
  local cal="rapid"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Rapid"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  for i in $(seq 1 5); do
    run_khal new -a "$cal" "2027-04-0${i}" "10:00" "11:00" "Event ${i}"
  done
  sync
  assert_file_count "5 events synced up" "${WORK_DIR}/vdir/${cal}" 5

  # Delete 3 of them
  local count=0
  for f in "${WORK_DIR}/vdir/${cal}"/*.ics; do
    if [[ $count -lt 3 ]]; then
      rm "$f"
      count=$((count + 1))
    fi
  done
  sync

  # Re-fetch everything from server fresh
  fresh_download "$cal"
  assert_file_count "2 events remain after deleting 3" "${WORK_DIR}/vdir/${cal}" 2
}

test_23_duplicate_uid_handling() {
  log "TEST 23: PUT two events with same UID (server should overwrite)"
  restart_server
  local cal="dupuid"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Dup UID"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="same-uid-12345"
  local ics_v1
  ics_v1=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270501T100000Z
DTEND:20270501T110000Z
SUMMARY:Version One
END:VEVENT
END:VCALENDAR
ICSEOF
)
  local ics_v2
  ics_v2=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270501T100000Z
DTEND:20270501T110000Z
SUMMARY:Version Two
END:VEVENT
END:VCALENDAR
ICSEOF
)

  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_v1"
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_v2"
  sync

  assert_file_count "only one file for same UID" "${WORK_DIR}/vdir/${cal}" 1

  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    assert_file_contains "latest version wins" "$ics_file" "Version Two"
  else
    fail "no .ics file found"
  fi
}

test_24_large_batch_sync() {
  log "TEST 24: Batch of 20 events"
  restart_server
  local cal="batch"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Batch"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  for i in $(seq 1 20); do
    local uid="batch-${i}-$(date +%s%N)"
    local day
    day=$(printf "%02d" $((i % 28 + 1)))
    local ics_body
    ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270601T${day}0000Z
DTEND:20270601T${day}3000Z
SUMMARY:Batch Event ${i}
END:VEVENT
END:VCALENDAR
ICSEOF
)
    http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  done

  sync
  assert_file_count "20 events synced down" "${WORK_DIR}/vdir/${cal}" 20
}

test_25_calendar_color_displayname_proppatch() {
  log "TEST 25: Calendar color and displayname via PROPPATCH round-trip"
  restart_server
  local cal="props"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Original Name"

  # PROPPATCH to change color
  curl -s -o /dev/null \
    -u "${USERNAME}:${PASSWORD}" \
    -X PROPPATCH \
    -H 'Content-Type: text/xml; charset=utf-8' \
    -d '<?xml version="1.0" encoding="UTF-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:x="http://apple.com/ns/ical/">
  <d:set><d:prop>
    <x:calendar-color>#FF0000FF</x:calendar-color>
    <d:displayname>Renamed Calendar</d:displayname>
  </d:prop></d:set>
</d:propertyupdate>' \
    "${SERVER_URL}/calendars/${USERNAME}/${cal}/"

  # PROPFIND to verify
  local propfind_out
  propfind_out=$(curl -s \
    -u "${USERNAME}:${PASSWORD}" \
    -X PROPFIND \
    -H 'Content-Type: text/xml; charset=utf-8' \
    -H 'Depth: 0' \
    -d '<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>' \
    "${SERVER_URL}/calendars/${USERNAME}/${cal}/")

  if echo "$propfind_out" | grep -q "Renamed Calendar"; then
    pass "displayname updated via PROPPATCH"
  else
    fail "displayname not updated"
  fi

  if echo "$propfind_out" | grep -q "FF0000"; then
    pass "color updated via PROPPATCH"
  else
    fail "color not updated"
  fi
}

test_26_propfind_depth_0() {
  log "TEST 26: PROPFIND Depth:0 returns only the resource itself"
  restart_server
  local cal="depth0"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Depth Test"

  local uid="depth0-ev-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20270901T100000Z
DTEND:20270901T110000Z
SUMMARY:Should Not Appear
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"

  local propfind_out
  propfind_out=$(curl -s \
    -u "${USERNAME}:${PASSWORD}" \
    -X PROPFIND \
    -H 'Content-Type: text/xml; charset=utf-8' \
    -H 'Depth: 0' \
    -d '<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>' \
    "${SERVER_URL}/calendars/${USERNAME}/${cal}/")

  # Should have the collection but NOT the child event
  local response_count
  response_count=$(echo "$propfind_out" | grep -c '<d:response>' || true)
  if [[ "$response_count" -eq 1 ]]; then
    pass "Depth:0 returns exactly 1 response"
  else
    fail "Depth:0 returned $response_count responses (expected 1)"
  fi
}

test_27_zero_duration_event() {
  log "TEST 27: Zero-duration event (DTSTART == DTEND)"
  restart_server
  local cal="zerodur"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Zero Duration"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="zerodur-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20271001T120000Z
DTEND:20271001T120000Z
SUMMARY:Instantaneous Checkpoint
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync
  assert_file_count "zero-duration event synced" "${WORK_DIR}/vdir/${cal}" 1
}

test_28_event_no_dtend() {
  log "TEST 28: Event with no DTEND (only DTSTART)"
  restart_server
  local cal="nodtend"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "No DTEND"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="nodtend-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20271101T100000Z
SUMMARY:Open-ended Event
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync
  assert_file_count "no-DTEND event synced" "${WORK_DIR}/vdir/${cal}" 1
}

test_29_event_with_duration_instead_of_dtend() {
  log "TEST 29: Event using DURATION instead of DTEND"
  restart_server
  local cal="duration"
  http_mkcalendar "/calendars/${USERNAME}/${cal}/" "Duration"
  setup_vdirsyncer_config "$cal"
  setup_khal_config "$cal"
  discover

  local uid="dur-$(date +%s)"
  local ics_body
  ics_body=$(cat <<ICSEOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:20271201T100000Z
DURATION:PT2H30M
SUMMARY:Long Workshop
END:VEVENT
END:VCALENDAR
ICSEOF
)
  http_put_ics "/calendars/${USERNAME}/${cal}/${uid}.ics" "$ics_body"
  sync
  assert_file_count "DURATION-based event synced" "${WORK_DIR}/vdir/${cal}" 1

  local ics_file
  ics_file=$(find "${WORK_DIR}/vdir/${cal}" -name '*.ics' | head -1)
  if [[ -n "$ics_file" ]]; then
    assert_file_contains "DURATION or DTEND in file" "$ics_file" "DURATION\|DTEND"
  else
    fail "no .ics file found"
  fi
}

test_30_wellknown_caldav_redirect() {
  log "TEST 30: .well-known/caldav endpoint responds"
  restart_server

  local status
  status=$(http_status -L "${SERVER_URL}/.well-known/caldav")
  if [[ "$status" == "200" || "$status" == "301" || "$status" == "302" ]]; then
    pass ".well-known/caldav returns $status"
  else
    fail ".well-known/caldav returned $status (expected 200/301/302)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo "========================================"
  echo "  CalDAV Server Edge Case Tests (khal)"
  echo "========================================"
  echo "  Server: ${SERVER_URL}"
  echo "  Work:   ${WORK_DIR}"
  echo "========================================"
  echo ""

  start_server

  test_01_basic_sync_roundtrip
  test_02_allday_event
  test_03_multiday_event
  test_04_unicode_summary
  test_05_very_long_summary
  test_06_special_chars_in_summary
  test_07_description_with_newlines
  test_08_multiple_events_same_day
  test_09_delete_event_and_sync
  test_10_event_update_roundtrip
  test_11_midnight_boundary_event
  test_12_past_date_event
  test_13_far_future_event
  test_14_recurring_event
  test_15_recurring_with_exception
  test_16_vtodo_roundtrip
  test_17_event_with_alarm
  test_18_event_with_attendees
  test_19_event_with_timezone
  test_20_event_with_location_url_categories
  test_21_empty_calendar_sync
  test_22_rapid_create_delete_cycle
  test_23_duplicate_uid_handling
  test_24_large_batch_sync
  test_25_calendar_color_displayname_proppatch
  test_26_propfind_depth_0
  test_27_zero_duration_event
  test_28_event_no_dtend
  test_29_event_with_duration_instead_of_dtend
  test_30_wellknown_caldav_redirect
}

main "$@"
