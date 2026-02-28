module Database

using SQLite
using DBInterface
using DataFrames
using Dates
using UUIDs

export init_db!, close_db!
export create_experiment, record_progress!, finish_experiment!, fail_experiment!
export get_experiment, get_running_experiments, get_all_experiments
export get_experiment_history, get_completion_histogram
export update_experiment_status!, update_experiment_steps!
export calculate_speeds, get_recent_speeds
export get_experiment_stats, get_daily_stats

# Global database connection (per-process)
const DB = Ref{Union{SQLite.DB,Nothing}}(nothing)

"""
    init_db!(db_path::String) -> SQLite.DB

Initialize the SQLite database with schema for full history retention.
Creates all necessary tables and indexes.
"""
function init_db!(db_path::String)
    mkpath(dirname(db_path))
    db = SQLite.DB(db_path)
    DB[] = db
    
    # Enable WAL mode for better concurrent write performance
    DBInterface.execute(db, "PRAGMA journal_mode=WAL")
    DBInterface.execute(db, "PRAGMA synchronous=NORMAL")
    
    # === Experiments Table ===
    # Master record for each progress tracking session
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS experiments (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            total_steps INTEGER NOT NULL,
            current_step INTEGER DEFAULT 0,
            status TEXT DEFAULT 'running', -- running, completed, failed, cancelled
            started_at DATETIME NOT NULL,
            finished_at DATETIME,
            final_message TEXT,
            worker_count INTEGER DEFAULT 1,
            metadata TEXT, -- JSON for extensibility
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    """)
    
    # === Progress Snapshots Table ===
    # Full history of all progress updates with timestamps
    # This enables accurate speed calculations and historical analysis
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS progress_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            experiment_id TEXT NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
            timestamp DATETIME NOT NULL,
            current_step INTEGER NOT NULL,
            total_elapsed_ms REAL NOT NULL,    -- Total time since experiment start
            delta_steps INTEGER NOT NULL,       -- Steps completed since last snapshot
            delta_ms REAL NOT NULL,             -- Time elapsed since last snapshot
            worker_id INTEGER,                  -- Which worker reported this (for distributed)
            metadata TEXT                       -- JSON for extensibility
        )
    """)
    
    # === Worker Assignments Table ===
    # Track which workers are assigned to which experiments
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS worker_assignments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            experiment_id TEXT NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
            worker_id INTEGER NOT NULL,
            assigned_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            steps_completed INTEGER DEFAULT 0,
            UNIQUE(experiment_id, worker_id)
        )
    """)
    
    # === Indexes for Performance ===
    
    # Fast lookups by experiment and time (for speed calculations)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_snapshots_exp_time 
        ON progress_snapshots(experiment_id, timestamp DESC)
    """)
    
    # Fast lookups for recent snapshots (speed calculations)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_snapshots_exp_time_recent 
        ON progress_snapshots(experiment_id, timestamp)
    """)
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_snapshots_exp_time_recent 
        ON progress_snapshots(experiment_id, timestamp)
        WHERE timestamp > datetime('now', '-1 hour')
    """)
    
    # Fast status filtering
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_experiments_status 
        ON experiments(status, started_at DESC)
    """)
    
    # Fast date-based queries for analytics
    DBInterface.execute(db, """
        CREATE INDEX IF NOT EXISTS idx_experiments_started 
        ON experiments(started_at DESC)
    """)
    
    # === Views for Analytics ===
    
    # Daily experiment summary
    DBInterface.execute(db, """
        CREATE VIEW IF NOT EXISTS v_daily_experiments AS
        SELECT 
            DATE(started_at) as date,
            COUNT(*) as total_started,
            SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed,
            SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) as running,
            AVG(CASE WHEN finished_at IS NOT NULL 
                THEN (julianday(finished_at) - julianday(started_at)) * 86400 
                ELSE NULL END) as avg_duration_seconds
        FROM experiments
        GROUP BY DATE(started_at)
        ORDER BY date DESC
    """)
    
    return db
end

"""
    get_db() -> SQLite.DB

Get the current database connection, throwing an error if not initialized.
"""
function get_db()
    db = DB[]
    db === nothing && error("Database not initialized. Call init_db! first.")
    return db
end

"""
    create_experiment(name::String, total_steps::Int; 
                       description="", worker_count=1, metadata=nothing) -> String

