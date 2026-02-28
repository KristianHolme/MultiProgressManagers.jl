module Database

using SQLite
using DBInterface
using DataFrames
using Dates
using UUIDs

export init_db!, close_db!, DBHandle
export create_experiment, record_progress!, finish_experiment!, fail_experiment!
export get_experiment, get_running_experiments, get_all_experiments
export get_experiment_history, get_completion_histogram
export update_experiment_status!, update_experiment_steps!
export calculate_speeds, get_recent_speeds
export get_experiment_stats, get_daily_stats
export ensure_open!

"""
    DBHandle

A handle to a SQLite database that opens the connection lazily.
This prevents issues during module precompilation.
"""
mutable struct DBHandle
    db::Union{SQLite.DB,Nothing}
    path::String

    function DBHandle(path::String)
        return new(nothing, path)
    end
end

"""
    ensure_open!(handle::DBHandle) -> SQLite.DB

Ensure the database handle is open, opening it if necessary.
Initializes schema on first open. Enables WAL mode and sets busy timeout.
"""
function ensure_open!(handle::DBHandle)
    if handle.db === nothing || !SQLite.isopen(handle.db)
        handle.db = SQLite.DB(handle.path)
        
        # Enable WAL mode for better concurrency
        DBInterface.execute(handle.db, "PRAGMA journal_mode = WAL;")
        
        # Set busy timeout to 5 seconds (5000ms) - wait for locks instead of failing
        DBInterface.execute(handle.db, "PRAGMA busy_timeout = 5000;")
        
        # Set synchronous mode to NORMAL for better performance with WAL
        DBInterface.execute(handle.db, "PRAGMA synchronous = NORMAL;")
        
        _init_schema!(handle.db)
    end
    return handle.db
end

"""
    close!(handle::DBHandle)

Close the database handle.
"""
function close!(handle::DBHandle)
    if handle.db !== nothing
        try
            SQLite.close(handle.db)
        catch
        end
        handle.db = nothing
    end
    return nothing
end

"""
    with_retry(f::Function, max_retries::Int=3, initial_delay::Float64=0.01)

Execute a database function with retry logic for lock errors.
"""
function with_retry(f::Function, max_retries::Int=3, initial_delay::Float64=0.01)
    delay = initial_delay
    for attempt in 1:max_retries
        try
            return f()
        catch e
            # Check if it's a database lock error
            error_str = sprint(showerror, e)
            is_lock_error = occursin("locked", lowercase(error_str)) || 
                           occursin("busy", lowercase(error_str)) ||
                           occursin("database is locked", error_str)
            
            if is_lock_error && attempt < max_retries
                # Exponential backoff with jitter
                sleep(delay * (1 + 0.1 * rand()))
                delay *= 2  # Double the delay for next attempt
            else
                # Last attempt failed or not a lock error
                rethrow(e)
            end
        end
    end
end

"""
    init_db!(db_path::String) -> DBHandle

Initialize the database handle. The actual connection is opened lazily.
This prevents database lock issues during precompilation.
"""
function init_db!(db_path::String)
    mkpath(dirname(db_path))
    return DBHandle(db_path)
end

"""
    close_db!(handle::DBHandle)

Close the database handle.
"""
function close_db!(handle::DBHandle)
    close!(handle)
    return nothing
end

"""
    _init_schema!(db::SQLite.DB)

Internal: Initialize database schema with tables and indexes.
"""
function _init_schema!(db::SQLite.DB)
    # Experiments table - master records
    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS experiments (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            total_steps INTEGER NOT NULL,
            current_step INTEGER DEFAULT 0,
            status TEXT DEFAULT 'running',
            started_at DATETIME NOT NULL,
            finished_at DATETIME,
            worker_count INTEGER DEFAULT 1,
            final_message TEXT
        )
        """
    )

    # Progress snapshots table - detailed history
    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS progress_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            experiment_id TEXT NOT NULL,
            timestamp DATETIME NOT NULL,
            current_step INTEGER NOT NULL,
            total_elapsed_ms INTEGER NOT NULL,
            delta_steps INTEGER,
            delta_ms INTEGER,
            info TEXT,
            worker_id INTEGER,
            FOREIGN KEY (experiment_id) REFERENCES experiments(id) ON DELETE CASCADE
        )
        """
    )

    # Indexes for common queries
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_exp_status ON experiments(status)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_exp_started ON experiments(started_at)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_snapshots_exp ON progress_snapshots(experiment_id)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_snapshots_time ON progress_snapshots(timestamp)")

    # Daily stats view
    DBInterface.execute(
        db,
        """
        CREATE VIEW IF NOT EXISTS v_daily_experiments AS
        SELECT 
            date(started_at) as date,
            count(*) as total_started,
            sum(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
            sum(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed,
            sum(CASE WHEN status = 'running' THEN 1 ELSE 0 END) as running
        FROM experiments
        GROUP BY date(started_at)
        ORDER BY date DESC
        """
    )
