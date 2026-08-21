const _UTC_TZ = tz"UTC"
const _LOCAL_TZ_CACHE = Ref{TimeZone}()

function _cached_localzone()
    if !isassigned(_LOCAL_TZ_CACHE)
        _LOCAL_TZ_CACHE[] = localzone()
    end
    return _LOCAL_TZ_CACHE[]
end

"""
Convert a UTC instant (`DateTime` from `unix2datetime` / DB) to naive local wall-clock
time for display, using the system zone from TimeZones.jl (`localzone()`).
"""
function instant_to_local_wall_datetime(dt::DateTime)::DateTime
    z = ZonedDateTime(dt, _UTC_TZ)
    return DateTime(astimezone(z, _cached_localzone()))
end
