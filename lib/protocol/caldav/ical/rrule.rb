# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "date"

module Protocol
  module Caldav
    module Ical
      module Rrule
        DAYS = { 'MO' => 1, 'TU' => 2, 'WE' => 3, 'TH' => 4, 'FR' => 5, 'SA' => 6, 'SU' => 0 }.freeze

        module_function

        # Expand an RRULE into concrete occurrence start times within a range.
        #
        # @param dtstart [Time] base event start
        # @param rrule_value [String] RRULE property value (e.g. "FREQ=DAILY;COUNT=5")
        # @param range_start [Time] query window start
        # @param range_end [Time] query window end
        # @param exdates [Array<Time>] excluded dates
        # @param max_count [Integer] safety limit to prevent infinite expansion
        # @return [Array<Time>] occurrence start times within range
        def expand(dtstart:, rrule_value:, range_start:, range_end:, exdates: [], max_count: 10000)
          parts = parse_rrule(rrule_value)
          freq = parts['FREQ']
          return [dtstart] unless freq

          interval = (parts['INTERVAL'] || '1').to_i
          count = parts['COUNT']&.to_i
          until_time = parts['UNTIL'] ? parse_dt(parts['UNTIL']) : nil
          byday = parts['BYDAY']&.split(',')
          bymonthday = parts['BYMONTHDAY']&.split(',')&.map(&:to_i)
          bymonth = parts['BYMONTH']&.split(',')&.map(&:to_i)

          occurrences = []
          current = dtstart
          generated = 0

          loop do
            # Stop conditions
            break if until_time && current > until_time
            break if current > range_end
            break if count && generated >= count
            break if occurrences.length >= max_count

            candidates = expand_freq(freq, current, interval, byday, bymonthday, bymonth, dtstart)

            candidates.each do |candidate|
              break if until_time && candidate > until_time
              break if count && generated >= count
              break if occurrences.length >= max_count

              generated += 1

              next if candidate < range_start && candidate < dtstart
              next if candidate >= range_end
              next if exdates.any? { |ex| times_equal?(candidate, ex) }

              occurrences << candidate if candidate >= range_start
            end

            current = advance(freq, current, interval)
          end

          occurrences.sort
        end

        def parse_rrule(value)
          parts = {}
          value.split(';').each do |part|
            key, val = part.split('=', 2)
            parts[key.upcase] = val
          end
          parts
        end

        def parse_dt(str)
          str = str.strip
          if str.length == 8
            Time.utc(str[0..3].to_i, str[4..5].to_i, str[6..7].to_i)
          else
            s = str.chomp('Z')
            Time.utc(s[0..3].to_i, s[4..5].to_i, s[6..7].to_i, s[9..10].to_i, s[11..12].to_i, s[13..14].to_i)
          end
        rescue ArgumentError
          nil
        end

        def times_equal?(a, b)
          # Compare ignoring sub-second precision; also handle DATE vs DATETIME
          a.year == b.year && a.month == b.month && a.day == b.day &&
            a.hour == b.hour && a.min == b.min
        end

        def expand_freq(freq, current, interval, byday, bymonthday, bymonth, dtstart)
          case freq
          when 'DAILY'
            [current]
          when 'WEEKLY'
            if byday
              week_start = current - (current.wday * 86400)
              byday.map do |day_str|
                wday = DAYS[day_str.gsub(/[^A-Z]/, '')]
                next nil unless wday
                candidate = week_start + (wday * 86400)
                # Preserve time of day from dtstart
                Time.utc(candidate.year, candidate.month, candidate.day, dtstart.hour, dtstart.min, dtstart.sec)
              end.compact.select { |c| c >= current }.sort
            else
              [current]
            end
          when 'MONTHLY'
            if bymonthday
              bymonthday.filter_map do |day|
                days_in_month = Date.new(current.year, current.month, -1).day
                actual_day = day > 0 ? day : days_in_month + day + 1
                next nil if actual_day < 1 || actual_day > days_in_month
                Time.utc(current.year, current.month, actual_day, dtstart.hour, dtstart.min, dtstart.sec)
              end.sort
            elsif byday
              expand_byday_monthly(current, byday, dtstart)
            else
              [current]
            end
          when 'YEARLY'
            if bymonth
              bymonth.map do |month|
                Time.utc(current.year, month, dtstart.day, dtstart.hour, dtstart.min, dtstart.sec)
              end.sort
            else
              [current]
            end
          else
            [current]
          end
        end

        def expand_byday_monthly(current, byday, dtstart)
          results = []
          byday.each do |day_str|
            match = day_str.match(/^(-?\d+)?([A-Z]{2})$/)
            next unless match
            ordinal = match[1]&.to_i
            wday = DAYS[match[2]]
            next unless wday

            if ordinal
              candidate = nth_weekday(current.year, current.month, wday, ordinal)
              results << Time.utc(candidate.year, candidate.month, candidate.day, dtstart.hour, dtstart.min, dtstart.sec) if candidate
            else
              # All matching weekdays in the month
              (1..5).each do |n|
                candidate = nth_weekday(current.year, current.month, wday, n)
                break unless candidate
                results << Time.utc(candidate.year, candidate.month, candidate.day, dtstart.hour, dtstart.min, dtstart.sec)
              end
            end
          end
          results.sort
        end

        def nth_weekday(year, month, wday, n)
          require 'date'
          first = Date.new(year, month, 1)
          last = Date.new(year, month, -1)

          if n > 0
            day = first + ((wday - first.wday + 7) % 7) + (7 * (n - 1))
            day.month == month ? day : nil
          else
            day = last - ((last.wday - wday + 7) % 7) + (7 * (n + 1))
            day.month == month ? day : nil
          end
        end

        def advance(freq, current, interval)
          case freq
          when 'DAILY'
            current + (86400 * interval)
          when 'WEEKLY'
            current + (604800 * interval)
          when 'MONTHLY'
            advance_months(current, interval)
          when 'YEARLY'
            advance_months(current, interval * 12)
          else
            current + 86400
          end
        end

        def advance_months(time, months)
          month = time.month + months
          year = time.year + ((month - 1) / 12)
          month = ((month - 1) % 12) + 1
          max_day = Date.new(year, month, -1).day
          day = [time.day, max_day].min
          Time.utc(year, month, day, time.hour, time.min, time.sec)
        end

        private_class_method :parse_rrule, :parse_dt, :times_equal?, :expand_freq,
                             :expand_byday_monthly, :nth_weekday, :advance, :advance_months
      end
    end
  end
