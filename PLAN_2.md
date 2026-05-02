You're right. Looking at your actual code:

## Your situation, specifically

You have **126 unit tests** spread across 22 files, each testing a specific class (`Caldav::Calendar::Put`, etc.). Plus **27 integration tests** in `app.rb` that exercise the full stack through `Caldav::App.new(storage: mock)`.

The unit tests are the problem — they name the structures being demolished. The integration tests in `app.rb` are the asset, because they only know about `App#call(env)`.

## The strategy

**Phase 0: Lock the integration tests as the spec.**

The 27 tests in `App`'s test block — full-stack MKCALENDAR→PROPFIND, PUT→GET, PUT→DELETE→GET, MKCOL→PROPFIND, PROPPATCH→PROPFIND, PUT→REPORT, DELETE collection, the discovery flow tests, path sanitization, MOVE, ETag round-trip, REPORT comp-filter, .well-known — these stay byte-identical through the entire refactor. They are the contract.

Before touching anything, audit them. There are gaps. Off the top: no test for `If-None-Match` 304 on `GET` going through `App` (only through `Calendar::Get` directly), no test for `HEAD` through `App`, no test for the `Multistatus` empty-body shape through `App`, no test for what happens when `MKCALENDAR` is called on a path under `/addressbooks/` or vice versa. Add the missing ones now, against the current implementation. Every test you add at this stage documents current behavior — including bugs. That's fine; bug-compatibility is the point.

**Phase 1: Add a snapshot harness alongside the existing tests.**

Wrap `Caldav::App` in a recording proxy. Run your existing app against a real client (Thunderbird Lightning is the most thorough — it does full discovery, sync-collection, calendar-multiget, the works). Save every (request env, response tuple) pair to disk. You want a few hundred of these covering: initial discovery, calendar create, event create, event modify, event delete, sync, conflict resolution.

Then write one test that loads each fixture and asserts `App.new(storage: fresh_mock).call(env) == recorded_response` after replaying any setup steps. If your storage is deterministic (it is — ETags are SHA256 of body, CTags are SHA256 of a fixed string), responses are reproducible.

This is your safety net. Phase 0 tests prove the API contract holds; Phase 1 fixtures prove real clients still work. The unit tests under each middleware can die without ceremony once these two pass.

**Phase 2: Strangler with a feature flag.**

Don't refactor `App`. Build `Caldav::App2` next to it. Initially `App2#call` just delegates to `App#call`. Add a comparison wrapper:

```
class App
  def self.build(storage:, mode: ENV['CALDAV_MODE'])
    case mode
    when 'new' then App2.new(storage: storage)
    when 'compare' then Comparison.new(App.new_old(storage: storage), App2.new(storage: storage))
    else App.new_old(storage: storage)
    end
  end
end
```

`Comparison#call` runs both, diffs the results, logs any divergence (with the env that caused it), returns the *old* result. You can run this in production-like environments and accumulate a divergence log without users seeing the new behavior. When the divergence log is empty for a week of real traffic, flip to `mode: 'new'`.

The diff has to be smart about three things in your code specifically:

- **XML whitespace.** Your `Multistatus` output has heredoc-driven whitespace that differs from what a different XML construction would produce. The `normalize` helper in your tests (`xml.gsub(/>\s+</, '><').strip`) is what you compare on, not raw bytes.
- **Hash order in headers.** Rack normalizes this but be explicit.
- **ETag values.** These are deterministic given identical bodies, so they should match. If they don't, that's a real divergence (somebody changed how a body is constructed).

**Phase 3: Refactor inside `App2` only.**

Now `App2` becomes the new structure: pure `protocol-caldav` classes underneath, single `Server` middleware on top, handler-per-method dispatch. Each time you move a piece of logic, run the Phase 0 tests and the Phase 1 fixtures against `App2`. They must pass. The `Comparison` mode catches anything Phase 0 and Phase 1 missed.

Crucially: the *old* `App` and its 19 middlewares stay completely untouched during this phase. You're not refactoring them. You're rebuilding from scratch in `App2` with the unit tests *of the new structure* providing fine-grained feedback, while the old behavior tests provide the contract.

**Phase 4: Cutover and deletion.**

When `Comparison` mode shows zero divergence across your fixture corpus and a stretch of real traffic:

1. Flip default to `App2`.
2. Leave the old code in place for one release.
3. Next release, delete `App`, the 19 middleware files, and their unit tests. The integration tests stay; they now test `App2` (renamed to `App`).

## What makes this bulletproof for *your* code specifically

Three properties of your codebase make this approach unusually safe:

1. **Storage is already abstracted.** `Storage::Mock` and `Storage::Filesystem` both work. The new implementation can use the same backends without modification, so the comparison is apples-to-apples.

2. **ETags and CTags are pure functions of state.** `%("#{Digest::SHA256.hexdigest(body)[0..15]}")` and the equivalent CTag formula. Two implementations that read the same storage produce the same ETags. No clock, no random, no nonce — your responses are reproducible. This is what makes fixture replay actually work; many systems can't do this.

3. **The 27 App-level integration tests already exercise multi-request flows.** That's rare and valuable. Most projects have to write these from scratch before refactoring; you've already done it.

## The thing that will actually bite you

The XML regex parsing in `Xml.extract_value` and `Xml.extract_attr`. When you replace it with proper XML parsing in `protocol-caldav`, you'll handle inputs the regex didn't — namespaced elements with unusual prefixes, CDATA sections, comments, attribute order variation. Some of these will produce *better* responses than the old code did, which means `Comparison` will flag them as divergences.

You then have to decide, per divergence: bug-compatible (make the new code match the old) or genuine improvement (update the test fixture, document the change). Budget time for this triage. It's the actual hard work of the refactor and it's where "zero disruption" stops being literally true and starts being "every divergence was an explicit choice."

That's the closest you get to bulletproof: every behavior change is logged, reviewed, and intentional, rather than discovered by a user.
