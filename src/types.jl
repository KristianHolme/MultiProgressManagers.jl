"""
    ProgressManager

Manages progress tracking for distributed experiments with SQLite persistence.
Created by the master process, writes to database, coordinates with workers via RemoteChannels.
"""
mutable struct ProgressManager
    experiment_id::String
    db_path::String
    total_steps::Int
    start_time::Float64
    last_update_time::Float64
    last_step::Int
    worker_channel::Union{RemoteChannel,Nothing}
    update_frequency_ms::Int  # Throttling: minimum time between DB writes
    speed_window_seconds::Float64  # For short-horizon speed calculation
    
    function ProgressManager(experiment_id::String, db_path::String, total_steps::Int;
                            worker_channel=nothing,
                            update_frequency_ms::Int=100,
                            speed_window_seconds::Real=30)
        new(experiment_id, db_path, total_steps, time(), time(), 0,
            worker_channel, update_frequency_ms, speed_window_seconds)
    end
end

"""
    WorkerProgressMessage

Base type for messages sent from workers to the ProgressManager.
"""
abstract type WorkerProgressMessage end

struct ProgressStart <: WorkerProgressMessage
    worker_id::Int
    total_steps::Int
    description::String
end

struct ProgressUpdate <: WorkerProgressMessage
    worker_id::Int
    current_step::Int
    info::String
    timestamp::Float64  # Worker's local time
end

struct ProgressComplete <: WorkerProgressMessage
    worker_id::Int
    message::String
end

struct ProgressError <: WorkerProgressMessage
    worker_id::Int
    error_message::String
end

const ProgressMessage = Union{ProgressStart, ProgressUpdate, ProgressComplete, ProgressError}
