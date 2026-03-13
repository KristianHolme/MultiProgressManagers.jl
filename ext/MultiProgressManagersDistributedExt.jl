module MultiProgressManagersDistributedExt

using Distributed: RemoteChannel, myid
using MultiProgressManagers

const REMOTE_CHANNELS = WeakKeyDict{ProgressManager,RemoteChannel}()
const REMOTE_CHANNELS_LOCK = ReentrantLock()

function _get_remote_channel(manager::ProgressManager)
    return lock(REMOTE_CHANNELS_LOCK) do
        return get(REMOTE_CHANNELS, manager, nothing)
    end
end

function _set_remote_channel!(manager::ProgressManager, remote_channel::RemoteChannel)
    return lock(REMOTE_CHANNELS_LOCK) do
        REMOTE_CHANNELS[manager] = remote_channel
        return remote_channel
    end
end

function _ensure_remote_channel!(manager::ProgressManager)
    remote_channel = _get_remote_channel(manager)
    if remote_channel !== nothing
        return remote_channel
    end

    return lock(manager._channel_lock) do
        remote_channel = _get_remote_channel(manager)
        if remote_channel !== nothing
            return remote_channel
        end
        sink = MultiProgressManagers._start_listener_if_needed!(manager)
        remote_channel = RemoteChannel(
            () -> Channel{ProgressMessage}(MultiProgressManagers.DEFAULT_CHANNEL_CAPACITY),
            myid(),
        )
        push!(manager._pump_tasks, @async MultiProgressManagers._pump_loop(remote_channel, sink))
        return _set_remote_channel!(manager, remote_channel)
    end
end

function get_remote_task(
    manager::ProgressManager,
    task_number::Int,
)
    remote_channel = _ensure_remote_channel!(manager)
    return ProgressTask(task_number, remote_channel)
end

end
