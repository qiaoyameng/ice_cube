require File.dirname(__FILE__) + "/../spec_helper"

module IceCube
  describe Schedule, "enumerator isolation" do
    def drain(enumerator)
      occurrences = []
      loop { occurrences << enumerator.next }
      occurrences
    end

    let(:start) { Time.utc(2020, 1, 1) }

    it "keeps separate COUNT progress for interleaved all_occurrences_enumerators" do
      schedule = Schedule.new(start)
      schedule.add_recurrence_rule Rule.daily.count(5)
      expected = schedule.all_occurrences

      first = schedule.all_occurrences_enumerator
      second = schedule.all_occurrences_enumerator

      expect(first.next).to eq(expected.first)
      expect(drain(second)).to eq(expected)
      expect(drain(first)).to eq(expected[1..])
    end

    it "isolates COUNT across multiple recurrence rules" do
      schedule = Schedule.new(start)
      schedule.add_recurrence_rule Rule.daily.count(5)
      schedule.add_recurrence_rule Rule.weekly.count(3)
      expected = schedule.all_occurrences

      first = schedule.all_occurrences_enumerator
      second = schedule.all_occurrences_enumerator
      first.next
      expect(drain(second)).to eq(expected)
    end

    it "isolates exception rule COUNT progress" do
      schedule = Schedule.new(start)
      schedule.add_recurrence_rule Rule.daily.count(30)
      schedule.add_exception_rule Rule.weekly.day(:saturday, :sunday).count(6)
      expected = schedule.all_occurrences

      first = schedule.all_occurrences_enumerator
      second = schedule.all_occurrences_enumerator
      first.next
      expect(drain(second)).to eq(expected)
      expect(first.next).to eq(expected[1])
      expect(drain(first)).to eq(expected[2..])
    end

    it "isolates BYSETPOS + COUNT combinations" do
      schedule = Schedule.new(Time.utc(2020, 1, 1, 8))
      schedule.add_recurrence_rule(
        Rule.monthly.day_of_week(monday: [1, -1]).count(8)
      )
      expected = schedule.all_occurrences

      first = schedule.all_occurrences_enumerator
      second = schedule.all_occurrences_enumerator
      first.next
      expect(drain(second)).to eq(expected)
    end

    it "does not truncate an in-flight enumeration when queries are made" do
      schedule = Schedule.new(start)
      schedule.add_recurrence_rule Rule.daily.count(5)
      expected = schedule.all_occurrences

      enumerator = schedule.all_occurrences_enumerator
      seen = [enumerator.next]
      schedule.occurrences(start + 10 * ONE_DAY)
      schedule.occurring_at?(expected[2])
      schedule.occurs_on?(expected[3].to_date)
      expect(seen.concat(drain(enumerator))).to eq(expected)
    end

    it "continues one enumerator when another is abandoned after raising" do
      schedule = Schedule.new(start)
      schedule.add_recurrence_rule Rule.daily.count(5)
      expected = schedule.all_occurrences

      first = schedule.all_occurrences_enumerator
      second = schedule.all_occurrences_enumerator
      expect(first.next).to eq(expected.first)
      expect(second.next).to eq(expected.first)

      begin
        raise "consumer failure"
      rescue RuntimeError
        # the second enumerator is abandoned with its internal progress intact
      end

      expect(drain(first)).to eq(expected[1..])
      expect(drain(second)).to eq(expected[1..])
    end

    it "leaves the schedule's rules unmodified by enumeration" do
      schedule = Schedule.new(start)
      rule = Rule.daily.count(3)
      schedule.add_recurrence_rule rule
      schedule.all_occurrences
      schedule.all_occurrences
      expect(schedule.all_occurrences.size).to eq(3)
      expect(rule.to_hash).to eq(Rule.from_hash(rule.to_hash).to_hash)
    end
  end
end
