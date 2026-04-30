# frozen_string_literal: true

# Integration tests for Timezone Service operations.
#
# Auto-generated from DAViCal's testing/tests/timezone/ regression suite.
# Each .test/.result pair in test/integ/fixtures/timezone/ becomes a test
# method automatically -- add new pairs and they'll run with zero changes.

require_relative 'integ_test_helper'

class TestTimezone < Caldav::IntegrationTest
  FIXTURE_DIR = File.expand_path('fixtures/timezone', __dir__)

  # ---------------------------------------------------------------------------
  # .test file DSL parser
  # ---------------------------------------------------------------------------

  # Parses a DAViCal .test file and returns a hash with:
  #   :method       - HTTP method (default "GET")
  #   :head         - true if response headers should be included
  #   :replacements - array of [Regexp, String] pairs
  #   :url          - the raw URL string (nil for SCRIPT-only tests)
  #   :path         - path portion extracted from URL
  ParsedTest = Struct.new(:method, :head, :replacements, :url, :path, keyword_init: true)

  def self.parse_test_file(path)
    method       = 'GET'
    head         = false
    replacements = []
    url          = nil

    File.readlines(path, chomp: true).each do |line|
      next if line =~ /^\s*(#|$)/

      case line
      when /^\s*TYPE\s*=\s*(\S+)/
        method = Regexp.last_match(1)
      when /^\s*HEAD\s*/
        head = true
      when /^REPLACE\s*=\s*(\S)(.*)/
        sep = Regexp.escape(Regexp.last_match(1))
        if Regexp.last_match(2) =~ /^([^#{sep}]*)#{sep}([^#{sep}]*)#{sep}$/
          replacements << [Regexp.new(Regexp.last_match(1)), Regexp.last_match(2)]
        end
      when /^\s*URL\s*=\s*(\S+)/
        url = Regexp.last_match(1)
      end
    end

    # Extract path + query from the URL, stripping the host.
    uri_path = nil
    if url
      uri = URI.parse(url.gsub('regression.host', 'localhost'))
      uri_path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
    end

    ParsedTest.new(method: method, head: head, replacements: replacements,
                   url: url, path: uri_path)
  end

  # ---------------------------------------------------------------------------
  # Response normalisation (port of DAViCal's normalise_result)
  # ---------------------------------------------------------------------------

  HTTP_DATE_RE = /(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-3]\d (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) 2\d{3} [0-2]\d(?::[0-5]\d){2} GMT/

  STRIP_HEADERS = %w[
    Server
    X-Powered-By
    X-Pad
    Keep-Alive
    Connection
    Transfer-Encoding
    Vary
    Request-ID
  ].freeze

  DAVICAL_VERSION_RE = %r{^X-(?:DAViCal|RSCDS)-Version: (?:DAViCal|RSCDS)/[\d.]+; DB/[\d.]+}

  def self.normalise(text)
    no_content = false
    lines = text.lines.flat_map do |line|
      # Strip well-known noisy headers
      next [] if STRIP_HEADERS.any? { |h| line.start_with?("#{h}: ") }
      next [] if line =~ DAVICAL_VERSION_RE
      next [] if line.start_with?('HTTP/1.1 100 Continue')

      # Normalise HTTP dates
      line = line.gsub(HTTP_DATE_RE, 'Dow, 01 Jan 2000 00:00:00 GMT')

      # Normalise opaquelocktoken UUIDs
      line = line.gsub(/opaquelocktoken:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/,
                       'opaquelocktoken:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')

      # Track 204 No Content to suppress empty Content-Length / Content-Type
      no_content = true if line =~ %r{^HTTP/1\.1 204 No Content}
      if no_content
        next [] if line =~ /^Content-Length: 0/
        next [] if line =~ /^Content-Type: /
      end

      [line]
    end
    lines.join
  end

  # ---------------------------------------------------------------------------
  # Build the "actual" output string from a Rack::Test response
  # ---------------------------------------------------------------------------

  # Rack status codes -> HTTP reason phrases for the codes we care about.
  REASON = Hash.new { |_h, k| "Status #{k}" }.merge(
    200 => 'OK',
    201 => 'Created',
    204 => 'No Content',
    207 => 'Multi-Status',
    301 => 'Moved Permanently',
    302 => 'Found',
    304 => 'Not Modified',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    409 => 'Conflict',
    412 => 'Precondition Failed',
    415 => 'Unsupported Media Type',
    500 => 'Internal Server Error'
  ).freeze

  def build_actual(response, parsed)
    body = response.body

    if parsed.head
      status_line = "HTTP/1.1 #{response.status} #{REASON[response.status]}\n"
      headers = response.headers.map { |k, v| "#{k}: #{v}\n" }.join
      raw = "#{status_line}#{headers}\n#{body}\n"
    else
      raw = body
    end

    # Normalise (port of normalise_result)
    actual = self.class.normalise(raw)

    # Apply per-test REPLACE patterns
    parsed.replacements.each do |pattern, replacement|
      actual = actual.gsub(pattern, replacement)
    end

    actual
  end

  # ---------------------------------------------------------------------------
  # Dynamic test generation: one method per .test file
  # ---------------------------------------------------------------------------

  Dir.glob(File.join(FIXTURE_DIR, '*.test')).sort.each do |test_file|
    basename = File.basename(test_file, '.test')
    result_file = test_file.sub(/\.test$/, '.result')

    # Skip if no corresponding .result file
    next unless File.exist?(result_file)

    # Skip SCRIPT-only tests (no URL directive)
    parsed = parse_test_file(test_file)
    next unless parsed.url

    method_name = "test_#{basename.gsub('-', '_')}"

    define_method(method_name) do
      # Re-parse at runtime so instance has fresh data
      parsed = self.class.parse_test_file(test_file)
      expected = File.read(result_file)

      # Make the request
      response = caldav_get(parsed.path)

      actual = build_actual(response, parsed)

      assert_equal expected, actual,
                   "Mismatch for #{basename} (#{test_file})"
    end
  end
end
