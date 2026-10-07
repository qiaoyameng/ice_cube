require "spec_helper"

describe IceCube::Occupancy do
  def single(start, duration)
    IceCube::Schedule.new(start, duration: duration)
  end

  def daily(start, duration, &block)
    IceCube::Schedule.new(start, duration: duration) do |s|
      s.add_recurrence_rule IceCube::Rule.daily
      block&.call(s)
    end
  end

  def query(from, to, schedules, threshold: 1, **options)
    IceCube::Occupancy.query(from, to, schedules, threshold: threshold, **options)
  end

  let(:t0) { Time.utc(2026, 10, 5, 9, 0, 0) }

  describe "half-open boundaries" do
    it "does not double count back-to-back occurrences at the shared instant" do
      a = single(t0, ONE_HOUR)
      b = single(t0 + ONE_HOUR, ONE_HOUR)
      result = query(t0, t0 + 2 * ONE_HOUR, [[a, 1], [b, 1]], threshold: 2)
      expect(result.segments).to be_empty
    end

    it "merges adjacent qualifying segments into one run" do
      a = single(t0, ONE_HOUR)
      b = single(t0 + ONE_HOUR, ONE_HOUR)
      result = query(t0, t0 + 2 * ONE_HOUR, [[a, 1], [b, 1]], threshold: 1)
      expect(result.runs.length).to eq 1
      run = result.runs.first
      expect(run.start_time).to eq t0
      expect(run.end_time).to eq t0 + 2 * ONE_HOUR
      expect(run.duration).to eq 2 * ONE_HOUR
      expect(run.segments.length).to eq 2
      expect(run.segments[0].contributors.map(&:schedule)).to eq [a]
      expect(run.segments[1].contributors.map(&:schedule)).to eq [b]
    end
  end

  describe "nested overlaps" do
    it "sums weights only while both schedules are active" do
      a = single(t0, 3 * ONE_HOUR)
      b = single(t0 + ONE_HOUR, ONE_HOUR)
      result = query(t0, t0 + 3 * ONE_HOUR, [[a, 1], [b, 2]], threshold: 3)
      expect(result.runs.length).to eq 1
      segment = result.longest.segments.first
      expect(segment.start_time).to eq t0 + ONE_HOUR
      expect(segment.end_time).to eq t0 + 2 * ONE_HOUR
      expect(segment.weight).to eq 3
    end

    it "reports contributors that explain the segment weight" do
      a = single(t0, 3 * ONE_HOUR)
      b = single(t0 + ONE_HOUR, ONE_HOUR)
      result = query(t0, t0 + 3 * ONE_HOUR, [[a, 1], [b, 2]], threshold: 1)
      weights = result.longest.segments.map(&:weight)
      expect(weights).to eq [1, 3, 1]
      middle = result.longest.segments[1]
      contributions = middle.contributors.map do |c|
        expect(c.contribution).to eq c.weight * c.occurrences
        c.contribution
      end
      expect(contributions.sum).to eq middle.weight
    end
  end

  it "counts occurrences that started before the window but still overlap it" do
    schedule = single(t0 - 2 * ONE_HOUR, 4 * ONE_HOUR) # 07:00 - 11:00
    result = query(t0, t0 + ONE_HOUR, [[schedule, 1]], threshold: 1)
    expect(result.segments.length).to eq 1
    expect(result.segments.first.start_time).to eq t0
    expect(result.segments.first.end_time).to eq t0 + ONE_HOUR
  end

  it "handles occurrences crossing midnight" do
    day = Time.utc(2026, 10, 5, 23, 0, 0)
    schedule = daily(day, 2 * ONE_HOUR)
    window_start = Time.utc(2026, 10, 6, 0, 0, 0)
    window_end = Time.utc(2026, 10, 7, 0, 0, 0)
    result = query(window_start, window_end, [[schedule, 1]], threshold: 1)
    segments = result.segments.map { |s| [s.start_time, s.end_time] }
    expect(segments).to eq [
      [Time.utc(2026, 10, 6, 0, 0, 0), Time.utc(2026, 10, 6, 1, 0, 0)],
      [Time.utc(2026, 10, 6, 23, 0, 0), Time.utc(2026, 10, 7, 0, 0, 0)]
    ]
  end

  it "counts self-overlapping occurrences of one schedule separately" do
    monday = Time.utc(2026, 10, 5, 0, 0, 0)
    schedule = daily(monday, 2 * ONE_DAY)
    result = query(monday, monday + 7 * ONE_DAY, [[schedule, 1]], threshold: 2)
    expect(result.runs.length).to eq 1
    segment = result.longest.segments.first
    expect(segment.start_time).to eq monday + ONE_DAY
    expect(segment.end_time).to eq monday + 7 * ONE_DAY
    contributor = segment.contributors.first
    expect(contributor.schedule).to eq schedule
    expect(contributor.occurrences).to eq 2
    expect(segment.weight).to eq 2
  end

  it "applies exception times as usual" do
    schedule = daily(t0, ONE_HOUR) do |s|
      s.add_exception_time(t0 + ONE_DAY)
    end
    result = query(t0, t0 + 3 * ONE_DAY, [[schedule, 1]], threshold: 1)
    days = result.segments.map { |s| (s.start_time - t0) / ONE_DAY }
    expect(days).to eq [0, 2]
  end

  it "returns the longest qualifying run" do
    a = single(t0, ONE_HOUR)
    b = single(t0 + 3 * ONE_HOUR, 2 * ONE_HOUR)
    result = query(t0, t0 + 6 * ONE_HOUR, [[a, 1], [b, 1]], threshold: 1)
    expect(result.runs.length).to eq 2
    expect(result.longest.start_time).to eq t0 + 3 * ONE_HOUR
    expect(result.longest.duration).to eq 2 * ONE_HOUR
  end

  it "prefers the earliest run when durations tie" do
    a = single(t0, ONE_HOUR)
    b = single(t0 + 3 * ONE_HOUR, ONE_HOUR)
    result = query(t0, t0 + 6 * ONE_HOUR, [[a, 1], [b, 1]], threshold: 1)
    expect(result.longest.start_time).to eq t0
  end

  it "returns nil longest and empty runs when nothing qualifies" do
    a = single(t0, ONE_HOUR)
    result = query(t0, t0 + ONE_DAY, [[a, 1]], threshold: 2)
    expect(result.runs).to be_empty
    expect(result.longest).to be_nil
  end

  it "accepts a hash of schedule => weight" do
    a = single(t0, ONE_HOUR)
    result = query(t0, t0 + ONE_DAY, {a => 1}, threshold: 1)
    expect(result.segments.length).to eq 1
  end

  describe "occurrence limit" do
    it "raises instead of returning a partial result" do
      schedule = IceCube::Schedule.new(t0, duration: ONE_MINUTE) do |s|
        s.add_recurrence_rule IceCube::Rule.minutely
      end
      expect {
        query(t0, t0 + ONE_DAY, [[schedule, 1]], threshold: 1, max_occurrences: 5)
      }.to raise_error(IceCube::OccupancyLimitExceeded)
    end

    it "completes when the limit is not exceeded" do
      schedule = daily(t0, ONE_HOUR)
      result = query(t0, t0 + 3 * ONE_DAY, [[schedule, 1]], threshold: 1, max_occurrences: 10)
      expect(result.segments.length).to eq 3
    end
  end

  describe "validation" do
    it "rejects an inverted window" do
      a = single(t0, ONE_HOUR)
      expect {
        query(t0 + ONE_HOUR, t0, [[a, 1]], threshold: 1)
      }.to raise_error(ArgumentError)
    end

    it "rejects a non-positive threshold" do
      a = single(t0, ONE_HOUR)
      expect {
        query(t0, t0 + ONE_HOUR, [[a, 1]], threshold: 0)
      }.to raise_error(ArgumentError)
    end

    it "rejects a non-positive weight" do
      a = single(t0, ONE_HOUR)
      expect {
        query(t0, t0 + ONE_HOUR, [[a, 0]], threshold: 1)
      }.to raise_error(ArgumentError)
    end
  end
end
