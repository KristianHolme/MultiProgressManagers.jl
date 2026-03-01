# MultiProgressManagers.jl

A lightweight progress tracking system for Julia with a Tachikoma.jl-based dashboard and SQLite persistence.

> **Note**: This is version 0.1.0, a simplified rewrite focused on multi-task experiment tracking. If you need the old ProgressMeter-based implementation, use version 0.0.x.

## Features

- **📊 Tachikoma Dashboard**: Clean 2-tab terminal UI for monitoring experiments
- **💾 SQLite Persistence**: Current state stored in SQLite (no history for MWP)
- **🔄 Multi-Task Support**: Track parallel sub-tasks within a single experiment
- **⚡ Simple API**: In-process: `update!`, `finish_task!`. Workers: `ProgressTask` + `report_progress!`, `finish!`
- **🔀 Distributed & Threads**: Single DB writer on the master; workers get a `ProgressTask` via `get_task(manager, id, :remote)` or `:local` and send updates over a channel

## Installation

```julia
using Pkg
Pkg.add("MultiProgressManagers")
```

## Quick Start

### Basic Usage (same process)

```julia
using MultiProgressManagers

# Create a multi-task experiment with 5 parallel tasks
manager = ProgressManager("Training Run", 5;
                         description = "Epoch 1-10 of ResNet training",
                         db_path = "./progresslogs/experiment1.db")

# Update progress for each task as it runs
for task_num in 1:5
    for step in 1:100
        do_work(task_num, step)
        update!(manager, task_num, step; total_steps = 100, message = "step $step")
    end
    finish_task!(manager, task_num)
end

# Mark entire experiment as complete
finish_experiment!(manager)
```

### Worker-based progress (threads or Distributed)

When work runs on other threads or processes, only the master touches the DB. Workers get a **ProgressTask** and send updates over a channel:

```julia
using MultiProgressManagers
using Distributed  # for pmap

@everywhere using MultiProgressManagers

# Master: create experiment and get task handles
manager = ProgressManager("Distributed Run", 8; db_path = "./progresslogs/dist.db")
tasks = [get_task(manager, i, :remote) for i in 1:8]  # :local for @spawn threads

# Workers: report progress via the task handle (no DB access)
@everywhere function run_worker(task::ProgressTask, total_steps::Int)
    for step in 1:total_steps
        do_work(step)
        report_progress!(task, step; total_steps = total_steps, message = "step $step")
    end
    finish!(task)
end

# Run and finish
pmap(i -> run_worker(tasks[i], 100), 1:8)
finish_experiment!(manager)
```

See `examples/multithreading.jl` (threads + direct `update!`) and `examples/distributed_pmap.jl` (Distributed + `ProgressTask`).

### Viewing the Dashboard

```bash
# From shell:
mpm ./progresslogs/experiment1.db

# Or from Julia:
using MultiProgressManagers
view_dashboard("./progresslogs/experiment1.db")
```

## Dashboard Tabs

### Tab 1: Runs
Shows all experiments in the database:
- Experiment name and description
- Status (running/completed/failed)
- Overall progress across all tasks
- Start time and duration

### Tab 2: Details (Running)
Shows detailed view of selected experiment:
- Individual task progress bars
- Task status (pending/running/completed/failed)
- Current step / total steps for each task
- **Message** column (from `update!(...; message=...)` or `report_progress!(...; message=...)`)
- Speed calculation (steps per second)

## API Reference

### Creating an Experiment

```julia
ProgressManager(name::String, num_tasks::Int;
                description::String = "",
                db_path::String = "./progresslogs/experiment.db")
# or
create_experiment(name::String, total_tasks::Int;
                  description::String = "",
                  db_path::String) -> ProgressManager
```

**Parameters:**
- `name`: Human-readable experiment name (shown in dashboard)
- `num_tasks` / `total_tasks`: Number of parallel sub-tasks in this experiment
- `description`: Optional longer description
- `db_path`: Path to SQLite database file

**Returns:** A `ProgressManager` instance for tracking this experiment.

### Updating Task Progress (in-process)

```julia
update!(manager::ProgressManager, task_number::Int, current_step::Int;
        total_steps::Int = 0,
        message::String = "")
```

