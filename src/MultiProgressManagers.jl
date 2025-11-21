module MultiProgressManagers

using Distributed
using ProgressMeter

export MultiProgressManager
export create_main_meter_tasks
export create_worker_meter_task
export update_progress!

export ProgressMessage
export ProgressStart
export ProgressStepUpdate
export ProgressFinished
export ProgressStop
export stop!
export create_dril_callback

# Progress inspection functions
export is_complete
export get_progress
export get_worker_status

abstract type AbstractProgressMessage end

"""
    ProgressStart(id, total_steps, desc)

Initialize a progress bar for a worker.

# Arguments
- `id::Int`: Worker ID (use `myid()`)
- `total_steps::Int`: Total iterations expected
- `desc::String`: Description shown next to progress bar
"""
struct ProgressStart <: AbstractProgressMessage
    id::Int
    total_steps::Int
    desc::String
end

"""
    ProgressStepUpdate(id, step, info)

Update worker progress.

# Arguments
- `id::Int`: Worker ID
- `step::Int`: Number of steps completed (typically 1)
- `info::String`: Optional status message
"""
struct ProgressStepUpdate <: AbstractProgressMessage
    id::Int
    step::Int
    info::String
end

"""
    ProgressFinished(id, desc)

Mark worker completion.

# Arguments
- `id::Int`: Worker ID
- `desc::String`: Final completion message
"""
struct ProgressFinished <: AbstractProgressMessage
    id::Int
    desc::String
end

"""
    ProgressStop()

Signal shutdown of the progress system.
"""
struct ProgressStop <: AbstractProgressMessage end

const ProgressMessage = Union{ProgressStart, ProgressStepUpdate, ProgressStop, ProgressFinished}

"""
    MultiProgressManager

Manages coordinated progress bars across distributed Julia workers.

# Fields
- `main_meter`: Overall progress meter
- `worker_meters`: Dictionary mapping worker IDs to their progress meters
- `worker2index`: Dictionary mapping worker IDs to display indices
- `main_channel`: Channel for main progress updates
- `worker_channel`: Channel for worker progress messages
- `io`: IO stream for progress output
"""
mutable struct MultiProgressManager
    main_meter::Progress
    worker_meters::Dict{Int, Progress}
    worker2index::Dict{Int, Int}
    main_channel::RemoteChannel{Channel{Bool}}
    worker_channel::RemoteChannel{Channel{ProgressMessage}}
    io::IO
end

function MultiProgressManager(n_jobs::Int, tty::Int; kwargs...)
    return MultiProgressManager(n_jobs, _open_tty(tty); kwargs...)
end

_open_tty(tty::Int) = IOContext(open("/dev/pts/$(tty)", "w"), :color => true)

"""
    MultiProgressManager(n_jobs::Int, io::IO=stderr; main_desc::String = "Total Progress:")

Create a progress manager for coordinating progress bars across `n_jobs` distributed tasks.

# Arguments
- `n_jobs::Int`: Total number of jobs to track (must be positive)
- `io::IO=stderr`: IO stream for progress output (default: stderr)
- `main_desc::String = "Total Progress:": Description of the main progress meter
# Returns
- `MultiProgressManager`: Manager instance with channels and meters

# Example
```julia
manager = MultiProgressManager(20)
manager = MultiProgressManager(20, main_desc = "Total Progress:")
```
See also: [`create_main_meter_tasks`](@ref), [`create_worker_meter_task`](@ref), [`stop!`](@ref)
"""
function MultiProgressManager(n_jobs::Int, io::IO = stderr; main_desc::String = "Total Progress:")
    n_jobs > 0 || throw(ArgumentError("n_jobs must be positive, got $n_jobs"))
    main_meter = Progress(n_jobs; desc = main_desc, showspeed = true, output = io)
    @async begin
        sleep(0.1)
        ProgressMeter.update!(main_meter, 0)
    end
    worker_meters = Dict{Int, Progress}()
    worker2index = Dict(worker_id => findfirst(==(worker_id), workers()) for worker_id in workers())
    main_channel = RemoteChannel(() -> Channel{Bool}(1024), 1)
    worker_channel = RemoteChannel(() -> Channel{ProgressMessage}(4096), 1)
    return MultiProgressManager(main_meter, worker_meters, worker2index, main_channel, worker_channel, io)
