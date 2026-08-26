# ProgressTask API: get_task, update!, finish!, fail!
# Local workers write overwrite-latest slots. Remote workers write a process-local
# slot and rate-limit puts onto a RemoteChannel; a master pump copies those
# messages into the same slots. A poller flushes dirty slots to SQLite on the
# interactive threadpool.

const DEFAULT_CHANNEL_CAPACITY = 4096
const LISTENER_COALESCE_SECONDS = 0.01
const REMOTE_FLUSH_INTERVAL_NS = UInt64(10_000_000)

function _new_remote_worker_state()
    return RemoteWorkerState(
        LocalProgressSlot(Threads.SpinLock(), 0, 0, SLOT_ACTIVE, UInt64(0), ""),
        UInt64(0),
        UInt64(0),
        0,
    )
end

function _remote_state!(transport::RemoteProgressTransport)
    return _unwrap_remote_state(transport.state, transport)
end

function _unwrap_remote_state(state::RemoteWorkerState, ::RemoteProgressTransport)
    return state
end

function _unwrap_remote_state(::Nothing, transport::RemoteProgressTransport)
    state = _new_remote_worker_state()
    transport.state = state
    return state
end

function _drop_remote_state!(transport::RemoteProgressTransport)
    transport.state = nothing
    return nothing
end

function _spawn_background(f::F) where {F}
    if Threads.nthreads(:interactive) > 0
        return Threads.@spawn :interactive f()
    end
    return Threads.@spawn f()
end

function _make_local_slots(manager::ProgressManager)
    n = manager.total_tasks
    slots = Vector{LocalProgressSlot}(undef, n)
    for task_number in 1:n
        ts = manager.task_status[task_number]
        slots[task_number] = LocalProgressSlot(
            Threads.SpinLock(),
            ts.current_step,
            ts.total_steps,
            SLOT_ACTIVE,
            UInt64(0),
            "",
        )
    end
    return slots
end

function _start_listener_if_needed!(manager::ProgressManager)
    return _get_or_create_local!(manager, manager._local_slots)
end

function _start_listener_from_empty!(manager::ProgressManager)
    slots = _make_local_slots(manager)
    manager._local_slots = slots
    manager._listener_task = _spawn_background() do
        return _listener_loop(manager, slots)
    end
    return slots
end

function _copy_slot(slot::LocalProgressSlot)
    lock(slot.lock)
    try
        return (slot.seq, slot.current_step, slot.total_steps, slot.status, slot.message)
    finally
        unlock(slot.lock)
    end
end

function _publish_update!(
        slot::LocalProgressSlot,
        step::Union{Int, Nothing},
        total_steps::Union{Int, Nothing},
        message::String,
    )
    lock(slot.lock)
    try
        if step isa Int
            slot.current_step = step
        end
        if total_steps isa Int
            slot.total_steps = total_steps
        end
        if !isempty(message)
            slot.message = message
        end
        slot.seq += UInt64(1)
    finally
        unlock(slot.lock)
    end
    return nothing
end

function _publish_finish!(slot::LocalProgressSlot)
    lock(slot.lock)
    try
        slot.status = SLOT_FINISHED
        slot.seq += UInt64(1)
    finally
        unlock(slot.lock)
    end
    return nothing
end

function _publish_fail!(slot::LocalProgressSlot, message::String)
    lock(slot.lock)
    try
        slot.status = SLOT_FAILED
        if !isempty(message)
            slot.message = message
        end
        slot.seq += UInt64(1)
    finally
        unlock(slot.lock)
    end
    return nothing
end

function _flush_remote_transport!(
        transport::RemoteProgressTransport,
        task_number::Int,
        now_ns::UInt64,
    )
    state = _remote_state!(transport)
    seq, current_step, total_steps, status, message = _copy_slot(state.slot)
    if seq == state.last_flushed_seq
        return nothing
    end
    state.last_flushed_seq = seq
    state.last_flush_ns = now_ns
    state.flush_count += 1
    ch = transport.channel
    if status == SLOT_FINISHED
        put!(ch, ProgressUpdate(task_number, current_step, total_steps, message))
        put!(ch, TaskFinished(task_number))
        _drop_remote_state!(transport)
    elseif status == SLOT_FAILED
        put!(ch, ProgressUpdate(task_number, current_step, total_steps, message))
        put!(ch, TaskFailed(task_number, message))
        _drop_remote_state!(transport)
    else
        put!(ch, ProgressUpdate(task_number, current_step, total_steps, message))
    end
    return nothing
end

function _maybe_flush_remote!(transport::RemoteProgressTransport, task_number::Int)
    state = _remote_state!(transport)
    now_ns = time_ns()
    if now_ns - state.last_flush_ns < REMOTE_FLUSH_INTERVAL_NS
        return nothing
    end
    _flush_remote_transport!(transport, task_number, now_ns)
    return nothing
end

function Base.isopen(transport::RemoteProgressTransport)
    return isopen(transport.channel)
end

function Base.close(transport::RemoteProgressTransport)
    return close(transport.channel)
end

function _apply_message_to_slot!(slots::Vector{LocalProgressSlot}, msg::ProgressUpdate)
    _publish_update!(slots[msg.task_number], msg.current_step, msg.total_steps, msg.message)
    return nothing
end

function _apply_message_to_slot!(slots::Vector{LocalProgressSlot}, msg::TaskFinished)
    _publish_finish!(slots[msg.task_number])
    return nothing
end

function _apply_message_to_slot!(slots::Vector{LocalProgressSlot}, msg::TaskFailed)
    _publish_fail!(slots[msg.task_number], msg.message)
    return nothing
end

