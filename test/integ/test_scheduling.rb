# frozen_string_literal: true

# Integration tests for CalDAV scheduling, ported from the DAViCal
# regression test suite (refs/davical/testing/tests/scheduling/).
#
# Rather than hand-coding each test, we iterate over the .test/.result
# fixture pairs in test/integ/fixtures/scheduling/. Each .test file
# defines an HTTP request; each .result file defines the expected response.

require_relative 'scheduling_test_helper'

class TestScheduling < Caldav::SchedulingIntegrationTest
  i_suck_and_my_tests_are_order_dependent!

  FIXTURES_DIR = File.expand_path('fixtures/scheduling', __dir__)

  # ---------------------------------------------------------------------------
  # Parse a .test file into a request spec hash:
  #   { method:, url:, auth:, headers:, body:, originator:, recipients: }
  # ---------------------------------------------------------------------------
  def self.parse_test_file(path)
    lines = File.read(path).lines
    spec = { method: 'GET', auth: %w[user1 user1], headers: {}, body: nil,
             originator: nil, recipients: nil, url: nil }

    i = 0
    while i < lines.length
      line = lines[i].chomp
      i += 1

      case line
      when /\ATYPE=(.+)/
        spec[:method] = ::Regexp.last_match(1).strip
      when /\AAUTH=(.+):(.+)/
        spec[:auth] = [::Regexp.last_match(1).strip, ::Regexp.last_match(2).strip]
      when /\AURL=(.+)/
        url = ::Regexp.last_match(1).strip
        # Strip DAViCal's regression host prefix, keep the path
        url = url.sub(%r{https?://[^/]+/caldav\.php}, '')
        url = url.sub(%r{https?://[^/]+}, '')
        # Normalize to /calendars/ prefix if path starts with /user or /manager
        url = "/calendars#{url}" unless url.start_with?('/calendars')
        spec[:url] = url
      when /\AHEADER=Originator:\s*(.+)/
        spec[:originator] = ::Regexp.last_match(1).strip
      when /\AHEADER=Recipient:\s*(.+)/
        spec[:recipients] = ::Regexp.last_match(1).strip.split(/,\s*/)
      when /\AHEADER=Content-Type:\s*(.+)/
        spec[:headers]['CONTENT_TYPE'] = ::Regexp.last_match(1).strip
      when /\AHEADER=If-Match:\s*(.+)/
        spec[:headers]['HTTP_IF_MATCH'] = ::Regexp.last_match(1).strip
      when /\AHEADER=If-None-Match:\s*(.+)/
        spec[:headers]['HTTP_IF_NONE_MATCH'] = ::Regexp.last_match(1).strip
      when /\ABEGINDATA\s*$/
        body_lines = []
        while i < lines.length
          bline = lines[i].chomp
          i += 1
          break if bline =~ /\AENDDATA\s*$/

          body_lines << bline
        end
        spec[:body] = body_lines.join("\r\n") + "\r\n"
      end
    end

    spec
  end

  # ---------------------------------------------------------------------------
  # Parse a .result file into an expected-response hash:
  #   { status:, body: }
  # ---------------------------------------------------------------------------
  def self.parse_result_file(path)
    content = File.read(path)
    result = { status: nil, body: content }

    result[:status] = ::Regexp.last_match(1).to_i if content =~ %r{^HTTP/1\.\d\s+(\d+)}

    result
  end

  # ---------------------------------------------------------------------------
  # Dynamically define one test method per .test/.result pair
  # ---------------------------------------------------------------------------
  Dir.glob(File.join(FIXTURES_DIR, '3*.test')).sort.each do |test_file|
    basename = File.basename(test_file, '.test')
    result_file = test_file.sub(/\.test$/, '.result')
    next unless File.exist?(result_file)

    test_name = "test_#{basename.gsub('-', '_')}"

    spec = parse_test_file(test_file)
    expected = parse_result_file(result_file)

    define_method(test_name) do
      # Set auth
      with_auth(*spec[:auth])

      case spec[:method]
      when 'POST'
        response = caldav_post_outbox(
          spec[:url], spec[:body],
          originator: spec[:originator],
          recipients: spec[:recipients],
          username: spec[:auth][0], password: spec[:auth][1]
        )
      when 'PUT'
        ct = spec[:headers]['CONTENT_TYPE'] || 'text/calendar; charset=utf-8'
        extra = {}
        extra['HTTP_IF_MATCH'] = spec[:headers]['HTTP_IF_MATCH'] if spec[:headers]['HTTP_IF_MATCH']
        extra['HTTP_IF_NONE_MATCH'] = spec[:headers]['HTTP_IF_NONE_MATCH'] if spec[:headers]['HTTP_IF_NONE_MATCH']

        request(spec[:url], method: 'PUT', input: spec[:body],
                            'CONTENT_TYPE' => ct, **extra)
        response = last_response
      when 'DELETE'
        delete spec[:url]
        response = last_response
      else
        request(spec[:url], method: spec[:method], input: spec[:body] || '')
        response = last_response
      end

      # Assert HTTP status if the .result file specifies one
      if expected[:status]
        assert_equal expected[:status], response.status,
                     "#{basename}: expected HTTP #{expected[:status]}, got #{response.status}"
      end

      # For POST schedule requests, check key response body content
      if spec[:method] == 'POST'
        if expected[:body].include?('schedule-response')
          assert_includes response.body, 'schedule-response',
                          "#{basename}: response should contain schedule-response"
        end
        if expected[:body].include?('2.0;Success')
          assert_includes response.body, '2.0;Success',
                          "#{basename}: response should contain 2.0;Success"
        end
        if expected[:body].include?('VFREEBUSY')
          assert_includes response.body, 'VFREEBUSY',
                          "#{basename}: response should contain VFREEBUSY"
        end
        if expected[:body].include?('FREEBUSY:')
          assert_includes response.body, 'FREEBUSY',
                          "#{basename}: response should contain FREEBUSY line"
        end
      end

      # For PUT/DELETE, check state via SQL results in .result file.
      # The .result SQL sections list dav_name paths and expected vcalendar content.
      # We verify key paths exist/don't exist and contain expected properties.
      check_sql_expectations(basename, expected[:body], spec)
    end
  end

  private

  # ---------------------------------------------------------------------------
  # Verify server state based on SQL query results in the .result file.
  #
  # Extracts dav_name values from "dav_name: >/path/<" lines and key
  # iCalendar properties (SCHEDULE-STATUS, PARTSTAT, METHOD) from the
  # vcalendar blocks, then verifies via GET.
  # ---------------------------------------------------------------------------
  def check_sql_expectations(basename, result_body, _spec)
    return unless result_body.include?('SQL Query')

    # Extract all dav_name paths from the result
    expected_paths = result_body.scan(/dav_name:\s*>([^<]+)</).flatten

    # For each expected path, verify it exists and check associated vcalendar content
    expected_paths.each do |dav_path|
      # Normalize DAViCal paths to our /calendars/ prefix
      get_path = dav_path.start_with?('/calendars') ? dav_path : "/calendars#{dav_path}"

      get_resp = caldav_get(get_path)
      assert_equal 200, get_resp.status,
                   "#{basename}: expected resource at #{get_path} to exist"

      # Find the vcalendar block associated with this dav_name in the result
      # and check key properties
      vcal_section = extract_vcal_for_path(result_body, dav_path)
      next unless vcal_section

      if vcal_section.include?('METHOD:REQUEST')
        assert_includes get_resp.body, 'METHOD:REQUEST',
                        "#{basename}: #{get_path} should have METHOD:REQUEST"
      end
      if vcal_section.include?('METHOD:REPLY')
        assert_includes get_resp.body, 'METHOD:REPLY',
                        "#{basename}: #{get_path} should have METHOD:REPLY"
      end
      if vcal_section.include?('METHOD:CANCEL')
        assert_includes get_resp.body, 'METHOD:CANCEL',
                        "#{basename}: #{get_path} should have METHOD:CANCEL"
      end
      if vcal_section.include?('SCHEDULE-STATUS=1.2')
        assert_includes get_resp.body, 'SCHEDULE-STATUS=1.2',
                        "#{basename}: #{get_path} should have SCHEDULE-STATUS=1.2"
      end
      if vcal_section.include?('PARTSTAT=ACCEPTED')
        assert_includes get_resp.body, 'PARTSTAT=ACCEPTED',
                        "#{basename}: #{get_path} should have PARTSTAT=ACCEPTED"
      end
      if vcal_section.include?('PARTSTAT=DECLINED')
        assert_includes get_resp.body, 'PARTSTAT=DECLINED',
                        "#{basename}: #{get_path} should have PARTSTAT=DECLINED"
      end
    end
  end

  # Extract the vcalendar content block following a specific dav_name in the result
  def extract_vcal_for_path(result_body, dav_path)
    escaped = Regexp.escape(dav_path)
    # Match from dav_name line to the closing "<" of the vcalendar block
    return unless result_body =~ /dav_name:\s*>#{escaped}<.*?vcalendar:\s*>(.*?)</m

    ::Regexp.last_match(1)
  end
end
