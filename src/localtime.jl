"""
Convert a UTC instant (`DateTime` from `unix2datetime` / DB) to naive local wall-clock
time for display, using the system zone from TimeZones.jl (`localzone()`).
"""
function instant_to_local_wall_datetime(dt::DateTime)::DateTime
    z = ZonedDateTime(dt, tz"UTC")
    return DateTime(astimezone(z, localzone()))
end
