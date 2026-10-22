# Headless query commands for mpm (list / show / tasks). Included from CLI.

using Dates
using JSON
using Printf
using SQLite

using ..MultiProgressManagers:
    Database,
    discover_db_files,
    instant_to_local_wall_datetime

const _QUERY_COMMANDS = ("list", "show", "tasks")
const _EXPERIMENT_STATUSES = Set(["running", "completed", "failed"])
const _TASK_STATUSES = Set(["pending", "running", "completed", "failed"])

struct ExperimentRow
    id::String
    name::String
    description::String
    status::String
    total_tasks::Int
    completed_tasks::Int
    current_step::Int
    total_steps::Int
    started_at::Union{DateTime,Nothing}
    finished_at::Union{DateTime,Nothing}
    source_db_path::String
end

struct AmbiguousExperiment <: Exception
    query::String
    candidates::Vector{ExperimentRow}
end

struct ExperimentNotFound <: Exception
    query::String
end

struct UsageError <: Exception
    message::String
end

_ismissing_or_nothing(x) = x === missing || x === nothing

function _coalesce_str(x; default::String = "")
    _ismissing_or_nothing(x) && return default
    return String(x)
end

function _coalesce_int(x; default::Int = 0)
    _ismissing_or_nothing(x) && return default
    return Int(x)
end

function _coalesce_dt(x)::Union{DateTime,Nothing}
    _ismissing_or_nothing(x) && return nothing
    return x isa DateTime ? x : nothing
end

function _step_progress_pct(current::Int, total::Int)::Float64
    return total > 0 ? current / total : 0.0
end

function _format_steps_pct(current::Int, total::Int)::String
    pct = 100 * _step_progress_pct(current, total)
    return @sprintf("%d/%d (%.1f%%)", current, total, pct)
end

function _format_cli_datetime(dt::Union{DateTime,Nothing}; with_seconds::Bool = false)::String
    dt === nothing && return "—"
    local_dt = instant_to_local_wall_datetime(dt)
    if with_seconds
        return Dates.format(local_dt, dateformat"yyyy-mm-dd HH:MM:SS")
    end
    return Dates.format(local_dt, dateformat"yyyy-mm-dd HH:MM")
end

function _datetime_to_unix(dt::Union{DateTime,Nothing,Missing})
    _ismissing_or_nothing(dt) && return nothing
    return Float64(Dates.datetime2unix(dt::DateTime))
end

function _is_cli_db_error(e)::Bool
    return e isa SQLiteException || e isa Base.IOError || e isa SystemError
end

function _cli_db_error_message(e)::String
    return sprint(showerror, e)
end

function _is_transient_cli_db_error(e)::Bool
    if !_is_cli_db_error(e)
        return false
    end
    error_str = lowercase(_cli_db_error_message(e))
    return occursin("locked", error_str) || occursin("busy", error_str)
end

function _read_experiments_from_db(db_path::String; limit_per_db::Int)
    handle = Database.init_db!(db_path)
    try
        df = Database.get_all_experiments(handle; limit = limit_per_db)
        experiments = ExperimentRow[_experiment_from_row(row, db_path) for row in eachrow(df)]
        return experiments
    finally
        Database.close_db!(handle)
    end
end

function _read_experiments_with_retry(db_path::String; limit_per_db::Int, max_attempts::Int = 5)
    delay = 0.02
    local last_error = nothing
    for attempt in 1:max_attempts
        try
            return _read_experiments_from_db(db_path; limit_per_db = limit_per_db)
        catch e
            if !_is_transient_cli_db_error(e)
                rethrow(e)
            end
            last_error = e
            if attempt < max_attempts
                sleep(delay * (1 + 0.1 * rand()))
                delay *= 2
            end
        end
    end
    throw(last_error)
end


function _experiment_from_row(row, source_db_path::String)::ExperimentRow
    return ExperimentRow(
        _coalesce_str(row.id),
        _coalesce_str(row.name),
        _coalesce_str(row.description),
        _coalesce_str(row.status; default = "unknown"),
        _coalesce_int(row.total_tasks),
        _coalesce_int(row.completed_tasks),
        _coalesce_int(row.current_step),
        _coalesce_int(row.total_steps),
        _coalesce_dt(row.started_at),
        _coalesce_dt(row.finished_at),
        source_db_path,
    )
