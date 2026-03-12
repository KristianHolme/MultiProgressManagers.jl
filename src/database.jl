module Database

using SQLite
using DBInterface
using DataFrames
using Dates
using UUIDs

export init_db!, close_db!, DBHandle, ensure_open!
export create_experiment, create_task, update_task!, get_experiment_tasks
export record_progress!, finish_experiment!, fail_experiment!
export get_experiment, get_running_experiments, get_all_experiments
export update_experiment_status!, update_experiment_steps!
export calculate_speeds, get_recent_speeds
export get_experiment_stats, get_completion_histogram

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

function _open_new_db(path::String)
    is_new_database = !isfile(path) || filesize(path) == 0
    db = SQLite.DB(path)
    DBInterface.execute(db, "PRAGMA busy_timeout = 5000;")
    if is_new_database
        DBInterface.execute(db, "PRAGMA journal_mode = WAL;")
    end
    DBInterface.execute(db, "PRAGMA synchronous = NORMAL;")
    _init_schema!(db)
    return db
end

function _get_db(::Nothing, path::String)
    return _open_new_db(path)
end

function _get_db(db::SQLite.DB, path::String)
    if SQLite.isopen(db)
        return db
    end
    try
        SQLite.close(db)
    catch
    end
    return _open_new_db(path)
end

"""
    ensure_open!(handle::DBHandle) -> SQLite.DB

Ensure the database handle is open, opening it if necessary.
Initializes schema on first open. Enables WAL mode and sets busy timeout.
"""
function ensure_open!(handle::DBHandle)
    db = _get_db(handle.db, handle.path)
    handle.db = db
    return db
end

function _close_db(::Nothing)
    return nothing
end

function _close_db(db::SQLite.DB)
    try
        SQLite.close(db)
    catch
    end
    return nothing
end

"""
    close!(handle::DBHandle)

Close the database handle.
"""
function close!(handle::DBHandle)
    _close_db(handle.db)
    handle.db = nothing
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
            error_str = sprint(showerror, e)
            is_lock_error = occursin("locked", lowercase(error_str)) ||
                occursin("busy", lowercase(error_str)) ||
                occursin("database is locked", error_str)

            if is_lock_error && attempt < max_retries
                sleep(delay * (1 + 0.1 * rand()))
                delay *= 2
            else
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
    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS experiments (
            id TEXT PRIMARY KEY,
            name TEXT,
            description TEXT,
            total_tasks INTEGER,
            status TEXT CHECK(status IN ('running', 'completed', 'failed')),
            started_at REAL,
            finished_at REAL,
            final_message TEXT
        )
        """
    )

    DBInterface.execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            experiment_id TEXT,
            task_number INTEGER,
            total_steps INTEGER,
            current_step INTEGER,
            status TEXT CHECK(status IN ('pending', 'running', 'completed', 'failed')),
            started_at REAL,
            last_updated REAL,
            display_message TEXT DEFAULT '',
            FOREIGN KEY (experiment_id) REFERENCES experiments(id)
        )
        """
    )

    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_exp_status ON experiments(status)")
    DBInterface.execute(db, "CREATE INDEX IF NOT EXISTS idx_tasks_exp ON tasks(experiment_id)")
    return nothing
end


function _current_timestamp()
    return time()
end

function _maybe_datetime(value::Union{Missing,Nothing,Real})
    value === missing && return missing
    value === nothing && return nothing
    return unix2datetime(value)
end

function _existing_experiment(handle::DBHandle)
    db = ensure_open!(handle)
    result = with_retry() do
        return DBInterface.execute(
            db,
            """
            SELECT id, name, description, total_tasks, status, started_at
            FROM experiments
            LIMIT 1
            """
        ) |> DataFrame
    end

    if isempty(result)
        return nothing
    end

    row = result[1, :]
    return (
        id = String(row.id),
        name = ismissing(row.name) ? "Unknown" : String(row.name),
        description = ismissing(row.description) ? "" : String(row.description),
        total_tasks = Int(row.total_tasks),
        status = ismissing(row.status) ? "running" : String(row.status),
        started_at = Float64(row.started_at),
    )
