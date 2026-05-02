# Building a protocol on top of the Async gem family

Notes assembled from designing HTTPO, a session protocol carried inside an
HTTP/2 request. These are conventions and constraints inferred from reading
`protocol-http`, `protocol-http1`, `protocol-http2`, `protocol-websocket`,
`async-http`, and `async-websocket` source. Treat them as observations about
how those libraries are structured, not as official guidance.

## What kind of protocol are you actually building

The first decision is which of three categories your protocol falls into,
because they imply very different library shapes:

1. **A new HTTP transport.** Different framing on the wire than HTTP/1 or
   HTTP/2 - a peer to those, not a layer above. Examples: HTTP/3, theoretical
   future HTTP versions. You'd build something parallel to `protocol-http1`
   and `protocol-http2` with a `Connection` class, `Framer`, and frame types,
   then add it to `Async::HTTP::Protocol` so endpoints can negotiate it.

2. **A new application protocol that hijacks HTTP for handshake.** Different
   framing on the wire after a handshake using HTTP - WebSocket is the
   archetype. You'd build something like `protocol-websocket` (Connection,
   Framer, Frame classes for the post-upgrade framing) plus an integration
   library shaped like `async-websocket` (handshake request/response classes
   per HTTP version, a Client, a Server middleware).

3. **An application-layer convention on top of HTTP.** No new wire framing -
   just specific requests, headers, status codes, and orderings. Examples:
   WebDAV, OCI Distribution, ACME. You build a client class and a server
   middleware. No protocol-level library is needed unless there's framing
   inside the bodies.

4. **An application protocol with framing inside HTTP bodies.** The middle
   case we discovered while building HTTPO. The connection isn't upgraded -
   it's still ordinary HTTP/2 - but the request and response bodies carry
   structured messages that need parsing. This *does* warrant a wire-protocol
   library, just for the body framing rather than for socket-level framing.

The mistake to avoid: assuming "stateful protocol" implies "needs an upgrade
or a new wire format." A long-lived bidirectional HTTP/2 stream with framed
bodies gives you stateful sessions without touching either.

## The gem split: `protocol-X` vs `async-X`

The Async ecosystem consistently splits a protocol implementation across two
gems:

- **`protocol-X`** carries pure code that speaks the wire protocol. No async,
  no I/O policy, no transport choice. Inputs and outputs are abstract -
  byte streams that look like `IO` or `Protocol::HTTP::Body::Readable`,
  not concrete sockets or fibers. Depends only on `protocol-http` and
  whatever else is unavoidable.

- **`async-X`** carries the integration with `async-http` and `async`:
  client class, server class or middleware, fiber-based concurrency,
  connection pooling, anything that uses `Async {}` blocks or
  `Async::Semaphore` or `Async::Queue`.

Why the split exists:

- Other transports can use `protocol-X` without pulling in async. Sync
  servers, alternative event loops, testing setups.
- Pure wire code is easier to test in isolation - feed it bytes, assert
  what comes out.
- It enforces a discipline: if a class needs `Async`, it doesn't belong
  in the protocol gem.

The boundary in practice:

- Framing parsers and writers go in `protocol-X`. They take a
  `Protocol::HTTP::Body::Readable` (or anything that responds to `read`)
  and don't care how the bytes got there.
- Schema enumeration, payload models, error classes, named constants all go
  in `protocol-X`.
- Anything that constructs `Async::HTTP::Client`, `Async::HTTP::Server`,
  spawns fibers, or uses `Async::Semaphore` goes in `async-X`.
- Caches and stores can go either way depending on whether you want them
  usable without async I/O. Filesystem-backed stores using plain `File`
  can live in `protocol-X`; ones that need async file I/O go in `async-X`.

## Bodies are the universal abstraction

