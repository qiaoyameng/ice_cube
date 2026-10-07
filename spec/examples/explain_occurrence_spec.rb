require File.dirname(__FILE__) + "/../spec_helper"

describe IceCube::Schedule do
  let(:start_time) { Time.utc(2024, 1, 1, 9, 0, 0) } # a Monday

  describe :explain_occurrence do
    it "identifies the recurrence rule that provides an occurrence" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
      end
      explanation = schedule.explain_occurrence(Time.utc(2024, 1, 5, 9, 0, 0))
      expect(explanation).to be_complete
      expect(explanation.occurs?).to be true
      expect(explanation.provided_by).to eq [
        {type: :rrule, index: 0, rule: schedule.recurrence_rules.first}
      ]
      expect(explanation.excluded_by).to eq []
    end

    it "reports no providers for a time that is not an occurrence" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
      end
      explanation = schedule.explain_occurrence(Time.utc(2024, 1, 5, 10, 0, 0))
      expect(explanation).to be_complete
      expect(explanation.occurs?).to be false
      expect(explanation.provided_by).to eq []
      expect(explanation.excluded_by).to eq []
    end

    it "distinguishes two similar rules by stable index" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily.hour_of_day(9)
        s.add_recurrence_rule IceCube::Rule.daily.hour_of_day(18)
      end
      morning = schedule.explain_occurrence(Time.utc(2024, 1, 3, 9, 0, 0))
      evening = schedule.explain_occurrence(Time.utc(2024, 1, 3, 18, 0, 0))
      expect(morning.provided_by.map { |e| e[:index] }).to eq [0]
      expect(evening.provided_by.map { |e| e[:index] }).to eq [1]
      expect(morning.provided_by.first[:rule]).to be schedule.recurrence_rules[0]
      expect(evening.provided_by.first[:rule]).to be schedule.recurrence_rules[1]
    end

    it "lists every rule when two rules hit the same time" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
        s.add_recurrence_rule IceCube::Rule.weekly.day(:monday)
      end
      explanation = schedule.explain_occurrence(Time.utc(2024, 1, 8, 9, 0, 0))
      expect(explanation.occurs?).to be true
      expect(explanation.provided_by.map { |e| e[:index] }).to eq [0, 1]
    end

    it "identifies a recurrence time that provides an occurrence" do
      rtime = Time.utc(2024, 2, 14, 9, 30, 0)
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
        s.add_recurrence_time rtime
      end
      explanation = schedule.explain_occurrence(rtime)
      expect(explanation.occurs?).to be true
      expect(explanation.provided_by).to eq [{type: :rtime, index: 0, time: rtime}]
    end

    it "reports the implicit start when the schedule only has recurrence times" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_time Time.utc(2024, 2, 1, 9, 0, 0)
      end
      explanation = schedule.explain_occurrence(start_time)
      expect(explanation.occurs?).to be true
      expect(explanation.provided_by).to eq [{type: :implicit_start}]
      expect(schedule.occurs_at?(start_time)).to be true
    end

    it "identifies an exception time that excludes an occurrence" do
      extime = Time.utc(2024, 1, 3, 9, 0, 0)
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
        s.add_exception_time extime
      end
      explanation = schedule.explain_occurrence(extime)
      expect(explanation.occurs?).to be false
      expect(explanation.provided_by).to eq [
        {type: :rrule, index: 0, rule: schedule.recurrence_rules.first}
      ]
      expect(explanation.excluded_by).to eq [{type: :extime, index: 0, time: extime}]
    end

    it "identifies an exception rule that excludes an occurrence" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
        s.add_exception_rule IceCube::Rule.weekly.day(:monday)
      end
      monday = schedule.explain_occurrence(Time.utc(2024, 1, 8, 9, 0, 0))
      tuesday = schedule.explain_occurrence(Time.utc(2024, 1, 9, 9, 0, 0))
      expect(monday.occurs?).to be false
      expect(monday.excluded_by).to eq [
        {type: :exrule, index: 0, rule: schedule.exception_rules.first}
      ]
      expect(tuesday.occurs?).to be true
      expect(tuesday.excluded_by).to eq []
    end

    it "honors COUNT by actual enumeration rather than date arithmetic" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily.count(3)
      end
      expect(schedule.explain_occurrence(start_time + 2 * IceCube::ONE_DAY).occurs?).to be true
      exhausted = schedule.explain_occurrence(start_time + 3 * IceCube::ONE_DAY)
      expect(exhausted.occurs?).to be false
      expect(exhausted.provided_by).to eq []
    end

    it "counts occurrences consumed by coinciding rules and exception times" do
      extime = start_time + IceCube::ONE_DAY
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily.count(2)
        s.add_exception_time extime
      end
      # The extime consumes the second of the two counted occurrences, so
      # day three is not provided even though only one occurrence is visible.
      expect(schedule.explain_occurrence(start_time).occurs?).to be true
      expect(schedule.explain_occurrence(extime).occurs?).to be false
      expect(schedule.explain_occurrence(start_time + 2 * IceCube::ONE_DAY).occurs?).to be false
      expect(schedule.occurrences(start_time + 10 * IceCube::ONE_DAY)).to eq [start_time]
    end

    it "honors UNTIL" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily.until(Time.utc(2024, 1, 4, 9, 0, 0))
      end
      expect(schedule.explain_occurrence(Time.utc(2024, 1, 4, 9, 0, 0)).occurs?).to be true
      expect(schedule.explain_occurrence(Time.utc(2024, 1, 5, 9, 0, 0)).occurs?).to be false
    end

    it "honors start-time alignment for interval rules" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily(2)
      end
      expect(schedule.explain_occurrence(start_time + 3 * IceCube::ONE_DAY).occurs?).to be false
      expect(schedule.explain_occurrence(start_time + 4 * IceCube::ONE_DAY).occurs?).to be true
    end

    it "honors BYSETPOS by actual enumeration" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.monthly.day(:monday).by_set_pos(1)
      end
      first_monday = Time.utc(2024, 2, 5, 9, 0, 0)
      second_monday = Time.utc(2024, 2, 12, 9, 0, 0)
      expect(schedule.explain_occurrence(first_monday).occurs?).to be true
      expect(schedule.explain_occurrence(second_monday).occurs?).to be false
      expect(schedule.explain_occurrence(second_monday).provided_by).to eq []
    end

    it "matches fractional seconds against the schedule's grid" do
      fractional_start = Time.utc(2024, 1, 1, 9, 0, 0) + Rational(1, 2)
      schedule = IceCube::Schedule.new(fractional_start) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
      end
      on_grid = Time.utc(2024, 1, 4, 9, 0, 0) + Rational(1, 2)
      off_grid = Time.utc(2024, 1, 4, 9, 0, 0)
      explanation = schedule.explain_occurrence(on_grid)
      expect(explanation.occurs?).to be true
      expect(explanation.occurrence_time).to eq on_grid
      expect(schedule.explain_occurrence(off_grid).occurs?).to be false
      expect(schedule.occurs_at?(on_grid)).to be true
      expect(schedule.occurs_at?(off_grid)).to be false
    end

    it "matches recurrence times with fractional seconds" do
      rtime = Time.utc(2024, 1, 10, 9, 30, 0) + Rational(1, 4)
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
        s.add_recurrence_time rtime
      end
      explanation = schedule.explain_occurrence(rtime)
      expect(explanation.occurs?).to be true
      expect(explanation.provided_by).to eq [{type: :rtime, index: 0, time: rtime}]
    end

    it "returns an incomplete status when the scan budget is exhausted" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.minutely.count(100_000)
      end
      target = start_time + 60 * 2_000
      explanation = schedule.explain_occurrence(target, budget: 100)
      expect(explanation).to be_incomplete
      expect(explanation.occurs?).to be_nil
      expect(explanation.provided_by).to eq []
      expect(explanation.excluded_by).to eq []
    end

    it "completes within a sufficient budget" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.minutely.count(100_000)
      end
      target = start_time + 60 * 2_000
      explanation = schedule.explain_occurrence(target, budget: 5_000)
      expect(explanation).to be_complete
      expect(explanation.occurs?).to be true
      expect(explanation.provided_by.map { |e| e[:type] }).to eq [:rrule]
    end

    it "does not advance an enumeration in progress" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily.count(5)
      end
      enumerator = schedule.all_occurrences_enumerator
      first = enumerator.next
      schedule.explain_occurrence(start_time + 3 * IceCube::ONE_DAY)
      rest = 4.times.map { enumerator.next }
      expect([first] + rest).to eq (0..4).map { |i| start_time + i * IceCube::ONE_DAY }
    end

    it "does not consume COUNT usage on the schedule's rules" do
      rule = IceCube::Rule.daily.count(2)
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule rule
      end
      schedule.explain_occurrence(start_time)
      expect(rule.uses).to eq 0
      expect(schedule.first(2)).to eq [start_time, start_time + IceCube::ONE_DAY]
    end

    it "raises ArgumentError without a time" do
      schedule = IceCube::Schedule.new(start_time)
      expect { schedule.explain_occurrence(nil) }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for an invalid budget" do
      schedule = IceCube::Schedule.new(start_time)
      expect { schedule.explain_occurrence(start_time, budget: -1) }.to raise_error(ArgumentError)
      expect { schedule.explain_occurrence(start_time, budget: "lots") }.to raise_error(ArgumentError)
    end

    it "agrees with occurs_at? for times before the start time" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
      end
      before = start_time - IceCube::ONE_DAY
      expect(schedule.explain_occurrence(before).occurs?).to be false
      expect(schedule.occurs_at?(before)).to be false
    end

    it "exposes a hash representation" do
      schedule = IceCube::Schedule.new(start_time) do |s|
        s.add_recurrence_rule IceCube::Rule.daily
      end
      explanation = schedule.explain_occurrence(start_time)
      expect(explanation.to_h).to eq(
        time: start_time,
        occurs: true,
        status: :complete,
        provided_by: [{type: :rrule, index: 0, rule: schedule.recurrence_rules.first}],
        excluded_by: [],
        occurrence_time: start_time,
        steps: 1,
        budget: nil
      )
    end

    describe "cross-checking against point-by-point enumeration" do
      def cross_check(schedule, times)
        times.each do |time|
          explanation = schedule.explain_occurrence(time)
          expect(explanation).to be_complete
          expect(explanation.occurs?).to eq(schedule.occurs_at?(time)),
            "mismatch at #{time.inspect}: #{explanation.to_h.inspect}"
          expect(explanation.occurs?).to eq(
            explanation.provided_by.any? && explanation.excluded_by.empty?
          )
        end
      end

      it "matches for a daily rule with an extime" do
        schedule = IceCube::Schedule.new(start_time) do |s|
          s.add_recurrence_rule IceCube::Rule.daily
          s.add_exception_time start_time + 2 * IceCube::ONE_DAY
        end
        times = (0...14).map { |i| start_time + i * IceCube::ONE_HOUR * 6 }
        cross_check(schedule, times)
      end

      it "matches for overlapping rules with an exception rule" do
        schedule = IceCube::Schedule.new(start_time) do |s|
          s.add_recurrence_rule IceCube::Rule.daily
          s.add_recurrence_rule IceCube::Rule.weekly.day(:monday, :wednesday)
          s.add_exception_rule IceCube::Rule.weekly.day(:wednesday)
        end
        times = (0...28).map { |i| start_time + i * IceCube::ONE_HOUR * 12 }
        cross_check(schedule, times)
      end

      it "matches for a counted rule" do
        schedule = IceCube::Schedule.new(start_time) do |s|
          s.add_recurrence_rule IceCube::Rule.daily.count(4)
        end
        times = (0...10).map { |i| start_time + i * IceCube::ONE_DAY }
        cross_check(schedule, times)
      end

      it "matches for a monthly BYSETPOS rule" do
        schedule = IceCube::Schedule.new(start_time) do |s|
          s.add_recurrence_rule IceCube::Rule.monthly.day(:monday).by_set_pos(1, -1)
        end
        times = (0...60).map { |i| start_time + i * IceCube::ONE_DAY }
        cross_check(schedule, times)
      end

      it "matches for recurrence times only, including fractional seconds" do
        fractional = start_time + Rational(1, 3)
        schedule = IceCube::Schedule.new(fractional) do |s|
          s.add_recurrence_time fractional + 2 * IceCube::ONE_DAY
          s.add_recurrence_time fractional + 5 * IceCube::ONE_DAY
        end
        times = (0...14).map { |i| fractional + i * IceCube::ONE_HOUR * 12 }
        times += [start_time, fractional, fractional + 2 * IceCube::ONE_DAY]
        cross_check(schedule, times)
      end
    end
  end
end
