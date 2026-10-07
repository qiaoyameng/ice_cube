require File.dirname(__FILE__) + "/../spec_helper"

describe IceCube::Occupancy do
  let(:window_start) { Time.utc(2020, 1, 1) }
  let(:window_end) { window_start + 6 * ONE_HOUR }
  let(:window) { window_start...window_end }

  def schedule(start_time, duration:, count: 1)
    IceCube::Schedule.new(start_time, duration: duration).tap do |schedule|
      schedule.add_recurrence_rule IceCube::Rule.hourly.count(count)
    end
  end

  def interval(segment)
    [segment.start_time, segment.end_time]
  end

  it "finds the longest occupied interval" do
    left = schedule(window_start, duration: 2 * ONE_HOUR)
    right = schedule(window_start + 3 * ONE_HOUR, duration: ONE_HOUR)

    result = IceCube.occupancy([[left, 1], [right, 1]], window: window, threshold: 1)

    expect(result.longest_segments.map(&method(:interval))).to eq(
      [[window_start, window_start + 2 * ONE_HOUR]]
    )
  end

  it "merges abutting half-open intervals" do
    first = schedule(window_start, duration: ONE_HOUR)
    second = schedule(window_start + ONE_HOUR, duration: ONE_HOUR)

    result = IceCube.occupancy([[first, 1], [second, 1]], window: window, threshold: 1)
    segment = result.longest_segments.first

    expect(interval(segment)).to eq([window_start, window_start + 2 * ONE_HOUR])
    expect(segment.slices.map(&:weight)).to eq([1, 1])
  end

  it "splits nested overlap into constant-weight slices" do
    outer = schedule(window_start, duration: 3 * ONE_HOUR)
    inner = schedule(window_start + ONE_HOUR, duration: ONE_HOUR)

    result = IceCube.occupancy([[outer, 2], [inner, 1]], window: window, threshold: 2)

    expect(result.slices.map { |slice|
      [slice.start_time, slice.end_time, slice.weight]
    }).to eq([
      [window_start, window_start + ONE_HOUR, 2],
      [window_start + ONE_HOUR, window_start + 2 * ONE_HOUR, 3],
      [window_start + 2 * ONE_HOUR, window_start + 3 * ONE_HOUR, 2]
    ])
    expect(result.longest_segments.first.participants).to eq([outer, inner])
  end

  it "counts occurrences that started before the window" do
    before = schedule(window_start - 30 * ONE_MINUTE, duration: ONE_HOUR)
    at_start = schedule(window_start, duration: ONE_HOUR)

    result = IceCube.occupancy([[before, 1], [at_start, 1]], window: window, threshold: 2)

    expect(result.slices.map { |slice|
      [slice.start_time, slice.end_time, slice.weight]
    }).to eq([[window_start, window_start + 30 * ONE_MINUTE, 2]])
  end

  it "does not count an occurrence ending exactly when the window starts" do
    ending = schedule(window_start - ONE_HOUR, duration: ONE_HOUR)
    starting = schedule(window_start, duration: ONE_HOUR)

    result = IceCube.occupancy([[ending, 1], [starting, 1]], window: window, threshold: 2)

    expect(result.segments).to be_empty
    expect(result.occurrence_count).to eq(1)
  end

  it "clips occurrences that continue past the window end" do
    continuing = schedule(window_end - 30 * ONE_MINUTE, duration: ONE_HOUR)

    result = IceCube.occupancy([[continuing, 1]], window: window, threshold: 1)

    expect(result.longest_segments.map(&method(:interval))).to eq(
      [[window_end - 30 * ONE_MINUTE, window_end]]
    )
  end

  it "counts overlapping occurrences from the same schedule separately" do
    overlapping = schedule(window_start, duration: 2 * ONE_HOUR, count: 2)

    result = IceCube.occupancy([[overlapping, 1]], window: window, threshold: 2)

    expect(result.slices.map { |slice|
      [slice.start_time, slice.end_time, slice.weight]
    }).to eq([[window_start + ONE_HOUR, window_start + 2 * ONE_HOUR, 2]])
    expect(result.slices.first.contributors.first.occurrences.size).to eq(2)
  end

  it "applies exception times before collecting occurrences" do
    recurring = schedule(window_start, duration: 2 * ONE_HOUR, count: 2)
    recurring.add_exception_time(window_start + ONE_HOUR)

    result = IceCube.occupancy([[recurring, 1]], window: window, threshold: 1)

    expect(result.slices.map { |slice|
      [slice.start_time, slice.end_time]
    }).to eq([[window_start, window_start + 2 * ONE_HOUR]])
  end

  it "handles an occurrence crossing midnight" do
    start = Time.utc(2020, 1, 1, 23, 30)
    overnight = schedule(start, duration: ONE_HOUR)

    result = IceCube.occupancy(
      [[overnight, 2]],
      window: start...(start + 90 * ONE_MINUTE),
      threshold: 2
    )

    expect(result.longest_segments.map(&method(:interval))).to eq(
      [[start, start + ONE_HOUR]]
    )
  end

  it "explains every slice with contributor weights" do
    first = schedule(window_start, duration: 2 * ONE_HOUR)
    second = schedule(window_start + 30 * ONE_MINUTE, duration: ONE_HOUR)

    result = IceCube.occupancy([[first, 2], [second, 3]], window: window, threshold: 1)

    result.slices.each do |slice|
      weight = slice.contributors.sum do |contributor|
        expect(contributor.total_weight).to eq(contributor.weight * contributor.occurrences.size)
        contributor.weight * contributor.occurrences.size
      end
      expect(weight).to eq(slice.weight)
    end
  end

  it "returns every longest interval when lengths tie" do
    first = schedule(window_start, duration: ONE_HOUR)
    second = schedule(window_start + 2 * ONE_HOUR, duration: ONE_HOUR)

    result = IceCube.occupancy([[first, 1], [second, 1]], window: window, threshold: 1)

    expect(result.map(&method(:interval))).to eq([
      [window_start, window_start + ONE_HOUR],
      [window_start + 2 * ONE_HOUR, window_start + 3 * ONE_HOUR]
    ])
  end

  it "raises instead of returning an incomplete result at the occurrence limit" do
    infinite = IceCube::Schedule.new(window_start, duration: ONE_HOUR)
    infinite.add_recurrence_rule IceCube::Rule.hourly

    expect do
      IceCube.occupancy(
        [[infinite, 1]],
        window: window,
        threshold: 1,
        occurrence_limit: 2
      )
    end.to raise_error(IceCube::OccurrenceLimitExceeded) do |error|
      expect(error.occurrence_count).to eq(3)
    end
  end

  it "accepts max_occurrences as an occurrence limit alias" do
    infinite = IceCube::Schedule.new(window_start, duration: ONE_HOUR)
    infinite.add_recurrence_rule IceCube::Rule.hourly

    expect do
      IceCube.occupancy(
        [[infinite, 1]],
        window: window,
        threshold: 1,
        max_occurrences: 1
      )
    end.to raise_error(IceCube::OccurrenceLimitExceeded)
  end

  it "supports a positional between query" do
    occupied = schedule(window_start, duration: ONE_HOUR)
    result = IceCube.occupancy_between(
      window_start,
      window_end,
      [[occupied, 1]],
      threshold: 1
    )

    expect(result.longest_segments.first.start_time).to eq(window_start)
  end

  it "supports a schedule to weight mapping" do
    occupied = schedule(window_start, duration: ONE_HOUR)

    result = IceCube.occupancy({occupied => 1}, window: window, threshold: 1)

    expect(result.longest_segments.first.contributors.first.schedule).to eq(occupied)
  end

  it "supports max_occurrences directly through the query class" do
    infinite = IceCube::Schedule.new(window_start, duration: ONE_HOUR)
    infinite.add_recurrence_rule IceCube::Rule.hourly

    expect do
      IceCube::Occupancy.query(
        [[infinite, 1]],
        window: window,
        threshold: 1,
        max_occurrences: 1
      )
    end.to raise_error(IceCube::OccurrenceLimitExceeded)
  end

  it "rejects a closed window" do
    occupied = schedule(window_start, duration: ONE_HOUR)

    expect do
      IceCube.occupancy([[occupied, 1]], window: window_start..window_end, threshold: 1)
    end.to raise_error(ArgumentError, /half-open/)
  end
end