`Protocol::HTTP::Body::Readable` is the contract that lets the same protocol
code work over HTTP/1, HTTP/2, hijacked sockets, in-memory test fixtures,
and anything else. Anything that produces bytes implements `read` returning
String chunks or `nil` at EOF. Anything that consumes bytes is a
`Protocol::HTTP::Body::Writable`-shaped sink with `write(chunk)`.

For protocol code:

- Parse from any `Readable`, write to any `Writable`-shaped sink.
- Don't take `IO` directly. Don't take a `Connection`. Take a body.
- Don't close the body unless you own it. Adapters wrap and forward; they
  don't take ownership.

The base class `Protocol::HTTP::Body::Wrapper` is the pattern for
"transform a body into another body" - useful for things like decompression,
digest verification (`Body::Digestable`), or rewinding. Subclass it when
you want to layer behavior on top of an existing body without the consumer
knowing.

## Streaming, bidirectional bodies

Both request and response bodies in `Async::HTTP` can be streamed. The key
type is `Protocol::HTTP::Body::Writable` (a queue-backed body that's safe
to write to while the client/server is reading from it).

The pattern for "session inside one HTTP request":

```ruby
request_body = Protocol::HTTP::Body::Writable.new
request = Protocol::HTTP::Request[METHOD, "/", body: request_body, ...]

response_task = Async { @delegate.call(request) }

# Write to request_body. The HTTP/2 layer streams it as DATA frames.
request_body.write(...)

response = response_task.wait

# response.body is a Readable. Read from it concurrently with writing
# to request_body. Both directions independent.
chunk = response.body.read
```

`@delegate.call(request)` returns when headers arrive. Bodies stream
independently in both directions after that. The fiber stays in the
calling method, holding both ends of the conversation on its stack.

This works on HTTP/2 natively. On HTTP/1 the same pattern works only for
chunked-encoded request bodies, which not every HTTP/1 server tolerates.
If you only target HTTP/2, you don't have to think about it.

## Framing inside bodies

If your protocol needs multiple distinct messages on a single body stream,
you need framing inside the body. HTTP gives you one byte stream per
direction; slicing it into messages is your problem.

Practical framing options, in increasing complexity:

- **Newline-delimited JSON.** Each message is one line. Simple, debuggable,
  no length prefixes. Fails for binary payloads (which can contain `\n`).
- **Length-prefixed.** Every message preceded by a length. Handles binary
  but every message pays a fixed-size header.
- **Hybrid: line-delimited control + size-announced binary.** Control
  messages are JSON lines; binary payloads are preceded by a control
  message that announces their size. This is what HTTPO uses. Costs
  one JSON line per binary payload, but keeps the wire human-readable
  for control flow.

The reader needs to maintain a buffer across calls because line and size
boundaries don't align with HTTP body chunk boundaries. The pattern:

```ruby
class FramedReader
  def initialize(body)
    @body = body
    @buffer = String.new(encoding: Encoding::BINARY)
  end
  
  def read_line
    loop do
      if i = @buffer.index("\n")
        line = @buffer.byteslice(0, i)
        @buffer = @buffer.byteslice(i + 1, @buffer.bytesize - i - 1)
        return line
      end
      chunk = @body.read or raise "EOF"
      @buffer << chunk
    end
  end
  
  def stream_bytes(n, sink)
    # Drain buffer first, then read further chunks until n bytes delivered.
  end
end
```

This belongs in the `protocol-X` gem. It's pure code over the body abstraction.

## Bidirectional protocols on the client

If both sides of a session can send messages independently (the whole point
of putting a stateful protocol on HTTP/2), the client needs concurrent
reader and writer fibers. The single-fiber linear approach forces
request/response cadence and defeats the purpose.

The toolkit:

- `Async::Semaphore.new(limit: N)` - bounded in-flight work. Acquire
  before sending; release in the reader fiber when an ack arrives.
- `Async::Queue` - producer/consumer between fibers. The reader pushes
  events; the writer pulls work items. Or the reader pushes retry
  requests; the writer drains those preferentially.
