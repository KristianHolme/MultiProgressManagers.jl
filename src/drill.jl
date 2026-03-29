# Drill.jl integration: entry point in the base module; Drill types live in MultiProgressManagersDrillExt.

"""
    create_drill_callback(task::ProgressTask)

Return a Drill training callback that forwards progress for `task` to the experiment database.

Load Drill.jl with `using Drill`, then call this function. For distributed training, obtain `task`
with [`get_task`](@ref) and `type = :remote` (and load `Distributed` as usual).
"""
function create_drill_callback(task::ProgressTask)
    drill_ext = Base.get_extension(MultiProgressManagers, :MultiProgressManagersDrillExt)
    if drill_ext === nothing
        Base.@warn "create_drill_callback requires Drill.jl. Load it with `using Drill` before calling this function."
        throw(
            ArgumentError(
                "The Drill extension is not loaded. Add Drill.jl to your environment and run `using Drill` before calling create_drill_callback.",
            ),
        )
    end
    cb = drill_ext._create_drill_callback_impl(task)
    return cb
end
