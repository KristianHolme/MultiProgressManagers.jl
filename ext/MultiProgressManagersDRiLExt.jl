module MultiProgressManagersDRiLExt

using MultiProgressManagers
import MultiProgressManagers: create_dril_callback
import DRiL
using Distributed

export DRiLWorkerProgressCallback

mutable struct DRiLWorkerProgressCallback <: DRiL.AbstractCallback
    worker_channel::RemoteChannel{Channel{ProgressMessage}}
end


function DRiL.on_training_start(callback::DRiLWorkerProgressCallback, locals::Dict)
    worker_channel = callback.worker_channel
    total_steps = locals[:total_steps]
    env = locals[:env]
    n_envs = DRiL.number_of_envs(env)
    @assert total_steps % n_envs == 0 "total_steps must be divisible by number of environments"
    msg = ProgressStart(myid(), total_steps, "Worker $(myid())")
    put!(worker_channel, msg)
    return true
end

function DRiL.on_step(callback::DRiLWorkerProgressCallback, locals::Dict)
    worker_channel = callback.worker_channel
    env = locals[:env]
    n_envs = DRiL.number_of_envs(env)
    msg = ProgressStepUpdate(myid(), n_envs, "")
    put!(worker_channel, msg)
    return true
end

function DRiL.on_training_end(callback::DRiLWorkerProgressCallback, locals::Dict)
    worker_channel = callback.worker_channel
    put!(worker_channel, ProgressFinished(myid(), "Finished training run!"))
    return true
end

"""
    create_dril_callback(worker_channel)

Create a DRiL callback for progress tracking.

# Arguments
- `worker_channel::RemoteChannel`: The worker channel from a MultiProgressManager

# Returns
- `DRiLWorkerProgressCallback`: Callback instance for use with DRiL training

# Example
```julia
using DRiL
manager = MultiProgressManager(10)
callback = create_dril_callback(manager.worker_channel)
```
"""
function create_dril_callback(worker_channel::RemoteChannel{Channel{ProgressMessage}})
    return DRiLWorkerProgressCallback(worker_channel)
end

end # module MultiProgressManagersDRiLExt
