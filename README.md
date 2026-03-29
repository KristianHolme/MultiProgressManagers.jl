# MultiProgressManagers.jl

A lightweight progress tracking system for parallel tasks. Implemented in pure Julia with a [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl)-based dashboard and SQLite persistence.

## Features

- **📊 Tachikoma Dashboard**: Clean 2-tab terminal UI for monitoring experiments
- **💾 SQLite Persistence**: Current state stored in SQLite
- **🔄 Multi-Task Support**: Track parallel sub-tasks within a single experiment
- **⚡ Simple API**: `update!`, `finish!`, `fail!`
- **🔀 Distributed & Threads**: Single DB writer on the master; workers get a `ProgressTask` via `get_task(manager, id, :remote)` or `:local` and send updates over a channel

## Demo

![recording_small](https://github.com/user-attachments/assets/e754d071-adb2-499a-b198-bebeb82c1585)

## Installation

**Package** (for use in Julia scripts/REPL):

```julia
using Pkg
Pkg.add("MultiProgressManagers")
```

**App / CLI** (optional, for the `mpm` dashboard from the shell):

```julia
using Pkg
Pkg.Apps.add("MultiProgressManagers")
```

Ensure `~/.julia/bin` is on your `PATH`. Then run `mpm <db_path>` or `mpm --help`.  
You can also open the dashboard from Julia without the app: `view_dashboard(db_path)` (see Quick Start).

## Quick Start

### Basic Usage (same process)

```julia
using MultiProgressManagers

# Create a multi-task experiment with 5 parallel tasks
N_tasks = 5
parameter_values = rand(N)
manager = ProgressManager(
    "Training Run", N;
    description = "Epoch 1-10 of ResNet training",
    db_path = "./progresslogs/experiment1.db",
    task_description = ["parameter=$(val)" for val in parameter_values],
)

# Update progress for each task as it runs
for (task_num, param_val) in enumerate(parameter_values)
    steps = rand([100, 200, 300])
    update!(manager;total_steps = steps, message="Starting run with $steps steps")
    for step in 1:steps
        do_work(task_num, param_val, step)
        update!(manager, task_num; step = step, message = "step $step")
    end
    finish!(manager, task_num)
end

# Mark entire experiment as complete
finish!(manager)
```

### Worker-based progress (threads or Distributed)

When work runs on other threads or processes, only the master touches the DB. Workers get a **ProgressTask** and send updates over a channel. Load `Distributed` before requesting `:remote` tasks so the remote-worker extension is available:

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

See `examples/multithreading.jl` (threads + `ProgressTask` via `get_task(..., :local)`) and `examples/distributed_pmap.jl` (Distributed + `ProgressTask` via `get_task(..., :remote)`).

### Drill.jl training callbacks

`create_drill_callback` is exported from `MultiProgressManagers`, so you do not need `Base.get_extension` to discover it. Add Drill.jl to your environment, load it with `using Drill` (this activates the package extension), then build a callback from a remote progress task:

```julia
using MultiProgressManagers
using Drill
using Distributed  # if workers use :remote tasks

manager = ProgressManager("my_study", n; db_path = default_db_path("my_study"))
task = get_task(manager, worker_index, :remote)
callback = create_drill_callback(task)
```

If Drill is not loaded, calling `create_drill_callback` raises `ArgumentError` after a warning.

### Viewing the Dashboard

From the shell: `mpm ./progresslogs/experiment1.db` (requires the app; see Installation).  
From Julia: `using MultiProgressManagers; view_dashboard("./progresslogs/experiment1.db")`.

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
                db_path::Union{String,Nothing} = nothing,
                task_descriptions::Vector{String} = String[])
