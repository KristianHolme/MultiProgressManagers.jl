# ProgressTask channel API: get_task, update!, finish!, fail!
# Single listener reads from a sink; pump tasks forward from local/remote channels into the sink.

using Distributed

const DEFAULT_CHANNEL_CAPACITY = 64

function _listener_loop(manager::ProgressManager)
    sink = manager._sink
    terminal_count = 0
    try
        while true
            msg = take!(sink)
            if msg isa ProgressUpdate
                update!(
                    manager,
                    msg.task_number;
                    step = msg.current_step,
                    total_steps = msg.total_steps,
                    message = msg.message,
                )
            elseif msg isa TaskFinished
                finish!(manager, msg.task_number)
                terminal_count += 1
                if terminal_count >= manager.total_tasks
                    break
                end
            elseif msg isa TaskFailed
                fail!(manager, msg.task_number; message = msg.message)
                terminal_count += 1
                if terminal_count >= manager.total_tasks
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
via `update!`, `finish!`, and `fail!`; the master runs a single listener that writes to the DB.

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
    update!(task::ProgressTask; step::Int,
            total_steps::Union{Int,Nothing}=nothing,
            message::String="")

Send a progress update for this task. The master's listener will call `update!` on the DB.
"""
function update!(
    task::ProgressTask;
    step::Int,
    total_steps::Union{Int,Nothing} = nothing,
    message::String = "",
)
    msg = ProgressUpdate(task.task_number, step, total_steps, message)
    put!(task.channel, msg)
    return nothing
end

function report_progress!(
    task::ProgressTask,
    current_step::Int;
    total_steps::Union{Int,Nothing} = nothing,
    message::String = "",
)
    Base.depwarn(
        "`report_progress!(task, step; ...)` is deprecated; use `update!(task; step = ..., total_steps = ..., message = ...)` instead.",
        :report_progress!,
    )
    return update!(task; step = current_step, total_steps = total_steps, message = message)
end

"""
    finish!(task::ProgressTask)

Signal that this task is complete. The master's listener will call `finish!` on the DB.
"""
function finish!(task::ProgressTask)
    put!(task.channel, TaskFinished(task.task_number))
    return nothing
end

"""
    fail!(task::ProgressTask; message::String="Task failed")

Signal that this task has failed. The master's listener will call `fail!` on the DB.
"""
function fail!(task::ProgressTask; message::String = "Task failed")
    put!(task.channel, TaskFailed(task.task_number, message))
    return nothing
end

function fail!(task::ProgressTask, error::Exception; message::Union{String,Nothing} = nothing)
    resolved_message = message === nothing ? sprint(showerror, error) : message
    fail!(task; message = resolved_message)
    return nothing
end

function fail!(task::ProgressTask, error_message::String)
    fail!(task; message = error_message)
    return nothing
end