end

# === CRUD Operations ===

"""
    create_experiment(handle::DBHandle, name::String, total_steps::Int;
                     description::String="", worker_count::Int=1) -> String

Create a new experiment record and return its ID.
"""
function create_experiment(handle::DBHandle, name::String, total_steps::Int;
                          description::String="", worker_count::Int=1)
    db = ensure_open!(handle)
    experiment_id = string(UUIDs.uuid4())
    
    with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            INSERT INTO experiments (id, name, description, total_steps, started_at, worker_count)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [experiment_id, name, description, total_steps, Dates.now(), worker_count]
        )
    end
    
    return experiment_id
end

"""
    record_progress!(handle::DBHandle, experiment_id::String, current_step::Int, 
                    total_elapsed_ms::Int; info::String="", worker_id::Int=0)

Record a progress snapshot with automatic delta calculation.
"""
function record_progress!(handle::DBHandle, experiment_id::String, current_step::Int, 
                         total_elapsed_ms::Int; info::String="", worker_id::Int=0)
    db = ensure_open!(handle)
    
    with_retry(3, 0.01) do
        # Get previous snapshot for delta calculation
        prev = DBInterface.execute(
            db,
            """
            SELECT current_step, total_elapsed_ms 
            FROM progress_snapshots 
            WHERE experiment_id = ? 
            ORDER BY timestamp DESC 
            LIMIT 1
            """,
            [experiment_id]
        ) |> DataFrame

        delta_steps = 0
        delta_ms = 0
        
        if !isempty(prev)
            delta_steps = current_step - prev.current_step[1]
            delta_ms = total_elapsed_ms - prev.total_elapsed_ms[1]
        end

        # Insert snapshot
        DBInterface.execute(
            db,
            """
            INSERT INTO progress_snapshots 
                (experiment_id, timestamp, current_step, total_elapsed_ms, delta_steps, delta_ms, info, worker_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [experiment_id, Dates.now(), current_step, total_elapsed_ms, delta_steps, delta_ms, info, worker_id]
        )

        # Update experiment current_step
        DBInterface.execute(
            db,
            "UPDATE experiments SET current_step = ? WHERE id = ?",
            [current_step, experiment_id]
        )
    end
end

"""
    finish_experiment!(handle::DBHandle, experiment_id::String; message::String="Completed successfully")

Mark an experiment as completed.
"""
function finish_experiment!(handle::DBHandle, experiment_id::String; message::String="Completed successfully")
    db = ensure_open!(handle)
    
    with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            UPDATE experiments 
            SET status = 'completed', finished_at = ?, final_message = ?
            WHERE id = ?
            """,
            [Dates.now(), message, experiment_id]
        )
    end
end

"""
    fail_experiment!(handle::DBHandle, experiment_id::String, error_message::String)

Mark an experiment as failed.
"""
function fail_experiment!(handle::DBHandle, experiment_id::String, error_message::String)
    db = ensure_open!(handle)
    
    with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            UPDATE experiments 
            SET status = 'failed', finished_at = ?, final_message = ?
            WHERE id = ?
            """,
            [Dates.now(), error_message, experiment_id]
        )
    end
end

"""
    update_experiment_status!(handle::DBHandle, experiment_id::String, status::String; 
                             message::Union{String,Nothing}=nothing)

