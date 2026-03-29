# Drill.jl integration: stub API in the base module; implementation in MultiProgressManagersDrillExt.

"""
    create_drill_callback(task::ProgressTask)

Return a Drill training callback that forwards progress for `task` to the experiment database.

Requires the Drill.jl package: load it with `using Drill` (or add it to your environment) so the
package extension is active, then call this function.

See also: [`get_task`](@ref) with `type = :remote` for distributed workers.
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
