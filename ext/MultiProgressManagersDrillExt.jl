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
    task_number = callback.task.task_number
    msg = ProgressUpdate(task_number, 0, total_steps, "Worker $(task_number)")
    put!(callback.task.channel, msg)
    return true
end

function Drill.on_step(callback::DrillWorkerProgressCallback, locals::Dict)
    env = locals[:env]
    n_envs = Drill.number_of_envs(env)
    callback._current_step += n_envs
    task_number = callback.task.task_number
    total_steps = callback._total_steps
    msg = ProgressUpdate(task_number, callback._current_step, total_steps, "")
    put!(callback.task.channel, msg)
    return true
end

function Drill.on_training_end(callback::DrillWorkerProgressCallback, locals::Dict)
    put!(callback.task.channel, TaskFinished(callback.task.task_number))
    return true
end

function _create_drill_callback_impl(task::ProgressTask)
    cb = DrillWorkerProgressCallback(task, 0, nothing)
    return cb
end

end # module MultiProgressManagersDrillExt