end

"""
Load experiments from every `.db` under `folder`. Failed files are skipped with a
warning on `err_io`. Returns `(experiments, n_failed)`.
"""
function load_folder_experiments(
    folder::String;
    err_io::IO = stderr,
    limit_per_db::Int = 10_000,
)::Tuple{Vector{ExperimentRow},Int}
    db_paths = discover_db_files(folder)
    experiments = ExperimentRow[]
    n_failed = 0

    for db_path in db_paths
        try
            append!(experiments, _read_experiments_with_retry(db_path; limit_per_db = limit_per_db))
        catch e
            if _is_cli_db_error(e)
                n_failed += 1
                println(err_io, "Warning: skipping unreadable database $(db_path): $(_cli_db_error_message(e))")
            else
                rethrow(e)
            end
        end
    end


    sort!(experiments; by = e -> something(e.started_at, DateTime(0)), rev = true)
    return experiments, n_failed
end

function _looks_like_uuid_fragment(s::AbstractString)::Bool
    return occursin(r"^[0-9a-fA-F-]+$", s)
end

function resolve_experiment(experiments::Vector{ExperimentRow}, query::String)::ExperimentRow
    # 1. Exact id
    exact_id = filter(e -> e.id == query, experiments)
    length(exact_id) == 1 && return exact_id[1]
    length(exact_id) > 1 && throw(AmbiguousExperiment(query, exact_id))

    # 2. Unique UUID prefix (≥4 chars)
    if length(query) >= 4 && _looks_like_uuid_fragment(query)
        prefix_matches = filter(e -> startswith(e.id, query), experiments)
        length(prefix_matches) == 1 && return prefix_matches[1]
        length(prefix_matches) > 1 && throw(AmbiguousExperiment(query, prefix_matches))
    end

    # 3. Exact name (case-sensitive), must be unique
    exact_name = filter(e -> e.name == query, experiments)
    length(exact_name) == 1 && return exact_name[1]
    length(exact_name) > 1 && throw(AmbiguousExperiment(query, exact_name))

    # 4. Case-insensitive name, must be unique
    qlower = lowercase(query)
    ci_name = filter(e -> lowercase(e.name) == qlower, experiments)
    length(ci_name) == 1 && return ci_name[1]
    length(ci_name) > 1 && throw(AmbiguousExperiment(query, ci_name))

    throw(ExperimentNotFound(query))
end

function load_tasks(exp::ExperimentRow)::Vector{Database.TaskSnapshot}
    delay = 0.02
    local last_error = nothing
    for attempt in 1:5
        handle = Database.init_db!(exp.source_db_path)
        try
            return Database.get_task_snapshots(handle, exp.id)
        catch e
            if !_is_transient_cli_db_error(e)
                rethrow(e)
            end
            last_error = e
            if attempt < 5
                sleep(delay * (1 + 0.1 * rand()))
                delay *= 2
            end
        finally
            Database.close_db!(handle)
        end
    end
    throw(last_error)
end


function _filter_experiments(experiments::Vector{ExperimentRow}, status::Union{String,Nothing})
    status === nothing && return experiments
    return filter(e -> e.status == status, experiments)
end

function _filter_tasks(tasks::Vector{Database.TaskSnapshot}, status::Union{String,Nothing})
    status === nothing && return tasks
    want = Symbol(status)
    return filter(t -> t.status == want, tasks)
end

function _validate_status(status::Union{String,Nothing}, allowed::Set{String}; context::String)
    status === nothing && return nothing
    if !(status in allowed)
        allowed_list = join(sort!(collect(allowed)), ", ")
        throw(UsageError("Invalid --status $(repr(status)) for $(context); expected one of: $(allowed_list)"))
    end
    return status
end

