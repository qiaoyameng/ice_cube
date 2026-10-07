require File.dirname(__FILE__) + "/../spec_helper"
require "logger"
require "active_support"
require "active_support/time"

module IceCube
  describe Schedule, "#rezone" do
    # Asia/Kathmandu is UTC+05:45 (a non-whole-hour offset) and has no DST
    let(:new_york) { "America/New_York" }
    let(:kathmandu) { "Asia/Kathmandu" }

    def zone(name)
      Time.find_zone!(name)
    end

    # Spans the 2024-03-10 spring-forward in America/New_York
    def build_schedule
      schedule = Schedule.new(zone(new_york).local(2024, 3, 4, 9, 0, 0), duration: ONE_HOUR)
      schedule.add_recurrence_rule Rule.weekly.day(:monday).count(3).until(zone(new_york).local(2024, 3, 31, 12, 0, 0))
      schedule.add_recurrence_time zone(new_york).local(2024, 3, 5, 9, 0, 0)
      schedule.add_exception_time zone(new_york).local(2024, 3, 11, 9, 0, 0)
      schedule
    end

    describe "mode: :instant" do
      it "preserves the real instant of the start time and duration" do
        rezoned = build_schedule.rezone(kathmandu, mode: :instant)
        expect(rezoned.start_time).to eq zone(kathmandu).local(2024, 3, 4, 19, 45, 0)
        expect(rezoned.start_time.utc_offset).to eq(20700) # +05:45
        expect(rezoned.duration).to eq ONE_HOUR
        expect(rezoned.end_time).to eq zone(kathmandu).local(2024, 3, 4, 20, 45, 0)
      end

      it "preserves the real instant of rtimes, extimes and rule UNTIL" do
        schedule = build_schedule
        rezoned = schedule.rezone(kathmandu, mode: :instant)
        expect(rezoned.rtimes).to eq [zone(kathmandu).local(2024, 3, 5, 19, 45, 0)]
        expect(rezoned.extimes).to eq [zone(kathmandu).local(2024, 3, 11, 18, 45, 0)]
        until_time = rezoned.recurrence_rules.first.until_time
        expect(until_time).to eq schedule.recurrence_rules.first.until_time
        expect(until_time.time_zone.name).to eq kathmandu
      end

      it "keeps weekly occurrences on the same instants' local reading in the new zone across DST" do
        rezoned = build_schedule.rezone(kathmandu, mode: :instant)
        # Kathmandu has no DST, so the weekly rule stays on 19:45 +0545
        # even while New York springs forward
        expect(rezoned.all_occurrences).to eq [
          zone(kathmandu).local(2024, 3, 4, 19, 45, 0),
          zone(kathmandu).local(2024, 3, 5, 19, 45, 0),
          zone(kathmandu).local(2024, 3, 11, 19, 45, 0),
          zone(kathmandu).local(2024, 3, 18, 19, 45, 0)
        ]
      end
    end

    describe "mode: :wall" do
      it "preserves the wall-clock reading of the start time and end time" do
        rezoned = build_schedule.rezone(kathmandu, mode: :wall)
        expect(rezoned.start_time).to eq zone(kathmandu).local(2024, 3, 4, 9, 0, 0)
        expect(rezoned.end_time).to eq zone(kathmandu).local(2024, 3, 4, 10, 0, 0)
      end

      it "preserves the wall-clock reading of rtimes, extimes and rule UNTIL" do
        rezoned = build_schedule.rezone(kathmandu, mode: :wall)
        expect(rezoned.rtimes).to eq [zone(kathmandu).local(2024, 3, 5, 9, 0, 0)]
        expect(rezoned.extimes).to eq [zone(kathmandu).local(2024, 3, 11, 9, 0, 0)]
        expect(rezoned.recurrence_rules.first.until_time).to eq zone(kathmandu).local(2024, 3, 31, 12, 0, 0)
      end

      it "keeps weekly occurrences on the same wall-clock reading across DST" do
        rezoned = build_schedule.rezone(kathmandu, mode: :wall)
        # The extime still falls on the Mar 11 occurrence in wall mode
        expect(rezoned.all_occurrences).to eq [
          zone(kathmandu).local(2024, 3, 4, 9, 0, 0),
          zone(kathmandu).local(2024, 3, 5, 9, 0, 0),
          zone(kathmandu).local(2024, 3, 18, 9, 0, 0)
        ]
      end

      it "compares both modes over a DST transition week" do
        schedule = build_schedule
        instant_occurrences = schedule.rezone(kathmandu, mode: :instant).all_occurrences
        wall_occurrences = schedule.rezone(kathmandu, mode: :wall).all_occurrences
        expect(instant_occurrences.map { |t| t.strftime("%H:%M") }.uniq).to eq ["19:45"]
        expect(wall_occurrences.map { |t| t.strftime("%H:%M") }.uniq).to eq ["09:00"]
        # The original New York schedule keeps 09:00 local while its UTC
        # instant shifts by one hour at the spring-forward
        expect(schedule.all_occurrences.map { |t| t.strftime("%H:%M") }.uniq).to eq ["09:00"]
      end
    end

    describe "wall-clock conflicts in the target zone" do
      # 2024-03-10 02:30 does not exist in America/New_York (spring forward)
      let(:gap_schedule) { Schedule.new(zone("UTC").local(2024, 3, 10, 2, 30, 0)) }
      # 2024-11-03 01:30 occurs twice in America/New_York (fall back)
      let(:overlap_schedule) { Schedule.new(zone("UTC").local(2024, 11, 3, 1, 30, 0)) }

      it "rejects a nonexistent wall time by default" do
        expect { gap_schedule.rezone(new_york, mode: :wall) }
          .to raise_error(InvalidLocalTime)
        expect { gap_schedule.rezone(new_york, mode: :wall, on_invalid: :reject) }
          .to raise_error(InvalidLocalTime)
      end

      it "maps a nonexistent wall time to the nearest earlier valid time" do
        rezoned = gap_schedule.rezone(new_york, mode: :wall, on_invalid: :earlier)
        expect(rezoned.start_time).to eq zone(new_york).local(2024, 3, 10, 1, 59, 59)
      end

      it "maps a nonexistent wall time to the nearest later valid time" do
        rezoned = gap_schedule.rezone(new_york, mode: :wall, on_invalid: :later)
        expect(rezoned.start_time).to eq zone(new_york).local(2024, 3, 10, 3, 0, 0)
      end

      it "rejects an ambiguous wall time by default" do
        expect { overlap_schedule.rezone(new_york, mode: :wall) }
          .to raise_error(AmbiguousLocalTime)
        expect { overlap_schedule.rezone(new_york, mode: :wall, on_ambiguous: :reject) }
          .to raise_error(AmbiguousLocalTime)
      end

      it "maps an ambiguous wall time to the earlier occurrence" do
        rezoned = overlap_schedule.rezone(new_york, mode: :wall, on_ambiguous: :earlier)
        expect(rezoned.start_time).to eq Time.utc(2024, 11, 3, 5, 30, 0)
        expect(rezoned.start_time.utc_offset).to eq(-4 * ONE_HOUR) # EDT
      end

      it "maps an ambiguous wall time to the later occurrence" do
        rezoned = overlap_schedule.rezone(new_york, mode: :wall, on_ambiguous: :later)
        expect(rezoned.start_time).to eq Time.utc(2024, 11, 3, 6, 30, 0)
        expect(rezoned.start_time.utc_offset).to eq(-5 * ONE_HOUR) # EST
      end

      it "applies the conflict policies to rtimes, extimes and UNTIL as well" do
        schedule = Schedule.new(zone("UTC").local(2024, 3, 1, 12, 0, 0))
        schedule.add_recurrence_time zone("UTC").local(2024, 3, 10, 2, 30, 0)
        schedule.add_exception_time zone("UTC").local(2024, 11, 3, 1, 30, 0)
        schedule.add_recurrence_rule Rule.daily.until(zone("UTC").local(2024, 3, 10, 2, 30, 0))
        rezoned = schedule.rezone(new_york, mode: :wall,
          on_invalid: :later, on_ambiguous: :earlier)
        expect(rezoned.rtimes).to eq [zone(new_york).local(2024, 3, 10, 3, 0, 0)]
        expect(rezoned.extimes.first.utc_offset).to eq(-4 * ONE_HOUR)
        expect(rezoned.recurrence_rules.first.until_time)
          .to eq zone(new_york).local(2024, 3, 10, 3, 0, 0)
      end
    end

    describe "rule interpretation in the new zone" do
      it "keeps the weekly phase and COUNT against the rezoned start time" do
        schedule = Schedule.new(zone(new_york).local(2024, 3, 4, 9, 0, 0))
        schedule.add_recurrence_rule Rule.weekly(2).day(:monday).count(3)
        rezoned = schedule.rezone(kathmandu, mode: :wall)
        expect(rezoned.all_occurrences).to eq [
          zone(kathmandu).local(2024, 3, 4, 9, 0, 0),
          zone(kathmandu).local(2024, 3, 18, 9, 0, 0),
          zone(kathmandu).local(2024, 4, 1, 9, 0, 0)
        ]
      end

      it "keeps plain Date constraints as dates interpreted by the new schedule" do
        schedule = Schedule.new(zone(new_york).local(2024, 3, 4, 9, 0, 0))
        schedule.add_recurrence_rule Rule.daily.until(Date.new(2024, 3, 6))
        rezoned = schedule.rezone(kathmandu, mode: :wall)
        expect(rezoned.recurrence_rules.first.until_time).to eq Date.new(2024, 3, 6)
        expect(rezoned.all_occurrences).to eq [
          zone(kathmandu).local(2024, 3, 4, 9, 0, 0),
          zone(kathmandu).local(2024, 3, 5, 9, 0, 0),
          zone(kathmandu).local(2024, 3, 6, 9, 0, 0)
        ]
      end
    end

    describe "the original schedule" do
      it "is left unchanged and usable" do
        schedule = build_schedule
        before = schedule.to_hash
        schedule.rezone(kathmandu, mode: :wall)
        schedule.rezone(kathmandu, mode: :instant)
        expect(schedule.to_hash).to eq before
        expect(schedule.all_occurrences).to eq [
          zone(new_york).local(2024, 3, 4, 9, 0, 0),
          zone(new_york).local(2024, 3, 5, 9, 0, 0),
          zone(new_york).local(2024, 3, 18, 9, 0, 0)
        ]
      end

      it "shares no rule state with the rezoned schedule" do
        schedule = build_schedule
        rezoned = schedule.rezone(kathmandu, mode: :instant)
        rezoned.recurrence_rules.first.count(1)
        expect(schedule.recurrence_rules.first.terminating?).to be_truthy
        expect(schedule.all_occurrences.size).to eq 3
      end
    end

    describe "serialization" do
      it "survives a hash round trip in both modes" do
        schedule = build_schedule
        [schedule.rezone(kathmandu, mode: :instant), schedule.rezone(kathmandu, mode: :wall)].each do |rezoned|
          restored = Schedule.from_hash(rezoned.to_hash)
          expect(restored.start_time).to eq rezoned.start_time
          expect(restored.all_occurrences).to eq rezoned.all_occurrences
        end
      end

      it "survives a YAML round trip in both modes" do
        schedule = build_schedule
        [schedule.rezone(kathmandu, mode: :instant), schedule.rezone(kathmandu, mode: :wall)].each do |rezoned|
          restored = Schedule.from_yaml(rezoned.to_yaml)
          expect(restored.start_time).to eq rezoned.start_time
          expect(restored.all_occurrences).to eq rezoned.all_occurrences
        end
      end

      it "survives a hash round trip after wall-clock conflict resolution" do
        schedule = Schedule.new(zone("UTC").local(2024, 3, 10, 2, 30, 0))
        rezoned = schedule.rezone(new_york, mode: :wall, on_invalid: :later)
        restored = Schedule.from_hash(rezoned.to_hash)
        expect(restored.start_time).to eq zone(new_york).local(2024, 3, 10, 3, 0, 0)
      end
    end

    describe "with plain Time objects" do
      it "converts to plain Times carrying the target zone offset" do
        schedule = Schedule.new(Time.utc(2024, 3, 4, 14, 0, 0))
        instant = schedule.rezone(kathmandu, mode: :instant)
        expect(instant.start_time).to eq Time.utc(2024, 3, 4, 14, 0, 0)
        expect(instant.start_time.utc_offset).to eq 20700
        wall = schedule.rezone(kathmandu, mode: :wall)
        expect(wall.start_time).to eq Time.new(2024, 3, 4, 14, 0, 0, "+05:45")
        expect(wall.start_time.utc_offset).to eq 20700
      end
    end

    describe "option validation" do
      it "requires a known mode" do
        expect { build_schedule.rezone(kathmandu, mode: :bogus) }
          .to raise_error(ArgumentError, /mode/i)
      end

      it "requires known conflict policies" do
        expect { build_schedule.rezone(kathmandu, mode: :wall, on_invalid: :bogus) }
          .to raise_error(ArgumentError, /on_invalid/)
        expect { build_schedule.rezone(kathmandu, mode: :wall, on_ambiguous: :bogus) }
          .to raise_error(ArgumentError, /on_ambiguous/)
      end
    end
  end
end
