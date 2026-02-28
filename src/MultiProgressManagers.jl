module MultiProgressManagers

using Dates
using UUIDs
using Printf
using Distributed

# Include submodules
include("database.jl")
include("types.jl")
include("api.jl")
include("distributed.jl")

# Re-export from Database
export Database

# Core types
export ProgressManager, WorkerProgressMessage
export ProgressStart, ProgressUpdate, ProgressComplete, ProgressError

# User API
export create_progress_manager, update!, finish!, fail!
export get_progress, get_speeds, default_db_path

# Dashboard (available when Tachikoma extension is loaded)
export view_dashboard, view_folder_dashboard

# Distributed
export DistributedSupport
export create_worker_task, worker_update!, worker_done!, worker_failed!

# Version info
const VERSION = v"0.1.0"

function __init__()
    # Nothing special needed at init time
end

# Stub functions for when dashboard is not available
# These will be overwritten by the Tachikoma extension if loaded
function view_dashboard(path::String; poll_frequency_ms::Int=500, speed_window_seconds::Real=30)
    error("""
    Dashboard requires Tachikoma.jl which is not loaded.
    
    To enable the dashboard:
        1. Install Tachikoma: ] dev /path/to/Tachikoma
        2. Then run: using Tachikoma; using MultiProgressManagers; view_dashboard(path)
    """)
end

function view_folder_dashboard(path::String; poll_frequency_ms::Int=500, speed_window_seconds::Real=30)
    error("""
    Dashboard requires Tachikoma.jl which is not loaded.
    
    To enable the dashboard:
        1. Install Tachikoma: ] dev /path/to/Tachikoma
        2. Then run: using Tachikoma; using MultiProgressManagers; view_folder_dashboard(path)
    """)
end

end # module MultiProgressManagers
