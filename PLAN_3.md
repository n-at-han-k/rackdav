The hardest part is extracting the filter logic — `comp-filter`, `prop-filter`, `text-match` — into `protocol-caldav` as a proper parsed-and-evaluated structure, replacing the regex-and-string-include approach in `Calendar::Report` and `Contacts::Report`.

It's the hardest because:

1. The current implementation is wrong in ways the tests don't catch — it uses `body.include?(text_match)` which matches anywhere in the iCalendar/vCard, not in the named property. A `text-match` on `SUMMARY` for "Alice" would match an event whose ATTENDEE is Alice.
2. RFC 4791 §9.7 (CalDAV) and RFC 6352 §10.5 (CardDAV) define recursive nested filters with negation, time ranges, parameter filters, and match semantics (substring/equals/starts-with/ends-with, case-sensitive/insensitive). The current code handles roughly 5% of the spec.
3. iCalendar and vCard are line-folded formats — a long SUMMARY can wrap across lines with `\r\n ` continuations. The regex/include approach silently fails on these.
4. The integration tests in `App` will pass either way for the simple cases, but real clients (Thunderbird with recurring events, Apple Calendar with attendees) will hit the broken paths.

Here's the design. I'm not running anything — this is the structure with the reasoning.

## The shape

Three layers: a tokenizer for the iCalendar/vCard line format, a filter AST with a parser from XML, and an evaluator that walks the AST against a parsed component.

```
protocol-caldav/
  lib/protocol/caldav/
    ical/
      parser.rb       # iCal text → Component tree
      component.rb    # VCALENDAR/VEVENT/VTODO with properties + sub-components
      property.rb     # SUMMARY, DTSTART, etc., with parameters
    vcard/
      parser.rb       # vCard text → Card
      card.rb         # vCard with properties
    filter/
      calendar.rb     # CalDAV filter AST (comp-filter, prop-filter, ...)
      addressbook.rb  # CardDAV filter AST (prop-filter, ...)
      parser.rb       # XML → filter AST
      match.rb        # AST + component → bool
```

## Why parse iCalendar properly

The current `Calendar::Report` does `item.body.include?("BEGIN:#{comp_name}")` to decide if a `VEVENT` is present. That's mostly fine but breaks on:

- A VEVENT inside a VTODO's `RELATED-TO` reference (won't happen in practice, but the `include?` doesn't know that).
- Line-folded properties — `BEGIN:VEVENT` itself can't fold but property values can, and substring matching across folded lines fails.
- `text-match` against a property — `body.include?("Alice")` matches the string "Alice" wherever it appears: SUMMARY, DESCRIPTION, ATTENDEE CN, ORGANIZER, a URL, anywhere.

