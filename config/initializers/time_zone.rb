require "active_support/core_ext/time/zones"

# The zone of every server-side "today" (a request without a `date`, such as
# the health check): TZ, an IANA name such as America/Vancouver, UTC when
# unset. Timestamps are still stored in UTC. An unknown name stops
# the boot rather than silently using UTC.
zone = ENV["TZ"].presence || "UTC"
Time.zone_default = Time.find_zone(zone) || raise(ArgumentError, "TZ=#{zone} is not a known time zone; use an IANA name such as America/Vancouver")
