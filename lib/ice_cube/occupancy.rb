module IceCube
  class Occupancy
    Entry = Struct.new(:schedule, :weight)

    Event = Struct.new(:entry, :occurrence, :start_time, :end_time)

    attr_reader :window, :entries, :threshold, :occurrence_limit, :occurrence_count

    def self.query(
      weighted_schedules,
      window:,
      threshold:,
      occurrence_limit: nil,
      max_occurrences: nil,
      limit: nil
    )
      new(
        window,
        weighted_schedules,
        threshold: threshold,
        occurrence_limit: occurrence_limit,
        max_occurrences: max_occurrences,
        limit: limit
      ).call
    end

    def self.between(
      start_time,
      end_time,
      weighted_schedules,
      threshold:,
      occurrence_limit: nil,
      max_occurrences: nil,
      limit: nil
    )
      query(
        weighted_schedules,
        window: start_time...end_time,
        threshold: threshold,
        occurrence_limit: occurrence_limit || max_occurrences || limit
      )
    end

    def initialize(
      window,
      weighted_schedules,
      threshold:,
      occurrence_limit: nil,
      max_occurrences: nil,
      limit: nil
    )
      @window = prepare_window(window)
      @entries = prepare_entries(weighted_schedules)
      @threshold = prepare_threshold(threshold)
      @occurrence_limit = prepare_occurrence_limit(
        occurrence_limit || max_occurrences || limit
      )
      @occurrence_count = 0
    end

    def call
      events = overlapping_events
      slices = build_slices(events)
      segments = build_segments(slices)
      Result.new(window, slices, segments, occurrence_count)
    end

    private

    def prepare_window(window)
      unless window.is_a?(Range) && window.exclude_end?
        raise ArgumentError, "window must be a half-open Range using `...`"
      end

      start_time = TimeUtil.ensure_time(window.begin)
      end_time = TimeUtil.ensure_time(window.end)
      start_time = TimeUtil.match_zone(start_time, start_time)
      end_time = TimeUtil.match_zone(end_time, start_time)

      unless start_time < end_time
        raise ArgumentError, "window start_time must be before end_time"
      end

      start_time...end_time
    end

    def prepare_entries(weighted_schedules)
      normalized_entries =
        if weighted_schedules.is_a?(Hash) &&
            weighted_schedules.keys.all? { |key| key.is_a?(Schedule) }
          weighted_schedules.to_a
        else
          Array(weighted_schedules)
        end

      normalized_entries.map do |entry|
        schedule, weight =
          case entry
          when Array
            entry
          when Hash
            [entry[:schedule] || entry["schedule"], entry[:weight] || entry["weight"]]
          when ->(candidate) { candidate.respond_to?(:schedule) && candidate.respond_to?(:weight) }
            [entry.schedule, entry.weight]
          else
            [entry, nil]
          end

        unless schedule.is_a?(Schedule)
          raise ArgumentError, "expected an IceCube::Schedule, got #{schedule.inspect}"
        end

        weight = 1 if weight.nil?
        unless weight.is_a?(Numeric) && weight > 0
          raise ArgumentError, "weight must be positive, got #{weight.inspect}"
        end

        Entry.new(schedule, weight)
      end
    end

    def prepare_threshold(threshold)
      unless threshold.is_a?(Numeric) && threshold > 0
        raise ArgumentError, "threshold must be positive, got #{threshold.inspect}"
      end
      threshold
    end

    def prepare_occurrence_limit(occurrence_limit)
      return if occurrence_limit.nil?
      unless occurrence_limit.is_a?(Integer) && occurrence_limit.positive?
        raise ArgumentError, "occurrence_limit must be a positive Integer"
      end
      occurrence_limit
    end

    def overlapping_events
      entries.flat_map { |entry| events_for_entry(entry) }
        .sort_by { |event| [event.start_time, event.end_time] }
    end

    def events_for_entry(entry)
      schedule = entry.schedule
      opening_time = TimeUtil.match_zone(window.begin, schedule.start_time)
      closing_time = TimeUtil.match_zone(window.end, schedule.start_time)
      events = []

      schedule.remaining_occurrences_enumerator(opening_time, spans: true).each do |occurrence|
        break if occurrence.start_time >= closing_time
        next if occurrence.end_time <= opening_time

        start_time = [TimeUtil.match_zone(occurrence.start_time, window.begin), window.begin].max
        end_time = [TimeUtil.match_zone(occurrence.end_time, window.begin), window.end].min
        next unless start_time < end_time

        @occurrence_count += 1
        if occurrence_limit && occurrence_count > occurrence_limit
          raise OccurrenceLimitExceeded.new(occurrence_count)
        end

        events << Event.new(entry, occurrence, start_time, end_time)
      end

      events
    end

    def build_slices(events)
      return [] if events.empty?

      transitions = Hash.new { |hash, time| hash[time] = {starting: [], ending: []} }
      events.each do |event|
        transitions[event.start_time][:starting] << event
        transitions[event.end_time][:ending] << event
      end

      slices = []
      active = transitions[window.begin][:starting].dup
      cursor = window.begin

      transitions.keys.sort.each do |time|
        next if time == window.begin

        if active.any? && time > cursor
          slice = build_slice(cursor, time, active)
          slices << slice if slice
        end

        active.delete_if { |event| transitions[time][:ending].include?(event) }
        active.concat(transitions[time][:starting])
        cursor = time
      end

      slices
    end

    def build_slice(start_time, end_time, active_events)
      contributors = active_events.group_by(&:entry).map do |entry, events|
        occurrences = events.map(&:occurrence).sort_by { |occurrence|
          [occurrence.start_time, occurrence.end_time]
        }
        Contributor.new(entry.schedule, entry.weight, occurrences)
      end.sort_by { |contributor|
        occurrence = contributor.occurrences.first
        [
          occurrence.start_time.to_i,
          occurrence.start_time.subsec,
          occurrence.end_time.to_i,
          occurrence.end_time.subsec
        ]
      }

      weight = contributors.sum { |contributor| contributor.weight * contributor.occurrences.size }
      return unless weight >= threshold

      Slice.new(start_time, end_time, weight, contributors)
    end

    def build_segments(slices)
      segments = []

      slices.each do |slice|
        current = segments.last
        if current && current.end_time == slice.start_time
          current.append(slice)
        else
          segments << Segment.new(slice)
        end
      end

      segments
    end

    class Contributor
      attr_reader :schedule, :weight, :occurrences

      def initialize(schedule, weight, occurrences)
        @schedule = schedule
        @weight = weight
        @occurrences = occurrences
      end

      def total_weight
        weight * occurrences.size
      end

      def ==(other)
        other.is_a?(self.class) &&
          schedule == other.schedule &&
          weight == other.weight &&
          occurrences == other.occurrences
      end
      alias_method :eql?, :==

      def hash
        [schedule, weight, occurrences].hash
      end
    end

    class Slice
      attr_reader :start_time, :end_time, :weight, :contributors

      def initialize(start_time, end_time, weight, contributors)
        @start_time = start_time
        @end_time = end_time
        @weight = weight
        @contributors = contributors
      end

      def duration
        end_time - start_time
      end

      def participants
        contributors.map(&:schedule)
      end
    end

    class Segment
      attr_reader :start_time, :end_time, :slices

      def initialize(slice)
        @start_time = slice.start_time
        @end_time = slice.end_time
        @slices = [slice]
      end

      def append(slice)
        @slices << slice
        @end_time = slice.end_time
        self
      end

      def duration
        end_time - start_time
      end

      def minimum_weight
        slices.map(&:weight).min
      end

      def maximum_weight
        slices.map(&:weight).max
      end

      def contributors
        slices.flat_map(&:contributors)
          .group_by { |contributor| [contributor.schedule, contributor.weight] }
          .map do |(schedule, weight), contributors|
            occurrences = contributors.flat_map(&:occurrences)
              .each_with_object({}) do |occurrence, unique|
                key = [
                  occurrence.start_time.to_i,
                  occurrence.start_time.subsec,
                  occurrence.end_time.to_i,
                  occurrence.end_time.subsec
                ]
                unique[key] ||= occurrence
              end.values.sort_by { |occurrence|
                [
                  occurrence.start_time.to_i,
                  occurrence.start_time.subsec,
                  occurrence.end_time.to_i,
                  occurrence.end_time.subsec
                ]
              }
            Contributor.new(schedule, weight, occurrences)
          end.sort_by { |contributor|
            occurrence = contributor.occurrences.first
            [
              occurrence.start_time.to_i,
              occurrence.start_time.subsec,
              occurrence.end_time.to_i,
              occurrence.end_time.subsec
            ]
          }
      end

      def schedules
        contributors.map(&:schedule)
      end
      alias_method :participants, :schedules
    end

    class Result
      include Enumerable

      attr_reader :window, :slices, :segments, :occurrence_count

      def initialize(window, slices, segments, occurrence_count)
        @window = window
        @slices = slices
        @segments = segments
        @occurrence_count = occurrence_count
      end

      def each(&block)
        longest_segments.each(&block)
      end

      def longest_interval
        longest_segments.first
      end

      def longest_segments
        longest_duration = segments.map(&:duration).max
        segments.select { |segment| segment.duration == longest_duration }
      end
      alias_method :longest_intervals, :longest_segments
      alias_method :to_a, :longest_segments

      def empty?
        segments.empty?
      end
    end
  end

  OccupancyQuery = Occupancy
end
