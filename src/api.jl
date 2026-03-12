# MULTI-TASK API: ProgressManager, update!, finish!, fail!

using Dates
using DataFrames

function _init_progress_manager(name::String, total_tasks::Int; description::String = "", db_path::String, task_descriptions::Vector{String} = String[])
    handle = Database.init_db!(db_path)
    task_descriptions_arg = isempty(task_descriptions) ? nothing : task_descriptions
    experiment_id = Database.create_experiment(handle, name, total_tasks; description = description, task_descriptions = task_descriptions_arg)
    experiment = Database._existing_experiment(handle)
    if experiment === nothing
        error("Experiment was not found after opening database: $db_path")
    end

    # Build in-memory task statuses from DB
    df = Database.get_experiment_tasks(handle, experiment_id)
    manager = ProgressManager(
        experiment_id,
        db_path,
        experiment.total_tasks,
        experiment.started_at,
        Dict{Int, TaskStatus}(),
        handle,
        nothing,
        nothing,
        nothing,
        Task[],
        Base.Threads.ReentrantLock(),
    )
    if !isempty(df)
        for row in eachrow(df)
            tnum = Int(row[:task_number])
            ts = TaskStatus(string(row[:id]), Int(row[:total_steps]), Int(row[:current_step]), String(row[:status]), float(row[:started_at]))
            manager.task_status[tnum] = ts
        end
    end
    return manager
end

function _ensure_default_db_path_available(name::String, db_path::String)
    if !isfile(db_path)
        return nothing
    end

    handle = Database.init_db!(db_path)
    try
        existing_experiment = Database._existing_experiment(handle)
        if existing_experiment === nothing
            return nothing
        end

        error(
            "Default database path already exists for experiment \"$(name)\": $(db_path). " *
            "Each experiment must use its own DB file. Choose a unique experiment name " *
            "or pass this db_path explicitly to reopen the existing experiment."
        )
    finally
        Database.close_db!(handle)
    end
end

"""Create a new multi-task experiment and return a ProgressManager."""
function create_experiment(name::String, total_tasks::Int; description::String = "", db_path::String)
    Base.depwarn(
        "`create_experiment(...)` is deprecated; use `ProgressManager(name, total_tasks; ...)` instead.",
        :create_experiment,
    )
    return _init_progress_manager(name, total_tasks; description = description, db_path = db_path)
end

# Outer constructor for easier creation
function ProgressManager(
    experiment_name::String,
    num_tasks::Int;
    description::String = "",
    db_path::Union{String,Nothing} = nothing,
    task_descriptions::Vector{String} = String[],
)
    if !isempty(task_descriptions) && length(task_descriptions) != num_tasks
        error("task_descriptions length ($(length(task_descriptions))) must equal num_tasks ($num_tasks)")
    end
    resolved_db_path = db_path === nothing ? default_db_path(experiment_name) : db_path
    if db_path === nothing
        _ensure_default_db_path_available(experiment_name, resolved_db_path)
    end
    return _init_progress_manager(experiment_name, num_tasks; description = description, db_path = resolved_db_path, task_descriptions = task_descriptions)
end

function _message_or_nothing(message::String)
    if isempty(message)
        return nothing
    end

    return message
end

function _validate_task_update!(
    ts::TaskStatus,
    task_number::Int,
    step::Int,
    total_steps::Union{Int,Nothing},
)
    if step < 0
        throw(ArgumentError("step must be nonnegative for task $(task_number), got $(step)"))
    end

    if total_steps !== nothing && total_steps < 0
        throw(ArgumentError("total_steps must be nonnegative for task $(task_number), got $(total_steps)"))
    end

    if step < ts.current_step
        throw(
            ArgumentError(
                "step must be monotonic for task $(task_number): previous=$(ts.current_step), new=$(step)",
            ),
        )
    end

    return nothing
end

