# AGENTS.md - MultiProgressManagers.jl

## Project Overview

MultiProgressManagers.jl is a Julia package for tracking and visualizing progress of long-running computations, especially distributed experiments. It provides:

1. **Progress Tracking API** - Simple interface for recording progress updates (in-process: `update!`, `finish!`, `fail!`; workers: `ProgressTask` + `update!`, `finish!`, `fail!`)
2. **SQLite Persistence** - All progress history stored in SQLite databases
3. **Tachikoma Dashboard** - Real-time terminal UI for monitoring experiments
4. **Distributed Support** - Single DB writer on the master; workers get a `ProgressTask` via `get_task(manager, id, :remote)` and send updates over a channel; listener on master applies them to the DB

## Architecture

### Core Components

```
src/
├── MultiProgressManagers.jl    # Main module, exports
├── database.jl                 # SQLite operations, DBHandle, ensure_open!, _get_db, _open_new_db
├── types.jl                    # ProgressManager, TaskStatus, ProgressTask, ProgressUpdate, TaskFinished, ProgressMessage
├── api.jl                      # create_experiment, update!, finish!, fail!
├── channel.jl                  # get_task, update!, finish!, fail!; listener + pump tasks; :local / :remote
└── dashboard/                  # Tachikoma-based UI
    ├── model.jl                # ProgressDashboard struct, _poll_database!
    ├── view.jl                 # Main view function, tab bar rendering
    ├── update.jl               # Event handling (keyboard, actions)
    ├── runs_tab.jl             # Tab: experiment list / runs
    └── running_tab.jl          # Tab: running experiments list + detail (tasks, message column)
```

## Tachikoma Patterns (Learn from Tachikoma.jl)

Tachikoma is a terminal UI framework using the Elm architecture (Model-View-Update).

### Key Tachikoma Concepts

1. **Model**: Subtype `Tachikoma.Model` abstract type
   ```julia
   @kwdef mutable struct ProgressDashboard <: Tachikoma.Model
       quit::Bool = false
       tick::Int = 0
       # ... your fields
   end
   ```

2. **View**: Render UI to a buffer
   ```julia
   function Tachikoma.view(m::ProgressDashboard, f::Frame)
       m.tick += 1
       buf = f.buffer
       area = f.area
       
       # Render outer block
       outer = Block(
           title = " Title ",
           border_style = tstyle(:border),
           title_style = tstyle(:title, bold = true)
       )
       main = render(outer, area, buf)
       
       # Split layout
       rows = tsplit(Layout(Vertical, [Fixed(1), Fill(), Fixed(1)]), main)
       
       # Render content
       _render_content!(m, rows[2], buf)
   end
   ```

3. **Update**: Handle events
   ```julia
   function Tachikoma.update!(m::ProgressDashboard, evt::KeyEvent)
       if evt.key == :q
           m.quit = true
           return
       end
       # ... handle other keys
   end
   ```

4. **App Entry Point**:
   ```julia
   Tachikoma.app(model; fps=60)
   ```

### Essential Tachikoma UI Components

- **Block**: Bordered container with title
  ```julia
  block = Block(title=" Title ", border_style=tstyle(:border))
  inner_area = render(block, area, buf)
  ```

- **set_string!**: Draw text at position
  ```julia
  set_string!(buf, x, y, "text", tstyle(:text); max_x=right(area))
  ```

- **SelectableList**: Interactive list with selection
  ```julia
  list = SelectableList(items; selected=current_index)
  render(list, area, buf)
  ```

- **DataTable**: Table with columns
  ```julia
  table = DataTable(columns, data; selected=selected_row)
  render(table, area, buf)
  ```

- **Gauge/Progress**: Visual progress indicator
  ```julia
  gauge = Gauge(label="Progress", value=0.75, show_percentage=true)
  render(gauge, area, buf)
  ```

- **Sparkline**: Mini line chart
  ```julia
  sparkline = Sparkline(data_vector)
  render(sparkline, area, buf)
  ```

- **BarChart**: Bar chart visualization
  ```julia
  bars = [BarEntry("label", value), ...]
  chart = BarChart(bars; max_value=max_val)
  render(chart, area, buf)
  ```

- **TextInput**: Editable text field
  ```julia
  input = TextInput("initial text")
  render(input, area, buf)
  value = Tachikoma.text(input)  # Get current value
  ```

- **ResizableLayout**: Draggable pane split
  ```julia
  layout = ResizableLayout(Horizontal, [Percent(40), Fill()])
  panes = split_layout(layout, area)
  ```

### Tachikoma Styling