function _parse_query_args(args::Vector{String}; require_experiment::Bool)
    json = false
    status = nothing
    positionals = String[]

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--json"
            json = true
        elseif arg in ("-h", "--help", "help")
            throw(UsageError("__help__"))
        elseif arg == "--status"
            i += 1
            i > length(args) && throw(UsageError("--status requires a value"))
            status = args[i]
        elseif startswith(arg, "--status=")
            status = String(arg[length("--status=") + 1:end])
            isempty(status) && throw(UsageError("--status requires a value"))
        elseif startswith(arg, "-")
            throw(UsageError("Unknown option: $(arg)"))
        else
            push!(positionals, arg)
        end
        i += 1
    end

    if isempty(positionals)
        throw(UsageError("Missing <folder> argument"))
    end

    folder = positionals[1]
    experiment = nothing
    if require_experiment
        length(positionals) < 2 && throw(UsageError("Missing <experiment> argument"))
        length(positionals) > 2 && throw(UsageError("Unexpected arguments: $(join(positionals[3:end], " "))"))
        experiment = positionals[2]
    else
        length(positionals) > 1 && throw(UsageError("Unexpected arguments: $(join(positionals[2:end], " "))"))
    end

    return (; folder, experiment, json, status)
end

function _resolve_folder(path::String)::String
    resolved = path == "." ? abspath(".") : abspath(path)
    if isfile(resolved)
        return dirname(resolved)
    end
    if isdir(resolved)
        return resolved
    end
    throw(UsageError("Path not found: $(path)"))
end

function _short_id(id::String; n::Int = 8)::String
    return length(id) <= n ? id : id[1:n] * "…"
end

function _pad(s::AbstractString, width::Int; right::Bool = false)::String
    n = textwidth(s)
    n >= width && return String(s)
    pad = " "^(width - n)
    return right ? pad * String(s) : String(s) * pad
end

function _experiment_to_dict(exp::ExperimentRow)::Dict{String,Any}
    return Dict{String,Any}(
        "id" => exp.id,
        "name" => exp.name,
        "description" => isempty(exp.description) ? nothing : exp.description,
        "status" => exp.status,
        "total_tasks" => exp.total_tasks,
        "completed_tasks" => exp.completed_tasks,
        "current_step" => exp.current_step,
        "total_steps" => exp.total_steps,
        "progress_pct" => _step_progress_pct(exp.current_step, exp.total_steps),
        "started_at" => _datetime_to_unix(exp.started_at),
        "finished_at" => _datetime_to_unix(exp.finished_at),
        "source_db_path" => exp.source_db_path,
    )
end

function _task_to_dict(task::Database.TaskSnapshot)::Dict{String,Any}
    return Dict{String,Any}(
        "task_number" => task.task_number,
        "status" => String(task.status),
        "current_step" => task.current_step,
        "total_steps" => task.total_steps,
        "progress_pct" => _step_progress_pct(task.current_step, task.total_steps),
        "message" => isempty(task.display_message) ? nothing : task.display_message,
        "description" => isempty(task.description) ? nothing : task.description,
        "started_at" => task.started_at == 0.0 ? nothing : task.started_at,
        "last_updated" => task.last_updated == 0.0 ? nothing : task.last_updated,
    )
end

function _print_json(io::IO, value)
    JSON.print(io, value)
    println(io)
    return nothing
end

function _print_list_human(io::IO, experiments::Vector{ExperimentRow})
    if isempty(experiments)
        println(io, "(no experiments)")
        return nothing
    end

    headers = ("STATUS", "PROGRESS", "TASKS", "NAME", "ID", "DB", "STARTED")
    rows = Vector{NTuple{7,String}}()
    for exp in experiments
        push!(
            rows,
            (
                exp.status,
                _format_steps_pct(exp.current_step, exp.total_steps),
                string(exp.completed_tasks, "/", exp.total_tasks),
                isempty(exp.name) ? "—" : exp.name,
                _short_id(exp.id),
                basename(exp.source_db_path),
                _format_cli_datetime(exp.started_at),
            ),
        )
    end

    widths = [textwidth(h) for h in headers]
    for row in rows
        for (i, cell) in enumerate(row)
            widths[i] = max(widths[i], textwidth(cell))
        end
    end

    println(io, join((_pad(headers[i], widths[i]) for i in 1:7), "  "))
    for row in rows
        println(io, join((_pad(row[i], widths[i]) for i in 1:7), "  "))
    end
    return nothing
end

