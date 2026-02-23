module MultiProgressManagersDrillExt

using MultiProgressManagers
import MultiProgressManagers: create_dril_callback
import Drill
using Distributed

export DrillWorkerProgressCallback

mutable struct DrillWorkerProgressCallback <: Drill.AbstractCallback
    worker_channel::RemoteChannel{Channel{ProgressMessage}}
end


function Drill.on_training_start(callback::DrillWorkerProgressCallback, locals::Dict)
    worker_channel = callback.worker_channel
    total_steps = locals[:total_steps]
    env = locals[:env]
    n_envs = Drill.number_of_envs(env)
    @assert total_steps % n_envs == 0 "total_steps must be divisible by number of environments"
    msg = ProgressStart(myid(), total_steps, "Worker $(myid())")
    put!(worker_channel, msg)
    return true
end

function Drill.on_step(callback::DrillWorkerProgressCallback, locals::Dict)
    worker_channel = callback.worker_channel
    env = locals[:env]
    n_envs = Drill.number_of_envs(env)
    msg = ProgressStepUpdate(myid(), n_envs, "")
    put!(worker_channel, msg)
    return true
end

function Drill.on_training_end(callback::DrillWorkerProgressCallback, locals::Dict)
    worker_channel = callback.worker_channel
    put!(worker_channel, ProgressFinished(myid(), "Finished training run!"))
    return true
end

"""
    create_dril_callback(worker_channel)

Create a Drill callback for progress tracking.

# Arguments
- `worker_channel::RemoteChannel`: The worker channel from a MultiProgressManager

# Returns
- `DrillWorkerProgressCallback`: Callback instance for use with Drill training

# Example
```julia
using Drill
manager = MultiProgressManager(10)
callback = create_dril_callback(manager.worker_channel)
```
"""
function create_dril_callback(worker_channel::RemoteChannel{Channel{ProgressMessage}})
    return DrillWorkerProgressCallback(worker_channel)
end

end # module MultiProgressManagersDrillExt