end

"""
    create_main_meter_tasks(manager::MultiProgressManager)

Create housekeeping tasks for the main progress meter.

Returns a tuple of two tasks:
- `t_periodic`: Periodically updates the main meter display
- `t_update`: Processes main channel updates when jobs complete

# Arguments
- `manager::MultiProgressManager`: The manager instance

# Returns
- `(Task, Task)`: Tuple of (periodic_task, update_task)

# Example
```julia
manager = MultiProgressManager(10)
t_periodic, t_update = create_main_meter_tasks(manager)
# ... do work ...
stop!(manager, t_periodic, t_update)
```
"""
function create_main_meter_tasks(manager::MultiProgressManager)
    t_periodic = @async begin
        try
            while isopen(manager.main_channel)
                meter = manager.main_meter
                ProgressMeter.update!(meter, meter.counter; showvalues = [("Jobs", iteration_string(0, meter))])
                sleep(10)
            end
        catch e
            if !(e isa InvalidStateException)
                rethrow()
            end
        end
    end
    t_update = @async begin
        try
            while take!(manager.main_channel)
                ProgressMeter.next!(manager.main_meter; showvalues = [("Jobs", iteration_string(1, manager.main_meter))])
            end
        catch e
            if !(e isa InvalidStateException && !isopen(manager.main_channel))
                rethrow()
            end
        end
    end
    return (t_periodic, t_update)
end

"""
    create_worker_meter_task(manager::MultiProgressManager)

Create a task that listens for and processes worker progress messages.

The task continuously reads from `manager.worker_channel` and updates
worker progress meters accordingly.

# Arguments
- `manager::MultiProgressManager`: The manager instance

# Returns
- `Task`: The worker listener task

# Example
```julia
manager = MultiProgressManager(10)
t_worker = create_worker_meter_task(manager)
# ... do work ...
stop!(manager, t_worker)
```
"""
function create_worker_meter_task(manager::MultiProgressManager)
    t_worker = @async begin
        try
            while isopen(manager.worker_channel)
                msg = take!(manager.worker_channel)
                update_progress!(manager, msg)
            end
        catch e
            if !(e isa InvalidStateException && !isopen(manager.worker_channel))
                @info "Worker meter task error" exception = (e, catch_backtrace())
                rethrow()
            end
        end
    end
    return t_worker
end

"""
    stop!(manager::MultiProgressManager, tasks::Task...)

Cleanly shutdown the progress manager and wait for all tasks to complete.

# Arguments
- `manager::MultiProgressManager`: The manager to stop
- `tasks::Task...`: Tasks to wait for (typically from `create_main_meter_tasks` and `create_worker_meter_task`)

# Side Effects
- Closes `manager.main_channel`
- Closes `manager.worker_channel`
- Waits for all provided tasks to finish
- Logs errors if channels fail to close

# Returns
- `nothing`

# Example
```julia
manager = MultiProgressManager(10)
t_periodic, t_update = create_main_meter_tasks(manager)
t_worker = create_worker_meter_task(manager)
# ... do work ...
stop!(manager, t_periodic, t_update, t_worker)
```
"""
function stop!(manager::MultiProgressManager, tasks::Task...)
    try
        put!(manager.main_channel, false)
        close(manager.main_channel)
    catch e
        @error "Failed to close main channel" exception = (e, catch_backtrace())
    end
    try
        close(manager.worker_channel)
    catch e
        @error "Failed to close worker channel" exception = (e, catch_backtrace())
    end
    for t in tasks
        if istaskstarted(t)
            try
                wait(t)
            catch e
                if !(e isa InvalidStateException)
                    @error "Task wait error" exception = (e, catch_backtrace())
                end
            end
        end
    end
    return nothing
end

function iteration_string(step::Int, progress_bar::Progress)
    return "$(progress_bar.counter + step) / $(progress_bar.n)"
end

