module IceCube
  # Explains why a specific time is (or is not) an occurrence of a Schedule.
  #
  # Built by Schedule#explain_occurrence. Reports which recurrence rules or
  # rtimes provide the time, which exception rules or extimes exclude it, and
  # whether the time ultimately belongs to the schedule. Rules are identified
  # by stable indexes into Schedule#recurrence_rules, #recurrence_times,
  # #exception_rules and #exception_times so that two similar rules can be
  # told apart.
  #
  # COUNT-bounded recurrence rules are resolved by enumerating their
  # occurrences from the schedule start on private copies of the rules, so
  # querying never advances a schedule that is being iterated. Those scans
  # are bounded by a budget of enumeration steps; when the budget is
  # exhausted the rule is reported as unresolved and the explanation is
  # marked incomplete instead of claiming the time is definitely absent.
  #
  # Exception rules are probed directly at the time, mirroring how the
  # schedule itself applies them during enumeration.
  class OccurrenceExplanation
    # Default number of enumeration steps shared by all COUNT-bounded rule
    # scans in a single explanation.
    DEFAULT_BUDGET = 1_000

    # Identifies a single source within the schedule: a recurrence rule
    # (:rrule), a recurrence time (:rtime), the implicit start occurrence
    # (:start_time), an exception rule (:exrule) or an exception time
    # (:extime).
    class Reference
      include Comparable

      attr_reader :type, :index, :source

      def initialize(type, index, source)
        @type = type
        @index = index
        @source = source
      end

      def provider?
        type == :rrule || type == :rtime || type == :start_time
      end

      def excluder?
        !provider?
      end

      def <=>(other)
        [type.to_s, index || -1] <=> [other.type.to_s, other.index || -1]
      end

      def ==(other)
        other.is_a?(Reference) && type == other.type && index == other.index
      end
      alias_method :eql?, :==

      def hash
        [type, index].hash
      end

      def to_h
        {type: type, index: index, source: source}
      end

      def inspect
        "#<IceCube::OccurrenceExplanation::Reference #{type}[#{index}]>"
      end
    end

    attr_reader :schedule, :time, :providers, :excluders, :unresolved

    def initialize(schedule, time, budget: DEFAULT_BUDGET)
      @schedule = schedule
      @start_time = schedule.start_time
      @time = TimeUtil.match_zone(time, @start_time) or
        raise ArgumentError, "Time required, got #{time.inspect}"
      @remaining_budget = budget
      @providers = []
      @excluders = []
      @unresolved = []
      evaluate!
    end

    # Whether the time belongs to the schedule: true or false when every
    # rule could be resolved, nil when the scan budget ran out first.
    def included?
      return false unless excluders.empty?
      if providers.any?
        unresolved.any?(&:excluder?) ? nil : true
      else
        unresolved.any?(&:provider?) ? nil : false
      end
    end

    # Whether any exception rule or extime excludes the time.
    def excluded?
      excluders.any?
    end

    # Whether every rule was resolved within the budget.
    def complete?
      unresolved.empty?
    end

    # One of :included, :excluded, :not_provided or :unknown.
    def status
      case included?
      when true then :included
      when false then excluders.any? ? :excluded : :not_provided
      else :unknown
      end
    end

    def to_h
      {
        time: time,
        status: status,
        included: included?,
        complete: complete?,
        providers: providers.map(&:to_h),
        excluders: excluders.map(&:to_h),
        unresolved: unresolved.map(&:to_h)
      }
    end

    private

    def evaluate!
      evaluate_providers
      evaluate_excluders
    end

    def evaluate_providers
      if schedule.recurrence_rules.empty? && time == @start_time
        providers << Reference.new(:start_time, nil, @start_time)
      end
      schedule.recurrence_rules.each_with_index do |rule, index|
        add_verdict providers, Reference.new(:rrule, index, rule), rule_verdict(rule, exact: true)
      end
      schedule.recurrence_times.each_with_index do |rtime, index|
        providers << Reference.new(:rtime, index, rtime) if rtime == time
      end
    end

    def evaluate_excluders
      schedule.exception_rules.each_with_index do |rule, index|
        verdict = probe_rule(rule, exact: false, ignore_count: true)
        add_verdict excluders, Reference.new(:exrule, index, rule), verdict
      end
      schedule.exception_times.each_with_index do |extime, index|
        excluders << Reference.new(:extime, index, extime) if extime.to_i == time.to_i
      end
    end

    def add_verdict(list, reference, verdict)
      case verdict
      when :unknown then unresolved << reference
      when true then list << reference
      end
    end

    def rule_verdict(rule, exact:)
      rule.full_required? ? scan_rule(rule, exact: exact) : probe_rule(rule, exact: exact)
    end

    def probe_rule(rule, exact:, ignore_count: false)
      if exact && TimeUtil.subsec(time) != TimeUtil.subsec(@start_time)
        return false
      end
      copy = ignore_count ? independent_copy_without_count(rule) : fresh_copy(rule)
      candidate = copy.next_time(time, @start_time, time, increment: false)
      !!(candidate && candidate.to_i == time.to_i)
    rescue StopIteration
      false
    end

    def scan_rule(rule, exact:)
      return :unknown unless budget_remaining?
      copy = independent_copy_without_count(rule)
      limit = rule.occurrence_count
      seen = 0
      t = @start_time
      loop do
        return :unknown unless spend_budget!
        candidate = begin
          copy.next_time(t, @start_time, time, increment: false)
        rescue StopIteration
          return false
        end
        return false if candidate.nil?
        seen += 1
        return false if limit && seen > limit
        matched = exact ? candidate == time : candidate.to_i == time.to_i
        return true if matched
        t = candidate + 1
      end
    end

    def independent_copy_without_count(rule)
      copy = fresh_copy(rule)
      copy.instance_variable_set(:@validations, rule.validations.dup)
      copy.replace_validations_for(:count, nil)
      copy
    end

    def fresh_copy(rule)
      copy = rule.dup
      copy.reset
      copy
    end

    def budget_remaining?
      @remaining_budget.nil? || @remaining_budget > 0
    end

    def spend_budget!
      return true if @remaining_budget.nil?
      return false if @remaining_budget <= 0
      @remaining_budget -= 1
      true
    end
  end
end
