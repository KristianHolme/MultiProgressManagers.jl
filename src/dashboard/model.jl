"""
Dashboard model and types for Tachikoma-based MultiProgressManagers UI.
"""

using Tachikoma
using Dates
using Match
using DataFrames

import Tachikoma: TabBar, SelectableList, ListItem, Table, Gauge, Sparkline, 
                  BarChart, BarEntry, TextInput, ResizableLayout, split_layout,
                  render_resize_handles!, handle_resize!, DataTable, DataColumn,
                  ProgressList, ProgressItem, Block, Paragraph, StatusBar,
                  Modal, tstyle, BOX_HEAVY

const tsplit = Tachikoma.split

# === View Types ===

@kwdef struct ExperimentSummary
    id::String = ""
    name::String = ""
    source_db_path::String = ""
    progress_pct::Float64 = 0.0
    status::Symbol = :unknown
    started_at::Union{DateTime,Nothing} = nothing
    total_avg_speed::Float64 = 0.0
    short_avg_speed::Float64 = 0.0
    eta_seconds::Union{Float64,Nothing} = nothing
    sparkline::Vector{Float64} = Float64[]
end

@kwdef struct ExperimentAdminView
    id::String = ""
    name::String = ""
    source_db_path::String = ""
    description::String = ""
    total_tasks::Int = 0
    total_steps::Int = 0
    current_step::Int = 0
    completed_tasks::Int = 0
    status::Symbol = :unknown
    started_at::Union{DateTime,Nothing} = nothing
    finished_at::Union{DateTime,Nothing} = nothing
end

# === Dashboard Model ===

@kwdef mutable struct ProgressDashboard <: Tachikoma.Model
    # Core
    quit::Bool = false
    tick::Int = 0
    
    # Database
    db_path::String = ""
    db_handle::Union{Database.DBHandle,Nothing} = nothing
    db_handles::Dict{String,Database.DBHandle} = Dict{String,Database.DBHandle}()
    folder_mode::Bool = true  # always folder mode (single-file paths resolve to their directory)
    folder_path::String = ""
    available_dbs::Vector{String} = String[]
    
    # Tabs: 1=Runs, 2=Details
    active_tab::Int = 1
    
    # Configurable update frequency (like btop)
    poll_frequency_ms::Int = 500  # Default: poll DB twice per second
    _last_poll::Float64 = 0.0
    folder_discovery_interval_ms::Int = 5000  # Folder mode: re-scan for .db files at this interval
    _last_folder_discover::Float64 = 0.0

    # Configurable speed calculation window
    speed_window_seconds::Float64 = 30.0
    
    # Tab 1: Runs List
    runs_selected::Int = 0
    selected_experiment_id::String = ""
    # Tab 2: Experiment Details
    running_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(50), Fill()])
    running_left_layout::ResizableLayout = ResizableLayout(Vertical, [Fill(), Percent(30)])
    running_experiments::Vector{ExperimentSummary} = ExperimentSummary[]
    selected_experiment::Int = 0
    task_scroll_offset::Int = 0
    task_list_msg_delta::Int = 0  # offset from 50% Msg/Desc split; a/d to adjust
    selected_task::Int = 0
    running_focus::Int = 2  # 2=Tasks only (Details tab)
    
    # Admin data (used for runs list/details)
    admin_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(40), Fill()])
    admin_experiments::Vector{ExperimentAdminView} = ExperimentAdminView[]
    admin_selected::Int = 0
    admin_edit_mode::Bool = false
    admin_edit_field::Int = 1  # 1=status, 2=current_step, 3=message
    admin_edit_input::Union{TextInput,Nothing} = nothing
    admin_confirm_action::Union{Symbol,Nothing} = nothing  # :delete, :reset, etc.
    confirm_mark_failed_id::Union{String,Nothing} = nothing
    confirm_modal_selected::Symbol = :cancel  # :cancel or :confirm

    # Async
    _task_queue::TaskQueue = TaskQueue()
    
    # Cache
    _selected_tasks::Vector{Database.TaskSnapshot} = Database.TaskSnapshot[]
    _selected_tasks_loaded::Bool = false
end

# === Helper Functions ===

function _normalized_datetime(value)::Union{DateTime,Nothing}
    if value === nothing || value === missing
        return nothing
    end

    return value
end

function _discover_db_files(folder_path::String)
    db_files = filter(readdir(folder_path; join = true)) do file_path
        return endswith(lowercase(file_path), ".db")
    end
    sort!(db_files)
    return db_files