- `tstyle(:text)` - Default text
- `tstyle(:text_dim)` - Dimmed text
- `tstyle(:accent)` - Accent/highlight
- `tstyle(:success)` - Success state (green)
- `tstyle(:warning)` - Warning state (yellow)
- `tstyle(:error)` - Error state (red)
- `tstyle(:border)` - Border color
- `tstyle(:title)` - Title color

### Tachikoma Event Handling

Key events have `evt.key` and `evt.char`:
- `evt.key == :char && evt.char == 'q'` - Letter keys
- `evt.key == :up/down/left/right` - Arrow keys
- `evt.key == :enter/escape/tab` - Special keys
- `evt.key == :f1/f2/f3/f4` - Function keys

Mouse events have `evt.button`, `evt.action`, `evt.x`, `evt.y`.

## Kaimon Patterns (Learn from Kaimon.jl)

Kaimon is an MCP server with a sophisticated Tachikoma dashboard. Key patterns:

### Real-Time Data Updates

Kaimon uses a polling pattern with cached data:

```julia
function _poll_database!(m::ProgressDashboard)
    # Only poll at configured frequency
    current_time = time()
    if (current_time - m._last_poll) * 1000 < m.poll_frequency_ms
        return  # Skip this frame
    end
    m._last_poll = current_time
    
    # Query database
    m.data = fetch_from_db(m.db_handle)
    
    # Update derived state
    m.stats = calculate_stats(m.data)
end
```

### Tab-Based Interface

Kaimon shows how to structure multi-tab dashboards:

```julia
function Tachikoma.view(m::KaimonModel, f::Frame)
    # Common header (tab bar)
    _render_tab_bar!(m, tab_area, buf)
    
    # Route to tab-specific view
    @match m.active_tab begin
        1 => _view_server_tab!(m, content_area, buf)
        2 => _view_sessions_tab!(m, content_area, buf)
        3 => _view_activity_tab!(m, content_area, buf)
        _ => nothing
    end
    
    # Common footer (status bar)
    _render_status_bar!(m, status_area, buf)
end
```

### Handling Missing Database Values

SQLite.jl returns `missing` for NULL columns. Always handle this:

```julia
# In struct definitions
@kwdef struct ExperimentView
    name::Union{String,Missing}  # Can be missing
    value::Union{Float64,Missing}
end

# When displaying
name = ismissing(exp.name) ? "Unknown" : exp.name
value = ismissing(exp.value) ? 0.0 : exp.value
```

### List Selection Management

Kaimon pattern for maintaining valid selection indices:

```julia
# After refreshing data, clamp selection to valid range
if isempty(m.items)
    m.selected = 0
elseif m.selected > length(m.items)
    m.selected = length(m.items)
end
```

### Layout Patterns

Kaimon uses nested resizable layouts:

```julia
# Main horizontal split
main_layout = ResizableLayout(Horizontal, [Percent(45), Fill()])
left, right = split_layout(main_layout, area)

# Nested vertical split in left pane
left_layout = ResizableLayout(Vertical, [Fill(), Percent(40)])
top, bottom = split_layout(left_layout, left)
```

## MultiProgressManager-Specific Patterns

### ProgressTask and Channel-Based Workers (Single DB Writer)

The **master process** is the only one that touches the DB. Workers (threads or separate processes) never call manager-side `update!` or open the database; they receive a **ProgressTask** and send progress over a channel. A single **listener** task on the master reads from a sink channel (fed by pump tasks from local/remote channels) and calls `update!` / `finish!` / `fail!` on the `ProgressManager`.

- **Get a task handle:** `task = get_task(manager, task_number, type=:local)` or `get_task(manager, task_number, :remote)`.
  - `:local` uses a plain `Channel` (same process, e.g. `@spawn`).
  - `:remote` uses a `RemoteChannel` (for `Distributed` / `pmap`).
- **From the worker:** `update!(task; step = current_step, total_steps = ..., message = "...")`, `finish!(task)`, and `fail!(task; message = "...")`. These only `put!` into the task's channel.
- **Message types:** `ProgressUpdate(task_number, current_step, total_steps, message)`, `TaskFinished(task_number)`, and `TaskFailed(task_number, message)`; the listener dispatches on these and updates the DB.
- **Implementation:** `channel.jl` defines `_current_slot`, `_ensure_channels_vector!`, `_get_or_create!` (dispatched on slot type for JET), and the listener/pump loops. ProgressManager stores `_channels`, `_sink`, `_listener_task`, `_pump_tasks`, and `_channel_lock`.