A real iCal parser is ~150 lines and you only need a subset (no recurrence expansion, no value-type coercion beyond strings and DATE-TIME for time-range). The grammar is in [RFC 5545 §3.1](https://datatracker.ietf.org/doc/html/rfc5545#section-3.1):

```
contentline = name *(";" param ) ":" value CRLF
```

Lines fold on `CRLF` followed by a space or tab. You unfold first, then split by `:` once for name+params vs value, then split params by `;`. Components nest via `BEGIN:X` / `END:X`. That's it for the parser surface you need.

The parsed shape:

```ruby
module Protocol::Caldav::Ical
  Component = Struct.new(:name, :properties, :components) do
    def find_property(name)
      properties.find { |p| p.name.casecmp?(name) }
    end
    
    def find_components(name)
      components.select { |c| c.name.casecmp?(name) }
    end
  end
  
  Property = Struct.new(:name, :params, :value)
end
```

Parameters matter for time-range (you need TZID) and for some prop-filters that match on parameter values. The vCard equivalent is structurally identical but flatter (no nesting), per [RFC 6350 §3.3](https://datatracker.ietf.org/doc/html/rfc6350#section-3.3).

## The filter AST

CalDAV filters are recursive. The XML mirrors the iCal nesting:

```xml
<c:filter>
  <c:comp-filter name="VCALENDAR">
    <c:comp-filter name="VEVENT">
      <c:time-range start="20260101T000000Z" end="20260201T000000Z"/>
      <c:prop-filter name="SUMMARY">
        <c:text-match collation="i;ascii-casemap" match-type="contains">Meeting</c:text-match>
      </c:prop-filter>
      <c:prop-filter name="STATUS">
        <c:is-not-defined/>
      </c:prop-filter>
    </c:comp-filter>
  </c:comp-filter>
</c:filter>
```

The AST:

```ruby
module Protocol::Caldav::Filter::Calendar
  CompFilter = Struct.new(:name, :is_not_defined, :time_range, :prop_filters, :comp_filters)
  PropFilter = Struct.new(:name, :is_not_defined, :time_range, :text_match, :param_filters)
  ParamFilter = Struct.new(:name, :is_not_defined, :text_match)
  TextMatch = Struct.new(:value, :collation, :match_type, :negate_condition)
  TimeRange = Struct.new(:start_time, :end_time)
end
```

Each node corresponds 1:1 to an XML element in [RFC 4791 §9.7](https://datatracker.ietf.org/doc/html/rfc4791#section-9.7). The `is_not_defined` flag captures the `<c:is-not-defined/>` empty element which means "this thing must be absent" — easy to forget; Thunderbird uses it.

## Evaluation semantics

This is where the spec is precise and the current code is silent. Per RFC 4791 §9.7.1, a `comp-filter` matches a component when:

- The component's name matches `name`, AND
- If `is-not-defined` is present: the component is absent (so the filter matches when the component doesn't exist — inverts the whole rule).
- Otherwise: every nested `time-range`, `prop-filter`, and `comp-filter` matches against this component.

The "every nested ... matches" is AND. There's no OR in the basic filter spec — clients that need OR send multiple REPORT requests. (CalDAV's `<c:filter>` was designed before anyone learned the lesson that filter languages need composition.)

Match types from [RFC 4791 §9.7.5](https://datatracker.ietf.org/doc/html/rfc4791#section-9.7.5): `equals`, `contains` (default), `starts-with`, `ends-with`. Collations from [RFC 4790](https://datatracker.ietf.org/doc/html/rfc4790): `i;ascii-casemap` (case-insensitive ASCII, default for CalDAV) and `i;octet` (binary). Don't try to be clever about Unicode collation — clients don't send anything else and implementing UCA is a project.

The evaluator:

```ruby
module Protocol::Caldav::Filter::Calendar::Match
  def self.matches?(filter, component)
    return false unless component.name.casecmp?(filter.name)
    
    if filter.is_not_defined
      # is-not-defined on a comp-filter means "this comp must not exist"
      # but we only get here if it does exist, so... no match
      return false
    end
    
    return false if filter.time_range && !time_range_matches?(filter.time_range, component)
    
    filter.prop_filters.all? { |pf| prop_filter_matches?(pf, component) } &&
      filter.comp_filters.all? { |cf| 
        children = component.find_components(cf.name)
        if cf.is_not_defined
          children.empty?
        else
          children.any? { |child| matches?(cf, child) }
        end
      }
  end
  
  def self.prop_filter_matches?(filter, component)
    properties = component.properties.select { |p| p.name.casecmp?(filter.name) }
    
    if filter.is_not_defined
      return properties.empty?
    end
    
    return false if properties.empty?
    
    properties.any? do |prop|
      next false if filter.text_match && !text_match_matches?(filter.text_match, prop.value)
      filter.param_filters.all? { |pf| param_filter_matches?(pf, prop) }
    end
  end
  
  def self.text_match_matches?(matcher, value)
    result = case matcher.match_type
    when 'equals'      then collate_equal?(matcher.collation, value, matcher.value)
    when 'starts-with' then collate_starts?(matcher.collation, value, matcher.value)
    when 'ends-with'   then collate_ends?(matcher.collation, value, matcher.value)
    else                    collate_contains?(matcher.collation, value, matcher.value)
    end
    matcher.negate_condition ? !result : result
  end
  
  def self.collate_contains?(collation, haystack, needle)
    case collation
    when 'i;octet' then haystack.include?(needle)
    else haystack.downcase.include?(needle.downcase)
    end
  end
  # ... collate_equal?, collate_starts?, collate_ends? similarly
end
```

A few things worth flagging here:

The double-negative on `is-not-defined` for comp-filters is deliberately confusing. The spec says "the named component must not be defined." So if the parent component has no children of that name, the filter passes. If it has any, you check `is_not_defined` and bail. The code above handles this at the call site (in the parent's iteration over `comp_filters`) rather than recursing into `matches?`, because `matches?` is called *for an existing component* and `is-not-defined` is about absence.

`text-match` can have `negate-condition="yes"` ([RFC 4791 §9.7.5](https://datatracker.ietf.org/doc/html/rfc4791#section-9.7.5)). Forgetting this inverts results for any client that uses it — DAVx5 does, occasionally.

For multi-valued properties (a VEVENT can have multiple ATTENDEE properties), `prop_filter_matches?` uses `any?` — the property filter passes if *any* matching property satisfies it. RFC 4791 is explicit: "A property is said to match if any instance of the property in the calendar component matches all the specified filter conditions."

## Time-range is the trap

[RFC 4791 §9.9](https://datatracker.ietf.org/doc/html/rfc4791#section-9.9) defines time-range matching with 12 cases depending on which combination of DTSTART, DTEND, DURATION, and recurrence are present. For VEVENT alone:

- `DTSTART` + `DTEND` → overlap test on `[DTSTART, DTEND)`.
- `DTSTART` + `DURATION` → compute end as DTSTART + DURATION, overlap test.
- `DTSTART` only, DATE-TIME value → instantaneous, point in `[start, end)`.
- `DTSTART` only, DATE value → all-day, `[DTSTART, DTSTART+1day)`.
- No `DTSTART` → never matches.

VTODO is different (uses DUE), VJOURNAL is different again (instantaneous on DTSTART). VFREEBUSY uses DTSTART/DTEND of the freebusy block. Recurring events need expansion via RRULE/RDATE/EXDATE which is its own multi-hundred-line problem ([RFC 5545 §3.8.5](https://datatracker.ietf.org/doc/html/rfc5545#section-3.8.5)).

My recommendation: ship time-range as "VEVENT non-recurring with DTSTART/DTEND only" first. That covers ~70% of real client filter requests. Add VTODO/VJOURNAL when you have a test fixture that needs it. Defer recurrence expansion entirely until you have a recurring-event test case from a real client — at which point pull in [`icalendar`](https://github.com/icalendar/icalendar) gem or [`ice_cube`](https://github.com/ice-cube-ruby/ice_cube) rather than implementing RFC 5545 §3.8.5 yourself. That section is genuinely hard; see the [errata list](https://www.rfc-editor.org/errata_search.php?rfc=5545) for how often even the spec authors got it wrong.

Ship a clear "unsupported" path: if a filter contains a time-range against a recurring component (presence of RRULE), return an empty multistatus rather than wrong matches. Wrong matches are worse than no matches because clients cache them.

## XML parsing for the filter

This is where you finally drop the regex. Use [Nokogiri](https://nokogiri.org/) with explicit namespace registration. The XML can use any prefix — `c:`, `C:`, `cal:`, anything bound to `urn:ietf:params:xml:ns:caldav`. Your current `extract_value(body, 'comp-filter')` happens to work because regex doesn't care about prefixes, but it also matches `<x:comp-filter>` from an unrelated namespace, which is a bug nobody's hit yet.

```ruby
module Protocol::Caldav::Filter::Calendar::Parser
  CALDAV_NS = 'urn:ietf:params:xml:ns:caldav'
  
  def self.parse(xml_string)
    doc = Nokogiri::XML(xml_string)
    filter_node = doc.at_xpath('//c:filter', c: CALDAV_NS)
    return nil unless filter_node
    
    comp_node = filter_node.at_xpath('./c:comp-filter', c: CALDAV_NS)
    parse_comp_filter(comp_node)
  end
  
  def self.parse_comp_filter(node)
    CompFilter.new(
      node['name'],
      !node.at_xpath('./c:is-not-defined', c: CALDAV_NS).nil?,
      parse_time_range(node.at_xpath('./c:time-range', c: CALDAV_NS)),
      node.xpath('./c:prop-filter', c: CALDAV_NS).map { |n| parse_prop_filter(n) },
      node.xpath('./c:comp-filter', c: CALDAV_NS).map { |n| parse_comp_filter(n) }
    )
  end
  # ... etc
end
```

The xpath approach catches mis-namespaced elements as parser bugs (they don't match) rather than as silent matches. The current regex-based `extract_attr` will happily return values from any element with the right local name; this won't.

## Hooking it into Report

The Report middleware (or its replacement handler in the new structure) becomes:

```ruby
def call_report(env, path)
  body = read_body(env)
  filter = Protocol::Caldav::Filter::Calendar::Parser.parse(body)
  
  items = DavItem.list(path)
  
  if filter
    items = items.select do |item|
      vcalendar = Protocol::Caldav::Ical::Parser.parse(item.body)
      Protocol::Caldav::Filter::Calendar::Match.matches?(filter, vcalendar)
    end
  end
  
  responses = items.map { |i| i.to_report_xml(data_tag: 'c:calendar-data') }
  [207, REPORT_HEADERS, [Multistatus.new(responses).to_xml]]
end
```

Three properties this gives you that the current code doesn't:

1. **A filter that asks for VEVENT with `is-not-defined` on `STATUS`** correctly matches events with no STATUS property and excludes events with `STATUS:CONFIRMED`. Current code: matches everything because `STATUS` is in the body of confirmed events and the substring check passes.

2. **A `text-match` on `SUMMARY=Meeting`** matches events whose SUMMARY contains "Meeting", not events whose DESCRIPTION mentions "team meeting" or whose ATTENDEE has name "Meeting Hall." Current code can't tell these apart.

3. **A folded SUMMARY** spanning two lines (`SUMMARY:Annual planning\r\n meeting for Q1`) matches `text-match` "planning meeting" because the parser unfolds before comparison. Current code: never matches across the fold.

## What to build first, in order

1. `Protocol::Caldav::Ical::Parser` — line unfolding, BEGIN/END nesting, property parsing with parameters. ~100 lines. Test against fixtures from real clients (Thunderbird, Apple, DAVx5 each produce subtly different output; collect samples).

2. `Protocol::Caldav::Filter::Calendar` AST + parser — without time-range. ~150 lines.

3. `Protocol::Caldav::Filter::Calendar::Match` — comp-filter and prop-filter and text-match, no time-range. ~80 lines.

4. Wire it into `Calendar::Report`. The integration tests in `App` should still pass — they only test simple cases. The unit tests in `Calendar::Report` may need their assertions sharpened (the current "Important" matches because `body.include?("Important")`; it'll still match because SUMMARY contains "Important", but the test will be checking for the right reason now).

5. Add the time-range subset for non-recurring VEVENTs.

6. Repeat 1-4 for vCard / CardDAV. CardDAV is a strict subset of CalDAV's filter model (no comp-filter, no time-range), so it's about a third of the work.

The reason this is the hardest part to do right: the current code looks like it works because the tests are simple enough that string matching coincides with property matching. Real clients send filters where they diverge. You'll know you got it right when DAVx5 stops showing duplicate events and Thunderbird stops asking for the same calendar twice.