function _print_tasks_human(io::IO, tasks::Vector{Database.TaskSnapshot})
    if isempty(tasks)
        println(io, "(no tasks)")
        return nothing
    end

    headers = ("#", "STATUS", "STEP", "MESSAGE", "DESCRIPTION")
    rows = Vector{NTuple{5,String}}()
    for task in tasks
        push!(
            rows,
            (
                string(task.task_number),
                String(task.status),
                _format_steps_pct(task.current_step, task.total_steps),
                isempty(task.display_message) ? "" : task.display_message,
                isempty(task.description) ? "" : task.description,
            ),
        )
    end

    widths = [textwidth(h) for h in headers]
    for row in rows
        for (i, cell) in enumerate(row)
            widths[i] = max(widths[i], textwidth(cell))
        end
    end

    println(io, join((_pad(headers[i], widths[i]) for i in 1:5), "  "))
    for row in rows
        println(io, join((_pad(row[i], widths[i]) for i in 1:5), "  "))
    end
    return nothing
end

function _print_show_human(io::IO, exp::ExperimentRow, tasks::Vector{Database.TaskSnapshot})
    name = isempty(exp.name) ? "—" : exp.name
    println(io, "Experiment: $(name) ($(exp.id))")
    progress = _format_steps_pct(exp.current_step, exp.total_steps)
    tasks_str = "$(exp.completed_tasks)/$(exp.total_tasks) completed"
    println(io, "Status: $(exp.status)  Progress: $(progress)  Tasks: $(tasks_str)  DB: $(exp.source_db_path)")
    desc = isempty(exp.description) ? "—" : exp.description
    println(io, "Description: $(desc)")
    started = _format_cli_datetime(exp.started_at; with_seconds = true)
    finished = _format_cli_datetime(exp.finished_at; with_seconds = true)
    println(io, "Started: $(started)  Finished: $(finished)")
    println(io)
    _print_tasks_human(io, tasks)
    return nothing
end

function _print_ambiguous(io::IO, err::AmbiguousExperiment)
    println(io, "Ambiguous experiment $(repr(err.query)); candidates:")
    for exp in err.candidates
        println(io, "  $(exp.id)  $(exp.name)  ($(basename(exp.source_db_path)))")
    end
    return nothing
end

function cmd_help(io::IO = stdout)
    print(
        io,
        """
        mpm query commands

          mpm list <folder> [--status STATUS] [--json]
              List experiments across all .db files in <folder>.

          mpm show <folder> <exp> [--json]
              Show one experiment summary and its tasks.
              <exp> may be a UUID, unique UUID prefix (≥4 chars), or unique name.

          mpm tasks <folder> <exp> [--status STATUS] [--json]
              List tasks for one experiment (no experiment header).

          mpm <folder>
              Open the interactive Tachikoma dashboard (unchanged).

        Status filters:
          list:  running | completed | failed
          tasks: pending | running | completed | failed

        Exit codes: 0 success, 1 runtime error, 2 usage / not found / ambiguous
        """,
    )
    return nothing
end

function _ensure_usable(experiments::Vector{ExperimentRow}, n_failed::Int, n_dbs::Int)
    if isempty(experiments) && n_failed > 0 && n_dbs > 0 && n_failed == n_dbs
        error("No usable databases in folder ($(n_failed) failed)")
    end
    return nothing
end

function run_list(args::Vector{String}; out_io::IO = stdout, err_io::IO = stderr)::Int
    parsed = try
        _parse_query_args(args; require_experiment = false)
    catch e
        e isa UsageError || rethrow(e)
        e.message == "__help__" && (cmd_help(out_io); return 0)
        println(err_io, "Error: $(e.message)")
        println(err_io, "Usage: mpm list <folder> [--status STATUS] [--json]")
        return 2
    end

    status = try
        _validate_status(parsed.status, _EXPERIMENT_STATUSES; context = "list")
    catch e
        e isa UsageError || rethrow(e)
        println(err_io, "Error: $(e.message)")
        return 2
    end

    folder = try
        _resolve_folder(parsed.folder)
    catch e
        e isa UsageError || rethrow(e)
        println(err_io, "Error: $(e.message)")
        return 2
    end

    db_paths = discover_db_files(folder)
    experiments, n_failed = load_folder_experiments(folder; err_io = err_io)
    try
        _ensure_usable(experiments, n_failed, length(db_paths))
    catch e
        println(err_io, "Error: $(sprint(showerror, e))")
        return 1
    end

    experiments = _filter_experiments(experiments, status)

    if parsed.json
        _print_json(out_io, [_experiment_to_dict(e) for e in experiments])
    else
        _print_list_human(out_io, experiments)
    end
    return 0