- `Async::Variable` - one-shot signal between fibers. Useful for
  "negotiation done" or "fatal error, both fibers exit."

A typical pattern for a pipelined sender with retries:

```ruby
in_flight = Async::Semaphore.new(WINDOW)
pending = Async::Queue.new
work.each { |item| pending.enqueue(item) }
done = Async::Variable.new

reader = Async do
  while outstanding.any?
    event = read_next_event
    case event
    when :ack
      in_flight.release
      outstanding.delete(event.id)
    when :retry_needed
      in_flight.release
      pending.enqueue(event.id)
    when :fatal
      done.resolve(error)
      break
    end
  end
end

writer = Async do
  while outstanding.any?
    break if done.resolved?
    item = pending.dequeue
    in_flight.acquire
    send(item)
  end
end

result = done.wait
writer.stop
reader.wait
raise result if result.is_a?(Exception)
```

The writer acquires before sending; the reader releases when the ack
arrives. The semaphore caps the unacked work without sequencing the
sends. Retries flow back through the same pending queue.

When the protocol terminates (success or error), one fiber resolves
`done`, the other exits, the main fiber raises if it was an error.
Stop the writer explicitly because it might be blocked in `dequeue`.

## Out-of-order acks need explicit identifiers

If the protocol is fully sequential (send N, wait for ack, send N+1), the
ack doesn't need to identify which message it acks - position implies it.
Once you pipeline, you can't rely on position. Each ack must name what
it's acking, and the sender keeps a set of in-flight identifiers it
checks each ack against.

This generally also means each outgoing message carries an explicit
identifier - if the receiver might process them out of order or need to
disambiguate retries from new messages, position-based identity breaks.

For HTTPO: blob uploads are preceded by `{"sending":"sha256:...","size":N}`
and acked by `{"verified":"sha256:..."}` or `{"rejected":"sha256:..."}`.
The digest is the identifier. The receiver matches acks to outstanding
sends by digest, not by position.

## Strict vs trusting receivers

When the receiver verifies what the sender claims (digest match, schema
shape, expected vs actual identifier), there's a design choice:

- **Strict**: maintain expected state, reject anything unexpected with a
  clean error. Catches sender bugs and protocol drift early.
- **Trusting**: accept whatever arrives if it's individually valid. Simpler
  receiver, more permissive in the face of sender quirks.

Strict is usually the right default for protocols. The diagnostic value
of "you sent something I didn't ask for" is high; the cost (a small set
maintained per session) is trivial. Trusting is reasonable for
content-addressable systems where idempotency makes the wasted work
recoverable.

If the receiver rejects an unexpected message but bytes are already
"committed" to its inbound stream (the sender has announced a size and
the bytes are coming), the receiver still has to drain those bytes -
otherwise the framing gets out of sync for everything that follows.
A null sink that discards while keeping the framing in step is the answer.

## API conventions that match `Async::HTTP`

These are observed conventions that make a new gem feel like part of the
Async ecosystem rather than an outsider:

- **Endpoint at construction.** `Client.new(endpoint, **options)`.
  Don't take separate scheme/authority kwargs - those come from the
  endpoint.
- **Block form via `.open`.** `Client.open(endpoint) { |client| ... }`
  yields the client, ensures `close` runs in `ensure`. Returns the
  client without yielding when no block given.
- **`close` releases resources.** Especially the wrapped HTTP client
  and its connection pool.
- **Servers are middleware.** A `Protocol::HTTP::Middleware` subclass
  that handles its own concerns and delegates everything else via `super`.
  Not a server in the listening sense - that's still `Async::HTTP::Server`.
  This composes cleanly: stack multiple middlewares, mount under any
  Rack/Falcon/etc setup.
- **Methods are domain operations.** `Client#run`, `Client#connect`,
  `Client#publish` - whatever the protocol calls for. Don't expose
  generic `#call(request)` unless the user is meant to build raw
  requests; if all the constructing is internal, hide it.
