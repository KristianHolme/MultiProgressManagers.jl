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
                  tstyle, BOX_HEAVY

const tsplit = Tachikoma.split

# === View Types ===

struct ExperimentSummary
    id::String
    name::String
    progress_pct::Float64
    status::Symbol
    started_at::DateTime
    total_avg_speed::Float64
    short_avg_speed::Float64
    eta_seconds::Union{Float64,Nothing}
    sparkline::Vector{Float64}
end

struct ExperimentAdminView
    id::String
    name::String
    description::String
    total_steps::Int
    current_step::Int
    status::Symbol
    started_at::DateTime
    finished_at::Union{DateTime,Nothing}
    final_message::String
end

# === Dashboard Model ===

@kwdef mutable struct ProgressDashboard <: Tachikoma.Model
    # Core
    quit::Bool = false
    tick::Int = 0
    
    # Database
    db_path::String = ""
    db_handle::Union{Database.DBHandle,Nothing} = nothing
    folder_mode::Bool = false  # true if viewing a folder of experiments
    folder_path::String = ""
    available_dbs::Vector{String} = String[]
    
    # Tabs: 1=Select (folder mode only), 2=Running, 3=Stats, 4=Admin
    active_tab::Int = 1
    
    # Configurable update frequency (like btop)
    poll_frequency_ms::Int = 500  # Default: poll DB twice per second
    _last_poll::Float64 = 0.0
    _poll_timer::Float64 = 0.0
    
    # Configurable speed calculation window
    speed_window_seconds::Float64 = 30.0
    
    # Tab 1: Experiment Selector (folder mode)
    select_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(40), Fill()])
    selected_db_index::Int = 0
    
    # Tab 2: Running Experiments
    running_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(50), Fill()])
    running_left_layout::ResizableLayout = ResizableLayout(Vertical, [Fill(), Fixed(8)])
    running_experiments::Vector{ExperimentSummary} = ExperimentSummary[]
    selected_experiment::Int = 0
    
    # Tab 3: Stats
    stats_layout::ResizableLayout = ResizableLayout(Vertical, [Percent(40), Fill()])
    completion_histogram::Vector{Int} = Int[]
    total_stats::Union{NamedTuple,Nothing} = nothing
    last_stats_refresh::Float64 = 0.0
    
    # Tab 4: Admin
    admin_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(40), Fill()])
    admin_experiments::Vector{ExperimentAdminView} = ExperimentAdminView[]
    admin_selected::Int = 0
    admin_edit_mode::Bool = false
    admin_edit_field::Int = 1  # 1=status, 2=current_step, 3=message
    admin_edit_input::Union{TextInput,Nothing} = nothing
    admin_confirm_action::Union{Symbol,Nothing} = nothing  # :delete, :reset, etc.
    
    # Async
    _task_queue::TaskQueue = TaskQueue()
    
    # Cache
    _cached_detail_experiment::Union{String,Nothing} = nothing
    _cached_detail_history::Vector = []
end

# === Helper Functions ===

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
        available_dbs = filter(readdir(db_path)) do f
            endswith(f, ".db")
        end
        available_dbs = map(f -> joinpath(db_path, f), available_dbs)
        
        if isempty(available_dbs)
            error("No .db files found in folder: $db_path")
        end
        
        # Start with selector tab
        active_tab = 1
    else
        # Single file mode
        if !isfile(db_path)
            error("Database file not found: $db_path")
        end
        available_dbs = [db_path]
        active_tab = 2  # Skip selector, go straight to Running tab
    end
    
    # Initialize first database
    db_handle = Database.init_db!(available_dbs[1])
    
    # Create model
    model = ProgressDashboard(
        db_path = folder_mode ? "" : db_path,
        db_handle = db_handle,
        folder_mode = folder_mode,
        folder_path = folder_mode ? db_path : "",
        available_dbs = available_dbs,
        active_tab = active_tab,
        poll_frequency_ms = poll_frequency_ms,
        speed_window_seconds = speed_window_seconds
    )
    
    # Run the app
    Tachikoma.app(model; fps=60)
    
    # Cleanup
    Database.close!(m.db_handle)
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
    
    m.db_handle === nothing && return
    
    # Refresh running experiments
    experiments = Database.get_running_experiments(m.db_handle)
    
    m.running_experiments = map(experiments) do exp
        speeds = Database.calculate_speeds(m.db_handle, exp.id; window_seconds=m.speed_window_seconds)
        sparkline = Database.get_recent_speeds(m.db_handle, exp.id; n=20, window_seconds=60)
        
        # Calculate ETA
        remaining_steps = exp.total_steps - exp.current_step
        eta = if speeds.short_avg_speed > 0
            remaining_steps / speeds.short_avg_speed
        else
            nothing
        end
        
        ExperimentSummary(
            id = exp.id,
            name = exp.name,
            progress_pct = exp.progress_pct,
            status = exp.status,
            started_at = exp.started_at,
            total_avg_speed = speeds.total_avg_speed,
            short_avg_speed = speeds.short_avg_speed,
            eta_seconds = eta,
            sparkline = sparkline
        )
    end
    
    # Refresh admin list (all experiments)
    all_exps = Database.get_all_experiments(m.db_handle; limit=100)
    m.admin_experiments = map(all_exps) do exp
        ExperimentAdminView(
            id = exp.id,
            name = exp.name,
            description = exp.description,
            total_steps = exp.total_steps,
            current_step = exp.current_step,
            status = exp.status,
            started_at = exp.started_at,
            finished_at = exp.finished_at,
            final_message = exp.final_message
        )
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

function format_duration(started_at::DateTime, finished_at::Union{DateTime,Nothing})::String
    end_time = finished_at === nothing ? now() : finished_at
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
