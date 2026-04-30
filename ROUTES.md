# Radicale Route Reference

Routes and HTTP methods implemented by Radicale (the reference implementation).

DAV compliance header: `1, 2, 3, calendar-access, addressbook, extended-mkcol`

## URL Structure

Radicale uses a flat path scheme. Collection type (calendar vs addressbook) is
determined by stored metadata, not by the URL.

```
/                              Root (principal discovery)
/.well-known/caldav            301 -> /
/.well-known/carddav           301 -> /
/{user}/                       User principal collection
/{user}/{collection}/          Calendar or addressbook collection
/{user}/{collection}/{item}    Individual event (.ics) or contact (.vcf)
```

## HTTP Methods

### OPTIONS

Returns DAV capability headers. No authentication required.

- **Response headers:** `Allow` (all supported methods), `DAV` (compliance classes)
- **Status:** `200`

### PROPFIND

Discover properties on any resource. Supports `Depth: 0` and `Depth: 1`.

- **Targets:** root, principal, collection, item
- **Request body:** `<propfind>` with `<allprop/>`, `<propname/>`, or `<prop>` listing specific properties
- **Status:** `207 Multi-Status`

Supported properties on collections:

| Property | Namespace |
|---|---|
| `resourcetype` | `DAV:` |
| `displayname` | `DAV:` |
| `getetag` | `DAV:` |
| `getlastmodified` | `DAV:` |
| `getcontenttype` | `DAV:` |
| `getcontentlength` | `DAV:` |
| `sync-token` | `DAV:` |
| `current-user-principal` | `DAV:` |
| `current-user-privilege-set` | `DAV:` |
| `supported-report-set` | `DAV:` |
| `principal-collection-set` | `DAV:` |
| `principal-URL` | `DAV:` |
| `owner` | `DAV:` |
| `getctag` | `http://calendarserver.org/ns/` |
| `calendar-home-set` | `urn:ietf:params:xml:ns:caldav` |
| `calendar-description` | `urn:ietf:params:xml:ns:caldav` |
| `calendar-color` | `http://apple.com/ns/ical/` |
| `supported-calendar-component-set` | `urn:ietf:params:xml:ns:caldav` |
| `max-resource-size` | `urn:ietf:params:xml:ns:caldav` |
| `addressbook-home-set` | `urn:ietf:params:xml:ns:carddav` |
| `supported-address-data` | `urn:ietf:params:xml:ns:carddav` |
| `calendar-user-address-set` | `urn:ietf:params:xml:ns:caldav` |

Supported properties on items:

| Property | Namespace |
|---|---|
| `resourcetype` | `DAV:` (returned empty) |
| `getetag` | `DAV:` |
| `getlastmodified` | `DAV:` |
| `getcontenttype` | `DAV:` |
| `getcontentlength` | `DAV:` |

### PROPPATCH

Modify properties on a collection.

- **Targets:** collection
- **Request body:** `<propertyupdate>` with `<set>` / `<remove>` sections
- **Status:** `207 Multi-Status`

### MKCALENDAR

Create a new calendar collection (RFC 4791).

- **Targets:** non-existent path under a principal
- **Request body:** optional `<mkcalendar>` with `<set><prop>` for initial properties (displayname, description, color, timezone, supported-calendar-component-set)
- **Preconditions:** parent must exist and be a non-tagged collection (principal); path must not already exist
- **Status:** `201 Created`

### MKCOL

Create a new collection (RFC 5689 extended-mkcol).

- **Targets:** non-existent path under a principal
- **Request body:** optional `<mkcol>` with `<set><prop>` including `resourcetype` (to specify addressbook, calendar, or plain collection)
- **Preconditions:** same as MKCALENDAR
- **Status:** `201 Created`

### PUT

Create or update an item. Also supports writing an entire collection.

- **Targets:** item path (create/update single item) or collection path (overwrite whole collection)
- **Request body:** iCalendar (`text/calendar`) or vCard (`text/vcard`) data
- **Conditional headers:**
  - `If-Match` -- update only if ETag matches (prevents conflicts)
  - `If-None-Match: *` -- create only, fail if item already exists