- **Wrap an `Async::HTTP::Client` internally**, don't subclass it.
  Subclassing `Async::HTTP::Client` exposes verbs and methods that
  don't make sense for your protocol.
- **Constants live near where they're used.** `Protocol::HTTPO::RUN`,
  `Protocol::HTTPO::SESSION_MEDIA_TYPE`. Not `Protocol::HTTPO::Headers::RUN`
  unless there's a reason to nest.

## Errors

`Protocol::HTTP::Error` is the base class to inherit from. The HTTP
ecosystem has structural error categories (`BadRequest`, `RefusedError`,
etc.) you can include into your own when applicable. For protocol-specific
errors, define a small hierarchy under `Protocol::X::Error`:

- `Protocol::X::Error` - base, inherits `Protocol::HTTP::Error`.
- `Protocol::X::ProtocolError` - generic violations.
- Specific subclasses for cases where the consumer might want to rescue
  specifically, e.g. `RetriesExhaustedError`, `DigestMismatchError`.

Errors live in the `protocol-X` gem if they're about the wire format,
in `async-X` if they're about client policy (retry budgets, timeouts).

## Running on HTTP/2 only

If your protocol depends on bidirectional streaming and you don't need
HTTP/1 compatibility, decide that explicitly and document it. Implications:

- The client's HTTP endpoint must speak HTTP/2 (TLS with ALPN, or h2c).
- You don't need to design fallbacks for chunked-vs-content-length,
  upgrade dance, or any HTTP/1 oddities.
- The protocol's wire shape can assume true bidirectional streams.

If HTTP/1 compatibility matters, you'll need a way to advertise and
negotiate the protocol via Upgrade headers and per-version request/response
classes (this is what `async-websocket` does with
`UpgradeRequest`/`UpgradeResponse` for HTTP/1 and
`ConnectRequest`/`ConnectResponse` for HTTP/2).

## What goes where: a checklist

Wire-format library (`protocol-X`):

- Framing parsers and writers (over the body abstraction).
- Schema enumeration and serialization (e.g. OCI layout walking).
- Constants: method names, media types, header names.
- Error classes for protocol violations.
- Pure helpers (digest computation, URL parsing) where reusable.

Integration library (`async-X`):

- `Client` class wrapping `Async::HTTP::Client`.
- `Server` class as `Protocol::HTTP::Middleware`.
- Concurrency: semaphores, queues, fiber-based pipelining.
- Caches and stores tied to async I/O.
- Policy: retry budgets, in-flight windows, timeouts.
- Examples and integration tests.

Neither library:

- Anything specific to your application's actual work (in HTTPO's case,
  the runner that executes commands). That's the consumer's problem -
  inject it via constructor.

## What we figured out the hard way

- Deciding "this isn't a wire protocol" too early hides the fact that
  body framing *is* a wire concern when bodies carry multiple messages.
- "Optimistic with retries" and "explicit handshake" feel similar but
  imply very different protocol shapes. The trigger for picking the
  explicit form is when state needs to persist across the conditional
  steps - if the negotiate phase is just "is this in your cache?" with
  no other state, optimistic-with-retries works. Otherwise commit to
  the handshake.
- Sequential client-side logic for a multi-step protocol works for v1
  on paper but defeats async I/O. If you're using `Async`, build the
  pipelined version from the start - the extra structure (semaphore,
  queues, two fibers) is small once you've done it once and sequential
  becomes a special case (window of 1).
- Strict server-side validation is essentially free if you already have
  the expected-set in memory for other reasons. Skip it and you ship a
  protocol where buggy clients corrupt server state silently.
- The `Protocol::HTTP::Body::Writable` -> framing-writer chain on one
  side and `Protocol::HTTP::Body::Readable` -> framing-reader chain on
  the other is the symmetric pattern. Both ends look the same. If they
  don't, something is wrong.
