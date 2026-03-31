"""
Convert a `DateTime` that represents a UTC instant (as produced by `unix2datetime`)
to the same instant expressed as naive local wall-clock time for display.
"""
function instant_to_local_wall_datetime(dt::DateTime)::DateTime
    unix_seconds = round(Int64, datetime2unix(dt))
    tm = Base.Libc.TmStruct()
    ccall(
        :localtime_r,
        Ptr{Base.Libc.TmStruct},
        (Ref{Int64}, Ref{Base.Libc.TmStruct}),
        Ref(unix_seconds),
        Ref(tm),
    )
    return DateTime(
        tm.year + 1900,
        tm.month + 1,
        tm.mday,
        tm.hour,
        tm.min,
        tm.sec,
    )
end
