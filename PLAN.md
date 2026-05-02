Looking at your code, you have a single-gem implementation that mixes wire-protocol concerns with HTTP server integration. Based on the conventions in your notes, this should split.

## Where your implementation falls in the taxonomy

CalDAV/CardDAV is squarely **category 3** from your notes: an application-layer convention on top of HTTP. No new wire framing, no upgrade, no body-internal framing. The "protocol" is just specific methods (`PROPFIND`, `MKCALENDAR`, `REPORT`), specific XML payloads, specific status codes, and specific orderings (discovery → home-set → list).

This matters because your notes warn against the opposite mistake — building a `protocol-X` gem when you don't need wire framing. But there's still a meaningful split available, because CalDAV has *plenty* of pure-code concerns that don't depend on Rack or Async: XML schema, property serialization, ETag/CTag computation, path semantics, multistatus envelopes, filter evaluation.

## What I see in your current code

Everything is in one namespace (`Caldav`) with no separation between:

1. **Pure protocol code** — `Xml`, `Multistatus`, `Path`, `DavCollection`/`DavItem` rendering methods (`to_propfind_xml`, `to_report_xml`), `DAV_HEADERS`, ETag/CTag derivation, the comp-filter / prop-filter / text-match evaluation logic inside `Calendar::Report` and `Contacts::Report`.

2. **Storage abstraction** — `Storage` base class, `Storage::Mock`, `Storage::Filesystem`. Already nicely abstract; doesn't depend on Rack at all.

3. **Rack middleware** — every `Calendar::*` and `Contacts::*` class, `App`, `ForwardAuth`, `TestMiddleware`. These are coupled to `Rack::Request` and the rack env.

The shape you're missing: `protocol-caldav` (a Rack-free, Async-free library that knows the wire format) and `async-caldav` (the integration: middleware, server, client). Compare to how `protocol-websocket` exposes `Connection`/`Framer`/`Frame` while `async-websocket` exposes `Client`/`Adapters::Rack`.

## The concrete split

**`protocol-caldav`** — pure code, depends on nothing async or rack-y:

