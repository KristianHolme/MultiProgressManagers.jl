module MultiProgressManagersDrillExt

using MultiProgressManagers
import Drill

export DrillWorkerProgressCallback

mutable struct DrillWorkerProgressCallback{T<:ProgressTask} <: Drill.AbstractCallback
    task::T
    _current_step::Int
    _total_steps::Union{Int, Nothing}
end

function Drill.on_training_start(callback::DrillWorkerProgressCallback, locals::Dict)
    total_steps = locals[:total_steps]
    env = locals[:env]
    n_envs = Drill.number_of_envs(env)
    @assert total_steps % n_envs == 0 "total_steps must be divisible by number of environments"
    callback._total_steps = total_steps
    callback._current_step = 0
    MultiProgressManagers.update!(callback.task; step = 0, total_steps = total_steps, message = "Worker $(callback.task.task_number)")
    return true
end

function Drill.on_step(callback::DrillWorkerProgressCallback, locals::Dict)
    env = locals[:env]
    n_envs = Drill.number_of_envs(env)
    callback._current_step += n_envs
    MultiProgressManagers.update!(
        callback.task;
        step = callback._current_step,
        total_steps = callback._total_steps,
    )
    return true
end

function Drill.on_training_end(callback::DrillWorkerProgressCallback, locals::Dict)
    MultiProgressManagers.finish!(callback.task)
    return true
end

function _create_drill_callback_impl(task::ProgressTask)
    cb = DrillWorkerProgressCallback(task, 0, nothing)
    return cb
end

end # module MultiProgressManagersDrillExt
