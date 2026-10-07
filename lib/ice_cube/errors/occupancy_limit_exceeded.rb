module IceCube
  # Raised by IceCube::Occupancy.query when the number of occurrences
  # examined exceeds the given max_occurrences limit. The query is
  # aborted rather than returning a partial result that would look
  # complete.
  class OccupancyLimitExceeded < StandardError
  end
end