end

function _existing_experiment_name(handle::DBHandle)
    experiment = _existing_experiment(handle)
    if experiment === nothing
        return nothing
    end

    return experiment.name
end

"""
    create_experiment(handle::DBHandle, name::String, total_tasks::Int;
                      description::String="") -> String

Create a new experiment record with tasks and return its ID.
"""
function create_experiment(handle::DBHandle, name::String, total_tasks::Int;
    description::String = ""
)
    db = ensure_open!(handle)
    existing_experiment = _existing_experiment(handle)
    if existing_experiment !== nothing
        if existing_experiment.name != name
            error(
                "Database file already contains experiment \"$(existing_experiment.name)\": $(handle.path). " *
                "Each experiment must use its own DB file."
            )
        end
        if existing_experiment.total_tasks != total_tasks
            error(
                "Existing experiment \"$name\" in $(handle.path) has $(existing_experiment.total_tasks) tasks, " *
                "but $total_tasks were requested."
            )
        end

        return existing_experiment.id
    end

    experiment_id = string(UUIDs.uuid4())
    started_at = _current_timestamp()

    with_retry() do
        try
            DBInterface.execute(
                db,
                """
                INSERT INTO experiments (id, name, description, total_tasks, status, started_at, final_message)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [experiment_id, name, description, total_tasks, "running", started_at, ""]
            )

            for task_number in 1:total_tasks
                task_id = string(UUIDs.uuid4())
                DBInterface.execute(
                    db,
                    """
                    INSERT INTO tasks
                        (id, experiment_id, task_number, total_steps, current_step, status, started_at, last_updated, display_message)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        task_id,
                        experiment_id,
                        task_number,
                        0,
                        0,
                        "pending",
                        started_at,
                        started_at,
                        "",
                    ]
                )
            end
        catch
            rethrow()
        end
    end

    return experiment_id
end

"""
    create_experiment(name::String, total_tasks::Int;
                      description::String="", db_path::String) -> String

Create a new experiment in the specified database path.
"""
function create_experiment(name::String, total_tasks::Int;
    description::String = "",
    db_path::String
)
    handle = init_db!(db_path)
    try
        return create_experiment(handle, name, total_tasks; description = description)
    finally
        close_db!(handle)
    end
end