end

function _open_dashboard_handles(db_paths::Vector{String})
    handles = Dict{String,Database.DBHandle}()
    for db_path in db_paths
        handles[db_path] = Database.init_db!(db_path)
    end
    return handles
end

function _close_dashboard_handles!(handles::Dict{String,Database.DBHandle})
    for handle in values(handles)
        Database.close_db!(handle)
    end
    return nothing
end

function _dashboard_handle_pairs(m::ProgressDashboard)
    if !isempty(m.db_handles)
        handle_pairs = collect(pairs(m.db_handles))
        sort!(handle_pairs; by = first)
        return handle_pairs
    end

    if m.db_handle === nothing
        return Pair{String,Database.DBHandle}[]
    end

    return [m.db_path => (m.db_handle::Database.DBHandle)]
end

function _handle_for_db_path(m::ProgressDashboard, db_path::String)
    if !isempty(m.db_handles)
        return get(m.db_handles, db_path, nothing)
    end

    if m.db_handle === nothing || m.db_path != db_path
        return nothing
    end

    return m.db_handle::Database.DBHandle
end

function _db_path_for_experiment(m::ProgressDashboard, experiment_id::String)
    isempty(experiment_id) && return nothing

    for experiment in m.admin_experiments
        if experiment.id == experiment_id
            return experiment.source_db_path
        end
    end

    for experiment in m.running_experiments
        if experiment.id == experiment_id
            return experiment.source_db_path
        end
    end

    if !isempty(m.db_path)
        return m.db_path
    end

    return nothing
end

function _handle_for_experiment(m::ProgressDashboard, experiment_id::String)
    db_path = _db_path_for_experiment(m, experiment_id)
    if db_path === nothing
        return nothing
    end

    return _handle_for_db_path(m, db_path)
end

function _refresh_folder_databases!(m::ProgressDashboard, current_time::Float64)
    if (current_time - m._last_folder_discover) * 1000 < m.folder_discovery_interval_ms
        return nothing
    end

    new_dbs = _discover_db_files(m.folder_path)
    removed = setdiff(m.available_dbs, new_dbs)
    added = setdiff(new_dbs, m.available_dbs)

    for path in removed
        if haskey(m.db_handles, path)
            Database.close_db!(m.db_handles[path])
            delete!(m.db_handles, path)
        end
    end

    for path in added
        m.db_handles[path] = Database.init_db!(path)
    end

    m.available_dbs = new_dbs
    m._last_folder_discover = current_time
    return nothing
end

function _collect_experiment_frames(handle_pairs)
    running_frames = DataFrame[]
    all_frames = DataFrame[]

    for (source_db_path, handle) in handle_pairs
        experiments = Database.get_running_experiments(handle)
        if !isempty(experiments)
            experiments.source_db_path = fill(source_db_path, nrow(experiments))
            push!(running_frames, experiments)
        end

        all_exps = Database.get_all_experiments(handle; limit = 100)
        if !isempty(all_exps)
            all_exps.source_db_path = fill(source_db_path, nrow(all_exps))
            push!(all_frames, all_exps)
        end
    end

    running_experiments_df = isempty(running_frames) ? DataFrame() : vcat(running_frames..., cols = :union)
    if !isempty(running_experiments_df)
        sort!(running_experiments_df, :started_at, rev = true)
    end

    all_experiments_df = isempty(all_frames) ? DataFrame() : vcat(all_frames..., cols = :union)
    if !isempty(all_experiments_df)
        sort!(all_experiments_df, :started_at, rev = true)
    end

    return running_experiments_df, all_experiments_df
end

function _build_running_experiments(
    m::ProgressDashboard,
    running_experiments_df::DataFrame,
)
    return map(eachrow(running_experiments_df)) do exp
        source_db_path = String(exp.source_db_path)
        exp_handle = _handle_for_db_path(m, source_db_path)
        speeds = if exp_handle === nothing
            (total_avg_speed = 0.0, short_avg_speed = 0.0)
        else
            Database.calculate_speeds(exp_handle, exp.id; window_seconds = m.speed_window_seconds)
        end
        sparkline = if exp_handle === nothing
            Float64[]
        else
            Database.get_recent_speeds(
                exp_handle,
                exp.id;
                n = 20,
                window_seconds = m.speed_window_seconds,
            )
        end

        eta_seconds = if exp_handle === nothing
            nothing
        else
            tasks = Database.get_task_snapshots(exp_handle, String(exp.id))
            Database.estimate_experiment_eta_seconds(tasks)
        end

        return ExperimentSummary(
            id = ismissing(exp.id) ? "" : String(exp.id),
            name = ismissing(exp.name) ? "Unknown" : String(exp.name),
            source_db_path = source_db_path,
            progress_pct = ismissing(exp.progress_pct) ? 0.0 : Float64(exp.progress_pct),
            status = ismissing(exp.status) ? :unknown : Symbol(exp.status),
            started_at = _normalized_datetime(exp.started_at),
            total_avg_speed = speeds.total_avg_speed,
            short_avg_speed = speeds.short_avg_speed,
            eta_seconds = eta_seconds,
            sparkline = sparkline,
        )
    end
