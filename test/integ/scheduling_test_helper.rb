# frozen_string_literal: true

# Minimal helper for CalDAV scheduling integration tests.
# Adds POST-to-outbox (Originator/Recipient headers) to the base IntegrationTest.

require_relative 'integ_test_helper'

module Caldav
  class SchedulingIntegrationTest < IntegrationTest
    private

    # POST an iCalendar body to a scheduling outbox.
    def caldav_post_outbox(path, body, originator:, recipients:, username: nil, password: nil)
      with_auth(username || 'admin', password || 'admin')

      recipients_str = Array(recipients).join(', ')

      request(path, method: 'POST', input: body,
                    'CONTENT_TYPE' => 'text/calendar',
                    'HTTP_ORIGINATOR' => originator,
                    'HTTP_RECIPIENT' => recipients_str)
      last_response
    end
  end
end
