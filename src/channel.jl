# ProgressTask channel API: get_task, update!, finish!, fail!
# Single listener reads from a sink; local workers write directly and extension-backed
# remote workers pump into the same sink.

const DEFAULT_CHANNEL_CAPACITY = 64

function _start_listener_if_needed!(manager::ProgressManager)
    if manager._sink === nothing
        sink = LocalProgressChannel(DEFAULT_CHANNEL_CAPACITY)
        manager._sink = sink
        manager._listener_task = @async _listener_loop(manager, sink)
    end

    return manager._sink::LocalProgressChannel
end

function _handle_progress_message!(manager::ProgressManager, msg::ProgressMessage)
    if msg isa ProgressUpdate
        update!(
            manager,
            msg.task_number;
            step = msg.current_step,
            total_steps = msg.total_steps,
            message = msg.message,
        )
        return false
    end

    if msg isa TaskFinished
        finish!(manager, msg.task_number)
        return true
    end

    fail!(manager, msg.task_number; message = msg.message)
    return true
end

function _listener_loop(manager::ProgressManager, sink::LocalProgressChannel)
    terminal_count = 0
    try
        while true
            msg = take!(sink)
            if _handle_progress_message!(manager, msg)
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

function _pump_loop(source, sink::LocalProgressChannel)
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

function _ensure_local_channel!(manager::ProgressManager)
    return lock(manager._channel_lock) do
        _get_or_create_local!(manager, manager._local_channel)
    end
end

function _get_or_create_local!(manager::ProgressManager, ::Nothing)
    sink = _start_listener_if_needed!(manager)
    local_ch = LocalProgressChannel(DEFAULT_CHANNEL_CAPACITY)
    push!(manager._pump_tasks, @async _pump_loop(local_ch, sink))
    manager._local_channel = local_ch
    return local_ch
end

function _get_or_create_local!(manager::ProgressManager, ch::LocalProgressChannel)
    return ch
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
    if type === :local
        ch = _ensure_local_channel!(manager)
        return ProgressTask(task_number, ch)
    end

    distributed_ext = Base.get_extension(MultiProgressManagers, :MultiProgressManagersDistributedExt)
    if distributed_ext === nothing
        throw(
            ArgumentError(
                "Remote progress tasks require loading the Distributed extension. " *
                "Load `Distributed` before requesting `get_task(manager, task_number, :remote)`.",
            ),
        )
    end

    return distributed_ext.get_remote_task(manager, task_number)
end

"""
    update!(task::ProgressTask; step::Int,
            total_steps::Union{Int,Nothing}=nothing,
            message::String="")

Send a progress update for this task. The master's listener will call `update!` on the DB.
"""
function update!(
    task::ProgressTask{C};
    step::Int,
    total_steps::Union{Int,Nothing} = nothing,
    message::String = "",
) where {C}
    msg = ProgressUpdate(task.task_number, step, total_steps, message)
    put!(task.channel, msg)
    return nothing
end

"""
    finish!(task::ProgressTask)

Signal that this task is complete. The master's listener will call `finish!` on the DB.
"""
function finish!(task::ProgressTask{C}) where {C}
    put!(task.channel, TaskFinished(task.task_number))
    return nothing
end

"""
    fail!(task::ProgressTask; message::String="Task failed")

Signal that this task has failed. The master's listener will call `fail!` on the DB.
"""
function fail!(task::ProgressTask{C}; message::String = "Task failed") where {C}
    put!(task.channel, TaskFailed(task.task_number, message))
    return nothing
end

function fail!(
    task::ProgressTask{C},
    error::Exception;
    message::Union{String,Nothing} = nothing,
) where {C}
    resolved_message = message === nothing ? sprint(showerror, error) : message
    fail!(task; message = resolved_message)
    return nothing
end

function fail!(task::ProgressTask{C}, error_message::String) where {C}
    fail!(task; message = error_message)
    return nothing
end