end

function _build_admin_experiments(all_experiments_df::DataFrame)
    return map(eachrow(all_experiments_df)) do exp
        return ExperimentAdminView(
            id = ismissing(exp.id) ? "" : String(exp.id),
            name = ismissing(exp.name) ? "Unknown" : String(exp.name),
            source_db_path = String(exp.source_db_path),
            description = ismissing(exp.description) ? "" : String(exp.description),
            total_tasks = ismissing(exp.total_tasks) ? 0 : Int(exp.total_tasks),
            total_steps = ismissing(exp.total_steps) ? 0 : Int(exp.total_steps),
            current_step = ismissing(exp.current_step) ? 0 : Int(exp.current_step),
            completed_tasks = ismissing(exp.completed_tasks) ? 0 : Int(exp.completed_tasks),
            status = ismissing(exp.status) ? :unknown : Symbol(exp.status),
            started_at = _normalized_datetime(exp.started_at),
            finished_at = _normalized_datetime(exp.finished_at),
        )
    end
end

function _sync_selected_experiment!(m::ProgressDashboard)
    if isempty(m.admin_experiments)
        m.selected_experiment_id = ""
        m.runs_selected = 0
        return nothing
    end

    selected_index = findfirst(m.admin_experiments) do exp
        return exp.id == m.selected_experiment_id
    end
    if selected_index === nothing
        m.runs_selected = 1
        top_experiment = m.admin_experiments[1]
        m.selected_experiment_id = top_experiment.id
    else
        m.runs_selected = selected_index
    end

    return nothing
end

function _refresh_selected_tasks!(m::ProgressDashboard)
    if isempty(m.selected_experiment_id)
        empty!(m._selected_tasks)
        m._selected_tasks_loaded = false
        return nothing
    end

    handle = _handle_for_experiment(m, m.selected_experiment_id)
    if handle === nothing
        empty!(m._selected_tasks)
        m._selected_tasks_loaded = false
        return nothing
    end

    m._selected_tasks = Database.get_task_snapshots(handle, m.selected_experiment_id)
    m._selected_tasks_loaded = true
    return nothing
end

"""
    view_dashboard(db_path::String; poll_frequency_ms=500, speed_window_seconds=30)

Launch a Tachikoma dashboard for viewing experiment progress.

Loads every `.db` file in the given directory (empty folders are allowed; new files appear on refresh).

# Arguments
- `db_path::String`: Path to the directory to watch for `.db` files.
- `poll_frequency_ms::Int=500`: How often to poll database for updates (lower = more frequent)
- `speed_window_seconds::Real=30`: Time window for short-horizon speed calculation
- `folder_discovery_interval_ms::Int=5000`: How often to re-scan for new `.db` files

# Examples
```julia
view_dashboard("./progresslogs")
```
"""
function view_dashboard(db_path::String; poll_frequency_ms::Int=500, speed_window_seconds::Real=30, folder_discovery_interval_ms::Int=5000)
    resolved = abspath(db_path)
    folder_path = if isdir(resolved)
        resolved
    elseif isfile(resolved)
        dirname(resolved)
    else
        error("Path not found: $db_path")
    end

    available_dbs = _discover_db_files(folder_path)
    active_tab = 1

    db_handles = _open_dashboard_handles(available_dbs)
    primary_db_path = folder_path
    primary_handle = nothing

    model = ProgressDashboard(
        db_path = primary_db_path,
        db_handle = primary_handle,
        db_handles = db_handles,
        folder_mode = true,
        folder_path = folder_path,
        available_dbs = available_dbs,
        active_tab = active_tab,
        poll_frequency_ms = poll_frequency_ms,
        folder_discovery_interval_ms = folder_discovery_interval_ms,
        speed_window_seconds = speed_window_seconds,
    )

    try
        Tachikoma.app(model; fps=60)
    finally
        _close_dashboard_handles!(db_handles)
    end

    return nothing