- **Status:** `201 Created` (new) or `204 No Content` (updated)
- **Response headers:** `ETag`

### GET

Retrieve a single item or export an entire collection.

- **Targets:** item (returns single object), collection (returns aggregated export)
- **Collection response:** all items serialized as one `.ics` or `.vcf` file
- **Response headers:** `Content-Type`, `ETag`, `Last-Modified`, `Content-Disposition` (for collections)
- **Status:** `200`

### HEAD

Identical to GET but the response body is dropped. Used for ETag/existence checks.

- **Status:** `200`

### DELETE

Delete an item or an entire collection (with all its contents).

- **Targets:** item or collection
- **Conditional headers:** `If-Match` -- only delete if ETag matches
- **Status:** `200` (with multistatus body)

### MOVE

Move an item from one collection to another.

- **Targets:** existing item
- **Request headers:**
  - `Destination` -- target URL
  - `Overwrite` -- `T` or `F` (default `F`)
- **Constraints:** source and destination collections must have the same tag; cannot move collections; UID conflict checks apply
- **Status:** `201 Created` (new location) or `204 No Content` (overwritten)

### REPORT

Query items or synchronize changes. The report type is determined by the root
element of the XML request body.

#### calendar-multiget (CalDAV)

Fetch specific calendar items by href.

- **Request body:** `<calendar-multiget>` with `<href>` list and `<prop>` (typically `getetag` + `calendar-data`)
- **Targets:** calendar collection
- **Status:** `207 Multi-Status`

#### calendar-query (CalDAV)

Query calendar items with filters (component type, time-range, property filters).

- **Request body:** `<calendar-query>` with `<filter>` and `<prop>`
- **Supports:** `<expand>` for recurring event expansion within a time range
- **Targets:** calendar collection
- **Status:** `207 Multi-Status`

#### free-busy-query (CalDAV)

Request free/busy information for a time range.

- **Request body:** `<free-busy-query>` with `<time-range>`
- **Targets:** calendar collection
- **Response:** `text/calendar` with VFREEBUSY components
- **Status:** `200`

#### addressbook-multiget (CardDAV)

Fetch specific contacts by href.

- **Request body:** `<addressbook-multiget>` with `<href>` list and `<prop>` (typically `getetag` + `address-data`)
- **Targets:** addressbook collection
- **Status:** `207 Multi-Status`

#### addressbook-query (CardDAV)

Query contacts with property filters (prop-filter, text-match, param-filter).

- **Request body:** `<addressbook-query>` with `<filter>` and `<prop>`
- **Supports:** `test="anyof"` / `test="allof"` filter logic
- **Targets:** addressbook collection
- **Status:** `207 Multi-Status`

#### sync-collection (WebDAV)

Incremental sync. Client sends a sync-token, server returns changes since that token.

- **Request body:** `<sync-collection>` with `<sync-token>`
- **Targets:** calendar or addressbook collection
- **Response:** includes new `<sync-token>` for next sync
- **Status:** `207 Multi-Status`

### POST

Not used for CalDAV/CardDAV protocol operations. Radicale only uses POST for
its internal web UI (`/.web`) and sharing endpoints (`/.sharing`). All other
paths return `405 Method Not Allowed`.

## What Radicale Does NOT Implement

These are present in DAViCal or other servers but absent from Radicale:

| Feature | Notes |
|---|---|
| `MKTICKET` | WebDAV ticketing (Xythos extension) |
| `BIND` | RFC 5842 path binding / aliasing |
| `LOCK` / `UNLOCK` | WebDAV locking (RFC 4918 Section 7) |
| `COPY` | WebDAV copy |
| `ACL` | Access control method (RFC 3744) |
| Implicit scheduling | Auto-distributing invites to attendee inboxes (RFC 6638) |
| Scheduling outbox POST | iTIP freebusy/invite via POST to `.out` (RFC 6638) |
| Timezone service | TZDIST protocol (`/tz.php`) |
| `/caldav.php` prefix | DAViCal compatibility path |
| Path-based type routing | `/calendars/` vs `/addressbooks/` prefixes |