Records progress for a specific task. Optionally pass `total_steps` and `message`; the message is shown in the dashboard Details tab. Automatically marks task as "completed" when `current_step` reaches the task's total steps.

**Parameters:**
- `manager`: The ProgressManager for this experiment
- `task_number`: 1-indexed task number (1 to total_tasks)
- `current_step`: Current progress step for this task
- `total_steps`: Optional; used for progress display
- `message`: Optional; shown in the "Message" column (e.g. phase or status)

### ProgressTask: worker-based updates

When work runs on other threads or processes, workers must not call `update!` or touch the DB. Instead they use a **ProgressTask**:

```julia
get_task(manager::ProgressManager, task_number::Int, type = :local) -> ProgressTask
```

Returns a handle for one task. `type`:
- `:local` — plain `Channel` (same process, e.g. `@spawn`)
- `:remote` — `RemoteChannel` (for `Distributed` / `pmap`)

```julia
report_progress!(task::ProgressTask, current_step::Int; total_steps::Int = 0, message::String = "")
finish!(task::ProgressTask)
```

Workers call `report_progress!` during the loop and `finish!(task)` when the task is done. A listener on the master process applies these to the DB.

### Finishing a Task (in-process)

```julia
finish_task!(manager::ProgressManager, task_number::Int)
```

Explicitly mark a task as completed. Use this when you call `update!` from the same process. For workers, use `finish!(task)` on the ProgressTask instead.

### Finishing an Experiment

```julia
finish_experiment!(manager::ProgressManager)
```

Mark the entire experiment as completed. This sets the experiment status to "completed" and marks all remaining tasks as done.

### Failing a Task

```julia
fail_task!(manager::ProgressManager, task_number::Int, error_message::String)
```

Mark a specific task as failed with an error message.

## Database Schema

The SQLite database uses a simplified 2-table schema:

### experiments table
- `id`: UUID primary key
- `name`: Experiment name
- `description`: Optional description
- `total_tasks`: Number of sub-tasks
- `status`: running, completed, or failed
- `started_at`: Unix timestamp when experiment started
- `finished_at`: Unix timestamp when experiment completed (NULL if running)
- `final_message`: Optional message (e.g. "Completed successfully" or error)

### tasks table
- `id`: UUID primary key
- `experiment_id`: Foreign key to experiments table
- `task_number`: 1-indexed position in task list
- `total_steps`: Total steps for this task
- `current_step`: Current progress (0 to total_steps)
- `status`: pending, running, completed, or failed
- `started_at`: Unix timestamp when task started
- `last_updated`: Unix timestamp of last progress update
- `display_message`: Optional message (e.g. phase or status) shown in dashboard

## CLI Tool: mpm

The `mpm` command provides easy dashboard access:

```bash
# View experiment database
mpm ./progresslogs/experiment1.db

# Show help
mpm --help
```

Install the CLI:
```bash
julia --project -e 'using Pkg; Pkg.add("MultiProgressManagers")'
# Then add to PATH or create alias
```

## Keyboard Shortcuts

In the dashboard:
- `1-2`: Switch between Runs and Details tabs
- `↑↓`: Navigate experiments/tasks
- `Enter`: Select experiment (in Runs tab)
- `q`: Quit

## Configuration

### Database Location

By default, you specify the database path when creating an experiment. The directory will be created if it doesn't exist.

```julia
# Example: Create database in specific directory
manager = ProgressManager("My Experiment", 3; db_path = "./logs/run1.db")
```

## Differences from v0.0.x

This is a simplified rewrite focused on multi-task experiments:

| Feature | v0.0.x | v0.1.0+ |
|---------|--------|---------|
| Display | ProgressMeter.jl | Tachikoma dashboard |
| Persistence | None | SQLite (current state only) |
| Task Model | Single task | Multi-task experiments |
| Dashboard | Terminal bars | 2-tab TUI (Runs + Details) |
| Admin Tools | None | Removed (simplified) |
| Distributed | RemoteChannels | ProgressTask + get_task(..., :remote); single DB writer, channel-based |
| History | Full snapshots | Current state only |

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