Example (Distributed): create `manager`, then `tasks = [get_task(manager, i, :remote) for i in 1:n]`, `pmap(i -> run_worker(tasks[i], ...), 1:n)`, then `finish!(manager)`. Worker: `run_worker(task, total_steps)` loops steps, calls `update!(task; step = step, ...)`, then `finish!(task)`.

### Database Handle Pattern

The DBHandle uses lazy connection opening to avoid precompilation issues. Opening and closing use **multiple dispatch** so JET sees concrete types (no `Union{Nothing, SQLite.DB}` in hot paths):

```julia
mutable struct DBHandle
    db::Union{SQLite.DB,Nothing}  # Nothing until first use
    path::String
end

# Internal: dispatch on current db type, return SQLite.DB
_get_db(::Nothing, path) = _open_new_db(path)
_get_db(db::SQLite.DB, path) = isopen(db) ? db : (close(db); _open_new_db(path))

function ensure_open!(handle::DBHandle)
    db = _get_db(handle.db, handle.path)
    handle.db = db
    return db  # callers use this return value (concrete type)
end
```

### Retry Logic for Database Locks

Always wrap database operations with retry logic:

```julia
function with_retry(f::Function, max_retries::Int=3)
    delay = 0.01
    for attempt in 1:max_retries
        try
            return f()
        catch e
            error_str = sprint(showerror, e)
            is_lock_error = occursin("locked", lowercase(error_str))
            if is_lock_error && attempt < max_retries
                sleep(delay * (1 + 0.1 * rand()))
                delay *= 2
            else
                rethrow(e)
            end
        end
    end
end
```

### WAL Mode for Concurrency

SQLite WAL mode allows readers while writer is active:

```julia
DBInterface.execute(db, "PRAGMA journal_mode = WAL;")
DBInterface.execute(db, "PRAGMA busy_timeout = 5000;")  # 5 second timeout
DBInterface.execute(db, "PRAGMA synchronous = NORMAL;")
```

### Stats Caching to Prevent Flickering

Cache stats that don't need real-time updates:

```julia
# In model
_last_preview_refresh::Float64 = 0.0
_cached_preview_stats::Union{NamedTuple,Nothing} = nothing

# In view
if time() - m._last_preview_refresh > 1.0  # Refresh every 1 second
    m._cached_preview_stats = query_stats()
    m._last_preview_refresh = time()
end
# Use m._cached_preview_stats for rendering
```

## Key Files to Understand

When working on this codebase, focus on:

1. **src/dashboard/model.jl** - The ProgressDashboard struct and _poll_database! function
2. **src/dashboard/view.jl** - Main view routing and tab bar
3. **src/dashboard/update.jl** - Keyboard event handling
4. **src/database.jl** - All SQLite operations, retry logic, and dispatch helpers (_get_db, _open_new_db, _close_db)
5. **src/api.jl** - User-facing API (create_experiment, update!, finish!, fail!)
6. **src/channel.jl** - ProgressTask API (`get_task`, `update!`, `finish!`, `fail!`), listener loop, pump tasks, `_current_slot` / `_get_or_create!` dispatch

## Common Tasks

### Adding a New Dashboard Tab

1. Add tab view function in new file (e.g., `new_tab.jl`)
2. Add tab handling in `view.jl` @match block
3. Add tab update handling in `update.jl`
4. Add tab label in `_render_tab_bar!`

### Adding a New Database Query

1. Add function in `database.jl` with retry logic
2. Handle Missing values in return data
3. Update struct types to accept Union{T,Missing}
4. Add ismissing checks in all display code

### Fixing Database Lock Issues

1. Ensure WAL mode is enabled
2. Add retry logic with with_retry()
3. Check for concurrent access patterns
4. Consider adding caching to reduce query frequency

### Reporting Progress from Workers (Distributed or Threads)

1. Master: create `manager = ProgressManager(...)`.
2. Master: get task handles with `get_task(manager, task_number, :local)` (threads) or `get_task(manager, task_number, :remote)` (Distributed). Precompute e.g. `tasks = [get_task(manager, i, :remote) for i in 1:num_tasks]` if using pmap.
3. Workers: receive a `ProgressTask`, call `update!(task; step = step, total_steps = ..., message = "...")` in the loop, then `finish!(task)` when done. Workers must not call manager-side `update!` or touch the DB.
4. Master: after all work is done, call `finish!(manager)`. See `examples/distributed_pmap.jl` and `examples/multithreading.jl`.

## References

- Tachikoma.jl: `/home/kristian/.julia/packages/Tachikoma/oMALT/src/`
  - Core: `app.jl`, `Tachikoma.jl`
  - Widgets: `widgets/` directory
  - Layout: `layout.jl`, `resizable_layout.jl`
  
