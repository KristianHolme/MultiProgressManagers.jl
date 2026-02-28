# MultiProgressManagers.jl

A modern progress tracking system for Julia with a Tachikoma.jl-based dashboard and SQLite persistence.

> **Note**: This is version 0.1.0, a complete rewrite using a custom dashboard backend instead of ProgressMeter.jl. If you need the old ProgressMeter-based implementation, use version 0.0.x.

## Features

- **📊 Tachikoma Dashboard**: Rich terminal UI with multiple tabs and real-time updates
- **💾 SQLite Persistence**: Full history retention for detailed analytics
- **🚀 Distributed Support**: Track progress across multiple workers via RemoteChannels
- **⚡ Speed Metrics**: Both total average and short-horizon (configurable) speed calculations
- **🔧 Admin Tools**: Manual database editing for fixing stuck experiments
- **📈 Statistics**: Completion histograms and aggregate metrics

## Installation

```julia
using Pkg
Pkg.add("MultiProgressManagers")
```

## Quick Start

### Basic Usage

```julia
using MultiProgressManagers

# Create a progress manager
manager = create_progress_manager("Training Run", 10000;
                                   description="Epoch 1-10 of ResNet training",
                                   db_path="./progresslogs/experiment1.db")

# In your computation loop:
for i in 1:10000
    do_work(i)
    update!(manager, i; info="Processing batch $i/10000")
end

# Mark as complete
finish!(manager; message="Training completed successfully")
```

### Viewing the Dashboard

```bash
# From shell:
mpm ./progresslogs/experiment1.db

# Or from Julia:
using MultiProgressManagers
view_dashboard("./progresslogs/experiment1.db")
```

## Dashboard Tabs

### 1. Running Experiments
Shows all currently running experiments with:
- Progress percentage
- ETA based on short-horizon speed
- Total and short-horizon average speeds
- Real-time sparkline of speed trends

### 2. Statistics  
- Completion distribution histogram (10% bins)
- Aggregate metrics (total, completed, failed, running)
- Average duration and success rate
- Daily breakdown table

### 3. Admin
Manual database editing:
- View all experiments (running and historical)
- Edit experiment status, step count, and messages
- Mark stuck experiments as completed
- Delete erroneous records

## API Reference

### Creating a ProgressManager

```julia
create_progress_manager(name::String, total_steps::Int;
                       description::String="",
                       db_path::String=default_db_path(),
                       update_frequency_ms::Int=100,
                       speed_window_seconds::Real=30,
                       worker_count::Int=1) -> ProgressManager
```

**Parameters:**
- `name`: Human-readable experiment name (shown in dashboard)
- `total_steps`: Total number of steps to complete
- `description`: Optional longer description
- `db_path`: Path to SQLite database file
- `update_frequency_ms`: Minimum time between DB writes (throttling)
- `speed_window_seconds`: Time window for short-horizon speed calculation
- `worker_count`: Number of workers for distributed runs

### Recording Progress

```julia
update!(manager::ProgressManager, current_step::Int; info::String="")
```

Records a progress update. Writes to database with throttling based on `update_frequency_ms`.

### Finishing an Experiment

```julia
finish!(manager::ProgressManager; message::String="Completed successfully")
fail!(manager::ProgressManager, error::Exception; message=nothing)
fail!(manager::ProgressManager, error_message::String)
```

### Querying Progress

```julia
get_progress(manager::ProgressManager) -> Float64  # 0.0 to 1.0
get_speeds(manager::ProgressManager) -> NamedTuple  # (total_avg_speed, short_avg_speed)
```

## Distributed Computing

MultiProgressManagers supports tracking progress across distributed workers:

```julia
using Distributed
addprocs(4)

@everywhere using MultiProgressManagers

# Create manager with worker support
manager = create_progress_manager("Distributed Training", 10000;
                                   worker_count=4)

# Create worker listener task
worker_task = create_worker_task(manager)

# Distribute work
@sync @distributed for i in 1:10000
    do_work(i)
    worker_update!(manager.worker_channel, i; info="Worker $(myid()) step $i")
end

# Cleanup
finish!(manager)
```

## Database Schema

The SQLite database maintains full history:

### experiments table
- `id`: UUID primary key
- `name`, `description`: Experiment metadata
- `total_steps`, `current_step`: Progress tracking
- `status`: running, completed, failed, cancelled
- `started_at`, `finished_at`: Timestamps
- `worker_count`: Number of distributed workers

### progress_snapshots table
- Full history of every progress update
- `timestamp`, `current_step`, `total_elapsed_ms`
- `delta_steps`, `delta_ms`: For speed calculations
- `worker_id`: For distributed tracking

## CLI Tool: mpm

The `mpm` command provides easy dashboard access:

```bash
# View single experiment
mpm ./progresslogs/experiment1.db

# View folder of experiments  
mpm ./progresslogs/

# View default database
mpm .

# Show help
mpm --help
```

Install the CLI:
```bash
julia --project -e 'using Pkg; Pkg.add("MultiProgressManagers")'
# Then add to PATH or create alias
```

## Configuration

### Database Location

By default, databases are created in `./progresslogs/{uuid}.db` if that directory exists, otherwise in `~/.local/share/MultiProgressManagers/default.db`.

### Update Frequency

The `update_frequency_ms` parameter controls throttling:
- Lower values = more frequent updates, more DB writes
- Higher values = fewer DB writes, better performance
- Default: 100ms (10 writes per second max)

For slow tasks, you can increase this significantly (e.g., 1000ms for once-per-second updates).

### Speed Calculation Window

The `speed_window_seconds` controls the short-horizon speed:
- Shorter windows = more responsive to recent changes
- Longer windows = smoother, more stable readings
- Default: 30 seconds

## Keyboard Shortcuts

In the dashboard:
- `1-4`: Switch tabs
- `↑↓`: Navigate lists
- `Enter`: Select / Open
- `q`: Quit

### Admin Tab Shortcuts
- `e`: Edit experiment
- `c`: Mark as completed
- `r`: Reset to running  
- `d`: Delete experiment
- `y/n`: Confirm/cancel in modals

## Differences from v0.0.x

This is a complete rewrite with different priorities:

| Feature | v0.0.x | v0.1.0+ |
|---------|--------|---------|
| Display | ProgressMeter.jl | Tachikoma dashboard |
| Persistence | None | SQLite with full history |
| Speed metrics | None | Total + configurable short-horizon |
| Admin tools | None | Full DB editing |
| Dashboard | Terminal bars | Multi-tab TUI |
| Distributed | RemoteChannels | RemoteChannels + DB |

## Development

Run tests:
```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Build documentation:
```bash
cd docs && julia make.jl
```

## License

MIT

## Contributing

Contributions welcome! Please open an issue to discuss changes before submitting PRs.
