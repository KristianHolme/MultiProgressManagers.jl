module MultiProgressManagersDrillExt

using MultiProgressManagers
import Drill

export DrillWorkerProgressCallback, create_dril_callback

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

"""
    create_dril_callback(task)

Create a Drill callback for progress tracking.

# Arguments
- `task::ProgressTask`: The progress task from `get_task(manager, task_number, :remote)`

# Returns
- `DrillWorkerProgressCallback`: Callback instance for use with Drill training

# Example
```julia
using MultiProgressManagers
using Drill
manager = ProgressManager("my_study", 10; db_path = default_db_path("my_study"))
task = get_task(manager, 1, :remote)
callback = create_dril_callback(task)
```
"""
function create_dril_callback(task::ProgressTask)
    return DrillWorkerProgressCallback(task, 0, nothing)
end

end # module MultiProgressManagersDrillExt
