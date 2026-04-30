# frozen_string_literal: true

# Integration tests for CardDAV operations.
#
# Converted from DAViCal's regression test suite:
#   refs/davical/testing/tests/carddav/
#
# Original .test/.result fixtures preserved in:
#   test/integ/fixtures/carddav/
#
# Each .test file is parsed to construct an HTTP request.
# Each .result file is parsed to get the expected HTTP status and body.
# The runner issues the request, normalizes dynamic values via REPLACE
# patterns from the .test file, and diffs actual vs expected.

require_relative 'integ_test_helper'

class TestCarddav < Caldav::IntegrationTest
  i_suck_and_my_tests_are_order_dependent!

  FIXTURES = File.expand_path('fixtures/carddav', __dir__)

  # Shared state across ordered tests
  @@state = {} # rubocop:disable Style/ClassVars

  # ---------------------------------------------------------------------------
  # Dynamically define a test method for every .test fixture file.
  # ---------------------------------------------------------------------------
  Dir[File.join(FIXTURES, '*.test')].sort.each do |test_file|
    name = File.basename(test_file, '.test')

    define_method("test_#{name.tr('-', '_')}") do
      run_carddav_test(name)
    end
  end

  private

  # ---------------------------------------------------------------------------
  # Generic test runner: parse .test + .result, issue request, compare.
  # ---------------------------------------------------------------------------
  def run_carddav_test(name)
    req = parse_test_file(name)
    expected = parse_result_file(name)
    return if expected.nil?

    # Set auth: use explicit AUTH= if given, otherwise infer from URL path
    if req[:auth]
      user, pass = req[:auth].split(':', 2)
      with_auth(user, pass)
    elsif req[:path] =~ %r{/caldav\.php/([^/]+)/}
      user = Regexp.last_match(1)
      with_auth(user, user)
    end

    # Issue the request
    opts = {}
    req[:headers].each { |k, v| opts[k] = v }
    opts['CONTENT_TYPE'] = req[:content_type] if req[:content_type]

    # Percent-encode non-ASCII characters in path for URI safety
    safe_path = req[:path].gsub(/[^\x00-\x7F]/) { |c| c.bytes.map { |b| '%%%02X' % b }.join }
    request(safe_path, method: req[:method], input: req[:body], **opts)
    resp = last_response

    # Assert status code
    assert_equal expected[:status], resp.status,
                 "[#{name}] Expected HTTP #{expected[:status]}, got #{resp.status}"

    # Normalize actual response body with REPLACE patterns from the .test file
    actual_body = resp.body.to_s
    # Strip encoding comments that Ruby adds to binary strings
    actual_body = actual_body.gsub(/^# encoding: .*$\n?/, '')
    actual_body = actual_body.gsub(/^#    valid: .*$\n?/, '')
    req[:replaces].each do |pattern, replacement|
      actual_body = actual_body.gsub(pattern, replacement)
    end

    # Compare body if expected body is non-empty
    expected_body = expected[:body]
    return if expected_body.strip.empty?

    assert_equal expected_body.strip, actual_body.strip,
                 "[#{name}] Response body mismatch"
  end

  # ---------------------------------------------------------------------------
  # Parse a .test file into a request hash.
  # ---------------------------------------------------------------------------
  def parse_test_file(name)
    lines = File.readlines(File.join(FIXTURES, "#{name}.test"), chomp: true)

    result = {
      method: 'GET',
      auth: nil,
      headers: {},
      content_type: nil,
      path: '/',
      body: '',
      replaces: []
    }

    in_data = false
    in_sql = false
    in_query = false
    body_lines = []

    lines.each do |line|
      # Skip comments (but not inside BEGINDATA)
      next if !in_data && !in_sql && !in_query && line.start_with?('#')

      # GETSQL / ENDSQL blocks -- skip entirely
      if line.start_with?('GETSQL=')
        in_sql = true
        next
      end
      if line == 'ENDSQL'
        in_sql = false
        next
      end
      next if in_sql

      # QUERY / ENDQUERY blocks -- skip entirely
      if line == 'QUERY'
        in_query = true
        next
      end
      if line == 'ENDQUERY'
        in_query = false
        next
      end
      next if in_query

      # BEGINDATA / ENDDATA
      if line == 'BEGINDATA'
        in_data = true
        next
      end
      if line == 'ENDDATA'
        in_data = false
        next
      end
      if in_data
        body_lines << line
        next
      end

      # Directives
      case line
      when /^TYPE=(.+)/
        result[:method] = Regexp.last_match(1).strip
      when /^AUTH=(.+)/
        result[:auth] = Regexp.last_match(1).strip
      when /^NOAUTH/
        result[:auth] = nil
      when %r{^URL=http://[^/]+(.+)}
        result[:path] = Regexp.last_match(1).strip
      when /^HEADER=Content-Type:\s*(.+)/i
        result[:content_type] = Regexp.last_match(1).strip
      when /^HEADER=Content-type:\s*(.+)/
        result[:content_type] = Regexp.last_match(1).strip
      when /^HEADER=Depth:\s*(.+)/i
        result[:headers]['HTTP_DEPTH'] = Regexp.last_match(1).strip
      when /^HEADER=If-None-Match:\s*(.+)/i
        result[:headers]['HTTP_IF_NONE_MATCH'] = Regexp.last_match(1).strip
      when /^HEADER=If-Match:\s*(.+)/i
        result[:headers]['HTTP_IF_MATCH'] = Regexp.last_match(1).strip
      when /^HEADER=Accept:\s*(.+)/i
        result[:headers]['HTTP_ACCEPT'] = Regexp.last_match(1).strip
      when /^HEADER=Ticket:\s*(.+)/i
        ticket_val = Regexp.last_match(1).strip
        ticket_val = @@state[:ticket] if ticket_val == '##ticket##' && @@state[:ticket]
        result[:headers]['HTTP_TICKET'] = ticket_val
      when /^HEADER=X-DAViCal-Flush-Cache:\s*(.+)/i
        result[:headers]['HTTP_X_DAVICAL_FLUSH_CACHE'] = Regexp.last_match(1).strip
      when /^HEADER=User-[Aa]gent:\s*(.+)/
        result[:headers]['HTTP_USER_AGENT'] = Regexp.last_match(1).strip
      when /^REPLACE=(.)(.*)\1(.*)\1$/
        pattern = Regexp.new(Regexp.last_match(2))
        replacement = Regexp.last_match(3)
        result[:replaces] << [pattern, replacement]
      when 'HEAD', /^DOSQL/, /^STATIC=/, /^HEADER=/, ''
        next
      end
    end

    result[:body] = body_lines.join("\r\n")
    result[:body] += "\r\n" unless body_lines.empty?
    result
  end

  # ---------------------------------------------------------------------------
  # Parse a .result file into expected status + body.
  # ---------------------------------------------------------------------------
  def parse_result_file(name)
    path = File.join(FIXTURES, "#{name}.result")
    return nil unless File.exist?(path)

    content = File.read(path)
    return nil if content.strip.empty?

    status = nil
    body = ''

    # Strip leading SQL execution results (DOSQL output before HTTP status line)
    content = content.sub(%r{\A.*?(?=^HTTP/)}m, '') if content =~ %r{^HTTP/}m && !content.start_with?('HTTP/')

    if content.start_with?('HTTP/')
      first_line, rest = content.split("\n", 2)
      status = first_line[%r{HTTP/\d+\.\d+\s+(\d+)}, 1].to_i

      _headers, body = rest.split("\n\n", 2)
      body ||= ''
    else
      status = 207
      body = content
    end

    # Strip SQL Query result blocks from expected body
    body = body.gsub(/\n?SQL Query \d+ Result:.*\z/m, '')

    { status: status, body: body }
  end
end
