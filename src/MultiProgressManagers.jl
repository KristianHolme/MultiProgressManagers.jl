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

abstract type AbstractProgressMessage end

struct ProgressStart <: AbstractProgressMessage
    id::Int
    total_steps::Int
    desc::String
end

struct ProgressStepUpdate <: AbstractProgressMessage
    id::Int
    step::Int
    info::String
end

struct ProgressFinished <: AbstractProgressMessage
    id::Int
    desc::String
end

struct ProgressStop <: AbstractProgressMessage end

const ProgressMessage = Union{ProgressStart, ProgressStepUpdate, ProgressStop, ProgressFinished}

mutable struct MultiProgressManager
    main_meter::Progress
    worker_meters::Dict{Int, Progress}
    worker2index::Dict{Int, Int}
    main_channel::RemoteChannel{Channel{Bool}}
    worker_channel::RemoteChannel{Channel{ProgressMessage}}
    io::IO
end

function MultiProgressManager(n_jobs::Int, tty::Int)
    return MultiProgressManager(n_jobs, _open_tty(tty))
end

_open_tty(tty::Int) = IOContext(open("/dev/pts/$(tty)", "w"), :color => true)

function MultiProgressManager(n_jobs::Int, io::IO = stderr)
    main_meter = Progress(n_jobs; desc = "Total Progress:", showspeed = true, output = io)
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
        @warn "Worker index for id $(message.id) not found, doing nothing"
        return nothing
    end
    meter = manager.worker_meters[message.id]
    step = message.step
    if step < 0
        @warn "Step $step is less than 0, doing nothing"
        return nothing
    end
    if meter.counter + step > meter.n
        @warn "Step $step is greater than the steps left $(meter.counter)/$(meter.n), setting to $(meter.n - meter.counter)"
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
        @warn "Worker index for id $(message.id) not found, doing nothing"
        return nothing
    end
    meter = manager.worker_meters[message.id]
    finish!(meter; showvalues = [(iteration_string(0, meter), message.desc)])
    return nothing
end

end # module MultiProgressManagers
