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
    id::Union{String,Missing}
    name::Union{String,Missing}
    source_db_path::String = ""
    progress_pct::Union{Float64,Missing}
    status::Union{Symbol,Missing}
    started_at::Union{DateTime,Missing}
    total_avg_speed::Union{Float64,Missing}
    short_avg_speed::Union{Float64,Missing}
    eta_seconds::Union{Float64,Nothing,Missing}
    sparkline::Vector{Float64}
end

@kwdef struct ExperimentAdminView
    id::Union{String,Missing}
    name::Union{String,Missing}
    source_db_path::String = ""
    description::Union{String,Missing}
    total_tasks::Union{Int,Missing}
    total_steps::Union{Int,Missing}
    current_step::Union{Int,Missing}
    completed_tasks::Union{Int,Missing}
    status::Union{Symbol,Missing}
    started_at::Union{DateTime,Missing}
    finished_at::Union{DateTime,Nothing,Missing}
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
    folder_mode::Bool = false  # true if viewing a folder of experiments
    folder_path::String = ""
    available_dbs::Vector{String} = String[]
    
    # Tabs: 1=Runs, 2=Details
    active_tab::Int = 1
    
    # Configurable update frequency (like btop)
    poll_frequency_ms::Int = 500  # Default: poll DB twice per second
    _last_poll::Float64 = 0.0
    _poll_timer::Float64 = 0.0
    
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
    selected_task::Int = 0
    running_focus::Int = 1  # 1=Experiments, 2=Tasks
    
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
    _cached_detail_experiment::Union{String,Nothing} = nothing
    _cached_detail_history::Vector = []
    _cached_preview_stats::Union{NamedTuple,Nothing} = nothing
    _cached_preview_running::Union{DataFrames.DataFrame,Nothing} = nothing
    _last_preview_refresh::Float64 = 0.0
end

# === Helper Functions ===

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
        if !ismissing(experiment.id) && experiment.id == experiment_id
            return experiment.source_db_path
        end
    end

    for experiment in m.running_experiments
        if !ismissing(experiment.id) && experiment.id == experiment_id
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

"""
    view_dashboard(db_path::String; poll_frequency_ms=500, speed_window_seconds=30)

Launch a Tachikoma dashboard for viewing experiment progress.

# Arguments
- `db_path::String`: Path to experiment database file, or folder containing .db files
- `poll_frequency_ms::Int=500`: How often to poll database for updates (lower = more frequent)
- `speed_window_seconds::Real=30`: Time window for short-horizon speed calculation

# Examples
```julia
# View single experiment
view_dashboard("./progresslogs/experiment1.db")

# View folder (shows experiment selector tab)
view_dashboard("./progresslogs/")
```
"""
function view_dashboard(db_path::String; poll_frequency_ms::Int=500, speed_window_seconds::Real=30)
    # Determine if it's a folder or file
    folder_mode = isdir(db_path)
    
    if folder_mode
        # Find all .db files in folder
        available_dbs = _discover_db_files(db_path)

        if isempty(available_dbs)
            error("No .db files found in folder: $db_path")
        end

        active_tab = 1
    else
        # Single file mode
        if !isfile(db_path)
            error("Database file not found: $db_path")
        end
        available_dbs = [db_path]
        active_tab = 1
    end

    db_handles = _open_dashboard_handles(available_dbs)
    primary_db_path = folder_mode ? db_path : available_dbs[1]
    primary_handle = folder_mode ? nothing : db_handles[available_dbs[1]]

    model = ProgressDashboard(
        db_path = primary_db_path,
        db_handle = primary_handle,
        db_handles = db_handles,
        folder_mode = folder_mode,
        folder_path = folder_mode ? db_path : "",
        available_dbs = available_dbs,
        active_tab = active_tab,
        poll_frequency_ms = poll_frequency_ms,
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
    # Only poll at configured frequency
    current_time = time()
    if (current_time - m._last_poll) * 1000 < m.poll_frequency_ms
        return
    end
    m._last_poll = current_time

    handle_pairs = _dashboard_handle_pairs(m)
    isempty(handle_pairs) && return

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

    m.running_experiments = map(eachrow(running_experiments_df)) do exp
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
            Database.get_recent_speeds(exp_handle, exp.id; n = 20, window_seconds = 60)
        end

        remaining_steps = exp.total_steps - exp.current_step
        eta = if speeds.short_avg_speed > 0
            remaining_steps / speeds.short_avg_speed
        else
            nothing
        end

        return ExperimentSummary(
            id = ismissing(exp.id) ? "" : exp.id,
            name = ismissing(exp.name) ? "Unknown" : exp.name,
            source_db_path = source_db_path,
            progress_pct = ismissing(exp.progress_pct) ? 0.0 : exp.progress_pct,
            status = ismissing(exp.status) ? :unknown : Symbol(exp.status),
            started_at = exp.started_at,
            total_avg_speed = speeds.total_avg_speed,
            short_avg_speed = speeds.short_avg_speed,
            eta_seconds = eta,
            sparkline = sparkline,
        )
    end

    all_exps_df = isempty(all_frames) ? DataFrame() : vcat(all_frames..., cols = :union)
    if !isempty(all_exps_df)
        sort!(all_exps_df, :started_at, rev = true)
    end

    m.admin_experiments = map(eachrow(all_exps_df)) do exp
        return ExperimentAdminView(
            id = ismissing(exp.id) ? "" : exp.id,
            name = ismissing(exp.name) ? "Unknown" : exp.name,
            source_db_path = String(exp.source_db_path),
            description = ismissing(exp.description) ? "" : exp.description,
            total_tasks = ismissing(exp.total_tasks) ? 0 : exp.total_tasks,
            total_steps = ismissing(exp.total_steps) ? 0 : exp.total_steps,
            current_step = ismissing(exp.current_step) ? 0 : exp.current_step,
            completed_tasks = ismissing(exp.completed_tasks) ? 0 : exp.completed_tasks,
            status = ismissing(exp.status) ? :unknown : Symbol(exp.status),
            started_at = exp.started_at,
            finished_at = exp.finished_at,
        )
    end
    
    # Ensure admin_selected stays valid after list refresh
    if isempty(m.admin_experiments)
        m.admin_selected = 0
    elseif m.admin_selected > length(m.admin_experiments)
        m.admin_selected = length(m.admin_experiments)
    end
    
    if !isempty(m.selected_experiment_id)
        has_selected = any(m.admin_experiments) do exp
            !ismissing(exp.id) && exp.id == m.selected_experiment_id
        end
        if !has_selected
            m.selected_experiment_id = ""
            m.runs_selected = 0
        end
    end
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
    if steps_per_sec < 1.0
        return @sprintf("%.2f s/step", 1.0 / steps_per_sec)
    elseif steps_per_sec < 1000
        return @sprintf("%.1f step/s", steps_per_sec)
    else
        return @sprintf("%.1fK step/s", steps_per_sec / 1000)
    end
end

function format_duration(::Missing, _)::String
    return "N/A"
end

function format_duration(started_at::DateTime, finished_at::Union{DateTime,Nothing})::String
    end_time = finished_at === nothing ? now(UTC) : finished_at
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

function format_datetime(dt::Union{DateTime,Missing})::String
    ismissing(dt) && return "Unknown"
    return Dates.format(dt, "HH:MM:SS")
end