end

"""
    view_folder_dashboard(folder_path::String; kwargs...)

View all experiments in a folder. Equivalent to view_dashboard(folder_path).
"""
function view_folder_dashboard(folder_path::String; kwargs...)
    view_dashboard(folder_path; kwargs...)
end

# === Poll Database ===

function _poll_database!(m::ProgressDashboard)
    current_time = time()
    if (current_time - m._last_poll) * 1000 < m.poll_frequency_ms
        return
    end
    m._last_poll = current_time

    _refresh_folder_databases!(m, current_time)
    handle_pairs = _dashboard_handle_pairs(m)
    if isempty(handle_pairs)
        m.running_experiments = ExperimentSummary[]
        m.admin_experiments = ExperimentAdminView[]
        m.selected_experiment_id = ""
        m.runs_selected = 0
        empty!(m._selected_tasks)
        m._selected_tasks_loaded = false
        return nothing
    end

    running_experiments_df, all_experiments_df = _collect_experiment_frames(handle_pairs)
    m.running_experiments = _build_running_experiments(m, running_experiments_df)
    m.admin_experiments = _build_admin_experiments(all_experiments_df)
    
    if isempty(m.admin_experiments)
        m.admin_selected = 0
    elseif m.admin_selected > length(m.admin_experiments)
        m.admin_selected = length(m.admin_experiments)
    end

    previous_selected_id = m.selected_experiment_id
    _sync_selected_experiment!(m)
    if m.selected_experiment_id != previous_selected_id
        m.task_scroll_offset = 0
        m.running_focus = 2
        if isempty(m.selected_experiment_id)
            m.selected_task = 0
        end
    end

    _refresh_selected_tasks!(m)
    return nothing
end

# === Formatting Helpers ===

function format_eta(seconds::Union{Float64,Nothing})::String
    seconds === nothing && return "N/A"
    
    if seconds < 60
        return @sprintf("%.0fs", seconds)
    elseif seconds < 3600
        mins = seconds ÷ 60
        secs = seconds % 60
        return @sprintf("%dm %02ds", mins, secs)
    else
        hours = seconds ÷ 3600
        mins = (seconds % 3600) ÷ 60
        return @sprintf("%dh %02dm", hours, mins)
    end
end

function format_speed(steps_per_sec::Float64)::String
    if !(steps_per_sec > 0.0)
        return "N/A"
    elseif steps_per_sec < 1.0
        return @sprintf("%.2f s/step", 1.0 / steps_per_sec)
    elseif steps_per_sec < 1000
        return @sprintf("%.1f step/s", steps_per_sec)
    else
        return @sprintf("%.1fK step/s", steps_per_sec / 1000)
    end
end

function format_duration(::Nothing, _)::String
    return "N/A"
end

function format_duration(started_at::DateTime, finished_at::Union{DateTime,Nothing})::String
    # DB times are UTC instants (`unix2datetime`); use the same basis for "now" — not `now()` (local wall clock).
    end_time = finished_at === nothing ? unix2datetime(time()) : finished_at
    duration = end_time - started_at
    total_seconds = round(Int, Dates.value(duration) / 1000)
    
    hours = total_seconds ÷ 3600
    mins = (total_seconds % 3600) ÷ 60
    secs = total_seconds % 60
    
    if hours > 0
        return @sprintf("%dh %02dm %02ds", hours, mins, secs)
    else
        return @sprintf("%dm %02ds", mins, secs)
    end
end

function format_datetime(dt::Union{DateTime,Nothing})::String
    dt === nothing && return "Unknown"
    local_dt = instant_to_local_wall_datetime(dt)
    return Dates.format(local_dt, dateformat"HH:MM:SS")
end

"""
Format datetime for the Started column in tab 1. When include_date is true
(e.g. oldest experiment was not started today), include date to disambiguate.
"""
function format_datetime_for_started_column(dt::Union{DateTime,Nothing}, include_date::Bool)::String
    dt === nothing && return "Unknown"
    local_dt = instant_to_local_wall_datetime(dt)
    if include_date
        return Dates.format(local_dt, dateformat"yyyy-mm-dd HH:MM")
    end
    return Dates.format(local_dt, dateformat"HH:MM:SS")
end