function update_progress!(manager::MultiProgressManager, message::ProgressStepUpdate)
    if !haskey(manager.worker_meters, message.id)
        @warn "Worker $(message.id) sent ProgressStepUpdate before ProgressStart. Send ProgressStart($(message.id), total_steps, description) first."
        return nothing
    end
    meter = manager.worker_meters[message.id]
    step = message.step
    if step < 0
        @warn "Worker $(message.id) sent negative step ($step). Steps must be non-negative. Ignoring update."
        return nothing
    end
    if meter.counter + step > meter.n
        @warn "Worker $(message.id) step ($step) exceeds remaining steps ($(meter.n - meter.counter) of $(meter.n) remaining). Clamping to completion."
        step = meter.n - meter.counter
    end
    next!(meter; step, showvalues = [(iteration_string(step, meter), message.info)])
    return nothing
end

function update_progress!(manager::MultiProgressManager, message::ProgressStart)
    if !haskey(manager.worker2index, message.id)
        offset_index = length(manager.worker2index) + 1
        manager.worker2index[message.id] = offset_index
    end
    offset = manager.worker2index[message.id] * 2
    progress = Progress(message.total_steps; desc = message.desc, showspeed = true, offset, output = manager.io)
    manager.worker_meters[message.id] = progress
    @async begin
        sleep(0.1)
        ProgressMeter.next!(progress, step = 0)
    end
    return nothing
end

function update_progress!(manager::MultiProgressManager, ::ProgressStop)
    close(manager.worker_channel)
    return nothing
end

function update_progress!(manager::MultiProgressManager, message::ProgressFinished)
    if !haskey(manager.worker_meters, message.id)
        @warn "Worker $(message.id) sent ProgressFinished without a progress meter. Was ProgressStart called?"
        return nothing
    end
    meter = manager.worker_meters[message.id]
    finish!(meter; showvalues = [(iteration_string(0, meter), message.desc)])
    return nothing
end

# Progress inspection functions

"""
    is_complete(manager::MultiProgressManager)

Check if all jobs tracked by the manager are complete.

# Arguments
- `manager::MultiProgressManager`: The manager instance

# Returns
- `Bool`: True if main meter counter equals total jobs, false otherwise

# Example
```julia
if is_complete(manager)
    println("All jobs finished!")
end
```
"""
function is_complete(manager::MultiProgressManager)
    return manager.main_meter.counter >= manager.main_meter.n
end

"""
    get_progress(manager::MultiProgressManager)

Get the overall progress fraction of all jobs.

# Arguments
- `manager::MultiProgressManager`: The manager instance

# Returns
- `Float64`: Progress fraction between 0.0 and 1.0

# Example
```julia
progress = get_progress(manager)
println("Overall progress: \$(progress * 100)%")
```
"""
function get_progress(manager::MultiProgressManager)
    return manager.main_meter.counter / manager.main_meter.n
end

"""
    get_worker_status(manager::MultiProgressManager, worker_id::Int)

Get the status of a specific worker.

# Arguments
- `manager::MultiProgressManager`: The manager instance
- `worker_id::Int`: The worker ID to query

# Returns
- `NamedTuple` with fields:
  - `exists::Bool`: Whether the worker has a progress meter
  - `counter::Union{Int, Nothing}`: Current step count (nothing if worker doesn't exist)
  - `total::Union{Int, Nothing}`: Total steps (nothing if worker doesn't exist)
  - `progress::Union{Float64, Nothing}`: Progress fraction 0.0-1.0 (nothing if worker doesn't exist)

# Example
```julia
status = get_worker_status(manager, 2)
if status.exists
    println("Worker 2: \$(status.counter)/\$(status.total)")
end
```
"""
function get_worker_status(manager::MultiProgressManager, worker_id::Int)
    if !haskey(manager.worker_meters, worker_id)
        return (exists = false, counter = nothing, total = nothing, progress = nothing)
    end
    meter = manager.worker_meters[worker_id]
    return (
        exists = true,
        counter = meter.counter,
        total = meter.n,
        progress = meter.counter / meter.n,
    )
end

"""
    create_dril_callback(worker_channel)

Create a DRiL callback for progress tracking (requires DRiL.jl to be loaded).

This function is defined when the DRiL extension is loaded. Load DRiL before calling.

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
function create_dril_callback(worker_channel)
    error("DRiL extension not loaded. Please run `using DRiL` before calling create_dril_callback.")
end

end # module MultiProgressManagers
