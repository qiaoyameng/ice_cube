module IceCube
  # Sweep-line occupancy query for several weighted schedules that share a
  # single resource (e.g. a device). Each occurrence of a schedule occupies
  # the half-open interval [start_time, end_time) and contributes the
  # schedule's weight while active. Overlapping occurrences - including
  # self-overlapping occurrences of the same schedule - each count
  # separately, and exception rules apply as usual.
  #
  #     result = IceCube::Occupancy.query(
  #       window_start, window_end,
  #       [[schedule_a, 2], [schedule_b, 1]],
  #       threshold: 2,
  #       max_occurrences: 1_000
  #     )
  #     result.longest          # => Run or nil
  #     result.runs             # => all runs at or above the threshold
  #     result.segments         # => the qualifying segments, flattened
  #
  # The query is answered by a sweep over occurrence boundaries, never by
  # sampling, and occurrences are enumerated lazily within the window.
  # When max_occurrences is given and exceeded, OccupancyLimitExceeded is
  # raised so a truncated computation can never masquerade as complete.
  module Occupancy
    # A maximal run of adjacent qualifying segments: occupancy stays at or
    # above the threshold for the whole run, while the contributing set may
    # change between its segments.
    class Run
      attr_reader :segments

      def initialize(segments)
        @segments = segments
      end

      def start_time
        segments.first.start_time
      end

      def end_time
        segments.last.end_time
      end

      def duration
        end_time - start_time
      end
    end

    # A half-open interval [start_time, end_time) during which the set of
    # active occurrences - and therefore the occupancy - is constant.
    class Segment
      attr_reader :start_time, :end_time, :contributors

      def initialize(start_time, end_time, contributors)
        @start_time = start_time
        @end_time = end_time
        @contributors = contributors
      end

      def duration
        end_time - start_time
      end

      # Total occupancy during the segment. Always equals the sum of the
      # contributors' contributions, so the listed schedules fully explain
      # the weight of the segment.
      def weight
        contributors.sum(&:contribution)
      end
    end

    # Explains how one schedule contributes to a segment: +occurrences+
    # simultaneously active occurrences of +weight+ each.
    class Contributor
      attr_reader :schedule, :weight, :occurrences

      def initialize(schedule, weight, occurrences)
        @schedule = schedule
        @weight = weight
        @occurrences = occurrences
      end

      def contribution
        weight * occurrences
      end
    end

    # The outcome of a query. Always complete: queries that would exceed
    # their occurrence limit raise instead of returning a Result.
    class Result
      attr_reader :segments, :runs

      def initialize(segments)
        @segments = segments
        @runs = []
        segments.each do |segment|
          if @runs.any? && @runs.last.end_time == segment.start_time
            @runs.last.segments << segment
          else
            @runs << Run.new([segment])
          end
        end
      end

      # The longest run at or above the threshold (the earliest one when
      # tied), or nil when no interval qualifies.
      def longest
        runs.max_by(&:duration)
      end
    end

    # Find where combined occupancy reaches +threshold+ within the
    # half-open window [window_start, window_end).
    #
    # +weighted_schedules+ is a Hash of schedule => weight or an array of
    # [schedule, weight] pairs. Weights must be positive numbers.
    def self.query(window_start, window_end, weighted_schedules, threshold:, max_occurrences: nil)
      window_start = TimeUtil.ensure_time(window_start)
      window_end = TimeUtil.ensure_time(window_end)
      unless window_start && window_end && window_end > window_start
        raise ArgumentError, "window_end must be after window_start"
      end
      unless threshold.is_a?(Numeric) && threshold > 0
        raise ArgumentError, "threshold must be a positive number, got #{threshold.inspect}"
      end

      entries = normalize(weighted_schedules)
      events, weights = collect_events(entries, window_start, window_end, max_occurrences)
      Result.new(sweep(events, weights, window_start, window_end, threshold))
    end

    def self.normalize(weighted_schedules)
      weighted_schedules.to_a.map do |pair|
        schedule, weight = pair
        unless schedule.is_a?(IceCube::Schedule)
          raise ArgumentError, "expected an IceCube::Schedule, got #{schedule.inspect}"
        end
        unless weight.is_a?(Numeric) && weight > 0
          raise ArgumentError, "weight must be a positive number, got #{weight.inspect}"
        end
        [schedule, weight]
      end
    end
    private_class_method :normalize

    # Enumerate occurrences lazily (spans: true also catches occurrences
    # that started before the window but still overlap it), clip them to
    # the window, and turn each into a pair of +weight/-weight events.
    def self.collect_events(entries, window_start, window_end, max_occurrences)
      events = []
      weights = {}
      examined = 0
      entries.each do |schedule, weight|
        next if schedule.duration <= 0
        weights[schedule] = weight
        schedule.send(:enumerate_occurrences, window_start, window_end, spans: true).each do |occurrence|
          examined += 1
          if max_occurrences && examined > max_occurrences
            raise OccupancyLimitExceeded,
              "occupancy query exceeded max_occurrences (#{max_occurrences}); result would be incomplete"
          end
          clip_start = (occurrence.start_time > window_start) ? occurrence.start_time : window_start
          clip_end = (occurrence.end_time < window_end) ? occurrence.end_time : window_end
          next unless clip_end > clip_start
          events << [clip_start, weight, schedule]
          events << [clip_end, -weight, schedule]
        end
      end
      # Half-open semantics: at any instant, ends are applied before starts
      # so back-to-back occurrences never overlap.
      events.sort_by! { |time, delta, _| [time, delta] }
      [events, weights]
    end
    private_class_method :collect_events

    def self.sweep(events, weights, window_start, window_end, threshold)
      segments = []
      counts = Hash.new(0)
      occupancy = 0
      open_start = nil
      open_signature = nil
      index = 0
      while index < events.length
        time = events[index][0]
        while index < events.length && events[index][0] == time
          _, delta, schedule = events[index]
          counts[schedule] += (delta > 0) ? 1 : -1
          occupancy += delta
          index += 1
        end
        signature = (occupancy >= threshold) ? active_signature(counts) : nil
        if signature != open_signature
          if open_signature && time > open_start
            segments << build_segment(open_start, time, open_signature, weights)
          end
          open_signature = signature
          open_start = time
        end
      end
      if open_signature && window_end > open_start
        segments << build_segment(open_start, window_end, open_signature, weights)
      end
      segments
    end
    private_class_method :sweep

    def self.active_signature(counts)
      counts.select { |_, count| count > 0 }
    end
    private_class_method :active_signature

    def self.build_segment(start_time, end_time, signature, weights)
      contributors = signature.map do |schedule, count|
        Contributor.new(schedule, weights[schedule], count)
      end
      Segment.new(start_time, end_time, contributors)
    end
    private_class_method :build_segment
  end
end