Create a new experiment and return its UUID.
"""
function create_experiment(name::String, total_steps::Int;
                          description::String="",
                          worker_count::Int=1,
                          metadata=nothing)
    db = get_db()
    id = string(UUIDs.uuid4())
    
    DBInterface.execute(db, """
        INSERT INTO experiments (id, name, description, total_steps, status, started_at, worker_count, metadata)
        VALUES (?, ?, ?, ?, 'running', datetime('now'), ?, ?)
    """, [id, name, description, total_steps, worker_count, 
          metadata === nothing ? nothing : JSON3.write(metadata)])
    
    return id
end

"""
    record_progress!(experiment_id::String, current_step::Int, 
                     elapsed_seconds::Real; worker_id=nothing, metadata=nothing)

Record a progress snapshot with full delta calculations.
"""
function record_progress!(experiment_id::String, current_step::Int,
                         elapsed_seconds::Real; 
                         worker_id::Union{Int,Nothing}=nothing,
                         metadata=nothing)
    db = get_db()
    
    # Get the last snapshot to calculate deltas
    last_snapshot = DBInterface.execute(db, """
        SELECT current_step, total_elapsed_ms
        FROM progress_snapshots
        WHERE experiment_id = ?
        ORDER BY timestamp DESC
        LIMIT 1
    """, [experiment_id]) |> DataFrame
    
    if nrow(last_snapshot) > 0
        last_step = last_snapshot.current_step[1]
        last_elapsed_ms = last_snapshot.total_elapsed_ms[1]
        delta_steps = current_step - last_step
        delta_ms = elapsed_seconds * 1000 - last_elapsed_ms
    else
        # First snapshot
        delta_steps = current_step
        delta_ms = elapsed_seconds * 1000
    end
    
    # Insert the new snapshot
    DBInterface.execute(db, """
        INSERT INTO progress_snapshots 
        (experiment_id, timestamp, current_step, total_elapsed_ms, delta_steps, delta_ms, worker_id, metadata)
        VALUES (?, datetime('now'), ?, ?, ?, ?, ?, ?)
    """, [experiment_id, current_step, elapsed_seconds * 1000, delta_steps, delta_ms,
          worker_id, metadata === nothing ? nothing : JSON3.write(metadata)])
    
    # Update the experiment's current_step
    DBInterface.execute(db, """
        UPDATE experiments 
        SET current_step = ?
        WHERE id = ?
    """, [current_step, experiment_id])
    
    return nothing
end

"""
    finish_experiment!(experiment_id::String; message="Completed successfully")

Mark an experiment as completed.
"""
function finish_experiment!(experiment_id::String; message::String="Completed successfully")
    db = get_db()
    
    DBInterface.execute(db, """
        UPDATE experiments 
        SET status = 'completed', 
            finished_at = datetime('now'),
            final_message = ?
        WHERE id = ?
    """, [message, experiment_id])
    
    return nothing
end

"""
    fail_experiment!(experiment_id::String, error_message::String)

Mark an experiment as failed.
"""
function fail_experiment!(experiment_id::String, error_message::String)
    db = get_db()
    
    DBInterface.execute(db, """
        UPDATE experiments 
        SET status = 'failed', 
            finished_at = datetime('now'),
            final_message = ?
        WHERE id = ?
    """, [error_message, experiment_id])
    
    return nothing
end

"""
    get_experiment(experiment_id::String) -> Union{NamedTuple, Nothing}

Get a single experiment by ID.
"""
function get_experiment(experiment_id::String)
    db = get_db()
    
    result = DBInterface.execute(db, """
        SELECT id, name, description, total_steps, current_step, status,
               started_at, finished_at, final_message, worker_count, metadata
        FROM experiments
        WHERE id = ?
    """, [experiment_id]) |> DataFrame
    
    nrow(result) == 0 && return nothing
    
    row = result[1, :]
    return (
        id = row.id,
        name = row.name,
        description = row.description,
        total_steps = row.total_steps,
        current_step = row.current_step,
        status = Symbol(row.status),
        started_at = row.started_at,
        finished_at = row.finished_at,
        final_message = row.final_message,
        worker_count = row.worker_count,
        metadata = row.metadata,
        progress_pct = 100.0 * row.current_step / row.total_steps
    )
end

"""
    get_running_experiments() -> Vector{NamedTuple}