- `Protocol::Caldav::Xml` — your existing escape/extract helpers.
- `Protocol::Caldav::Multistatus` — already pure.
- `Protocol::Caldav::Path` — already pure (the `storage_class` injection is fine; it doesn't reach for Rack).
- `Protocol::Caldav::Collection` and `Protocol::Caldav::Item` — but stripped of their `find`/`create`/`list` class methods that talk to storage. Those are integration. The classes should be value objects with `to_propfind_xml` / `to_report_xml` and a constructor. Storage adapters return data; the integration layer wraps it into these.
- `Protocol::Caldav::Filter` — extract the comp-filter / prop-filter / text-match logic that's currently inlined in your two `Report` middlewares. This is duplicated wire-format code; it belongs in one place. A `Filter.parse(xml)` returning something like `Filter#matches?(ical_or_vcard_body)` is the right shape.
- `Protocol::Caldav::ETag` — the `%("#{Digest::SHA256.hexdigest(body)[0..15]}")` formula appears in three places (Mock, Filesystem, your test helpers). Centralize.
- `Protocol::Caldav::CTag` — same. The `Digest::SHA256.hexdigest("#{path}:#{displayname}:...")` calculation lives in `DavCollection#to_propfind_xml` and is reproduced in test helpers. One canonical implementation.
- `Protocol::Caldav::Constants` — `DAV_HEADERS`, namespace URIs (`urn:ietf:params:xml:ns:caldav`, etc.), media types.
- `Protocol::Caldav::Storage` (the abstract base only) — the interface is wire-relevant: it defines what a storage backend must answer. Concrete implementations stay in their own gems or in `async-caldav`.
- Error hierarchy: `Protocol::Caldav::Error` < `Protocol::HTTP::Error`, with subclasses like `PreconditionFailed`, `UidConflict`, `InvalidCalendarData`.

The test that this split is right: every file in `protocol-caldav` should be loadable without `require "rack"` or `require "async"`. Right now your `Path`, `Xml`, `Multistatus`, `DavCollection`, `DavItem` all `require "bundler/setup"` and `require "caldav"`, and the umbrella `caldav.rb` requires `rack`. Untangle that and the rest falls out.

**`async-caldav`** — the Rack/Async integration:

- `Async::Caldav::Server` — a `Protocol::HTTP::Middleware`, not a Rack stack of nine middlewares per resource type. More on this below.
- `Async::Caldav::Storage::Mock`, `Async::Caldav::Storage::Filesystem` — the concrete backends. Filesystem could arguably live in `protocol-caldav` since it uses sync `File`, but your notes say "Caches and stores can go either way." Async file I/O if you add it would push it here regardless.
- `Async::Caldav::ForwardAuth` — auth header parsing is integration concern, lives here.
- `Async::Caldav::Client` — if you want one. There isn't one currently. CalDAV clients aren't widely needed (most consumers are Apple/Mozilla/Thunderbird code), but if you want symmetry, this is where it goes. `Client.new(endpoint).open { |c| c.calendars(user: 'admin') }` shape.
- A test middleware analogous to `TestMiddleware`, but renamed since it's not a middleware-shaped object the way the others are — it's a test harness.

## The middleware-per-method pattern is the bigger refactor

Setting aside the gem split: your `App#build_stack` composes 19 middlewares, each of which does the same dispatch check (`if request.request_method != 'X' || !path.start_with?('/Y/')` then passthrough). Every middleware re-parses the path, re-checks auth, re-fetches the collection or item.

Compare to `async-websocket`'s `Adapters::Rack`, which is a single class that handles the whole upgrade because that's the natural unit. Or `protocol-http`'s middleware base — one class, one `call`, dispatch internally.

The unit of CalDAV isn't "one middleware per HTTP method." It's "one handler per resource type" or even "one server, dispatching by method." Your current factoring forces every request to walk past 18 passthrough checks before reaching the right handler, and it makes the auth check appear in 19 places (with subtle variations — some middlewares check `path.start_with?('/calendars/')` first, others check auth first, the order of the early-returns isn't consistent).

What the structure could look like:

```
Async::Caldav::Server (Protocol::HTTP::Middleware)
  - dispatches by method to internal handlers
  - one auth check at the top
  - one path parse
  
Async::Caldav::Handlers::Propfind
Async::Caldav::Handlers::Report
Async::Caldav::Handlers::Put
Async::Caldav::Handlers::Mkcol     # handles MKCOL + MKCALENDAR
Async::Caldav::Handlers::Move
... etc
```

Handlers are plain objects, not Rack middlewares. They take a parsed request context (path, body, user, storage) and return a response tuple. The Calendar/Contacts split inside `PROPFIND`, `REPORT`, `PUT`, `DELETE`, `GET`, `HEAD`, `MOVE` collapses — there's almost no behavioral difference between `Calendar::Get` and `Contacts::Get`, or `Calendar::Delete` and `Contacts::Delete`. They differ in default content-type and not much else. The duplication is mechanical; one handler with a `resource_type` derived from the path prefix handles both.

The places where calendar and contacts genuinely diverge:

- `PROPFIND` rendering (different resourcetypes, calendar adds `supported-calendar-component-set`).
- `MKCALENDAR` vs `MKCOL` (different methods, different XML, different default type).
- `REPORT` filter (calendar has `comp-filter`, addressbook only has `prop-filter`).
- `PUT` body validation (`BEGIN:VCALENDAR` vs `BEGIN:VCARD`).

Those four differences justify polymorphism inside individual handlers, not 18 separate middleware classes.

## Specific things in the current code worth flagging

A few observations on issues that are independent of the abstraction question but that you'd want to address while you're moving things:

The `extract_value` regex in `Xml` matches the *first* tag of that name anywhere in the document. In `Calendar::Proppatch`, when both `<d:set>` and `<d:remove>` contain `<d:displayname>`, your code does `dn = Xml.extract_value(body, 'displayname')` and then has special-case logic checking `body.match?(/<[^>]*remove[^>]*>.*displayname/m) && !dn` to detect removes. That's fragile — a set with displayname and a remove with description would mis-route. Real XML parsing (Nokogiri or REXML) belongs in `protocol-caldav`; the regex approach is fine for prototypes but it's already showing seams.

The `DELETE collection` semantics in your test — `[204, 405].should.include status` — is acknowledging you haven't decided. RFC 4918 §9.6 requires DELETE on a collection to return a multistatus with per-resource statuses on partial failure (404 if it succeeded fully). Right now `Calendar::Delete` does the right thing for the success case but doesn't handle partial failure. Worth deciding.

In `Calendar::Move` and `Contacts::Move`, the destination URL parse is `URI.parse(destination).path` — this strips the host check that RFC 4918 §9.9.4 requires (a destination on a different server should return 502). Minor, and most clients don't exercise it, but it's a place where the wire spec says one thing and the code does another.

`Path#child_of?` is defined but I don't see it called anywhere — dead code worth removing or covering.

## What I'd suggest as the order of operations

1. Pull `Xml`, `Multistatus`, `Path`, `Filter` (extracted from the two `Report` middlewares), `ETag`/`CTag` (extracted from storage backends and `DavCollection#to_propfind_xml`), `Constants`, error classes, and `Storage` (abstract) into a `protocol-caldav` gem. No `require "rack"` anywhere. Tests use stubbed bodies, not Rack envs.

2. Collapse the 19 middlewares into one `Server` middleware with a handler-per-method internal dispatch. The Calendar/Contacts duplication should mostly disappear — write it once, parameterize on resource type.

3. Move `Storage::Mock`, `Storage::Filesystem`, `ForwardAuth`, `Server`, `TestHarness`, and (optionally) `Client` into `async-caldav`. This gem depends on `protocol-caldav`, `async-http`, and `rack`.

4. The `caldav.rb` umbrella file with the explicit load order goes away. Each gem requires what it needs. The `Dir.glob` of all middlewares becomes a static require list since there are far fewer files.

The result mirrors the `protocol-websocket` / `async-websocket` and `protocol-http` / `async-http` shape your notes describe, and it makes the protocol code reusable for anyone who wants to embed CalDAV semantics in a non-Async server (Falcon's sync mode, a test harness, an alternative event loop) without dragging in your middleware stack.

Want me to go deeper on any one of these — the handler collapse, the filter extraction, the protocol-gem boundary specifically, or something else?
