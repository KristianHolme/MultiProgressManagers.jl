module MultiProgressManagers

using Dates
using UUIDs
using Printf
using Distributed
using Tachikoma

# Include submodules
include("database.jl")
include("types.jl")
include("api.jl")
include("distributed.jl")
include("dashboard/model.jl")
include("dashboard/view.jl")
include("dashboard/update.jl")
include("dashboard/select_tab.jl")
include("dashboard/running_tab.jl")
include("dashboard/stats_tab.jl")
include("dashboard/admin_tab.jl")

# Re-export from Database
export Database

# Core types
export ProgressManager, WorkerProgressMessage
export ProgressStart, ProgressUpdate, ProgressComplete, ProgressError

# User API
export create_progress_manager, update!, finish!, fail!
export get_progress, get_speeds, default_db_path

# Dashboard
export view_dashboard, view_folder_dashboard
export ProgressDashboard

# Distributed
export DistributedSupport
export create_worker_task, worker_update!, worker_done!, worker_failed!

# Version info
const VERSION = v"0.1.0"

function __init__()
    # Nothing special needed at init time
end

end # module MultiProgressManagers
