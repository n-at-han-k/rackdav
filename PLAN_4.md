Here's the test list for each file in the design. These are the specs — what to assert, not how to assert it.

## `protocol/caldav/ical/parser.rb`

Line unfolding:
- Unfolds `CRLF SPACE` continuations into a single logical line
- Unfolds `CRLF TAB` continuations the same way
- Does not unfold `CRLF` followed by a non-whitespace character
- Does not unfold `LF SPACE` without the CR (or does — pick one and document; RFC says CRLF, real clients send LF)
- Preserves the space/tab character is *removed*, not kept (this is a common bug — RFC 5545 §3.1 says the space is part of the folding, not the value)
- Handles three or more consecutive folded lines
- Handles a fold at the very last line of input

Component nesting:
- Parses a flat `BEGIN:VCALENDAR` / `END:VCALENDAR` with no children
- Parses one `VEVENT` inside `VCALENDAR`
- Parses multiple sibling `VEVENT`s
- Parses `VALARM` nested inside `VEVENT` inside `VCALENDAR`
- Rejects mismatched END (`BEGIN:VEVENT` ... `END:VTODO`) — decide: raise, or recover?
- Rejects unclosed components (EOF before matching END)
- Handles BEGIN/END names case-insensitively (`begin:vevent` is valid per RFC)
- Preserves component order (matters for some filters)

Property parsing:
- Parses a property with no parameters: `SUMMARY:Hello`
- Parses a property with one parameter: `DTSTART;TZID=America/New_York:20260101T090000`
- Parses a property with multiple parameters
- Parses a parameter with a quoted value: `ATTENDEE;CN="Smith, John":mailto:j@e.com`
- Handles a colon inside a quoted parameter value (the value-separator colon is the first unquoted one)
- Handles a property value containing colons (everything after the first unquoted colon)
- Handles a property value containing semicolons (only param separators before the value colon)
- Handles an empty property value: `DESCRIPTION:`
- Preserves case of property values
- Lowercases or preserves property names — pick one (RFC says case-insensitive comparison; preserving original is friendlier for round-trips)

Edge cases:
- Empty input returns nil or empty component (decide)
- Input without VCALENDAR wrapper (just a bare VEVENT) — decide
- Trailing whitespace and blank lines tolerated
- BOM at start of file tolerated
- LF-only line endings (not CRLF) tolerated — Linux clients send these
- A property name with X-prefix (custom): `X-WR-CALNAME:My Calendar`
- Round-trip: parsing then re-serializing produces equivalent structure (not byte-identical — folding may differ)

## `protocol/caldav/ical/component.rb`

- `find_property(name)` returns the first property with that name
- `find_property` is case-insensitive
- `find_property` returns nil when absent
- `find_components(name)` returns all matching children
- `find_components` returns an empty array when none match
- `find_components` does not recurse into grandchildren (only direct children)
- A component with no properties or sub-components is valid

## `protocol/caldav/ical/property.rb`

- Property exposes name, params (as a hash or list), value
- Parameter lookup is case-insensitive on parameter names
- A parameter with multiple comma-separated values is exposed as a list
- Value is the raw string — no type coercion in this layer

## `protocol/caldav/vcard/parser.rb`

