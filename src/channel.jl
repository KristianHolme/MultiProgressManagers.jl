# ProgressTask channel API: get_task, update!, finish!, fail!
# Local workers write directly to the sink. Remote workers pump into the same sink.
# The listener coalesces pending messages per task and flushes them in one DB transaction.

const DEFAULT_CHANNEL_CAPACITY = 4096
const LISTENER_COALESCE_SECONDS = 0.01

function _spawn_background(f::F) where {F}
    if Threads.nthreads(:interactive) > 0
        return Threads.@spawn :interactive f()
    end
    return Threads.@spawn f()
end

function _start_listener_if_needed!(manager::ProgressManager)
    if manager._sink === nothing
        sink = LocalProgressChannel(DEFAULT_CHANNEL_CAPACITY)
        manager._sink = sink
        manager._listener_task = _spawn_background() do
            return _listener_loop(manager, sink)
        end
    end

    return manager._sink::LocalProgressChannel
end

function _apply_channel_message!(
        manager::ProgressManager,
        dirty::Set{Int},
        messages::Dict{Int, String},
        msg::ProgressUpdate,
    )
    _stage_update!(
        manager,
        msg.task_number;
        step = msg.current_step,
        total_steps = msg.total_steps,
    )
    push!(dirty, msg.task_number)
    if !isempty(msg.message)
        messages[msg.task_number] = msg.message
    end
    return false
end

function _apply_channel_message!(
        manager::ProgressManager,
        dirty::Set{Int},
        messages::Dict{Int, String},
        msg::TaskFinished,
    )
    _stage_finish!(manager, msg.task_number)
    push!(dirty, msg.task_number)
    return true
end

function _apply_channel_message!(
        manager::ProgressManager,
        dirty::Set{Int},
        messages::Dict{Int, String},
        msg::TaskFailed,
    )
    _stage_fail!(manager, msg.task_number)
    push!(dirty, msg.task_number)
    if !isempty(msg.message)
        messages[msg.task_number] = msg.message
    end
    return true
end

function _drain_progress_channel!(
        manager::ProgressManager,
        sink::LocalProgressChannel,
        dirty::Set{Int},
        messages::Dict{Int, String},
    )
    terminal_count = 0
    while isready(sink)
        if _apply_channel_message!(manager, dirty, messages, take!(sink))
            terminal_count += 1
        end
    end
    return terminal_count
end

function _flush_dirty_tasks!(
        manager::ProgressManager,
        dirty::Set{Int},
        messages::Dict{Int, String},
    )
    if isempty(dirty)
        return nothing
    end

    now = time()
    writes = Database.TaskWrite[]
    for task_number in dirty
        ts = manager.task_status[task_number]
        message = get(messages, task_number, nothing)
        push!(
            writes,
            Database.TaskWrite(
                ts.task_id,
                ts.current_step,
                ts.total_steps,
                String(ts.status),
                message,
                now,
            ),
        )
    end
    Database.apply_task_writes!(manager.db_handle, writes)
    return nothing
end

function _listener_loop(manager::ProgressManager, sink::LocalProgressChannel)
    terminal_count = 0
    try
        while true
            dirty = Set{Int}()
            messages = Dict{Int, String}()
            first_msg = take!(sink)
            if _apply_channel_message!(manager, dirty, messages, first_msg)
                terminal_count += 1
            end
            terminal_count += _drain_progress_channel!(manager, sink, dirty, messages)
            if terminal_count < manager.total_tasks
                sleep(LISTENER_COALESCE_SECONDS)
                terminal_count += _drain_progress_channel!(manager, sink, dirty, messages)
            end
            _flush_dirty_tasks!(manager, dirty, messages)
            if terminal_count >= manager.total_tasks
                break
            end
        end
    catch e
        if !(e isa InvalidStateException) || e.state !== :closed
            rethrow(e)
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
    ch = _start_listener_if_needed!(manager)
    manager._local_channel = ch
    return ch
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
Local tasks write directly to the listener sink. Remote tasks are pumped into the same sink.
The listener coalesces queued updates per task and flushes them in one SQLite transaction.
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
    update!(task::ProgressTask; step::Union{Int, Nothing} = nothing,
            total_steps::Union{Int,Nothing} = nothing,
            message::String="")

Send a progress update for this task. The master's listener coalesces queued
updates and writes the latest per-task state to the DB.
"""
function update!(
        task::ProgressTask{C};
        step::Union{Int, Nothing} = nothing,
        total_steps::Union{Int, Nothing} = nothing,
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
        message::Union{String, Nothing} = nothing,
    ) where {C}
    resolved_message = message === nothing ? sprint(showerror, error) : message
    fail!(task; message = resolved_message)
    return nothing
end

function fail!(task::ProgressTask{C}, error_message::String) where {C}
    fail!(task; message = error_message)
    return nothing
end
