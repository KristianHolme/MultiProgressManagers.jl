# MultiProgressManagers Examples

This directory contains example scripts demonstrating the multi-task experiment tracking features of MultiProgressManagers.jl.

## Quick Start

```bash
# Run the simple example
julia examples/simple_monitor.jl

# View the dashboard
mpm ./progresslogs/simple_monitor.db
```

## Examples Overview

### 1. `simple_monitor.jl` - Minimal Example
**Purpose**: The simplest possible demonstration of multi-task tracking.

**Features**:
- Creating a multi-task experiment with 5 tasks
- Basic progress updates
- Task completion tracking
- Minimal code (~30 lines)

**Run**: `julia examples/simple_monitor.jl`

**Duration**: ~3 seconds

---

### 2. `basic_example.jl` - Standard Multi-Task Example
**Purpose**: Standard example showing the multi-task API with more detail.

**Features**:
- Creating an experiment with configurable task count
- Progress updates with simulated work
- Task-by-task completion
- Dashboard viewing instructions

**Run**: `julia examples/basic_example.jl`

**Duration**: ~10 seconds

---

### 3. `multi_task_demo.jl` - Full-Featured Demo
**Purpose**: Comprehensive demonstration of the multi-task API.

**Features**:
- 10 parallel tasks with individual progress tracking
- Simulated variable workload per task
- Progress milestones and console output
- Detailed comments explaining the API

**Run**: `julia examples/multi_task_demo.jl`

**Duration**: ~8 seconds

---

### 4. `multithreading.jl` - Concurrent Task Execution
**Purpose**: Demonstrates running 40 tasks concurrently using Julia's multithreading.

**Features**:
- 40 parallel tasks with random durations (10-40 seconds each)
- Uses `@spawn` for concurrent execution
- Shows how to update progress from worker threads
- Monitor concurrent progress in real-time

**Run**: `julia --threads=8 examples/multithreading.jl`

**Note**: Adjust thread count (`--threads=8`) to match your CPU cores

**Duration**: ~40 seconds (tasks run concurrently, not sequentially)

---

---

## Dashboard Usage

After running any example, view the dashboard:

```bash
# From shell
mpm ./progresslogs/example.db

# From Julia
using MultiProgressManagers
view_dashboard("./progresslogs/example.db")
```

### Dashboard Tabs

The dashboard has 2 tabs for monitoring experiments:

**Tab 1: Runs** (press `1`)
- List of all experiments in the database
- Shows experiment name, status, and overall progress
- Sorted by start time (newest first)
- Select an experiment to view details

**Tab 2: Details** (press `2`)
- Detailed view of the selected experiment
- Progress histogram showing task completion distribution
- Task list with individual progress bars
- Shows current step / total steps for each task

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `1` | Switch to Runs tab |
| `2` | Switch to Details tab |
| `↑` / `↓` | Navigate experiments (Runs) or tasks (Details) |
| `Enter` | Select experiment in Runs tab |
| `q` | Quit dashboard |

## Creating Your Own Examples

Template for a multi-task experiment:

```julia
using MultiProgressManagers

# Create an experiment with N tasks
manager = ProgressManager(
    "My Experiment",      # Name shown in dashboard
    5;                    # Number of parallel tasks
    description = "Optional longer description",
    db_path = "./progresslogs/my_exp.db"
)

# Update progress for each task (with total_steps for accurate %)
for task_num in 1:5
    total_steps = 100
    for step in 1:total_steps
        do_work(task_num, step)
        update!(manager, task_num, step; total_steps=total_steps)
    end
    finish_task!(manager, task_num)
end
for task_num in 1:5
    for step in 1:100
        do_work(task_num, step)
        update!(manager, task_num, step)
    end
    finish_task!(manager, task_num)
end

# Mark entire experiment as complete
finish_experiment!(manager)

# View with: mpm ./progresslogs/my_exp.db
```

### API Reference

**Creating an Experiment**
```julia
create_experiment(name::String, total_tasks::Int;
                  description::String="",
                  db_path::String) -> ProgressManager
```

**Updating Task Progress**
```julia
update!(manager::ProgressManager, task_number::Int, current_step::Int;
        total_steps::Int=0)
```

- `total_steps`: Total expected steps for this task. If > 0, enables accurate progress percentage calculation.
- If `total_steps=0` (default), it will be dynamically set to the maximum `current_step` seen so far.
```julia
update!(manager::ProgressManager, task_number::Int, current_step::Int)
```

**Finishing a Task**
```julia
finish_task!(manager::ProgressManager, task_number::Int)
```

**Finishing an Experiment**
```julia
finish_experiment!(manager::ProgressManager)
```

## Tips

1. **Database Location**: The `db_path` directory is created automatically if it doesn't exist
2. **Task Count**: Each experiment can have any number of tasks - choose based on your workload
3. **Step Granularity**: More frequent updates give smoother progress but more DB writes
4. **View While Running**: Open the dashboard while an experiment is running to see real-time updates

## Troubleshooting

**Database locked errors**: 
- Wait a moment and retry
- Close other processes using the database
- The dashboard uses WAL mode for concurrent access

**Dashboard not showing updates**:
- Check that the DB path is correct
- Verify the experiment is still running
- Try quitting and restarting the dashboard

**Empty task list in Details tab**:
- Make sure you've selected an experiment in the Runs tab (press Enter)
- Check that tasks were actually created and updated