function _poll_slots!(
        manager::ProgressManager,
        slots::Vector{LocalProgressSlot},
        last_seq::Vector{UInt64},
        dirty::Set{Int},
        messages::Dict{Int, String},
    )
    terminal_count = 0
    n = length(slots)
    for task_number in 1:n
        seq, current_step, total_steps, status, message = _copy_slot(slots[task_number])
        if status == SLOT_FINISHED || status == SLOT_FAILED
            terminal_count += 1
        end
        if seq == last_seq[task_number]
            continue
        end
        last_seq[task_number] = seq
        if status == SLOT_FINISHED
            _stage_update!(manager, task_number; step = current_step, total_steps = total_steps)
            _stage_finish!(manager, task_number)
        elseif status == SLOT_FAILED
            _stage_update!(manager, task_number; step = current_step, total_steps = total_steps)
            _stage_fail!(manager, task_number)
        else
            _stage_update!(manager, task_number; step = current_step, total_steps = total_steps)
        end
        push!(dirty, task_number)
        if !isempty(message)
            messages[task_number] = message
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

function _listener_loop(manager::ProgressManager, slots::Vector{LocalProgressSlot})
    last_seq = zeros(UInt64, length(slots))
    try
        while true
            dirty = Set{Int}()
            messages = Dict{Int, String}()
            terminal_count = _poll_slots!(manager, slots, last_seq, dirty, messages)
            _flush_dirty_tasks!(manager, dirty, messages)
            if terminal_count >= manager.total_tasks
                break
            end
            sleep(LISTENER_COALESCE_SECONDS)
        end
    catch e
        if !(e isa InvalidStateException) || e.state !== :closed
            rethrow(e)
        end
    end
    return nothing
end

function _pump_loop(source, slots::Vector{LocalProgressSlot})
    try
        while true
            _apply_message_to_slot!(slots, take!(source))
        end
    catch e
        if !(e isa InvalidStateException) || e.state !== :closed
            rethrow(e)
        end
    end
    return nothing
end

function _ensure_local_slots!(manager::ProgressManager)
    return lock(manager._channel_lock) do
        return _get_or_create_local!(manager, manager._local_slots)
    end
end

function _get_or_create_local!(manager::ProgressManager, ::Nothing)
    return _start_listener_from_empty!(manager)
end

function _get_or_create_local!(manager::ProgressManager, slots::Vector{LocalProgressSlot})
    return slots
end

"""
    get_task(manager::ProgressManager, task_number::Int, type=:local) -> ProgressTask

Return a ProgressTask for the given task number. Workers use this handle to report progress
via `update!`, `finish!`, and `fail!`; the master runs a single poller that writes to the DB.

- `type == :local`: uses a per-task overwrite-latest slot (same process, e.g. multithreading).
- `type == :remote`: uses a process-local overwrite-latest slot in front of a `RemoteChannel`
  (for `Distributed` workers on other processes). `update!` does not `put!` on every step.

The first call for each type starts the poller if needed. Local tasks write slots directly.
Remote tasks rate-limit IPC into the same slots. The poller coalesces to the latest per-task
state and flushes dirty rows to SQLite.
"""
function get_task(manager::ProgressManager, task_number::Int, type::Symbol = :local)
    if type !== :local && type !== :remote
        throw(ArgumentError("type must be :local or :remote, got :$type"))
    end
    if task_number < 1 || task_number > manager.total_tasks
        throw(ArgumentError("task_number must be in 1:$(manager.total_tasks), got $(task_number)"))
    end
    if type === :local
        slots = _ensure_local_slots!(manager)
        return ProgressTask(task_number, slots[task_number])
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

Send a progress update for this task. Local and remote tasks overwrite a
per-task slot. Remote tasks additionally send the latest state over a
`RemoteChannel` at most every `LISTENER_COALESCE_SECONDS`. The poller writes
the latest per-task state to the DB.
"""
function update!(
        task::ProgressTask{LocalProgressSlot};
        step::Union{Int, Nothing} = nothing,
        total_steps::Union{Int, Nothing} = nothing,
        message::String = "",
    )
    _publish_update!(task.channel, step, total_steps, message)
    return nothing
end

function update!(
        task::ProgressTask{<:RemoteProgressTransport};
        step::Union{Int, Nothing} = nothing,
        total_steps::Union{Int, Nothing} = nothing,
        message::String = "",
    )
    transport = task.channel
    _publish_update!(_remote_state!(transport).slot, step, total_steps, message)
    _maybe_flush_remote!(transport, task.task_number)
    return nothing
end

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

Signal that this task is complete. The master's poller will persist the finished state.
"""
function finish!(task::ProgressTask{LocalProgressSlot})
    _publish_finish!(task.channel)
    return nothing
end

function finish!(task::ProgressTask{<:RemoteProgressTransport})
    transport = task.channel
    _publish_finish!(_remote_state!(transport).slot)
    _flush_remote_transport!(transport, task.task_number, time_ns())
    return nothing
end

function finish!(task::ProgressTask{C}) where {C}
    put!(task.channel, TaskFinished(task.task_number))
    return nothing
end

"""
    fail!(task::ProgressTask; message::String="Task failed")

Signal that this task has failed. The master's poller will persist the failed state.
"""
function fail!(task::ProgressTask{LocalProgressSlot}; message::String = "Task failed")
    _publish_fail!(task.channel, message)
    return nothing
end

function fail!(task::ProgressTask{<:RemoteProgressTransport}; message::String = "Task failed")
    transport = task.channel
    _publish_fail!(_remote_state!(transport).slot, message)
    _flush_remote_transport!(transport, task.task_number, time_ns())
    return nothing
end

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
