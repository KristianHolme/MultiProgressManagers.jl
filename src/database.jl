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
Initializes schema on first open.
"""
function ensure_open!(handle::DBHandle)
    if handle.db === nothing || !SQLite.isopen(handle.db)
        handle.db = SQLite.DB(handle.path)
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
            final_message TEXT,
            worker_count INTEGER DEFAULT 1,
            metadata TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        """,
    )

    # Progress snapshots - full history
    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS progress_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            experiment_id TEXT NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
            timestamp DATETIME NOT NULL,
            current_step INTEGER NOT NULL,
            total_elapsed_ms REAL NOT NULL,
            delta_steps INTEGER NOT NULL,
            delta_ms REAL NOT NULL,
            worker_id INTEGER,
            metadata TEXT
        )
        """,
    )

    # Worker assignments
    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS worker_assignments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            experiment_id TEXT NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
            worker_id INTEGER NOT NULL,
            assigned_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            steps_completed INTEGER DEFAULT 0,
            UNIQUE(experiment_id, worker_id)
        )
        """,
    )

    # Indexes for performance
    DBInterface.execute(
        db,
        """
        CREATE INDEX IF NOT EXISTS idx_snapshots_exp_time
        ON progress_snapshots(experiment_id, timestamp DESC)
        """,
    )

    DBInterface.execute(
        db,
        """
        CREATE INDEX IF NOT EXISTS idx_experiments_status
        ON experiments(status, started_at DESC)
        """,
    )

    DBInterface.execute(
        db,
        """
        CREATE INDEX IF NOT EXISTS idx_experiments_started
        ON experiments(started_at DESC)
        """,
    )

    # Analytics view
    DBInterface.execute(
        db,
        """
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
        """,
    )

    return db
end

# ============================================================================
# Database Operations
# ============================================================================

function create_experiment(
    handle::DBHandle,
    name::String,
    total_steps::Int;
    description::String = "",
    worker_count::Int = 1,
    metadata = nothing,
)
    db = ensure_open!(handle)
    id = string(UUIDs.uuid4())

    DBInterface.execute(
        db,
        """
        INSERT INTO experiments (id, name, description, total_steps, status, started_at, worker_count, metadata)
        VALUES (?, ?, ?, ?, 'running', datetime('now'), ?, ?)
        """,
        [id, name, description, total_steps, worker_count,
            metadata === nothing ? nothing : JSON3.write(metadata)],
    )

    return id
end

function record_progress!(
    handle::DBHandle,
    experiment_id::String,
    current_step::Int,
    elapsed_seconds::Real;
    worker_id::Union{Int,Nothing} = nothing,
    metadata = nothing,
)
    db = ensure_open!(handle)

    # Calculate deltas from last snapshot
    last_snapshot = DBInterface.execute(
        db,
        """
        SELECT current_step, total_elapsed_ms
        FROM progress_snapshots
        WHERE experiment_id = ?
        ORDER BY timestamp DESC
        LIMIT 1
        """,
        [experiment_id],
    ) |> DataFrame

    if nrow(last_snapshot) > 0
        last_step = last_snapshot.current_step[1]
        last_elapsed_ms = last_snapshot.total_elapsed_ms[1]
        delta_steps = current_step - last_step
        delta_ms = elapsed_seconds * 1000 - last_elapsed_ms
    else
        delta_steps = current_step
        delta_ms = elapsed_seconds * 1000
    end

    # Insert snapshot
    DBInterface.execute(
        db,
        """
        INSERT INTO progress_snapshots
        (experiment_id, timestamp, current_step, total_elapsed_ms, delta_steps, delta_ms, worker_id, metadata)
        VALUES (?, datetime('now'), ?, ?, ?, ?, ?, ?)
        """,
        [experiment_id, current_step, elapsed_seconds * 1000, delta_steps, delta_ms,
            worker_id, metadata === nothing ? nothing : JSON3.write(metadata)],
    )

    # Update experiment current_step
    DBInterface.execute(
        db,
        """
        UPDATE experiments
        SET current_step = ?
        WHERE id = ?
        """,
        [current_step, experiment_id],
    )

    return nothing