```

**Parameters:**

- `name`: Human-readable experiment name (shown in dashboard)
- `num_tasks`: Number of parallel sub-tasks in this experiment
- `description`: Optional longer description
- `db_path`: Optional path to SQLite database file. When omitted, the package derives a default path from the experiment name.
- `task_descriptions`: Optional vector of per-task labels (length must equal `num_tasks`).

**Returns:** A `ProgressManager` instance for tracking this experiment.

### Updating Task Progress (in-process)

```julia
update!(
    manager::ProgressManager, task_number::Int;
    step::Union{Int, Nothing} = nothing,
    total_steps::Union{Int,Nothing} = nothing,
    message::String = ""
)
```

Records progress for a specific task. Report progress by supplying `step`, Update total steps for the task by using `total_steps`. Update the current task message using `message`. The message is shown in the dashboard Details tab. When `total_steps` is omitted, the previously stored total is reused. Its recommended to update `total_steps` at the beginning of a task. If `total_steps` is not supplied, it is updated automatically as `step` is updated.

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

- `:local` — plain `Channel` (same process,e.g. `@spawn` or `@threads`)
- `:remote` — `RemoteChannel` (for `Distributed` / `pmap`)

```julia
update!(task::ProgressTask;
    step::Union{Int,Nothing} = nothing
    total_steps::Union{Int,Nothing} = nothing,
    message::String = ""
)
finish!(task::ProgressTask)
fail!(task::ProgressTask; message::String = "Task failed")
```

Workers call `update!` during the loop and `finish!(task)` when the task is done. A listener on the master process applies these to the DB. As with manager-side `update!`, `total_steps` only needs to be supplied when it changes or is first established.

### Drill training integration

```julia
create_drill_callback(task::ProgressTask)
```

Returns a Drill callback that reports training progress through `task`. Requires Drill.jl: run `using Drill` before calling so the extension loads. Exported from the main module as `create_drill_callback`.

### Finishing a Task (in-process)

```julia
finish!(manager::ProgressManager, task_number::Int)
```

Explicitly mark a task as completed. When doing multithreaded or distributed tasks, use `finish!(task)` on the `ProgressTask` instead.

### Finishing an Experiment

```julia
finish!(manager::ProgressManager; message::String = "Completed successfully")
```

Mark the entire experiment as completed. This sets the experiment status to "completed" and marks all remaining tasks as done. Optional `message` is stored as the experiment's final message.

### Failing a Task or Experiment

```julia
fail!(manager::ProgressManager, task_number::Int; message::String = "Task failed")
fail!(manager::ProgressManager; message::String = "Experiment failed")
```

Mark either a specific task or the entire experiment as failed with a message. The code also provides overloads that take an `Exception` or a positional `error_message::String`; these ultimately set the same `message` used in the DB.

## Keyboard Shortcuts

**Global**

- `q` / `Q`: Quit
- `r`: Refresh (reload data from database)

**Tabs**

- `1` or `F1`: Runs tab
- `2` or `F2`: Details (Running) tab
- `←` / `h`: Previous tab
- `→` / `l`: Next tab

**Runs tab**

- `↑` / `↓` or `Ctrl+k` / `Ctrl+j`: Move selection; the highlighted experiment is the one shown in the Details tab
- `f`: Mark selected running experiment as failed (opens confirmation modal)

**Confirmation modal** (after pressing `f`)

- `Enter`: Confirm (mark as failed) or cancel, depending on highlighted option
- `←` / `h` or `→` / `l`: Switch between Cancel and Confirm
- `Escape` or `c`: Cancel and close modal

**Details (Running) tab**

- `↑` / `↓` or `Ctrl+k` / `Ctrl+j`: Scroll the task list
- `a` / `d`: Shrink or grow the message column width

## Configuration

### Database Location

If you omit `db_path`, the package stores the experiment under the default progress-log directory using a filename derived from the experiment name. Because each experiment gets its own DB file, duplicate names at the default path are rejected; pass an explicit `db_path` if you want to reopen an existing experiment file.

```julia
# Example: Create database in specific directory
manager = ProgressManager("My Experiment", 3; db_path = "./logs/run1.db")
```

## License

MIT

## Contributing

Contributions welcome! Please open an issue to discuss changes before submitting PRs with new features.