"""
    create_task(handle::DBHandle, experiment_id::String, task_number::Int, total_steps::Int;
                status::String="pending") -> String

Create a new task for an experiment and return its ID.
"""
function create_task(
    handle::DBHandle,
    experiment_id::String,
    task_number::Int,
    total_steps::Int;
    status::String = "pending"
)
    db = ensure_open!(handle)
    task_id = string(UUIDs.uuid4())
    started_at = _current_timestamp()

    with_retry() do
        DBInterface.execute(
            db,
            """
            INSERT INTO tasks
                (id, experiment_id, task_number, total_steps, current_step, status, started_at, last_updated, display_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                task_id,
                experiment_id,
                task_number,
                total_steps,
                0,
                status,
                started_at,
                started_at,
                "",
            ]
        )
    end

    return task_id
end

"""
    update_task!(handle::DBHandle, task_id::String, current_step::Int;
                 total_steps::Union{Int,Nothing}=nothing,
                 status::Union{String,Nothing}=nothing,
                 message::Union{String,Nothing}=nothing)

Update task progress, timestamps, and optional display message.
"""
function update_task!(
    handle::DBHandle,
    task_id::String,
    current_step::Int;
    total_steps::Union{Int,Nothing} = nothing,
    status::Union{String,Nothing} = nothing,
    message::Union{String,Nothing} = nothing
)
    db = ensure_open!(handle)
    last_updated = _current_timestamp()

    task_row = with_retry() do
        DBInterface.execute(
            db,
            "SELECT total_steps FROM tasks WHERE id = ?",
            [task_id]
        ) |> DataFrame
    end

    if isempty(task_row)
        error("Task not found: $task_id")
    end

    effective_total = total_steps === nothing ? task_row.total_steps[1] : total_steps
    next_status = if status !== nothing
        status
    elseif effective_total > 0 && current_step >= effective_total
        "completed"
    else
        "running"
    end

    with_retry() do
        if total_steps === nothing && message === nothing
            DBInterface.execute(
                db,
                """
                UPDATE tasks
                SET current_step = ?, status = ?, last_updated = ?
                WHERE id = ?
                """,
                [current_step, next_status, last_updated, task_id]
            )
        elseif total_steps === nothing && message !== nothing
            DBInterface.execute(
                db,
                """
                UPDATE tasks
                SET current_step = ?, status = ?, last_updated = ?, display_message = ?
                WHERE id = ?
                """,
                [current_step, next_status, last_updated, message, task_id]
            )
        elseif total_steps !== nothing && message === nothing
            DBInterface.execute(
                db,
                """
                UPDATE tasks
                SET total_steps = ?, current_step = ?, status = ?, last_updated = ?
                WHERE id = ?
                """,
                [effective_total, current_step, next_status, last_updated, task_id]
            )
        else
            DBInterface.execute(
                db,
                """
                UPDATE tasks
                SET total_steps = ?, current_step = ?, status = ?, last_updated = ?, display_message = ?
                WHERE id = ?
                """,
                [effective_total, current_step, next_status, last_updated, message, task_id]
            )
        end
    end

    return nothing
end

"""
    get_experiment_tasks(handle::DBHandle, experiment_id::String) -> DataFrame

Return all tasks for an experiment.
"""
function get_experiment_tasks(handle::DBHandle, experiment_id::String)
    db = ensure_open!(handle)

    return with_retry() do
        DBInterface.execute(
            db,
            """
            SELECT * FROM tasks
            WHERE experiment_id = ?
            ORDER BY task_number
            """,
            [experiment_id]
        ) |> DataFrame
    end
end

"""
    record_progress!(handle::DBHandle, experiment_id::String, current_step::Int,
                     total_elapsed_ms::Int; info::String="", worker_id::Int=0)

Record progress by updating a task associated with the experiment.
"""
function record_progress!(
    handle::DBHandle,
    experiment_id::String,
    current_step::Int,
    total_elapsed_ms::Int;
    info::String = "",
    worker_id::Int = 0
)
    db = ensure_open!(handle)
    task_number = worker_id > 0 ? worker_id : 1
    _ = total_elapsed_ms

    task_id_df = with_retry() do
        DBInterface.execute(
            db,
            "SELECT id FROM tasks WHERE experiment_id = ? AND task_number = ?",
            [experiment_id, task_number]
        ) |> DataFrame
    end

    if isempty(task_id_df)
        task_id = create_task(handle, experiment_id, task_number, max(current_step, 0))
    else
        task_id = task_id_df.id[1]
    end

    msg = isempty(info) ? nothing : info
    update_task!(handle, task_id, current_step; message = msg)
    return nothing
end

"""
    finish_experiment!(handle::DBHandle, experiment_id::String; message::String="Completed successfully")

Mark an experiment and its tasks as completed.
"""
function finish_experiment!(
    handle::DBHandle,
    experiment_id::String;
    message::String = "Completed successfully"
)
    db = ensure_open!(handle)
    finished_at = _current_timestamp()

    with_retry() do
        DBInterface.execute(
            db,
            """
            UPDATE experiments
            SET status = 'completed', finished_at = ?, final_message = ?
            WHERE id = ?
            """,
            [finished_at, message, experiment_id]
        )

        DBInterface.execute(
            db,
            """
            UPDATE tasks
            SET current_step = total_steps, status = 'completed', last_updated = ?
            WHERE experiment_id = ?
            """,
            [finished_at, experiment_id]
        )
    end

    return nothing
end

function fail_experiment!(handle::DBHandle, experiment_id::Nothing, error_message::String)
    return nothing
end

"""
    fail_experiment!(handle::DBHandle, experiment_id::String, error_message::String)

Mark an experiment as failed.
"""
function fail_experiment!(handle::DBHandle, experiment_id::String, error_message::String)
    db = ensure_open!(handle)
    finished_at = _current_timestamp()

    with_retry() do
        DBInterface.execute(
            db,
            """
            UPDATE experiments
            SET status = 'failed', finished_at = ?, final_message = ?
            WHERE id = ?
            """,
            [finished_at, error_message, experiment_id]
        )

        DBInterface.execute(
            db,
            """
            UPDATE tasks
            SET status = 'failed', last_updated = ?
            WHERE experiment_id = ?
            """,
            [finished_at, experiment_id]
        )
    end

    return nothing
end

"""
    update_experiment_status!(handle::DBHandle, experiment_id::String, status::String)

Manually update experiment status.
"""
function update_experiment_status!(handle::DBHandle, experiment_id::String, status::String)
    db = ensure_open!(handle)
    finished_at = status == "running" ? nothing : _current_timestamp()

    with_retry() do
        if finished_at === nothing
            DBInterface.execute(
                db,
                "UPDATE experiments SET status = ?, finished_at = NULL WHERE id = ?",
                [status, experiment_id]
            )
        else
            DBInterface.execute(
                db,
                "UPDATE experiments SET status = ?, finished_at = ? WHERE id = ?",
                [status, finished_at, experiment_id]
            )
        end
    end

    return nothing
end

"""
    update_experiment_steps!(handle::DBHandle, experiment_id::String, current_step::Int)

Manually update current step for all tasks in an experiment.
"""
function update_experiment_steps!(handle::DBHandle, experiment_id::String, current_step::Int)
    db = ensure_open!(handle)
    last_updated = _current_timestamp()

    with_retry() do
        DBInterface.execute(
            db,
            """
            UPDATE tasks
            SET current_step = ?,
                status = CASE
                    WHEN total_steps > 0 AND ? >= total_steps THEN 'completed'
                    ELSE 'running'
                END,
                last_updated = ?
            WHERE experiment_id = ?
            """,
            [current_step, current_step, last_updated, experiment_id]
        )
    end

    return nothing
end

"""
    get_experiment(handle::DBHandle, experiment_id::String)

Get experiment details by ID.
"""
function get_experiment(handle::DBHandle, experiment_id::String)
    db = ensure_open!(handle)

    result = with_retry() do
        DBInterface.execute(
            db,
            "SELECT * FROM experiments WHERE id = ?",
            [experiment_id]
        ) |> DataFrame
    end

    if isempty(result)
        return nothing
    end

    result.started_at .= _maybe_datetime.(result.started_at)
    result.finished_at .= _maybe_datetime.(result.finished_at)
    return result[1, :]
end

"""
    get_running_experiments(handle::DBHandle)

Get all running experiments with aggregate progress.
"""
function get_running_experiments(handle::DBHandle)
    db = ensure_open!(handle)

    result = with_retry() do
        DBInterface.execute(
            db,
            """
            SELECT
                e.id,
                e.name,
                e.description,
                e.total_tasks,
                e.status,
                e.started_at,
                e.finished_at,
                COALESCE(SUM(t.total_steps), 0) as total_steps,
                COALESCE(SUM(t.current_step), 0) as current_step,
                CASE
                    WHEN COALESCE(SUM(t.total_steps), 0) > 0
                    THEN CAST(SUM(t.current_step) AS FLOAT) / SUM(t.total_steps)
                    ELSE 0
                END as progress_pct
            FROM experiments e
            LEFT JOIN tasks t ON t.experiment_id = e.id
            WHERE e.status = 'running'
            GROUP BY e.id
            ORDER BY e.started_at DESC
            """
        ) |> DataFrame
    end

    if !isempty(result)
        result.started_at .= _maybe_datetime.(result.started_at)
        result.finished_at .= _maybe_datetime.(result.finished_at)
    end

    return result
end

"""
    get_all_experiments(handle::DBHandle; limit::Int=100, offset::Int=0)

Get all experiments with pagination and aggregate progress.
"""
function get_all_experiments(handle::DBHandle; limit::Int=100, offset::Int=0)
    db = ensure_open!(handle)

    result = with_retry() do
        DBInterface.execute(
            db,
            """
            SELECT
                e.id,
                e.name,
                e.description,
                e.total_tasks,
                e.status,
                e.started_at,
                e.finished_at,
                COALESCE(SUM(CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END), 0) as completed_tasks,
                0 as total_steps,
                0 as current_step,
                CASE
                    WHEN e.total_tasks > 0
                    THEN CAST(SUM(CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END) AS FLOAT) / e.total_tasks
                    ELSE 0
                END as progress_pct
            FROM experiments e
            LEFT JOIN tasks t ON t.experiment_id = e.id
            GROUP BY e.id
            ORDER BY e.started_at DESC
            LIMIT ? OFFSET ?
            """,
            [limit, offset]
        ) |> DataFrame
    end

    if !isempty(result)
        result.started_at .= _maybe_datetime.(result.started_at)
        result.finished_at .= _maybe_datetime.(result.finished_at)
    end

    return result
end

"""
    calculate_speeds(handle::DBHandle, experiment_id::String) -> NamedTuple

Calculate average speed based on task timestamps.
"""
function calculate_speeds(handle::DBHandle, experiment_id::String; window_seconds::Real=30)
    db = ensure_open!(handle)
    _ = window_seconds

    tasks = with_retry() do
        DBInterface.execute(
            db,
            """
            SELECT current_step, started_at, last_updated
            FROM tasks
            WHERE experiment_id = ?
            """,
            [experiment_id]
        ) |> DataFrame
    end

    if isempty(tasks)
        return (total_avg_speed = 0.0, short_avg_speed = 0.0)
    end

    speeds = Float64[]
    for row in eachrow(tasks)
        elapsed = row.last_updated - row.started_at
        if elapsed > 0
            push!(speeds, row.current_step / elapsed)
        end
    end

    total_avg_speed = isempty(speeds) ? 0.0 : sum(speeds) / length(speeds)
    return (total_avg_speed = total_avg_speed, short_avg_speed = total_avg_speed)
end

"""
    get_recent_speeds(handle::DBHandle, experiment_id::String; n::Int=20)

Return a placeholder vector of recent speeds.
"""
function get_recent_speeds(handle::DBHandle, experiment_id::String; n::Int=20, window_seconds::Real=60)
    _ = window_seconds
    speeds = calculate_speeds(handle, experiment_id)
    if speeds.total_avg_speed <= 0 || n <= 0
        return Float64[]
    end
    return fill(speeds.total_avg_speed, min(n, 20))
end

"""
    get_experiment_stats(handle::DBHandle; days::Int=7)

Get aggregate statistics for experiments.
"""
function get_experiment_stats(handle::DBHandle; days::Int=7)
    db = ensure_open!(handle)
    since = _current_timestamp() - (days * 24 * 3600)

    result = with_retry() do
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
                    THEN (finished_at - started_at)
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
            avg_duration_seconds = nothing,
        )
    end

    row = result[1, :]
    return (
        total = coalesce(row.total, 0),
        completed = coalesce(row.completed, 0),
        failed = coalesce(row.failed, 0),
        running = coalesce(row.running, 0),
        avg_duration_seconds = row.avg_duration_seconds,
    )
end

"""
    get_completion_histogram(handle::DBHandle, bin_size::Int=10)

Get histogram of experiment completion percentages.
"""
function get_completion_histogram(handle::DBHandle, bin_size::Int=10)
    db = ensure_open!(handle)
    bins = zeros(Int, bin_size)

    result = with_retry() do
        DBInterface.execute(
            db,
            """
            SELECT
                e.id,
                COALESCE(SUM(t.total_steps), 0) as total_steps,
                COALESCE(SUM(t.current_step), 0) as current_step
            FROM experiments e
            LEFT JOIN tasks t ON t.experiment_id = e.id
            GROUP BY e.id
            """
        ) |> DataFrame
    end

    if result isa DataFrame
        for row in eachrow(result)
            progress = row.total_steps > 0 ? row.current_step / row.total_steps : 0.0
            bin_idx = min(floor(Int, progress * bin_size) + 1, bin_size)
            bins[bin_idx] += 1
        end
    end

    return bins
end

end # module Database
