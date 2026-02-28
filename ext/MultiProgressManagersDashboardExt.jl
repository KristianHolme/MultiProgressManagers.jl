"""
Dashboard extension for MultiProgressManagers.
Loaded when Tachikoma.jl is available.
"""

module MultiProgressManagersDashboardExt

using MultiProgressManagers
using Tachikoma
using Dates
using Printf

import Tachikoma: TabBar, SelectableList, ListItem, Table, Gauge, Sparkline, 
                  BarChart, BarEntry, TextInput, ResizableLayout, split_layout,
                  render_resize_handles!, handle_resize!, DataTable, DataColumn,
                  ProgressList, ProgressItem, Block, Paragraph, StatusBar,
                  tstyle, BOX_HEAVY

const tsplit = Tachikoma.split

# Include dashboard implementation
include("../src/dashboard/model.jl")
include("../src/dashboard/view.jl")
include("../src/dashboard/update.jl")
include("../src/dashboard/select_tab.jl")
include("../src/dashboard/running_tab.jl")
include("../src/dashboard/stats_tab.jl")
include("../src/dashboard/admin_tab.jl")

# Export dashboard functions
MultiProgressManagers.view_dashboard(path::String; kwargs...) = view_dashboard(path; kwargs...)
MultiProgressManagers.view_folder_dashboard(path::String; kwargs...) = view_folder_dashboard(path; kwargs...)

end # module
