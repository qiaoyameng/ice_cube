module IceCube
  class OccurrenceLimitExceeded < StandardError
    attr_reader :occurrence_count

    def initialize(occurrence_count)
      @occurrence_count = occurrence_count
      super("Occurrence limit exceeded after #{occurrence_count} occurrences")
    end
  end

  OccurrenceLimitError = OccurrenceLimitExceeded
end
