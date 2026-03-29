struct TaskStatus
    task_id::String
    total_steps::Int
    current_step::Int
    status::Symbol
    started_at::Float64
end

"""Message sent over the progress channel for a step update."""
struct ProgressUpdate
    task_number::Int
    current_step::Union{Int, Nothing}
    total_steps::Union{Int, Nothing}
    message::String
end

"""Message sent over the progress channel when a task completes."""
struct TaskFinished
    task_number::Int
end

"""Message sent over the progress channel when a task fails."""
struct TaskFailed
    task_number::Int
    message::String
end

const ProgressMessage = Union{ProgressUpdate, TaskFinished, TaskFailed}
const LocalProgressChannel = Channel{ProgressMessage}

"""Handle for a single task; workers use this to report progress via the channel."""
struct ProgressTask{C}
    task_number::Int
    channel::C
end

mutable struct ProgressManager
    experiment_id::String
    db_path::String
    total_tasks::Int
    start_time::Float64
    task_status::Dict{Int, TaskStatus}
    db_handle::Database.DBHandle
    _local_channel::Union{LocalProgressChannel, Nothing}
    _sink::Union{LocalProgressChannel, Nothing}
    _listener_task::Union{Task, Nothing}
    _pump_tasks::Vector{Task}
    _channel_lock::Base.Threads.ReentrantLock
end
