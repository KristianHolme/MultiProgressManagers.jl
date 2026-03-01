# ProgressTask channel API: get_task, report_progress!, finish!
# Single listener reads from a sink; pump tasks forward from local/remote channels into the sink.

using Distributed

const DEFAULT_CHANNEL_CAPACITY = 64

function _listener_loop(manager::ProgressManager)
    sink = manager._sink
    finished_count = 0
    try
        while true
            msg = take!(sink)
            if msg isa ProgressUpdate
                update!(
                    manager,
                    msg.task_number,
                    msg.current_step;
                    total_steps = msg.total_steps,
                    message = msg.message,
                )
            elseif msg isa TaskFinished
                finish_task!(manager, msg.task_number)
                finished_count += 1
                if finished_count >= manager.total_tasks
                    break
                end
            end
        end
    finally
        if isopen(sink)
            close(sink)
        end
    end
    return nothing
end

function _pump_loop(source, sink)
    try
        while true
            msg = take!(source)
            put!(sink, msg)
        end
    catch e
        if !(e isa InvalidStateException) || e.state !== :closed
            rethrow(e)
        end
    end
    return nothing
end

function _current_slot(::Nothing, ::Val{:local})
    return nothing
end

function _current_slot(::Nothing, ::Val{:remote})
    return nothing
end

function _current_slot(channels::Vector{Any}, ::Val{:local})
    return channels[1]
end

function _current_slot(channels::Vector{Any}, ::Val{:remote})
    return channels[2]
end

function _ensure_channels_vector!(::Nothing, manager::ProgressManager)
    vec = Any[nothing, nothing]
    manager._channels = vec
    return vec
end

function _ensure_channels_vector!(channels::Vector{Any}, manager::ProgressManager)
    return channels
end

function _get_or_create!(manager::ProgressManager, ::Val{:local}, ::Nothing)
    channels = _ensure_channels_vector!(manager._channels, manager)
    if manager._sink === nothing
        manager._sink = Channel{ProgressMessage}(DEFAULT_CHANNEL_CAPACITY)
        manager._listener_task = @async _listener_loop(manager)
    end
    local_ch = Channel{ProgressMessage}(DEFAULT_CHANNEL_CAPACITY)
    push!(manager._pump_tasks, @async _pump_loop(local_ch, manager._sink))
    channels[1] = local_ch
    return local_ch
end

function _get_or_create!(manager::ProgressManager, ::Val{:local}, ch::Channel{ProgressMessage})
    return ch
end

function _get_or_create!(manager::ProgressManager, ::Val{:remote}, ::Nothing)
    channels = _ensure_channels_vector!(manager._channels, manager)
    if manager._sink === nothing
        manager._sink = Channel{ProgressMessage}(DEFAULT_CHANNEL_CAPACITY)
        manager._listener_task = @async _listener_loop(manager)
    end
    remote_ch = RemoteChannel(
        () -> Channel{ProgressMessage}(DEFAULT_CHANNEL_CAPACITY),
        myid(),
    )
    push!(manager._pump_tasks, @async _pump_loop(remote_ch, manager._sink))
    channels[2] = remote_ch
    return remote_ch
end

function _get_or_create!(manager::ProgressManager, ::Val{:remote}, ch)
    return ch
end

function _ensure_channels!(manager::ProgressManager, type::Symbol)
    return lock(manager._channel_lock) do
        slot = _current_slot(manager._channels, Val(type))
        return _get_or_create!(manager, Val(type), slot)
    end
end

"""
    get_task(manager::ProgressManager, task_number::Int, type=:local) -> ProgressTask

Return a ProgressTask for the given task number. Workers use this handle to report progress
via `report_progress!` and `finish!`; the master runs a single listener that writes to the DB.

- `type == :local`: uses a plain `Channel` (same process, e.g. multithreading).
- `type == :remote`: uses a `RemoteChannel` (for `Distributed` workers on other processes).

The first call for each type creates the channel and starts the listener/pump if needed.
"""
function get_task(manager::ProgressManager, task_number::Int, type::Symbol = :local)
    if type !== :local && type !== :remote
        throw(ArgumentError("type must be :local or :remote, got :$type"))
    end
    ch = _ensure_channels!(manager, type)
    return ProgressTask(task_number, ch)
end

"""
    report_progress!(task::ProgressTask, current_step::Int; total_steps::Int=0, message::String="")

Send a progress update for this task. The master's listener will call `update!` on the DB.
"""
function report_progress!(
    task::ProgressTask,
    current_step::Int;
    total_steps::Int = 0,
    message::String = "",
)
    msg = ProgressUpdate(task.task_number, current_step, total_steps, message)
    put!(task.channel, msg)
    return nothing
end

"""
    finish!(task::ProgressTask)

Signal that this task is complete. The master's listener will call `finish_task!` on the DB.
"""
function finish!(task::ProgressTask)
    put!(task.channel, TaskFinished(task.task_number))
    return nothing
end