Get all currently running experiments.
"""
function get_running_experiments()
    db = get_db()
    
    result = DBInterface.execute(db, """
        SELECT id, name, description, total_steps, current_step, status,
               started_at, finished_at, final_message, worker_count, metadata
        FROM experiments
        WHERE status = 'running'
        ORDER BY started_at DESC
    """) |> DataFrame
    
    return [_row_to_namedtuple(row) for row in eachrow(result)]
end

"""
    get_all_experiments(; status=nothing, limit=100) -> Vector{NamedTuple}

Get all experiments, optionally filtered by status.
"""
function get_all_experiments(; status::Union{String,Nothing}=nothing, limit::Int=100)
    db = get_db()
    
    if status === nothing
        result = DBInterface.execute(db, """
            SELECT id, name, description, total_steps, current_step, status,
                   started_at, finished_at, final_message, worker_count, metadata
            FROM experiments
            ORDER BY started_at DESC
            LIMIT ?
        """, [limit]) |> DataFrame
    else
        result = DBInterface.execute(db, """
            SELECT id, name, description, total_steps, current_step, status,
                   started_at, finished_at, final_message, worker_count, metadata
            FROM experiments
            WHERE status = ?
            ORDER BY started_at DESC
            LIMIT ?
        """, [status, limit]) |> DataFrame
    end
    
    return [_row_to_namedtuple(row) for row in eachrow(result)]
end

"""
    get_experiment_history(experiment_id::String; limit=1000) -> Vector{NamedTuple}

Get the full progress history for an experiment.
"""
function get_experiment_history(experiment_id::String; limit::Int=1000)
    db = get_db()
    
    result = DBInterface.execute(db, """
        SELECT timestamp, current_step, total_elapsed_ms, delta_steps, delta_ms, worker_id
        FROM progress_snapshots
        WHERE experiment_id = ?
        ORDER BY timestamp DESC
        LIMIT ?
    """, [experiment_id, limit]) |> DataFrame
    
    return [(
        timestamp = row.timestamp,
        current_step = row.current_step,
        total_elapsed_ms = row.total_elapsed_ms,
        delta_steps = row.delta_steps,
        delta_ms = row.delta_ms,
        instant_speed = row.delta_ms > 0 ? row.delta_steps / (row.delta_ms / 1000) : 0.0,
        worker_id = row.worker_id
    ) for row in eachrow(result)]
end

"""
    calculate_speeds(experiment_id::String; window_seconds=30) -> NamedTuple

Calculate total and short-horizon average speeds for an experiment.

Returns (total_avg_speed, short_avg_speed) in steps per second.
"""
function calculate_speeds(experiment_id::String; window_seconds::Real=30)
    db = get_db()
    
    # Total average speed (entire experiment)
    total_result = DBInterface.execute(db, """
        SELECT 
            MAX(current_step) as total_steps,
            MAX(total_elapsed_ms) as total_ms
        FROM progress_snapshots
        WHERE experiment_id = ?
    """, [experiment_id]) |> DataFrame
    
    total_avg_speed = if nrow(total_result) > 0 && total_result.total_steps[1] !== nothing
        total_ms = total_result.total_ms[1]
        total_steps = total_result.total_steps[1]
        total_ms > 0 ? total_steps / (total_ms / 1000) : 0.0
    else
        0.0
    end
    
    # Short-horizon speed (recent window)
    short_result = DBInterface.execute(db, """
        SELECT 
            SUM(delta_steps) as window_steps,
            SUM(delta_ms) as window_ms
        FROM progress_snapshots
        WHERE experiment_id = ?
        AND timestamp > datetime('now', '-$(Int(window_seconds)) seconds')
    """, [experiment_id]) |> DataFrame
    
    short_avg_speed = if nrow(short_result) > 0 && short_result.window_steps[1] !== nothing
        window_steps = short_result.window_steps[1]
        window_ms = short_result.window_ms[1]
        window_ms > 0 ? window_steps / (window_ms / 1000) : 0.0
    else
        # Fall back to using the last snapshot's instantaneous speed
        0.0
    end
    
    return (total_avg_speed=total_avg_speed, short_avg_speed=short_avg_speed)
end

"""
    get_recent_speeds(experiment_id::String; n=20, window_seconds=60) -> Vector{Float64}

