module IceCube
  # Raised when a wall-clock time occurs twice in the target zone of a
  # rezone operation (e.g. it falls into a DST overlap) and the :reject
  # conflict policy is selected.
  class AmbiguousLocalTime < ArgumentError
  end
end