end

function _run_experiment_command(
    args::Vector{String};
    out_io::IO,
    err_io::IO,
    command::String,
    include_header::Bool,
    allow_status::Bool,
)::Int
    parsed = try
        _parse_query_args(args; require_experiment = true)
    catch e
        e isa UsageError || rethrow(e)
        e.message == "__help__" && (cmd_help(out_io); return 0)
        println(err_io, "Error: $(e.message)")
        println(err_io, "Usage: mpm $(command) <folder> <exp>$(allow_status ? " [--status STATUS]" : "") [--json]")
        return 2
    end

    if !allow_status && parsed.status !== nothing
        println(err_io, "Error: --status is not supported for $(command)")
        return 2
    end

    status = try
        allow_status ? _validate_status(parsed.status, _TASK_STATUSES; context = command) : nothing
    catch e
        e isa UsageError || rethrow(e)
        println(err_io, "Error: $(e.message)")
        return 2
    end

    folder = try
        _resolve_folder(parsed.folder)
    catch e
        e isa UsageError || rethrow(e)
        println(err_io, "Error: $(e.message)")
        return 2
    end

    db_paths = discover_db_files(folder)
    experiments, n_failed = load_folder_experiments(folder; err_io = err_io)
    try
        _ensure_usable(experiments, n_failed, length(db_paths))
    catch e
        println(err_io, "Error: $(sprint(showerror, e))")
        return 1
    end

    exp = try
        resolve_experiment(experiments, parsed.experiment::String)
    catch e
        if e isa ExperimentNotFound
            println(err_io, "Error: experiment not found: $(repr(e.query))")
            return 2
        elseif e isa AmbiguousExperiment
            _print_ambiguous(err_io, e)
            return 2
        else
            rethrow(e)
        end
    end

    tasks = try
        load_tasks(exp)
    catch e
        if _is_cli_db_error(e)
            println(err_io, "Error: failed to read tasks from $(exp.source_db_path): $(_cli_db_error_message(e))")
            return 1
        end
        rethrow(e)
    end

    tasks = _filter_tasks(tasks, status)

    if parsed.json
        if include_header
            payload = _experiment_to_dict(exp)
            payload["tasks"] = [_task_to_dict(t) for t in tasks]
            _print_json(out_io, payload)
        else
            _print_json(out_io, [_task_to_dict(t) for t in tasks])
        end
    else
        if include_header
            _print_show_human(out_io, exp, tasks)
        else
            _print_tasks_human(out_io, tasks)
        end
    end
    return 0
end

function run_show(args::Vector{String}; out_io::IO = stdout, err_io::IO = stderr)::Int
    return _run_experiment_command(
        args;
        out_io = out_io,
        err_io = err_io,
        command = "show",
        include_header = true,
        allow_status = false,
    )
end

function run_tasks(args::Vector{String}; out_io::IO = stdout, err_io::IO = stderr)::Int
    return _run_experiment_command(
        args;
        out_io = out_io,
        err_io = err_io,
        command = "tasks",
        include_header = false,
        allow_status = true,
    )
end

function dispatch(cmd::String, args::Vector{String}; out_io::IO = stdout, err_io::IO = stderr)::Int
    try
        if cmd == "list"
            return run_list(args; out_io = out_io, err_io = err_io)
        elseif cmd == "show"
            return run_show(args; out_io = out_io, err_io = err_io)
        elseif cmd == "tasks"
            return run_tasks(args; out_io = out_io, err_io = err_io)
        else
            println(err_io, "Error: unknown command $(repr(cmd))")
            return 2
        end
    catch e
        if e isa InterruptException
            println(err_io, "Interrupted.")
            return 0
        end
        println(err_io, "Error: $(sprint(showerror, e))")
        return 1
    end
end