Get recent speed measurements for sparkline visualization.
Returns vector of speeds (steps per second) over time.
"""
function get_recent_speeds(experiment_id::String; n::Int=20, window_seconds::Real=60)
    db = get_db()
    
    result = DBInterface.execute(db, """
        SELECT 
            delta_steps,
            delta_ms,
            timestamp
        FROM progress_snapshots
        WHERE experiment_id = ?
        AND timestamp > datetime('now', '-$(Int(window_seconds)) seconds')
        ORDER BY timestamp DESC
        LIMIT ?
    """, [experiment_id, n]) |> DataFrame
    
    speeds = Float64[]
    for row in eachrow(result)
        if row.delta_ms > 0
            push!(speeds, row.delta_steps / (row.delta_ms / 1000))
        end
    end
    
    return reverse(speeds)  # Return in chronological order
end

"""
    get_completion_histogram(bin_size::Int=10) -> Vector{Int}

Get distribution of experiment completion percentages in bins.
Returns vector of counts for bins: 0-10%, 10-20%, ..., 90-100%.
"""
function get_completion_histogram(bin_size::Int=10)
    db = get_db()
    
    num_bins = div(100, bin_size)
    histogram = zeros(Int, num_bins)
    
    result = DBInterface.execute(db, """
        SELECT 
            CAST((current_step * 100.0 / total_steps) / ? AS INTEGER) as bin,
            COUNT(*) as count
        FROM experiments
        WHERE status IN ('running', 'completed', 'failed')
        GROUP BY bin
    """, [bin_size]) |> DataFrame
    
    for row in eachrow(result)
        bin_idx = row.bin + 1  # Convert 0-indexed to 1-indexed
        if 1 <= bin_idx <= num_bins
            histogram[bin_idx] = row.count
        end
    end
    
    return histogram
end

"""
    get_experiment_stats(; days=7) -> NamedTuple

Get aggregate statistics for experiments.
"""
function get_experiment_stats(; days::Int=7)
    db = get_db()
    
    result = DBInterface.execute(db, """
        SELECT 
            COUNT(*) as total,
            SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed,
            SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) as running,
            AVG(CASE WHEN finished_at IS NOT NULL 
                THEN (julianday(finished_at) - julianday(started_at)) * 86400 
                ELSE NULL END) as avg_duration_seconds,
            AVG(CASE WHEN status = 'completed' AND finished_at IS NOT NULL
                THEN (julianday(finished_at) - julianday(started_at)) * 86400
                ELSE NULL END) as avg_success_duration_seconds
        FROM experiments
        WHERE started_at > datetime('now', '-$(days) days')
    """) |> DataFrame
    
    row = result[1, :]
    return (
        total = row.total,
        completed = row.completed,
        failed = row.failed,
        running = row.running,
        avg_duration_seconds = row.avg_duration_seconds,
        avg_success_duration_seconds = row.avg_success_duration_seconds
    )
end

"""
    update_experiment_status!(experiment_id::String, status::String; message=nothing)

Manually update an experiment's status (for admin operations).
"""
function update_experiment_status!(experiment_id::String, status::String;
                                   message::Union{String,Nothing}=nothing)
    db = get_db()
    
    if message !== nothing
        DBInterface.execute(db, """
            UPDATE experiments 
            SET status = ?, final_message = ?
            WHERE id = ?
        """, [status, message, experiment_id])
    else
        DBInterface.execute(db, """
            UPDATE experiments 
            SET status = ?
            WHERE id = ?
        """, [status, experiment_id])
    end
    
    # If completing, set finished_at
    if status in ("completed", "failed", "cancelled")
        DBInterface.execute(db, """
            UPDATE experiments 
            SET finished_at = datetime('now')
            WHERE id = ? AND finished_at IS NULL
        """, [experiment_id])
    end
    
    return nothing
end

"""
    update_experiment_steps!(experiment_id::String, current_step::Int)

Manually update an experiment's current step (for admin operations).
"""
function update_experiment_steps!(experiment_id::String, current_step::Int)
    db = get_db()
    
    DBInterface.execute(db, """
        UPDATE experiments 
        SET current_step = ?
        WHERE id = ?
    """, [current_step, experiment_id])
    
    return nothing
end

"""
    close_db!()

Close the database connection.
"""
function close_db!()
    if DB[] !== nothing
        SQLite.close(DB[])
        DB[] = nothing
    end
end

# === Helper Functions ===

function _row_to_namedtuple(row)
    return (
        id = row.id,
        name = row.name,
        description = row.description,
        total_steps = row.total_steps,
        current_step = row.current_step,
        status = Symbol(row.status),
        started_at = row.started_at,
        finished_at = row.finished_at,
        final_message = row.final_message,
        worker_count = row.worker_count,
        metadata = row.metadata,
        progress_pct = 100.0 * row.current_step / row.total_steps
    )
end

end # module Database