Manually update experiment status (for admin operations).
"""
function update_experiment_status!(handle::DBHandle, experiment_id::String, status::String; 
                                 message::Union{String,Nothing}=nothing)
    db = ensure_open!(handle)
    
    with_retry(3, 0.01) do
        if message !== nothing
            DBInterface.execute(
                db,
                "UPDATE experiments SET status = ?, final_message = ? WHERE id = ?",
                [status, message, experiment_id]
            )
        else
            DBInterface.execute(
                db,
                "UPDATE experiments SET status = ? WHERE id = ?",
                [status, experiment_id]
            )
        end
    end
end

"""
    update_experiment_steps!(handle::DBHandle, experiment_id::String, current_step::Int)

Manually update current step (for admin operations).
"""
function update_experiment_steps!(handle::DBHandle, experiment_id::String, current_step::Int)
    db = ensure_open!(handle)
    
    with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            "UPDATE experiments SET current_step = ? WHERE id = ?",
            [current_step, experiment_id]
        )
    end
end

# === Query Operations ===

"""
    get_experiment(handle::DBHandle, experiment_id::String)

Get experiment details by ID.
"""
function get_experiment(handle::DBHandle, experiment_id::String)
    db = ensure_open!(handle)
    
    result = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            "SELECT * FROM experiments WHERE id = ?",
            [experiment_id]
        ) |> DataFrame
    end
    
    return isempty(result) ? nothing : result[1, :]
end

"""
    get_running_experiments(handle::DBHandle)

Get all running experiments.
"""
function get_running_experiments(handle::DBHandle)
    db = ensure_open!(handle)
    
    result = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            SELECT id, name, total_steps, current_step, started_at, worker_count, status,
                   CAST(current_step AS FLOAT) / total_steps as progress_pct
            FROM experiments 
            WHERE status = 'running'
            ORDER BY started_at DESC
            """
        ) |> DataFrame
    end
    
    return result
end

"""
    get_all_experiments(handle::DBHandle; limit::Int=100, offset::Int=0)

Get all experiments with pagination.
"""
function get_all_experiments(handle::DBHandle; limit::Int=100, offset::Int=0)
    db = ensure_open!(handle)
    
    result = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            SELECT *, CAST(current_step AS FLOAT) / total_steps as progress_pct
            FROM experiments 
            ORDER BY started_at DESC
            LIMIT ? OFFSET ?
            """,
            [limit, offset]
        ) |> DataFrame
    end
    
    return result
end

"""
    get_experiment_history(handle::DBHandle, experiment_id::String; 
                          since::Union{DateTime,Nothing}=nothing)

Get progress history for an experiment.
"""
function get_experiment_history(handle::DBHandle, experiment_id::String; 
                               since::Union{DateTime,Nothing}=nothing)
    db = ensure_open!(handle)
    
    if since !== nothing
        result = with_retry(3, 0.01) do
            DBInterface.execute(
                db,
                """
                SELECT * FROM progress_snapshots 
                WHERE experiment_id = ? AND timestamp > ?
                ORDER BY timestamp
                """,
                [experiment_id, since]
            ) |> DataFrame
        end
    else
        result = with_retry(3, 0.01) do
            DBInterface.execute(
                db,
                """
                SELECT * FROM progress_snapshots 
                WHERE experiment_id = ?
                ORDER BY timestamp
                """,
                [experiment_id]
            ) |> DataFrame
        end
    end
    
    return result
end

# === Speed Calculations ===

"""
    calculate_speeds(handle::DBHandle, experiment_id::String; 
                    window_seconds::Real=30) -> NamedTuple