- Kaimon.jl: `/home/kristian/.julia/dev/MultiProgressManagers/dev/Kaimon/src/tui/`
  - Model: `types.jl`
  - View: `view.jl`
  - Update: `update.jl`
  - Advanced patterns: `activity.jl`, `search.jl`

## Development Notes

- Package is on branch `tachikoma-rewrite`
- Uses Tachikoma for terminal UI
- Uses SQLite.jl with WAL mode
- All database fields can be Missing - handle with ismissing()
- Dashboard polls database at configurable frequency (default 500ms)
- Dashboard always uses folder mode (a file path uses the directory containing that file)
- **Single DB writer:** Only the process that owns the ProgressManager writes to the DB; workers use `ProgressTask` + `update!` / `finish!` / `fail!` and a channel-backed listener.
- **JET-friendly patterns:** Union{Nothing, T} is handled via multiple dispatch (e.g. _get_db(::Nothing, path) vs _get_db(db::SQLite.DB, path), _current_slot(::Nothing, ...) vs _current_slot(channels::Vector{Any}, ...), _get_or_create!(..., ::Nothing) vs concrete channel type). Use return values of concrete type instead of mutable fields after assignment so the compiler/JET infers narrow types.

## Simplified Database Schema (MWP)

For the Minimum Working Product, we use a simplified schema with only 2 tables:

### experiments table
Stores metadata about each experiment run:

```sql
CREATE TABLE experiments (
    id TEXT PRIMARY KEY,
    name TEXT,
    description TEXT,
    total_tasks INTEGER,
    status TEXT CHECK(status IN ('running', 'completed', 'failed')),
    started_at REAL,
    finished_at REAL
);
```

**Fields:**
- `id`: UUID primary key for the experiment
- `name`: Human-readable experiment name
- `description`: Optional longer description
- `total_tasks`: Number of sub-tasks in this experiment
- `status`: Current status (running/completed/failed)
- `started_at`: Unix timestamp when experiment started
- `finished_at`: Unix timestamp when experiment completed/failed (NULL if running)

### tasks table
Stores current state of each sub-task (no history):

```sql
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    experiment_id TEXT,
    task_number INTEGER,
    total_steps INTEGER,
    current_step INTEGER,
    status TEXT CHECK(status IN ('pending', 'running', 'completed', 'failed')),
    started_at REAL,
    last_updated REAL,
    display_message TEXT DEFAULT '',
    description TEXT DEFAULT '',
    FOREIGN KEY (experiment_id) REFERENCES experiments(id)
);
```

**Fields:**
- `id`: UUID primary key for the task
- `experiment_id`: Foreign key to experiments table
- `task_number`: 1-indexed position in the experiment's task list (for ordering)
- `total_steps`: Total steps required to complete this task
- `current_step`: Current progress (0 to total_steps)
- `status`: Task status (pending/running/completed/failed)
- `started_at`: Unix timestamp when task started
- `last_updated`: Unix timestamp of last progress update
- `display_message`: Live message updated during simulation (epoch, stage, etc.)
- `description`: Static metadata for the task (set at creation, not updated by progress)

**Key Design Decisions:**
- NO progress_snapshots table (no history tracking for MWP)
- Speed calculated as: current_step / (last_updated - started_at)
- Each experiment can have multiple parallel sub-tasks
- Current state only - previous progress updates are not retained

## Cursor Cloud specific instructions

### Quick reference

| Action | Command |
|---|---|
| Instantiate deps | `julia --project=. -e 'using Pkg; Pkg.instantiate()'` |
| Run tests | `julia --project=. -e 'using Pkg; Pkg.test()'` |
| Load package | `julia --project=. -e 'using MultiProgressManagers'` |

### Environment notes

- Julia is installed via `juliaup` (release channel, currently 1.12.5) at `~/.juliaup/bin`. Ensure `PATH` includes this directory.
- The project requires Julia >= 1.12 (`julia = "1.12"` in `[compat]`).
- `Tachikoma.jl` is a registered package in the General registry.
- Tests use `ParallelTestRunner` and run 3 test files in parallel: `core.jl`, `aqua.jl`, `jet.jl`. All 24 tests should pass.
- No linter is configured. JET.jl and Aqua.jl checks run as part of the test suite.
- This is a library — there is no dev server. The Tachikoma dashboard (`view_dashboard(db_path)` or `bin/mpm.jl`) requires a real terminal (TTY) and cannot be tested headlessly in a cloud agent environment.
