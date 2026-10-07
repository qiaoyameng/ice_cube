module IceCube
  # Raised when a wall-clock time does not exist in the target zone of a
  # rezone operation (e.g. it falls into a DST gap) and the :reject
  # conflict policy is selected.
  class InvalidLocalTime < ArgumentError
  end
end