Calculate total average speed and short-horizon speed.
"""
function calculate_speeds(handle::DBHandle, experiment_id::String; 
                         window_seconds::Real=30)
    db = ensure_open!(handle)
    
    # Get experiment info
    exp = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            "SELECT current_step, total_steps FROM experiments WHERE id = ?",
            [experiment_id]
        ) |> DataFrame
    end
    
    if isempty(exp)
        return (total_avg_speed = 0.0, short_avg_speed = 0.0)
    end
    
    current_step = exp.current_step[1]
    
    # Calculate total average (from very first snapshot)
    first_snap = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            SELECT timestamp, current_step, total_elapsed_ms
            FROM progress_snapshots 
            WHERE experiment_id = ?
            ORDER BY timestamp ASC
            LIMIT 1
            """,
            [experiment_id]
        ) |> DataFrame
    end
    
    total_avg_speed = 0.0
    if !isempty(first_snap) && first_snap.total_elapsed_ms[1] > 0
        total_elapsed_sec = first_snap.total_elapsed_ms[1] / 1000
        total_avg_speed = current_step / total_elapsed_sec
    end
    
    # Calculate short-horizon speed from window
    window_start = Dates.now() - Dates.Second(round(Int, window_seconds))
    window_snaps = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            SELECT delta_steps, delta_ms
            FROM progress_snapshots 
            WHERE experiment_id = ? AND timestamp > ? AND delta_steps > 0
            ORDER BY timestamp
            """,
            [experiment_id, window_start]
        ) |> DataFrame
    end
    
    short_avg_speed = 0.0
    if !isempty(window_snaps)
        total_delta_steps = sum(window_snaps.delta_steps)
        total_delta_ms = sum(window_snaps.delta_ms)
        if total_delta_ms > 0
            short_avg_speed = total_delta_steps / (total_delta_ms / 1000)
        end
    end
    
    return (
        total_avg_speed = total_avg_speed,
        short_avg_speed = short_avg_speed > 0 ? short_avg_speed : total_avg_speed
    )
end

"""
    get_recent_speeds(handle::DBHandle, experiment_id::String; 
                     n::Int=20, window_seconds::Real=60)

Get recent speed measurements as a vector for sparkline.
"""
function get_recent_speeds(handle::DBHandle, experiment_id::String; 
                          n::Int=20, window_seconds::Real=60)
    db = ensure_open!(handle)
    
    window_start = Dates.now() - Dates.Second(round(Int, window_seconds))
    
    result = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            SELECT delta_steps, delta_ms,
                   CAST(delta_steps AS FLOAT) / (CAST(delta_ms AS FLOAT) / 1000) as speed
            FROM progress_snapshots 
            WHERE experiment_id = ? AND timestamp > ? AND delta_ms > 0
            ORDER BY timestamp DESC
            LIMIT ?
            """,
            [experiment_id, window_start, n]
        ) |> DataFrame
    end
    
    if isempty(result)
        return Float64[]
    end
    
    # Reverse to get chronological order and handle any Inf/NaN
    speeds = Float64[]
    for s in reverse(result.speed)
        if isfinite(s) && s >= 0
            push!(speeds, s)
        end
    end
    
    return speeds
end

# === Statistics ===

"""
    get_experiment_stats(handle::DBHandle; days::Int=7)

Get aggregate statistics for experiments.
"""
function get_experiment_stats(handle::DBHandle; days::Int=7)
    db = ensure_open!(handle)
    
    since = Dates.now() - Dates.Day(days)
    
    result = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            SELECT 
                COUNT(*) as total,
                SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
                SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed,
                SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) as running,
                AVG(CASE 
                    WHEN finished_at IS NOT NULL 
                    THEN (julianday(finished_at) - julianday(started_at)) * 86400 
                    ELSE NULL 
                END) as avg_duration_seconds
            FROM experiments 
            WHERE started_at > ?
            """,
            [since]
        ) |> DataFrame
    end
    
    if isempty(result)
        return (
            total = 0,
            completed = 0,
            failed = 0,
            running = 0,
            avg_duration_seconds = nothing
        )
    end
    
    row = result[1, :]
    return (
        total = row.total,
        completed = row.completed,
        failed = row.failed,
        running = row.running,
        avg_duration_seconds = row.avg_duration_seconds
    )
end

"""
    get_completion_histogram(handle::DBHandle, bin_size::Int=10)

Get histogram of experiment completion percentages.
"""
function get_completion_histogram(handle::DBHandle, bin_size::Int=10)
    db = ensure_open!(handle)
    
    bins = zeros(Int, bin_size)
    
    result = with_retry(3, 0.01) do
        DBInterface.execute(
            db,
            """
            SELECT CAST(current_step AS FLOAT) / total_steps as progress
            FROM experiments
            WHERE status IN ('running', 'completed')
            """
        ) |> DataFrame
    end
    
    for row in eachrow(result)
        progress = row.progress
        bin_idx = min(floor(Int, progress * bin_size) + 1, bin_size)
        bins[bin_idx] += 1
    end
    
    return bins
end

end # module Database