end

function finish_experiment!(
    handle::DBHandle,
    experiment_id::String;
    message::String = "Completed successfully",
)
    db = ensure_open!(handle)

    DBInterface.execute(
        db,
        """
        UPDATE experiments
        SET status = 'completed',
            finished_at = datetime('now'),
            final_message = ?
        WHERE id = ?
        """,
        [message, experiment_id],
    )

    return nothing
end

function fail_experiment!(handle::DBHandle, experiment_id::String, error_message::String)
    db = ensure_open!(handle)

    DBInterface.execute(
        db,
        """
        UPDATE experiments
        SET status = 'failed',
            finished_at = datetime('now'),
            final_message = ?
        WHERE id = ?
        """,
        [error_message, experiment_id],
    )

    return nothing
end

function get_experiment(handle::DBHandle, experiment_id::String)
    db = ensure_open!(handle)

    result = DBInterface.execute(
        db,
        """
        SELECT id, name, description, total_steps, current_step, status,
               started_at, finished_at, final_message, worker_count, metadata
        FROM experiments
        WHERE id = ?
        """,
        [experiment_id],
    ) |> DataFrame

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
        progress_pct = 100.0 * row.current_step / row.total_steps,
    )
end

function get_running_experiments(handle::DBHandle)
    db = ensure_open!(handle)

    result = DBInterface.execute(
        db,
        """
        SELECT id, name, description, total_steps, current_step, status,
               started_at, finished_at, final_message, worker_count, metadata
        FROM experiments
        WHERE status = 'running'
        ORDER BY started_at DESC
        """,
    ) |> DataFrame

    return [_row_to_namedtuple(row) for row in eachrow(result)]
end

function get_all_experiments(
    handle::DBHandle;
    status::Union{String,Nothing} = nothing,
    limit::Int = 100,
)
    db = ensure_open!(handle)

    if status === nothing
        result = DBInterface.execute(
            db,
            """
            SELECT id, name, description, total_steps, current_step, status,
                   started_at, finished_at, final_message, worker_count, metadata
            FROM experiments
            ORDER BY started_at DESC
            LIMIT ?
            """,
            [limit],
        ) |> DataFrame
    else
        result = DBInterface.execute(
            db,
            """
            SELECT id, name, description, total_steps, current_step, status,
                   started_at, finished_at, final_message, worker_count, metadata
            FROM experiments
            WHERE status = ?
            ORDER BY started_at DESC
            LIMIT ?
            """,
            [status, limit],
        ) |> DataFrame
    end

    return [_row_to_namedtuple(row) for row in eachrow(result)]
end

function calculate_speeds(
    handle::DBHandle,
    experiment_id::String;
    window_seconds::Real = 30,
)
    db = ensure_open!(handle)

    # Total average speed
    total_result = DBInterface.execute(
        db,
        """
        SELECT
            MAX(current_step) as total_steps,
            MAX(total_elapsed_ms) as total_ms
        FROM progress_snapshots
        WHERE experiment_id = ?
        """,
        [experiment_id],
    ) |> DataFrame

    total_avg_speed = if nrow(total_result) > 0 && total_result.total_steps[1] !== nothing
        total_ms = total_result.total_ms[1]
        total_steps = total_result.total_steps[1]
        total_ms > 0 ? total_steps / (total_ms / 1000) : 0.0
    else
        0.0
    end

    # Short-horizon speed
    short_result = DBInterface.execute(
        db,
        """
        SELECT
            SUM(delta_steps) as window_steps,
            SUM(delta_ms) as window_ms
        FROM progress_snapshots
        WHERE experiment_id = ?
        AND timestamp > datetime('now', '-$(Int(window_seconds)) seconds')
        """,
        [experiment_id],
    ) |> DataFrame

    short_avg_speed = if nrow(short_result) > 0 && short_result.window_steps[1] !== nothing
        window_steps = short_result.window_steps[1]
        window_ms = short_result.window_ms[1]
        window_ms > 0 ? window_steps / (window_ms / 1000) : 0.0
    else
        0.0
    end

    return (;total_avg_speed, short_avg_speed)
end

