# MultiProgressManagers.jl

A lightweight progress tracking system for Julia with a Tachikoma.jl-based dashboard and SQLite persistence.

> **Note**: This is version 0.1.0, a simplified rewrite focused on multi-task experiment tracking. If you need the old ProgressMeter-based implementation, use version 0.0.x.

## Features

- **📊 Tachikoma Dashboard**: Clean 2-tab terminal UI for monitoring experiments
- **💾 SQLite Persistence**: Current state stored in SQLite (no history for MWP)
- **🔄 Multi-Task Support**: Track parallel sub-tasks within a single experiment
- **⚡ Simple API**: In-process: `update!`, `finish!`, `fail!`. Workers: `ProgressTask` + `update!`, `finish!`, `fail!`
- **🔀 Distributed & Threads**: Single DB writer on the master; workers get a `ProgressTask` via `get_task(manager, id, :remote)` or `:local` and send updates over a channel

## Installation

This package is not yet registered. Add it from the `tachikoma-rewrite` branch:

```julia
using Pkg
# From git (replace with your repo URL):
Pkg.add(url = "https://github.com/<owner>/MultiProgressManagers.jl", rev = "tachikoma-rewrite")
# Or from a local clone:
# Pkg.develop(path = "/path/to/MultiProgressManagers")
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
        update!(manager, task_num; step = step, total_steps = 100, message = "step $step")
    end
    finish!(manager, task_num)
end

# Mark entire experiment as complete
finish!(manager)
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

# Workers: send progress via the task handle (no DB access)
@everywhere function run_worker(task::ProgressTask, total_steps::Int)
    for step in 1:total_steps
        do_work(step)
        update!(task; step = step, total_steps = total_steps, message = "step $step")
    end
    finish!(task)
end

# Run and finish
pmap(i -> run_worker(tasks[i], 100), 1:8)
finish!(manager)
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
- Automatically selects the newest experiment at the top of the list

### Tab 2: Details (Running)

Shows detailed view of selected experiment:

- Individual task progress bars
- Task status (pending/running/completed/failed)
- Current step / total steps for each task
- **Message** column (from `update!(...; message=...)`)
- Speed calculation (steps per second)

## API Reference

### Creating an Experiment

```julia
ProgressManager(name::String, num_tasks::Int;
                description::String = "",
                db_path::Union{String,Nothing} = nothing)
```

**Parameters:**

- `name`: Human-readable experiment name (shown in dashboard)
- `num_tasks` / `total_tasks`: Number of parallel sub-tasks in this experiment
- `description`: Optional longer description
- `db_path`: Optional path to SQLite database file. When omitted, the package derives a default path from the experiment name.

**Returns:** A `ProgressManager` instance for tracking this experiment.

`create_experiment(...)` remains available as a deprecated compatibility alias.

### Updating Task Progress (in-process)

```julia
update!(manager::ProgressManager, task_number::Int;
        step::Int,
        total_steps::Union{Int,Nothing} = nothing,
        message::String = "")
```

Records progress for a specific task. Optionally pass `total_steps` and `message`; the message is shown in the dashboard Details tab. When `total_steps` is omitted, the previously stored total is reused.

**Parameters:**

- `manager`: The ProgressManager for this experiment
- `task_number`: 1-indexed task number (1 to total_tasks)
- `step`: Current progress step for this task
- `total_steps`: Optional; set it once and later updates may omit it
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
update!(task::ProgressTask;
        step::Int,
        total_steps::Union{Int,Nothing} = nothing,
        message::String = "")
finish!(task::ProgressTask)
fail!(task::ProgressTask; message::String = "Task failed")
```

Workers call `update!` during the loop and `finish!(task)` when the task is done. A listener on the master process applies these to the DB. As with manager-side `update!`, `total_steps` only needs to be supplied when it changes or is first established.

### Finishing a Task (in-process)

```julia
finish!(manager::ProgressManager, task_number::Int)
```

Explicitly mark a task as completed. Use this when you call `update!` from the same process. For workers, use `finish!(task)` on the `ProgressTask` instead.

### Finishing an Experiment

```julia
finish!(manager::ProgressManager)
```

Mark the entire experiment as completed. This sets the experiment status to "completed" and marks all remaining tasks as done.

### Failing a Task

```julia
fail!(manager::ProgressManager, task_number::Int; message::String = "Task failed")
fail!(manager::ProgressManager; message::String = "Experiment failed")
```

Mark either a specific task or the entire experiment as failed with a message.

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

Install the CLI (installs the `mpm` executable to `~/.julia/bin`). The package must already be in your environment (see Installation above; use the `tachikoma-rewrite` branch):

```julia
using Pkg
Pkg.Apps.add("https://github.com/KristianHolme/MultiProgressManagers.jl", rev = "tachikoma-rewrite")
```

Ensure `~/.julia/bin` is on your PATH. Then run `mpm <db_path>` or `mpm --help`.

## Keyboard Shortcuts

In the dashboard:

- `1-2`: Switch between Runs and Details tabs
- `↑↓`: Navigate experiments/tasks
- `Enter`: Select experiment (in Runs tab)
- `q`: Quit

## Configuration

### Database Location

If you omit `db_path`, the package stores the experiment under the default progress-log directory using a filename derived from the experiment name. Because each experiment now gets its own DB file, duplicate names at the default path are rejected; pass an explicit `db_path` if you want to reopen an existing experiment file.

```julia
# Example: Create database in specific directory
manager = ProgressManager("My Experiment", 3; db_path = "./logs/run1.db")
```

## License

MIT

## Contributing

Contributions welcome! Please open an issue to discuss changes before submitting PRs with new features.
