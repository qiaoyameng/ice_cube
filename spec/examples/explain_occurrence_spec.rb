require "spec_helper"

describe IceCube::Schedule, "#explain_occurrence" do
  let(:start_time) { Time.utc(2024, 1, 1, 9, 0, 0) } # a Monday

  it "lists every rule that provides the time, with stable indexes" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily
    schedule.add_recurrence_rule IceCube::Rule.weekly.day(:monday)

    explanation = schedule.explain_occurrence(Time.utc(2024, 1, 8, 9, 0, 0))

    expect(explanation.included?).to be true
    expect(explanation.status).to eq :included
    expect(explanation.providers.map(&:type)).to eq [:rrule, :rrule]
    expect(explanation.providers.map(&:index)).to eq [0, 1]
    expect(explanation.providers.map(&:source)).to eq schedule.recurrence_rules
    expect(explanation.excluders).to be_empty
    expect(explanation).to be_complete
  end

  it "reports the implicit start occurrence when there are only rtimes" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_time Time.utc(2024, 2, 1, 9, 0, 0)

    at_start = schedule.explain_occurrence(start_time)
    expect(at_start.providers.map(&:type)).to eq [:start_time]
    expect(at_start.included?).to be true

    at_rtime = schedule.explain_occurrence(Time.utc(2024, 2, 1, 9, 0, 0))
    expect(at_rtime.providers.map(&:type)).to eq [:rtime]
    expect(at_rtime.providers.first.index).to eq 0
    expect(at_rtime.included?).to be true

    elsewhere = schedule.explain_occurrence(Time.utc(2024, 2, 2, 9, 0, 0))
    expect(elsewhere.providers).to be_empty
    expect(elsewhere.included?).to be false
    expect(elsewhere.status).to eq :not_provided
  end

  it "lists exception rules and extimes that exclude the time" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily
    schedule.add_exception_rule IceCube::Rule.weekly.day(:tuesday)
    schedule.add_exception_time Time.utc(2024, 1, 5, 9, 0, 0)

    tuesday = schedule.explain_occurrence(Time.utc(2024, 1, 2, 9, 0, 0))
    expect(tuesday.providers.map(&:type)).to eq [:rrule]
    expect(tuesday.excluders.map(&:type)).to eq [:exrule]
    expect(tuesday.excluders.first.index).to eq 0
    expect(tuesday.included?).to be false
    expect(tuesday.status).to eq :excluded

    extime = schedule.explain_occurrence(Time.utc(2024, 1, 5, 9, 0, 0))
    expect(extime.excluders.map(&:type)).to eq [:extime]
    expect(extime.included?).to be false
  end

  it "honours COUNT by enumerating from the schedule start" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily.count(3)

    expect(schedule.explain_occurrence(start_time + 2 * ONE_DAY).included?).to be true
    expect(schedule.explain_occurrence(start_time + 3 * ONE_DAY).included?).to be false
  end

  it "honours UNTIL" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily.until(start_time + 2 * ONE_DAY)

    expect(schedule.explain_occurrence(start_time + 2 * ONE_DAY).included?).to be true
    expect(schedule.explain_occurrence(start_time + 3 * ONE_DAY).included?).to be false
  end

  it "treats exception rules with the same probe semantics as enumeration" do
    # The schedule applies exception rules by probing them at each candidate
    # occurrence without ever consuming their COUNT, so a COUNT-bounded
    # exrule excludes every time it matches.
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily.count(5)
    schedule.add_exception_rule IceCube::Rule.daily.count(2)

    time = start_time + 3 * ONE_DAY
    explanation = schedule.explain_occurrence(time)
    expect(explanation.excluders.map(&:type)).to eq [:exrule]
    expect(explanation.included?).to be false
    expect(explanation.included?).to be schedule.occurs_at?(time)
  end

  it "treats UNTIL-bounded exception rules as inert after their boundary" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily.count(4)
    schedule.add_exception_rule IceCube::Rule.daily.until(start_time)

    expect(schedule.explain_occurrence(start_time).included?).to be false
    later = schedule.explain_occurrence(start_time + ONE_DAY)
    expect(later.excluders).to be_empty
    expect(later.included?).to be true
  end

  it "honours the start alignment of interval rules" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily(2)

    expect(schedule.explain_occurrence(start_time + 2 * ONE_DAY).included?).to be true
    expect(schedule.explain_occurrence(start_time + 3 * ONE_DAY).included?).to be false
  end

  it "resolves BYSETPOS by actual enumeration semantics" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.monthly.day_of_month(1, 15).by_set_pos(2)

    expect(schedule.explain_occurrence(Time.utc(2024, 2, 15, 9, 0, 0)).included?).to be true
    expect(schedule.explain_occurrence(Time.utc(2024, 2, 1, 9, 0, 0)).included?).to be false
  end

  it "handles fractional seconds exactly" do
    fractional_start = start_time + 0.5
    schedule = IceCube::Schedule.new(fractional_start)
    schedule.add_recurrence_rule IceCube::Rule.daily.count(2)
    schedule.add_recurrence_time Time.utc(2024, 3, 1, 12, 0, 0) + 0.25

    expect(schedule.all_occurrences).to eq [
      fractional_start,
      fractional_start + ONE_DAY,
      Time.utc(2024, 3, 1, 12, 0, 0) + 0.25
    ]

    expect(schedule.explain_occurrence(fractional_start + ONE_DAY).included?).to be true
    expect(schedule.explain_occurrence(fractional_start + ONE_DAY - 0.5).included?).to be false
    expect(schedule.explain_occurrence(Time.utc(2024, 3, 1, 12, 0, 0) + 0.25).included?).to be true
    expect(schedule.explain_occurrence(Time.utc(2024, 3, 1, 12, 0, 0)).included?).to be false
  end

  it "reports an incomplete status when the scan budget runs out" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.minutely.count(10_000)
    last = start_time + 9_999 * ONE_MINUTE

    explanation = schedule.explain_occurrence(last, budget: 10)
    expect(explanation.complete?).to be false
    expect(explanation.included?).to be_nil
    expect(explanation.status).to eq :unknown
    expect(explanation.unresolved.map(&:type)).to eq [:rrule]
    expect(explanation.unresolved.first.index).to eq 0

    expect(schedule.explain_occurrence(last, budget: 20_000).included?).to be true
    expect(schedule.explain_occurrence(last + ONE_MINUTE, budget: 20_000).included?).to be false
  end

  it "accepts an unlimited budget" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily.count(5)

    explanation = schedule.explain_occurrence(start_time + 4 * ONE_DAY, budget: nil)
    expect(explanation.included?).to be true
    expect(explanation).to be_complete
  end

  it "does not advance a schedule that is being iterated" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily.count(3)

    enumerator = schedule.all_occurrences_enumerator
    expect(enumerator.next).to eq start_time

    schedule.explain_occurrence(start_time + ONE_DAY)

    expect(enumerator.next).to eq start_time + ONE_DAY
    expect(enumerator.next).to eq start_time + 2 * ONE_DAY
    expect { enumerator.next }.to raise_error(StopIteration)
  end

  it "leaves the usage state of the schedule's rules untouched" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily.count(3)

    schedule.explain_occurrence(start_time + ONE_DAY)

    expect(schedule.recurrence_rules.first.uses).to eq 0
    expect(schedule.all_occurrences).to eq [
      start_time, start_time + ONE_DAY, start_time + 2 * ONE_DAY
    ]
  end

  it "agrees with point-by-point enumeration of a finite schedule" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.daily.count(10)
    schedule.add_recurrence_rule IceCube::Rule.weekly.day(:monday).count(3)
    schedule.add_recurrence_time Time.utc(2024, 2, 14, 9, 0, 0)
    schedule.add_exception_rule IceCube::Rule.weekly.day(:wednesday)
    schedule.add_exception_time start_time + ONE_DAY

    closing = start_time + 30 * ONE_DAY
    occurrences = schedule.occurrences(closing)

    occurrences.each do |time|
      explanation = schedule.explain_occurrence(time)
      expect(explanation.included?).to(be(true), "expected #{time} to be included")
      expect(explanation.providers).not_to be_empty
    end

    day = start_time
    while day <= closing
      unless occurrences.include?(day)
        explanation = schedule.explain_occurrence(day)
        expect(explanation.included?).to(be(false), "expected #{day} to be excluded")
      end
      day += ONE_DAY
    end
  end

  it "agrees with occurs_at? for grid-aligned times" do
    schedule = IceCube::Schedule.new(start_time)
    schedule.add_recurrence_rule IceCube::Rule.weekly.day(:monday, :friday).count(6)

    schedule.all_occurrences.each do |time|
      expect(schedule.explain_occurrence(time).included?).to be schedule.occurs_at?(time)
    end
    expect(schedule.explain_occurrence(start_time + ONE_DAY).included?).to be false
  end

  it "raises ArgumentError for a nil time" do
    schedule = IceCube::Schedule.new(start_time)
    expect { schedule.explain_occurrence(nil) }.to raise_error(ArgumentError)
  end
end
