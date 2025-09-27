module MultiProgressManagersDRiLExt

using MultiProgressManagers
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

end # module MultiProgressManagersDRiLExt
