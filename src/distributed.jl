"""
    Distributed worker support for MultiProgressManagers.

This module provides functions for coordinating progress across distributed Julia workers.
Workers communicate with the master process via RemoteChannels, and the master
writes all updates to the database.
"""
module DistributedSupport

using Distributed
using ..MultiProgressManagers: ProgressManager, ProgressMessage, ProgressStart, ProgressUpdate, 
                                ProgressComplete, ProgressError

export create_worker_task, worker_update!, worker_done!, worker_failed!

"""
    create_worker_task(manager::ProgressManager) -> Task

Create a background task that listens for progress messages from workers
and writes them to the database.

This should be run on the master process.
"""
function create_worker_task(manager::ProgressManager)
    if manager.worker_channel === nothing
        error("Worker channel not initialized. Create manager with worker_count > 1 for distributed mode.")
    end
    
    @async begin
        try
            while isopen(manager.worker_channel)
                msg = take!(manager.worker_channel)
                _handle_worker_message!(manager, msg)
            end
        catch e
            if !(e isa InvalidStateException)
                @error "Worker task error" exception=(e, catch_backtrace())
                rethrow()
            end
        end
    end
end

"""
    worker_update!(worker_channel::RemoteChannel, current_step::Int; 
                  info::String="", worker_id::Int=myid())

Called from a worker process to report progress.

# Example
```julia
@everywhere using MultiProgressManagers

@sync @distributed for i in 1:n
    # ... do work ...
    worker_update!(channel, i; info="Worker \$(myid()) step \$i")
end
```
"""
function worker_update!(worker_channel::RemoteChannel, current_step::Int;
                       info::String="", worker_id::Int=myid())
    msg = ProgressUpdate(worker_id, current_step, info, time())
    put!(worker_channel, msg)
    return nothing
end

"""
    worker_done!(worker_channel::RemoteChannel, message::String="Worker completed";
                worker_id::Int=myid())

Called from a worker process to signal completion.
"""
function worker_done!(worker_channel::RemoteChannel, message::String="Worker completed";
                     worker_id::Int=myid())
    msg = ProgressComplete(worker_id, message)
    put!(worker_channel, msg)
    return nothing
end

"""
    worker_failed!(worker_channel::RemoteChannel, error_message::String;
                  worker_id::Int=myid())

Called from a worker process to report a failure.
"""
function worker_failed!(worker_channel::RemoteChannel, error_message::String;
                       worker_id::Int=myid())
    msg = ProgressError(worker_id, error_message)
    put!(worker_channel, msg)
    return nothing
end

# === Internal Functions ===

function _handle_worker_message!(manager, msg::ProgressStart)
    # Record worker assignment
    # Workers report their total steps and description
    @info "Worker $(msg.worker_id) started: $(msg.description) ($(msg.total_steps) steps)"
end

function _handle_worker_message!(manager, msg::ProgressUpdate)
    # Aggregate worker progress into overall progress
    # For now, we just record the update with worker attribution
    tls = task_local_storage()
    if !haskey(tls, :mpm_db_handle)
        tls[:mpm_db_handle] = Database.init_db!(manager.db_path)
    end
    db_handle = tls[:mpm_db_handle]
    
    elapsed = time() - manager.start_time
    elapsed_ms = round(Int, elapsed * 1000)
    
    Database.record_progress!(db_handle, manager.experiment_id, msg.current_step, elapsed_ms;
                             info="Worker $(msg.worker_id)", worker_id=msg.worker_id)
    
    manager.last_step = msg.current_step
    manager.last_update_time = time()
end

function _handle_worker_message!(manager, msg::ProgressComplete)
    @info "Worker $(msg.worker_id) completed: $(msg.message)"
    # TODO: Track which workers have completed
    # When all workers done, could auto-finish the experiment
end

function _handle_worker_message!(manager, msg::ProgressError)
    @error "Worker $(msg.worker_id) failed: $(msg.error_message)"
    # Could mark experiment as failed or wait for other workers
end

end # module DistributedSupport