function get_recent_speeds(
    handle::DBHandle,
    experiment_id::String;
    n::Int = 20,
    window_seconds::Real = 60,
)
    db = ensure_open!(handle)

    result = DBInterface.execute(
        db,
        """
        SELECT delta_steps, delta_ms
        FROM progress_snapshots
        WHERE experiment_id = ?
        AND timestamp > datetime('now', '-$(Int(window_seconds)) seconds')
        ORDER BY timestamp DESC
        LIMIT ?
        """,
        [experiment_id, n],
    ) |> DataFrame

    speeds = Float64[]
    for row in eachrow(result)
        if row.delta_ms > 0
            push!(speeds, row.delta_steps / (row.delta_ms / 1000))
        end
    end

    return reverse(speeds)
end

function get_completion_histogram(handle::DBHandle, bin_size::Int = 10)
    db = ensure_open!(handle)

    num_bins = div(100, bin_size)
    histogram = zeros(Int, num_bins)

    result = DBInterface.execute(
        db,
        """
        SELECT
            CAST((current_step * 100.0 / total_steps) / ? AS INTEGER) as bin,
            COUNT(*) as count
        FROM experiments
        WHERE status IN ('running', 'completed', 'failed')
        GROUP BY bin
        """,
        [bin_size],
    ) |> DataFrame

    for row in eachrow(result)
        bin_idx = row.bin + 1
        if 1 <= bin_idx <= num_bins
            histogram[bin_idx] = row.count
        end
    end

    return histogram
end

function get_experiment_stats(handle::DBHandle; days::Int = 7)
    db = ensure_open!(handle)

    result = DBInterface.execute(
        db,
        """
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
        """,
    ) |> DataFrame

    row = result[1, :]
    return (
        total = row.total,
        completed = row.completed,
        failed = row.failed,
        running = row.running,
        avg_duration_seconds = row.avg_duration_seconds,
        avg_success_duration_seconds = row.avg_success_duration_seconds,
    )
end

function update_experiment_status!(
    handle::DBHandle,
    experiment_id::String,
    status::String;
    message::Union{String,Nothing} = nothing,
)
    db = ensure_open!(handle)

    if message !== nothing
        DBInterface.execute(
            db,
            """
            UPDATE experiments
            SET status = ?, final_message = ?
            WHERE id = ?
            """,
            [status, message, experiment_id],
        )
    else
        DBInterface.execute(
            db,
            """
            UPDATE experiments
            SET status = ?
            WHERE id = ?
            """,
            [status, experiment_id],
        )
    end

    if status in ("completed", "failed", "cancelled")
        DBInterface.execute(
            db,
            """
            UPDATE experiments
            SET finished_at = datetime('now')
            WHERE id = ? AND finished_at IS NULL
            """,
            [experiment_id],
        )
    end

    return nothing
end

function update_experiment_steps!(
    handle::DBHandle,
    experiment_id::String,
    current_step::Int,
)
    db = ensure_open!(handle)

    DBInterface.execute(
        db,
        """
        UPDATE experiments
        SET current_step = ?
        WHERE id = ?
        """,
        [current_step, experiment_id],
    )

    return nothing
end

function get_experiment_history(
    handle::DBHandle,
    experiment_id::String;
    limit::Int = 1000,
)
    db = ensure_open!(handle)

    result = DBInterface.execute(
        db,
        """
        SELECT timestamp, current_step, total_elapsed_ms, delta_steps, delta_ms, worker_id
        FROM progress_snapshots
        WHERE experiment_id = ?
        ORDER BY timestamp DESC
        LIMIT ?
        """,
        [experiment_id, limit],
    ) |> DataFrame

    return [(
        timestamp = row.timestamp,
        current_step = row.current_step,
        total_elapsed_ms = row.total_elapsed_ms,
        delta_steps = row.delta_steps,
        delta_ms = row.delta_ms,
        instant_speed = row.delta_ms > 0 ? row.delta_steps / (row.delta_ms / 1000) : 0.0,
        worker_id = row.worker_id,
    ) for row in eachrow(result)]
end

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
        progress_pct = 100.0 * row.current_step / row.total_steps,
    )
end

end # module Database
