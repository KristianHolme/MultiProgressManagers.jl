# AGENTS.md - MultiProgressManagers.jl

## Project Overview

MultiProgressManagers.jl is a Julia package for tracking and visualizing progress of long-running computations, especially distributed experiments. It provides:

1. **Progress Tracking API** - Simple interface for recording progress updates
2. **SQLite Persistence** - All progress history stored in SQLite databases
3. **Tachikoma Dashboard** - Real-time terminal UI for monitoring experiments
4. **Distributed Support** - RemoteChannels for worker coordination

## Architecture

### Core Components

```
src/
├── MultiProgressManagers.jl    # Main module, exports
├── database.jl                 # SQLite operations, DBHandle
├── types.jl                  # ProgressManager, message types
├── api.jl                    # User-facing API (create_progress_manager, update!, etc.)
├── distributed.jl            # Worker coordination via RemoteChannels
└── dashboard/                # Tachikoma-based UI
    ├── model.jl              # ProgressDashboard struct, _poll_database!
    ├── view.jl               # Main view function, tab bar rendering
    ├── update.jl             # Event handling (keyboard, actions)
    ├── select_tab.jl         # Tab 1: Database selector (folder mode)
    ├── running_tab.jl        # Tab 2: Running experiments list + detail
    ├── stats_tab.jl          # Tab 3: Statistics and histograms
    └── admin_tab.jl          # Tab 4: Manual experiment editing
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

### Database Handle Pattern

The DBHandle uses lazy connection opening to avoid precompilation issues:

```julia
mutable struct DBHandle
    db::Union{SQLite.DB,Nothing}  # Nothing until first use
    path::String
end

function ensure_open!(handle::DBHandle)
    if handle.db === nothing || !SQLite.isopen(handle.db)
        handle.db = SQLite.DB(handle.path)
        _init_schema!(handle.db)
    end
    return handle.db
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
4. **src/database.jl** - All SQLite operations and retry logic
5. **src/api.jl** - User-facing API functions

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
- Supports both single-file and folder modes
