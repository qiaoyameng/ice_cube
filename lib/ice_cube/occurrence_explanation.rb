module IceCube
  # The result of Schedule#explain_occurrence.
  #
  # Describes which recurrence rules or recurrence times provide a given
  # time, which exception rules or exception times exclude it, and whether
  # the time ultimately falls on the schedule.
  #
  # Providers and excluders are identified by their stable index within the
  # schedule's #recurrence_rules, #recurrence_times, #exception_rules and
  # #exception_times lists, so that two similar rules can be told apart:
  #
  #   {type: :rrule, index: 0, rule: ...}   # Schedule#recurrence_rules[index]
  #   {type: :rtime, index: 1, time: ...}   # Schedule#recurrence_times[index]
  #   {type: :implicit_start}               # the schedule's own start_time
  #   {type: :exrule, index: 0, rule: ...}  # Schedule#exception_rules[index]
  #   {type: :extime, index: 2, time: ...}  # Schedule#exception_times[index]
  #
  class OccurrenceExplanation
    # The queried time, matched to the schedule's zone.
    attr_reader :time

    # The occurrence start time that was matched, if any. This can differ
    # from #time by sub-second grid alignment with the schedule's start_time.
    attr_reader :occurrence_time

    # Array of sources providing the occurrence (see class documentation).
    attr_reader :provided_by

    # Array of sources excluding the occurrence (see class documentation).
    attr_reader :excluded_by

    # :complete when the answer is definitive, :incomplete when the scan
    # budget was exhausted before the time could be reached.
    attr_reader :status

    # The number of enumeration steps performed while explaining.
    attr_reader :steps

    # The scan budget that was in effect, if any.
    attr_reader :budget

    def initialize(time:, occurs:, status:, provided_by:, excluded_by:, occurrence_time:, steps:, budget:)
      @time = time
      @occurs = occurs
      @status = status
      @provided_by = provided_by
      @excluded_by = excluded_by
      @occurrence_time = occurrence_time
      @steps = steps
      @budget = budget
    end

    # Whether the time belongs to the schedule. Returns nil when the
    # explanation is incomplete rather than guessing.
    def occurs?
      @occurs
    end

    def complete?
      status == :complete
    end

    def incomplete?
      status == :incomplete
    end

    def to_h
      {
        time: time,
        occurs: occurs?,
        status: status,
        provided_by: provided_by,
        excluded_by: excluded_by,
        occurrence_time: occurrence_time,
        steps: steps,
        budget: budget
      }
    end
  end
end
