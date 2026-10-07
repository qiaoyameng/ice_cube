require "tzinfo"

module IceCube
  # Converts times into another time zone for Schedule#rezone, either
  # preserving the exact instant or the local wall-clock reading.
  module Rezone
    MODES = [:instant, :wall].freeze
    CONFLICT_POLICIES = [:reject, :earlier, :later].freeze

    module_function

    # Convert +time+ into +zone+ according to +mode+:
    #
    # :instant - keep the same real moment in time
    # :wall    - keep the same local year/month/day/hour/min/sec reading
    #
    # In :wall mode the local reading may not exist (a DST gap) or may
    # occur twice (a DST overlap) in the target zone. +on_invalid+ and
    # +on_ambiguous+ select how such conflicts are resolved:
    #
    # :reject  - raise InvalidLocalTime / AmbiguousLocalTime
    # :earlier - use the nearest earlier valid interpretation
    # :later   - use the nearest later valid interpretation
    #
    # The result keeps the class of +time+: ActiveSupport::TimeWithZone
    # inputs produce a TimeWithZone in the target zone, while plain Time
    # inputs produce a plain Time with the target zone's UTC offset.
    def convert_time(time, zone, mode:, on_invalid: :reject, on_ambiguous: :reject)
      validate_options!(mode, on_invalid, on_ambiguous)
      tzinfo = tzinfo_zone(zone)
      case mode
      when :instant
        wrap_in_zone(utc_time(time), tzinfo, zone, time)
      when :wall
        convert_wall_time(time, tzinfo, zone, on_invalid, on_ambiguous)
      end
    end

    def convert_wall_time(time, tzinfo, zone, on_invalid, on_ambiguous)
      subsec = TimeUtil.subsec(time)
      instant = begin
        local = tzinfo.local_time(
          time.year, time.month, time.day,
          time.hour, time.min, time.sec, subsec
        ) do |periods|
          resolve_ambiguous(time, periods, on_ambiguous)
        end
        utc_time(local)
      rescue TZInfo::PeriodNotFound
        resolve_invalid(time, tzinfo, subsec, on_invalid)
      end
      wrap_in_zone(instant, tzinfo, zone, time)
    end

    # A repeated local reading maps to two possible instants; pick the
    # earlier or later one, or reject.
    def resolve_ambiguous(time, periods, policy)
      case policy
      when :earlier
        periods.max_by { |period| period.utc_total_offset }
      when :later
        periods.min_by { |period| period.utc_total_offset }
      else
        raise AmbiguousLocalTime,
          "#{wall_reading(time)} occurs twice in the target zone; " \
          "pass on_ambiguous: :earlier or :later to choose one"
      end
    end

    # A skipped local reading maps to the boundary of the gap: the last
    # valid instant before it (:earlier) or the first valid instant
    # after it (:later), or reject.
    def resolve_invalid(time, tzinfo, subsec, policy)
      unless [:earlier, :later].include?(policy)
        raise InvalidLocalTime,
          "#{wall_reading(time)} does not exist in the target zone; " \
          "pass on_invalid: :earlier or :later to choose a nearby valid time"
      end
      transition = gap_transition(time, tzinfo)
      base = transition.timestamp_value
      base -= 1 if policy == :earlier
      Time.at(base, in: "UTC") + subsec
    end

    # Find the transition whose skipped local range contains the wall
    # reading of +time+.
    def gap_transition(time, tzinfo)
      local_value = TZInfo::Timestamp.create(
        time.year, time.month, time.day, time.hour, time.min, time.sec
      ).value
      from = TZInfo::Timestamp.utc(local_value - 2 * ONE_DAY)
      to = TZInfo::Timestamp.utc(local_value + 2 * ONE_DAY)
      tzinfo.transitions_up_to(to, from).find do |transition|
        gap_start = transition.local_end_at.value + transition.local_end_at.utc_offset
        gap_end = transition.local_start_at.value + transition.local_start_at.utc_offset
        gap_start <= local_value && local_value < gap_end
      end || raise(InvalidLocalTime, "#{wall_reading(time)} does not exist in the target zone")
    end

    # Re-express a UTC instant in the target zone, keeping the input's
    # time representation.
    def wrap_in_zone(instant, tzinfo, zone, original)
      if original.respond_to?(:time_zone)
        instant.in_time_zone(zone)
      else
        offset = tzinfo.period_for_utc(instant).utc_total_offset
        instant.getlocal(offset)
      end
    end

    def tzinfo_zone(zone)
      return zone if zone.is_a?(TZInfo::Timezone)
      if defined?(ActiveSupport::TimeZone) && zone.is_a?(ActiveSupport::TimeZone)
        return zone.tzinfo
      end
      TZInfo::Timezone.get(zone.to_s)
    end

    def utc_time(time)
      utc = time.getutc
      return utc if utc.instance_of?(Time)
      Time.at(utc.to_i + TimeUtil.subsec(utc), in: "UTC")
    end

    def wall_reading(time)
      format(
        "%04d-%02d-%02d %02d:%02d:%02d",
        time.year, time.month, time.day, time.hour, time.min, time.sec
      )
    end

    def validate_options!(mode, on_invalid, on_ambiguous)
      unless MODES.include?(mode)
        raise ArgumentError,
          "Unknown rezone mode: #{mode.inspect} (expected :instant or :wall)"
      end
      {on_invalid: on_invalid, on_ambiguous: on_ambiguous}.each do |name, policy|
        unless CONFLICT_POLICIES.include?(policy)
          raise ArgumentError,
            "Unknown #{name} policy: #{policy.inspect} (expected :reject, :earlier or :later)"
        end
      end
    end
  end
end
