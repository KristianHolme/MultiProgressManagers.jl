# MultiProgressManagers Examples

This directory contains example scripts demonstrating various features of MultiProgressManagers.

## Quick Start

```bash
# Run the basic example
julia examples/basic_example.jl

# View the dashboard after running
mpm ./progresslogs/basic_example.db
```

## Examples Overview

### 1. `basic_example.jl` - Single Process Progress Tracking
**Purpose**: Simplest example showing basic progress tracking.

**Features**:
- Creating a ProgressManager
- Recording progress updates
- Viewing progress and speeds
- Finishing an experiment

**Run**: `julia examples/basic_example.jl`

**Duration**: ~15 seconds

---

### 2. `distributed_example.jl` - Multi-Worker Progress
**Purpose**: Demonstrates progress tracking across distributed workers.

**Features**:
- Setting up distributed workers
- Using RemoteChannels for coordination
- Tracking worker-specific progress

**Run**: `julia -p 4 examples/distributed_example.jl`

**Note**: Requires 4 workers (adjust `-p 4` to your preference)

---

### 3. `speed_demo.jl` - Speed Tracking Demonstration
**Purpose**: Shows how total vs short-horizon speed calculations work.

**Features**:
- Different task speeds (fast/medium/slow)
- Comparing total average vs short-horizon speed
- Configurable speed calculation window

**Run**: `julia examples/speed_demo.jl`

**Duration**: ~30 seconds (includes 3 phases with different speeds)

---

### 4. `multiple_experiments.jl` - Folder Mode Demo
**Purpose**: Creates multiple experiments to demonstrate folder-mode dashboard.

**Features**:
- Creating experiments in a shared folder
- Mix of completed/failed experiments
- Folder selection in dashboard

**Run**: `julia examples/multiple_experiments.jl`

**View**: `mpm ./progresslogs/multi_example/`

---

### 5. `admin_operations.jl` - Database Operations
**Purpose**: Shows how to query and modify experiments programmatically.

**Features**:
- Querying all/running experiments
- Getting completion statistics
- Manual status updates
- Fixing stuck experiments

**Run**: `julia examples/admin_operations.jl`

---

## Dashboard Usage

After running any example, you can view the dashboard:

```bash
# View single experiment
mpm ./progresslogs/example.db

# View folder of experiments
mpm ./progresslogs/folder/

# From Julia
using MultiProgressManagers
view_dashboard("./progresslogs/example.db")
```

### Dashboard Navigation

**Tabs** (use number keys 1-4 or F1-F4):
- **Select**: Choose database (folder mode only)
- **Running**: View active experiments with real-time metrics
- **Stats**: Completion histograms and statistics
- **Admin**: Edit experiment records manually

**Common Keys**:
- `↑↓`: Navigate lists
- `Enter`: Select/Confirm
- `q`: Quit

**Admin Tab Keys**:
- `e`: Edit experiment
- `c`: Mark as completed
- `r`: Reset to running
- `d`: Delete experiment
- `y/n`: Confirm/cancel

## Creating Your Own Examples

Template for a basic example:

```julia
using MultiProgressManagers

# Create progress manager
manager = create_progress_manager(
    "My Experiment",
    1000;
    db_path="./progresslogs/my_exp.db",
    update_frequency_ms=100,
    speed_window_seconds=30
)

# Do your work and update progress
for i in 1:1000
    do_work(i)
    update!(manager, i)
end

# Mark as complete
finish!(manager)

# View with: mpm ./progresslogs/my_exp.db
```

## Tips

1. **Update Frequency**: For fast tasks, increase `update_frequency_ms` to reduce DB writes
2. **Speed Window**: Use shorter windows for more responsive ETA, longer for stability
3. **Folder Organization**: Group related experiments in folders for easy navigation
4. **DB Cleanup**: Old databases can be deleted manually or via the Admin tab

## Troubleshooting

**Database locked errors**: 
- Wait a moment and retry
- Close other processes using the database
- Restart Julia if necessary

**Dashboard not showing updates**:
- Check that the DB path is correct
- Try refreshing with 'r' in Stats tab
- Verify the experiment is still running

**Slow performance**:
- Increase `update_frequency_ms` (try 500-1000ms)
- Use longer `speed_window_seconds` for smoother calculations
