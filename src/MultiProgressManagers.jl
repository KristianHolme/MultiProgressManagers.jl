module MultiProgressManagers
using Dates
using UUIDs
using Printf
using Tachikoma

# Include submodules
include("database.jl")
include("types.jl")
include("api.jl")
include("channel.jl")
include("dashboard/model.jl")
include("dashboard/view.jl")
include("dashboard/update.jl")
include("dashboard/runs_tab.jl")
include("dashboard/running_tab.jl")
include("cli.jl")
include("drill.jl")

# Re-export from Database
export Database

# Core types
export ProgressManager, TaskStatus, ProgressTask, ProgressUpdate, TaskFinished, TaskFailed, ProgressMessage

# API functions
export update!, finish!, fail!
export get_task
export view_dashboard, default_db_path
export create_drill_callback

end # module
