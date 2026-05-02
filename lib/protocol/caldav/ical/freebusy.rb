# frozen_string_literal: true

require "bundler/setup"
require "scampi"

require "protocol/caldav"

module Protocol
  module Caldav
    module Ical
      module FreeBusy
        module_function

        # Generate a VCALENDAR containing VFREEBUSY from a list of calendar items.
        #
        # @param items [Array] items with .body method returning iCal strings
        # @param range_start [Time] query range start
        # @param range_end [Time] query range end
        # @return [String] serialized VCALENDAR with VFREEBUSY
        def generate(items, range_start:, range_end:)
          busy_periods = []
          free_periods = []

          items.each do |item|
            component = Parser.parse(item.body)
            next unless component

            component.find_components('VEVENT').each do |vevent|
              next if vevent.find_property('RECURRENCE-ID') # skip overrides in this pass

              status = vevent.find_property('STATUS')&.value&.strip&.upcase
              transp = vevent.find_property('TRANSP')&.value&.strip&.upcase

              is_free = status == 'CANCELLED' || transp == 'TRANSPARENT'

              rrule = vevent.find_property('RRULE')
              if rrule
                collect_recurring_periods(vevent, rrule, range_start, range_end, is_free, busy_periods, free_periods)
              else
                collect_single_period(vevent, range_start, range_end, is_free, busy_periods, free_periods)
              end
            end
          end

          serialize_freebusy(busy_periods, free_periods, range_start, range_end)
        end

        def collect_single_period(vevent, range_start, range_end, is_free, busy_periods, free_periods)
          dtstart = Filter::Match.send(:parse_ical_datetime, vevent, 'DTSTART')
          dtend = Filter::Match.send(:parse_ical_datetime, vevent, 'DTEND')
          return unless dtstart

          dtend ||= dtstart + 3600 # default 1 hour
          return unless dtstart < range_end && dtend > range_start

          period = "#{format_utc(dtstart)}/#{format_utc(dtend)}"
          if is_free
            free_periods << period
          else
            busy_periods << period
          end
        end

        def collect_recurring_periods(vevent, rrule, range_start, range_end, is_free, busy_periods, free_periods)
          dtstart = Filter::Match.send(:parse_ical_datetime, vevent, 'DTSTART')
          return unless dtstart

          dtend = Filter::Match.send(:parse_ical_datetime, vevent, 'DTEND')
          duration = dtend ? (dtend - dtstart).to_i : 3600

          exdates = vevent.find_all_properties('EXDATE').filter_map do |ex|
            Filter::Match.send(:parse_datetime_string, ex.value.strip)
          end

          occurrences = Rrule.expand(
            dtstart: dtstart,
            rrule_value: rrule.value.strip,
            range_start: range_start - duration,
            range_end: range_end,
            exdates: exdates,
            max_count: 10000
          )

          occurrences.each do |occ_start|
            occ_end = occ_start + duration
            next unless occ_start < range_end && occ_end > range_start

            period = "#{format_utc(occ_start)}/#{format_utc(occ_end)}"
            if is_free
              free_periods << period
            else
              busy_periods << period
            end
          end
        end

        def serialize_freebusy(busy_periods, free_periods, range_start, range_end)
          lines = []
          lines << "BEGIN:VCALENDAR"
          lines << "VERSION:2.0"
          lines << "PRODID:-//Protocol::Caldav//NONSGML//EN"
          lines << "BEGIN:VFREEBUSY"
          lines << "DTSTART:#{format_utc(range_start)}"
          lines << "DTEND:#{format_utc(range_end)}"

          busy_periods.each do |period|
            lines << "FREEBUSY;FBTYPE=BUSY:#{period}"
          end

          free_periods.each do |period|
            lines << "FREEBUSY;FBTYPE=FREE:#{period}"
          end

          lines << "END:VFREEBUSY"
          lines << "END:VCALENDAR"
          lines.map { |l| "#{l}\r\n" }.join
        end

        def format_utc(time)
          time.utc.strftime('%Y%m%dT%H%M%SZ')
        end

        private_class_method :collect_single_period, :collect_recurring_periods,
                             :serialize_freebusy, :format_utc
      end
    end
  end
end

test do
  describe "Protocol::Caldav::Ical::FreeBusy" do
    FakeItem = Struct.new(:body)

    it "returns VCALENDAR with VFREEBUSY" do
      ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260115T090000Z\r\nDTEND:20260115T100000Z\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR"
      items = [FakeItem.new(ical)]
      result = Protocol::Caldav::Ical::FreeBusy.generate(
        items,
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 2, 1)
      )
      result.should.include "BEGIN:VCALENDAR"
      result.should.include "BEGIN:VFREEBUSY"
      result.should.include "FREEBUSY;FBTYPE=BUSY:20260115T090000Z/20260115T100000Z"
      result.should.include "END:VFREEBUSY"
      result.should.include "END:VCALENDAR"
    end

    it "empty items list returns empty freebusy" do
      result = Protocol::Caldav::Ical::FreeBusy.generate(
        [],
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 2, 1)
      )
      result.should.include "BEGIN:VCALENDAR"
      result.should.include "BEGIN:VFREEBUSY"
      result.should.include "END:VFREEBUSY"
      result.should.not.include "FREEBUSY;FBTYPE=BUSY"
    end
  end
end