Most of the iCal tests apply. Additionally:
- Parses a flat `BEGIN:VCARD` / `END:VCARD`
- Rejects nested components (vCard 3.0 doesn't nest; 4.0 has no nesting in the wild)
- Handles `VERSION:3.0` and `VERSION:4.0` properties without distinction at parse time
- Handles structured values (semicolon-delimited) in N and ADR — store as raw string at this layer, structuring is the consumer's job

## `protocol/caldav/vcard/card.rb`

- Same property-finder semantics as Component
- No sub-component finder (vCards don't nest)

## `protocol/caldav/filter/calendar.rb` (the AST)

Structural tests only — these are data classes:
- `CompFilter.new` accepts the documented fields
- `CompFilter` with `is_not_defined: true` and other fields populated is a valid (if semantically weird) construction — the parser's job to enforce, not the AST's
- Equality: two ASTs built from the same XML compare equal (matters for caching parsed filters)

## `protocol/caldav/filter/addressbook.rb`

Same as above for the AddressBook AST. Cardinal difference: no `comp-filter`, no `time-range`.

## `protocol/caldav/filter/parser.rb`

Calendar parser:
- Parses `<c:filter><c:comp-filter name="VCALENDAR"/></c:filter>` to a single CompFilter
- Parses nested comp-filters (VCALENDAR > VEVENT)
- Parses `<c:is-not-defined/>` as the `is_not_defined` flag, with no value content
- Parses `<c:prop-filter name="SUMMARY"/>` with no children as a defined-only check
- Parses `<c:text-match>Meeting</c:text-match>` with default collation and match-type
- Parses `<c:text-match collation="i;octet" match-type="equals">X</c:text-match>` with explicit attributes
- Parses `<c:text-match negate-condition="yes">X</c:text-match>` and sets the flag
- Parses `<c:time-range start="20260101T000000Z" end="20260201T000000Z"/>`
- Parses `<c:time-range start="..."/>` with only start
- Parses `<c:time-range end="..."/>` with only end
- Parses multiple sibling prop-filters under one comp-filter
- Parses multiple sibling comp-filters under one comp-filter
- Parses param-filter inside prop-filter
- Returns nil for missing `<c:filter>` element
- Returns nil for empty `<c:filter/>` (some clients send this)
- Accepts any namespace prefix bound to `urn:ietf:params:xml:ns:caldav`
- Rejects elements bound to a different namespace with the same local name (the regex bug)
- Rejects elements outside any namespace
- Tolerates whitespace and comments between elements
- Raises a meaningful error on malformed XML (not a Nokogiri stack trace)
- Raises on a comp-filter with no `name` attribute

AddressBook parser:
- Parses `<cr:filter><cr:prop-filter name="FN"/></cr:filter>`
- Parses `test` attribute on `<cr:filter test="anyof|allof">` — RFC 6352 §10.5.1 (CardDAV has OR semantics that CalDAV doesn't!) — important and currently absent from your code
- Default test is `anyof` per spec
- Same text-match semantics as calendar
- Same namespace rigor

## `protocol/caldav/filter/match.rb`

This is where most of the work is. Group by node type.

CompFilter against component:
- Matches when component name equals filter name (case-insensitive)
- Does not match when names differ
- With `is_not_defined`: matches when component absent (called from parent's iteration)
- With `is_not_defined`: does not match when component present
- All nested prop-filters must match (AND semantics)
- All nested comp-filters must match
- Prop-filter on absent property with `is_not_defined` matches
- Prop-filter on absent property without `is_not_defined` does not match
- Empty filter (just `name`) matches any component of that name

PropFilter:
- Matches when any instance of the property satisfies the conditions (multi-value semantics)
- With `is_not_defined`: matches when property absent
- With `is_not_defined`: does not match when property present (regardless of value)
- text-match on the property value works
- param-filter on the property's parameters works
- Both text-match and param-filter must satisfy (AND on the same property instance)

TextMatch:
- `contains` (default) matches substring
- `equals` matches whole-string equality
- `starts-with` matches prefix
- `ends-with` matches suffix
- `i;ascii-casemap` (default) is case-insensitive
- `i;octet` is case-sensitive byte comparison
- `negate-condition="yes"` inverts the result
- Negation combined with each match-type produces the expected result
- Empty match value: decide — RFC is silent; sensible default is "matches anything"
- Match value containing the collation-relevant edge cases (multibyte UTF-8, non-ASCII letters with i;ascii-casemap — should compare bytes)

ParamFilter:
- Matches when the parameter exists with text-match satisfied
- With `is_not_defined`: matches when parameter absent
- Parameter name comparison is case-insensitive

TimeRange (the deferred-but-eventually-needed set):
- VEVENT with DTSTART and DTEND — overlap test on `[start, end)` is half-open both sides
- VEVENT with DTSTART and DURATION — DTEND computed
- VEVENT with DTSTART only as DATE-TIME — instantaneous, point-in-range
- VEVENT with DTSTART only as DATE — all-day, `[DTSTART, DTSTART+1day)`
- VEVENT with no DTSTART — never matches (with a documented reason)
- Time-range with only `start` attribute — open-ended on the right
- Time-range with only `end` attribute — open-ended on the left
- Time-range fully before the event — no match
- Time-range fully after the event — no match
- Time-range exactly meeting event end — no match (half-open)
- Time-range exactly meeting event start — match (half-open includes start)
- Floating times (no Z, no TZID) — decide and document; RFC 4791 §9.9 says "treated as if in UTC" for filtering
- TZID parameter resolved correctly (this is where you punt to a TZ library or document the subset)

Recurring events (when you get there):
- Document the unsupported path explicitly: filter with time-range on a component containing RRULE returns "no match" rather than wrong match
- Test that this returns no match (so the behavior is locked in)

AddressBook filter test/anyof/allof:
- `anyof` returns true if any prop-filter matches
- `allof` returns true only if all prop-filters match
- Empty filter list under `anyof` — decide (typically false)
- Empty filter list under `allof` — decide (typically true, vacuous)

## `protocol/caldav/multistatus.rb` (already exists)

Your current tests cover the basics. Add:
- Output declares all four required namespaces (d, c, cr, cs) — a regression guard
- Responses are emitted in the order given (matters for some clients that assume position)
- Empty response array produces a valid (parseable) multistatus document
- A response containing pre-escaped XML is not double-escaped

## `protocol/caldav/path.rb` (already exists)

Your current code has no test block. Add:
- Normalizes `//` to `/`
- Normalizes leading `///foo` to `/foo`
- Adds leading `/` if missing
- `parent` of `/a/b/c/` is `/a/b/`
- `parent` of `/a/` is `/`
- `parent` of `/` is `/` (idempotent)
- `depth` of `/` is 0
- `depth` of `/a/` is 1
- `depth` of `/a/b` is 2 (trailing-slash-insensitive)
- `child_of?` returns true for direct child
- `child_of?` returns false for grandchild
- `child_of?` returns false for sibling
- `child_of?` returns false for self
- `ensure_trailing_slash` is idempotent on a slashed path
- `ensure_trailing_slash` adds slash to unslashed
- `start_with?` delegates to string semantics
- Equality: paths from different storage_class but same string compare equal (decide; current code does)
- Path containing `..` — what happens? The App test expects 400 or 404 from the upper layer, but Path itself currently doesn't sanitize. Test the actual behavior and document it.
- Path containing URL-encoded segments (`/calendars/admin/work%20cal/`) — does Path decode? Probably not (storage uses the raw string). Test that.
- `to_propfind_xml` output structure

## `protocol/caldav/xml.rb` (already exists, will be replaced)

If you keep regex helpers as a fallback or for non-filter uses, the tests are: escape the five XML entities, extract value, extract attr, handle namespace prefixes. But the main story is that `Filter::Parser` replaces these for the filter use case, and the regex helpers should be deleted from filter code paths.

## `protocol/caldav/etag.rb` and `protocol/caldav/ctag.rb`

ETag:
- Stable: same body produces same etag across calls
- Different bodies produce different etags
- Quoted in the output (RFC 7232 §2.3 weak/strong ETags — yours are strong, double-quoted)
- Truncated to your chosen length consistently
- Binary-safe: a body containing null bytes still produces an etag

CTag:
- Stable for the same collection state
- Changes when displayname changes
- Changes when description changes
- Changes when color changes
- Changes when an item is added
- Changes when an item is modified (its etag changes)
- Changes when an item is removed
- Does NOT change for a collection-property read with no state change
- Same collection state on two different storage backends produces the same ctag (the formula is content-addressable)

## `protocol/caldav/storage.rb` (abstract base)

- Every method raises `NotImplementedError` (you have this)
- Base class can be subclassed and a partial implementation works (sanity check on the contract)

## Storage backend conformance suite

This is one shared test file run against both `Storage::Mock` and `Storage::Filesystem`. Same suite, two backends. Catches divergence.

Collections:
- `create_collection` followed by `get_collection` returns the data
- `create_collection` returns the created data (doesn't require a re-fetch)
- `get_collection` returns nil for nonexistent path
- `collection_exists?` is true after create, false before
- `collection_exists?` is false after delete
- `delete_collection` removes the collection
- `delete_collection` removes all items in the collection
- `delete_collection` does not affect sibling collections
- `delete_collection` returns true when something was deleted, false otherwise
- `list_collections` returns direct children only, not grandchildren
- `list_collections` on a path with no children returns empty
- `update_collection` modifies named fields, leaves others untouched
- `update_collection` returns nil for nonexistent collection
- `update_collection` with `displayname: nil` actually nils it (vs leaving it alone) — your current code is ambiguous here; pick one
- Type symbol round-trips: `:calendar` saved is `:calendar` loaded (Filesystem serializes through JSON strings — important test)

Items:
- `put_item` with new path returns `is_new: true`
- `put_item` with existing path returns `is_new: false`
- `put_item` overwrites the body
- `get_item` returns body, content_type, etag
- `get_item` returns nil for nonexistent
- `delete_item` returns true on existence, false on absence
- `list_items` returns only items, not nested collections
- `list_items` excludes hidden files (Filesystem-specific but the contract is "items, not metadata")
- `list_items` on empty collection returns empty
- `move_item` removes source, creates destination
- `move_item` returns the new item's data
- `move_item` returns nil when source doesn't exist
- `move_item` overwrites destination if it exists (current behavior — confirm)
- `get_multi` returns results in input order
- `get_multi` returns nil for missing paths, in position
- `get_multi` with empty input returns empty
- ETag of the same body is the same across backends
- ETag changes when body changes

General:
- `exists?` true for items
- `exists?` true for collections
- `exists?` false otherwise
- `etag` returns item etag
- `etag` returns nil for collection (or returns ctag — decide; current code returns nil)
- `etag` returns nil for nonexistent

Filesystem-specific (don't apply to Mock):
- Persists across instance recreation (you have this)
- Survives the metadata file being missing (decide: treat as not-existing, or raise)
- Handles paths with characters that are valid in URLs but problematic on filesystems (`?`, `#`, spaces — should already work since you don't use them as separators, but test it)
- Concurrent writes from two processes — out of scope, document it
- Symlinks in the storage root — out of scope, document it

## `async/caldav/forward_auth.rb`

- Sets `dav.user` from `HTTP_REMOTE_USER`
- Leaves `dav.user` nil when header absent
- Parses `HTTP_REMOTE_GROUPS` as comma-separated list
- Trims whitespace around group names
- Empty groups header produces empty list
- Email and name flow through
- TestStub injects defaults when no header present
- TestStub respects existing headers when present
- Calls through to the wrapped app exactly once

## `async/caldav/server.rb` (the new single middleware)

This is the refactor target. The tests here are *exactly* the integration tests already in your `App` test block — the 27 of them. They are the contract. Don't add to them as part of the refactor; add to them only after the refactor is done and you're improving real behavior.

The fixture-replay tests (Phase 1 in the previous answer) live here too: load a recorded request, assert the response matches.

## Handler tests (per-handler, in async-caldav)

If you keep handlers as separate testable units, each handler gets:
- Happy path (one or two cases)
- 401 when unauthenticated
- 405 / 409 / 412 for the documented precondition failures specific to that handler
- Path-prefix dispatch correctness (Calendar handler doesn't handle `/addressbooks/` paths)
- Default content-type when none provided

But: the unit tests on individual middlewares in your *current* code are the kind of tests that make refactoring painful. Consider whether handler-level tests are worth having at all, or whether the integration tests + fixture replay cover everything you actually care about. My lean is: skip the per-handler unit tests, rely on integration. If a handler is complex enough to need its own tests, that's a sign it should be a pure function in `protocol-caldav` instead.

## What I'd specifically *not* test

- Behavior of `Rack::Request` itself
- Behavior of `Nokogiri` itself
- Parser performance (until you have a profiler-driven reason)
- That `Async` works (out of scope of this codebase)

## The cross-cutting test that catches the most bugs

One test, somewhere in `async-caldav`, that does:

- Take a known-good iCal fixture file with a tricky property (folded SUMMARY, multi-value ATTENDEE, parameter with quoted value, time-range edge case)
- PUT it through the full server
- REPORT it back with various filters
- Assert each filter returns or excludes it correctly

This is the test that proves the parser, filter, evaluator, and middleware all agree. The unit tests on each layer can pass while the integration is broken. This catches that.