"""Update progress for a specific task within a multi-task experiment."""
function update!(
    manager::ProgressManager,
    task_number::Int;
    step::Union{Int,Nothing} = nothing,
    total_steps::Union{Int,Nothing} = nothing,
    message::String = "",
    info::Union{String,Nothing} = nothing,
)
    if step === nothing
        Base.depwarn(
            "`update!(manager, step; info = ...)` is deprecated; use `update!(manager; step = ..., message = ...)` instead.",
            :update!,
        )
        resolved_message = info === nothing ? message : info
        return update!(manager; step = task_number, total_steps = total_steps, message = resolved_message)
    end

    if info !== nothing
        throw(ArgumentError("`info` is only supported by the deprecated single-argument form; use `message` instead."))
    end

    ts = manager.task_status[task_number]
    _validate_task_update!(ts, task_number, step, total_steps)
    new_total_steps = if total_steps === nothing
        ts.total_steps
    else
        max(total_steps, step)
    end
    new_step = new_total_steps > 0 ? min(step, new_total_steps) : step
    new_status = ts.status == "completed" ? "completed" : "running"
    db_total_steps = total_steps === nothing ? nothing : new_total_steps
    Database.update_task!(
        manager.db_handle,
        ts.task_id,
        new_step;
        total_steps = db_total_steps,
        status = new_status,
        message = _message_or_nothing(message),
    )
    manager.task_status[task_number] = TaskStatus(
        ts.task_id,
        new_total_steps,
        new_step,
        new_status,
        ts.started_at,
    )
    return nothing
end

"""Update progress for the first task in a single-task workflow."""
function update!(
    manager::ProgressManager;
    step::Int,
    total_steps::Union{Int,Nothing} = nothing,
    message::String = "",
)
    return update!(manager, 1; step = step, total_steps = total_steps, message = message)
end

"""Mark a specific task as completed."""
function finish!(manager::ProgressManager, task_number::Int)
    ts = manager.task_status[task_number]
    completed_steps = max(ts.total_steps, ts.current_step)
    Database.update_task!(
        manager.db_handle,
        ts.task_id,
        completed_steps;
        total_steps = completed_steps,
        status = "completed",
    )
    manager.task_status[task_number] = TaskStatus(
        ts.task_id,
        completed_steps,
        completed_steps,
        "completed",
        ts.started_at,
    )
    return nothing
end

"""Finish an entire experiment: mark all tasks as completed and set experiment status."""
function finish!(manager::ProgressManager; message::String = "Completed successfully")
    Database.finish_experiment!(manager.db_handle, manager.experiment_id; message = message)
    for (task_number, ts) in manager.task_status
        completed_steps = max(ts.total_steps, ts.current_step)
        manager.task_status[task_number] = TaskStatus(
            ts.task_id,
            completed_steps,
            completed_steps,
            "completed",
            ts.started_at,
        )
    end
    return nothing
end

"""Mark a specific task as failed with a message."""
function fail!(
    manager::ProgressManager,
    task_number::Int;
    message::String = "Task failed",
)
    ts = manager.task_status[task_number]
    Database.update_task!(
        manager.db_handle,
        ts.task_id,
        ts.current_step;
        total_steps = ts.total_steps,
        status = "failed",
        message = _message_or_nothing(message),
    )
    manager.task_status[task_number] = TaskStatus(
        ts.task_id,
        ts.total_steps,
        ts.current_step,
        "failed",
        ts.started_at,
    )
    return nothing
end

"""Mark an entire experiment as failed."""
function fail!(manager::ProgressManager; message::String = "Experiment failed")
    Database.fail_experiment!(manager.db_handle, manager.experiment_id, message)
    for (task_number, ts) in manager.task_status
        manager.task_status[task_number] = TaskStatus(
            ts.task_id,
            ts.total_steps,
            ts.current_step,
            "failed",
            ts.started_at,
        )
    end
    return nothing
end

# Legacy compatibility functions

