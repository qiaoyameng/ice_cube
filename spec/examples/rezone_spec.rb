require "active_support"
require "active_support/time"
require File.dirname(__FILE__) + "/../spec_helper"

describe IceCube::Schedule, "#rezone" do
  let(:source_zone) { "America/New_York" }
  let(:start_time) { Time.find_zone!(source_zone).local(2020, 1, 15, 9, 30, 15) }

  def weekly_count_schedule(start_time)
    schedule = IceCube::Schedule.new(start_time, duration: 90 * 60)
    schedule.add_recurrence_rule(
      IceCube::Rule.weekly(2).day(:wednesday).count(3).until(
        Time.find_zone!(source_zone).local(2020, 2, 15, 9, 30, 15)
      )
    )
    schedule.add_recurrence_time(start_time + IceCube::ONE_DAY)
    schedule.add_exception_time(start_time + 2 * IceCube::ONE_DAY)
    schedule.add_exception_rule(
      IceCube::Rule.weekly.day(:sunday).until(
        Time.find_zone!(source_zone).local(2020, 2, 16, 9, 30, 15)
      )
    )
    schedule
  end

  it "preserves absolute instants for every time and duration" do
    schedule = weekly_count_schedule(start_time)
    moved = schedule.rezone("Asia/Kolkata", preserve: :instant)

    expect(moved).not_to equal(schedule)
    expect(moved.start_time).to eq(start_time)
    expect(moved.start_time.time_zone.name).to eq("Asia/Kolkata")
    expect(moved.start_time.hour).to eq(20)
    expect(moved.start_time.min).to eq(0)
    expect(moved.end_time).to eq(schedule.end_time)
    expect(moved.duration).to eq(90 * 60)
    expect(moved.rrules.first.until_time).to eq(schedule.rrules.first.until_time)
    expect(moved.rtimes).to eq(schedule.rtimes)
    expect(moved.extimes).to eq(schedule.extimes)
    expect(schedule.start_time.time_zone.name).to eq("America/New_York")
    expect(schedule.rrules.first.until_time.time_zone.name).to eq("America/New_York")
  end

  it "preserves local wall-clock components for every time and duration" do
    schedule = weekly_count_schedule(start_time)
    moved = schedule.rezone(
      "Asia/Kolkata",
      preserve: :wall_time,
      ambiguous_time: :reject
    )
    original_rule = schedule.rrules.first
    moved_rule = moved.rrules.first

    expect(moved.start_time).to eq(Time.find_zone!("Asia/Kolkata").local(2020, 1, 15, 9, 30, 15))
    expect(moved.start_time.time_zone.name).to eq("Asia/Kolkata")
    expect(moved.end_time).to eq(Time.find_zone!("Asia/Kolkata").local(2020, 1, 15, 11, 0, 15))
    expect(moved.duration).to eq(90 * 60)
    expect(moved_rule.until_time).to eq(Time.find_zone!("Asia/Kolkata").local(2020, 2, 15, 9, 30, 15))
    expect(moved_rule.occurrence_count).to eq(3)
    expect(moved_rule.to_hash[:interval]).to eq(2)
    expect(moved_rule.to_hash[:validations]).to include(day: [3])
    expect(moved.rtimes.first).to eq(Time.find_zone!("Asia/Kolkata").local(2020, 1, 16, 9, 30, 15))
    expect(moved.extimes.first).to eq(Time.find_zone!("Asia/Kolkata").local(2020, 1, 17, 9, 30, 15))
    expect(moved.exrules.first.until_time).to eq(
      Time.find_zone!("Asia/Kolkata").local(2020, 2, 16, 9, 30, 15)
    )
    expect(original_rule.until_time.time_zone.name).to eq("America/New_York")
  end

  it "interprets weekly phase and count from the moved schedule" do
    phase_start = Time.find_zone!(source_zone).local(2020, 1, 13, 9, 30, 15)
    schedule = IceCube::Schedule.new(phase_start)
    schedule.rrule(IceCube::Rule.weekly(2).day(:monday, :wednesday).count(4))

    moved = schedule.rezone(
      "Asia/Kolkata",
      preserve: :wall_time,
      ambiguous_time: :reject
    )

    expect(moved.first(4).map { |time| [time.wday, time.hour, time.min] }).to eq([
      [1, 9, 30], [3, 9, 30], [1, 9, 30], [3, 9, 30]
    ])
    expect(moved.first(4).map(&:time_zone).uniq.map(&:name)).to eq(["Asia/Kolkata"])
  end

  it "compares absolute and wall-time behavior around a DST change week" do
    chicago = Time.find_zone!("America/Chicago")
    schedule = IceCube::Schedule.new(chicago.local(2017, 3, 8, 9, 30), duration: 3600)
    schedule.rrule(
      IceCube::Rule.weekly.count(2).until(chicago.local(2017, 3, 22, 9, 30))
    )

    instant = schedule.rezone("America/New_York", preserve: :instant)
    wall = schedule.rezone(
      "America/New_York",
      preserve: :wall_time,
      ambiguous_time: :reject
    )

    expect(instant.first(2).map(&:utc)).to eq([
      Time.utc(2017, 3, 8, 15, 30), Time.utc(2017, 3, 15, 14, 30)
    ])
    expect(wall.first(2).map(&:utc)).to eq([
      Time.utc(2017, 3, 8, 14, 30), Time.utc(2017, 3, 15, 13, 30)
    ])
    expect(instant.rrules.first.until_time.utc).to eq(Time.utc(2017, 3, 22, 14, 30))
    expect(wall.rrules.first.until_time.utc).to eq(Time.utc(2017, 3, 22, 13, 30))
    expect(instant.duration).to eq(3600)
    expect(wall.duration).to eq(3600)
  end

  it "keeps a date-only UNTIL as a date constraint in wall-time mode" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.rrule(IceCube::Rule.daily.until(Date.new(2020, 1, 20)))

    instant = schedule.rezone("Asia/Kolkata", preserve: :instant)
    wall = schedule.rezone(
      "Asia/Kolkata",
      preserve: :wall_time,
      ambiguous_time: :reject
    )

    expect(instant.rrules.first.until_time).to eq(
      Time.find_zone!("Asia/Kolkata").local(2020, 1, 21, 10, 29, 59)
    )
    expect(wall.rrules.first.until_time).to eq(Date.new(2020, 1, 20))
    expect(wall.occurs_on?(Date.new(2020, 1, 20))).to eq(true)
    expect(
      IceCube::Schedule.from_yaml(wall.to_yaml).rrules.first.until_time
    ).to eq(Date.new(2020, 1, 20))
  end

  it "accepts the mode and disambiguation as positional string choices" do
    schedule = weekly_count_schedule(start_time)

    moved = schedule.rezone("Asia/Kolkata", "wall_time", ambiguous_time: "reject")

    expect(moved.start_time).to eq(Time.find_zone!("Asia/Kolkata").local(2020, 1, 15, 9, 30, 15))
    expect(moved.rrules.first.until_time).to eq(
      Time.find_zone!("Asia/Kolkata").local(2020, 2, 15, 9, 30, 15)
    )
  end

  it "requires an explicit legal mapping for wall-time conversions" do
    schedule = weekly_count_schedule(start_time)

    expect do
      schedule.rezone("Asia/Kolkata", preserve: :wall_time)
    end.to raise_error(ArgumentError, /Expected :reject, :earlier, or :later/)
  end

  it "handles a 30-minute DST gap using the actual transition boundaries" do
    schedule = IceCube::Schedule.new(
      Time.utc(2020, 10, 4, 2, 15),
      end_time: Time.utc(2020, 10, 4, 4)
    )

    earlier = schedule.rezone(
      "Australia/Lord_Howe",
      preserve: :wall_time,
      ambiguous_time: :earlier
    )
    later = schedule.rezone(
      "Australia/Lord_Howe",
      preserve: :wall_time,
      ambiguous_time: :later
    )

    expect([earlier.start_time.hour, earlier.start_time.min, earlier.start_time.nsec, earlier.start_time.utc_offset]).to eq([1, 59, 999_999_999, 37_800])
    expect([later.start_time.hour, later.start_time.min, later.start_time.utc_offset]).to eq([2, 30, 39_600])
    expect(earlier.end_time).to eq(Time.find_zone!("Australia/Lord_Howe").local(2020, 10, 4, 4))
    expect(later.end_time).to eq(Time.find_zone!("Australia/Lord_Howe").local(2020, 10, 4, 4))
  end

  it "round-trips the selected wall-time result through yaml and hash storage" do
    schedule = weekly_count_schedule(start_time)
    moved = schedule.rezone(
      "Asia/Kolkata",
      preserve: :wall_time,
      ambiguous_time: :reject
    )

    [
      IceCube::Schedule.from_yaml(moved.to_yaml),
      IceCube::Schedule.from_hash(moved.to_hash)
    ].each do |loaded|
      expect(loaded.start_time).to eq(moved.start_time)
      expect(loaded.end_time).to eq(moved.end_time)
      expect(loaded.rrules.first.until_time).to eq(moved.rrules.first.until_time)
      expect(loaded.rtimes).to eq(moved.rtimes)
      expect(loaded.extimes).to eq(moved.extimes)
      expect(loaded.exrules.first.until_time).to eq(moved.exrules.first.until_time)
      expect(loaded.duration).to eq(90 * 60)
    end
  end

  context "with a nonexistent local time during a spring-forward transition" do
    let(:start_time) do
      Time.utc(2017, 3, 12, 2, 30, 0)
    end

    it "rejects the ambiguous wall time when selected" do
      schedule = IceCube::Schedule.new(start_time)

      expect do
        schedule.rezone("America/New_York", preserve: :wall_time, ambiguous_time: :reject)
      end.to raise_error(ArgumentError, /2017-03-12 02:30:00.*America\/New_York/)
    end

    it "maps the gap to the earlier or later legal local representation" do
      schedule = IceCube::Schedule.new(start_time, end_time: Time.utc(2017, 3, 12, 4, 0, 0))

      earlier = schedule.rezone(
        "America/New_York",
        preserve: :wall_time,
        ambiguous_time: :earlier
      )
      later = schedule.rezone(
        "America/New_York",
        preserve: :wall_time,
        ambiguous_time: :later
      )

      expect([earlier.start_time.hour, earlier.start_time.min, earlier.start_time.nsec]).to eq([1, 59, 999_999_999])
      expect(earlier.start_time.utc_offset).to eq(-5 * 3600)
      expect(earlier.end_time).to eq(Time.find_zone!(source_zone).local(2017, 3, 12, 4, 0, 0))
      expect(later.start_time).to eq(Time.find_zone!(source_zone).local(2017, 3, 12, 3, 0, 0))
      expect(later.start_time.utc_offset).to eq(-4 * 3600)
      expect(later.end_time).to eq(Time.find_zone!(source_zone).local(2017, 3, 12, 4, 0, 0))
    end
  end

  context "with a repeated local time during a fall-back transition" do
    let(:start_time) do
      Time.utc(2017, 11, 5, 1, 30, 0)
    end

    it "rejects the repeated wall time when selected" do
      schedule = IceCube::Schedule.new(start_time)

      expect do
        schedule.rezone("America/New_York", preserve: :wall_time, ambiguous_time: :reject)
      end.to raise_error(ArgumentError, /2017-11-05 01:30:00.*America\/New_York/)
    end

    it "maps the repeated wall time to the earlier or later instant" do
      schedule = IceCube::Schedule.new(start_time, end_time: Time.utc(2017, 11, 5, 4, 0, 0))

      earlier = schedule.rezone(
        "America/New_York",
        preserve: :wall_time,
        ambiguous_time: :earlier
      )
      later = schedule.rezone(
        "America/New_York",
        preserve: :wall_time,
        ambiguous_time: :later
      )

      expect(earlier.start_time).to eq(Time.find_zone!(source_zone).local(2017, 11, 5, 1, 30, 0))
      expect(earlier.start_time.utc_offset).to eq(-4 * 3600)
      expect(earlier.end_time.utc_offset).to eq(-5 * 3600)
      expect([
        later.start_time.year, later.start_time.month, later.start_time.day,
        later.start_time.hour, later.start_time.min
      ]).to eq([2017, 11, 5, 1, 30])
      expect(later.start_time.utc_offset).to eq(-5 * 3600)
      expect(later.end_time.utc_offset).to eq(-5 * 3600)
      expect(earlier.start_time).to be < later.start_time
    end
  end
end