end


test do
  describe "Protocol::Caldav::Ical::Rrule" do
    def expand(**kwargs)
      Protocol::Caldav::Ical::Rrule.expand(**kwargs)
    end

    it "FREQ=DAILY expands daily occurrences" do
      dtstart = Time.utc(2026, 1, 1, 9, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=DAILY",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 1, 4)
      )
      result.length.should.equal 3
      result[0].should.equal Time.utc(2026, 1, 1, 9, 0, 0)
      result[1].should.equal Time.utc(2026, 1, 2, 9, 0, 0)
      result[2].should.equal Time.utc(2026, 1, 3, 9, 0, 0)
    end

    it "COUNT limits the total occurrences" do
      dtstart = Time.utc(2026, 1, 1, 9, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=DAILY;COUNT=2",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 2
    end

    it "UNTIL stops at the given time" do
      dtstart = Time.utc(2026, 1, 1, 9, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=DAILY;UNTIL=20260103T090000Z",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 3
      result.last.should.equal Time.utc(2026, 1, 3, 9, 0, 0)
    end

    it "EXDATE excludes specific dates" do
      dtstart = Time.utc(2026, 1, 1, 9, 0, 0)
      exdates = [Time.utc(2026, 1, 2, 9, 0, 0)]
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=DAILY;COUNT=3",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31),
        exdates: exdates
      )
      result.length.should.equal 2
      result.should.not.include Time.utc(2026, 1, 2, 9, 0, 0)
    end

    it "FREQ=WEEKLY with BYDAY expands on specified days" do
      dtstart = Time.utc(2026, 1, 5, 9, 0, 0) # Monday
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=6",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 6
      result[0].wday.should.equal 1 # Monday
      result[1].wday.should.equal 3 # Wednesday
      result[2].wday.should.equal 5 # Friday
    end

    it "FREQ=WEEKLY without BYDAY defaults to dtstart weekday" do
      dtstart = Time.utc(2026, 1, 7, 9, 0, 0) # Wednesday
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=WEEKLY;COUNT=3",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 3
      result.each { |t| t.wday.should.equal 3 }
    end

    it "FREQ=MONTHLY with BYMONTHDAY" do
      dtstart = Time.utc(2026, 1, 15, 10, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 3
      result[0].day.should.equal 15
      result[1].month.should.equal 2
      result[2].month.should.equal 3
    end

    it "FREQ=MONTHLY with BYDAY (second Monday)" do
      dtstart = Time.utc(2026, 1, 12, 9, 0, 0) # 2nd Monday of Jan 2026
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=MONTHLY;BYDAY=2MO;COUNT=3",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 3
      result.each { |t| t.wday.should.equal 1 } # all Mondays
      result[0].day.should.equal 12 # Jan
      result[1].day.should.equal 9  # Feb 2nd Monday
    end

    it "FREQ=YEARLY with BYMONTH" do
      dtstart = Time.utc(2026, 3, 15, 9, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=YEARLY;BYMONTH=3,6;COUNT=4",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2028, 12, 31)
      )
      result.length.should.equal 4
      result[0].month.should.equal 3
      result[1].month.should.equal 6
      result[2].month.should.equal 3
      result[2].year.should.equal 2027
    end

    it "INTERVAL > 1 spaces occurrences" do
      dtstart = Time.utc(2026, 1, 1, 9, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=DAILY;INTERVAL=3;COUNT=3",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 3
      result[0].day.should.equal 1
      result[1].day.should.equal 4
      result[2].day.should.equal 7
    end

    it "negative BYMONTHDAY (-1 = last day of month)" do
      dtstart = Time.utc(2026, 1, 31, 9, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 3
      result[0].day.should.equal 31 # Jan
      result[1].day.should.equal 28 # Feb
      result[2].day.should.equal 31 # Mar
    end

    it "UNTIL with DATE-only format" do
      dtstart = Time.utc(2026, 1, 1, 9, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=DAILY;UNTIL=20260104",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 3
      result.last.day.should.equal 3
    end

    it "COUNT + INTERVAL combined" do
      dtstart = Time.utc(2026, 1, 1, 9, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "FREQ=WEEKLY;INTERVAL=2;COUNT=3",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.length.should.equal 3
      # Every 2 weeks: Jan 1, Jan 15, Jan 29
      (result[1] - result[0]).should.equal 14 * 86400
    end

    it "returns just dtstart when no valid FREQ" do
      dtstart = Time.utc(2026, 6, 15, 10, 0, 0)
      result = expand(
        dtstart: dtstart,
        rrule_value: "BOGUS=STUFF",
        range_start: Time.utc(2026, 1, 1),
        range_end: Time.utc(2026, 12, 31)
      )
      result.should.equal [dtstart]
    end
  end
end