function create_progress_manager(name::String, total_steps::Int;
    description::String = "",
    db_path::Union{String,Nothing} = nothing,
    update_frequency_ms::Int = 100,
    speed_window_seconds::Real = 30,
    worker_count::Int = 1,
)
    Base.depwarn(
        "`create_progress_manager(...)` is deprecated; use `ProgressManager(name, total_tasks; ...)` instead.",
        :create_progress_manager,
    )
    manager = ProgressManager(
        name,
        total_steps;
        description = description,
        db_path = db_path,
    )
    _ = update_frequency_ms
    _ = speed_window_seconds
    _ = worker_count
    return manager
end

function update!(
    manager::ProgressManager,
    task_number::Int,
    current_step::Int;
    total_steps::Union{Int,Nothing} = nothing,
    message::String = "",
)
    Base.depwarn(
        "`update!(manager, task_number, step; ...)` is deprecated; use `update!(manager, task_number; step = ..., total_steps = ..., message = ...)` instead.",
        :update!,
    )
    return update!(
        manager,
        task_number;
        step = current_step,
        total_steps = total_steps,
        message = message,
    )
end

function finish_task!(manager::ProgressManager, task_number::Int)
    Base.depwarn(
        "`finish_task!(manager, task_number)` is deprecated; use `finish!(manager, task_number)` instead.",
        :finish_task!,
    )
    finish!(manager, task_number)
    return nothing
end

function finish_experiment!(manager::ProgressManager)
    Base.depwarn(
        "`finish_experiment!(manager)` is deprecated; use `finish!(manager)` instead.",
        :finish_experiment!,
    )
    finish!(manager)
    return nothing
end

function fail_task!(manager::ProgressManager, task_number::Int, error_message::String)
    Base.depwarn(
        "`fail_task!(manager, task_number, message)` is deprecated; use `fail!(manager, task_number; message = ...)` instead.",
        :fail_task!,
    )
    fail!(manager, task_number; message = error_message)
    return nothing
end

function fail!(manager::ProgressManager, error::Exception; message::Union{String,Nothing} = nothing)
    resolved_message = message === nothing ? sprint(showerror, error) : message
    fail!(manager; message = resolved_message)
    return nothing
end

function fail!(
    manager::ProgressManager,
    task_number::Int,
    error::Exception;
    message::Union{String,Nothing} = nothing,
)
    resolved_message = message === nothing ? sprint(showerror, error) : message
    fail!(manager, task_number; message = resolved_message)
    return nothing
end

function fail!(manager::ProgressManager, error_message::String)
    fail!(manager; message = error_message)
    return nothing
end

function _default_db_directory()
    if isdir("./progresslogs")
        return "./progresslogs"
    end

    cache_dir = get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
    dir = joinpath(cache_dir, "MultiProgressManagers")
    mkpath(dir)
    return dir
end

function _experiment_db_basename(name::String)
    slug = lowercase(strip(name))
    slug = replace(slug, r"[^a-z0-9]+" => "_")
    slug = strip(slug, '_')

    if isempty(slug)
        return "experiment.db"
    end

    return "$(slug).db"
end

function default_db_path(name::String)
    return joinpath(_default_db_directory(), _experiment_db_basename(name))
end

function default_db_path()
    return joinpath(_default_db_directory(), "$(UUIDs.uuid4()).db")
end

function get_progress(manager::ProgressManager)
    # Calculate average progress across all tasks
    if isempty(manager.task_status)
        return 0.0
    end
    total = sum(ts.current_step for ts in values(manager.task_status))
    total_steps = sum(ts.total_steps for ts in values(manager.task_status))
    return total_steps > 0 ? total / total_steps : 0.0
end

function get_speeds(manager::ProgressManager)
    # Get handle
    db_handle = Database.init_db!(manager.db_path)
    speeds = Database.calculate_speeds(db_handle, manager.experiment_id)
    Database.close_db!(db_handle)
    return speeds
end
