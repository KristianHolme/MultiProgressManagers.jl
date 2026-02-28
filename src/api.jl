"""
    create_progress_manager(name::String, total_steps::Int;
                           description::String="",
                           db_path::String=default_db_path(),
                           update_frequency_ms::Int=100,
                           speed_window_seconds::Real=30,
                           worker_count::Int=1) -> ProgressManager

Create a new ProgressManager for tracking experiment progress.

# Arguments
- `name::String`: Human-readable name for the experiment (used in dashboard)
- `total_steps::Int`: Total number of steps to complete
- `description::String=""`: Optional description
- `db_path::String`: Path to SQLite database file (default: ./progresslogs/{uuid}.db or ~/.local/share/MultiProgressManagers/default.db)
- `update_frequency_ms::Int=100`: Minimum time between database writes (throttling)
- `speed_window_seconds::Real=30`: Time window for short-horizon speed calculation
- `worker_count::Int=1`: Number of workers expected (for distributed runs)

# Returns
- `ProgressManager`: Manager instance that coordinates progress tracking

# Example
```julia
manager = create_progress_manager("Training Run", 10000; 
                                  description="Epoch 1-10",
                                  db_path="./progresslogs/experiment1.db")

# In your computation loop:
for i in 1:10000
    do_work(i)
    update!(manager, i; info="Processing batch \$i")
end

finish!(manager; message="Training completed successfully")
```

# Dashboard Access
After creating the manager, you can view it in the dashboard:
```bash
# From shell:
mpm ./progresslogs/experiment1.db

# Or from Julia:
using MultiProgressManagers
view_dashboard("./progresslogs/experiment1.db")
```
"""
function create_progress_manager(name::String, total_steps::Int;
                                description::String="",
                                db_path::String=default_db_path(),
                                update_frequency_ms::Int=100,
                                speed_window_seconds::Real=30,
                                worker_count::Int=1)
    # Ensure directory exists
    mkpath(dirname(db_path))
    
    # Initialize database and get handle
    db_handle = Database.init_db!(db_path)
    
    # Create experiment record
    experiment_id = Database.create_experiment(db_handle, name, total_steps;
                                               description=description,
                                               worker_count=worker_count)
    
    # Create RemoteChannel for worker coordination (if distributed)
    worker_channel = worker_count > 1 ? RemoteChannel(() -> Channel{ProgressMessage}(4096), 1) : nothing
    
    manager = ProgressManager(experiment_id, db_path, total_steps;
                             worker_channel=worker_channel,
                             update_frequency_ms=update_frequency_ms,
                             speed_window_seconds=speed_window_seconds)
    
    # Store handle in task local storage for this task
    tls = task_local_storage()
    tls[:mpm_db_handle] = db_handle
    
    # Print helpful message about dashboard
    @info """
    ProgressManager created for experiment '$name'
    
    Database: $db_path
    Experiment ID: $experiment_id
    
    To view dashboard:
      Shell:  mpm $db_path
      Julia:  using MultiProgressManagers; view_dashboard("$db_path")
    
    To view all experiments in folder:
      Shell:  mpm $(dirname(db_path))
      Julia:  using MultiProgressManagers; view_folder_dashboard("$(dirname(db_path))")
    """
    
    return manager
end

"""
    update!(manager::ProgressManager, current_step::Int; info::String="")

Record a progress update. Writes to database with throttling based on update_frequency_ms.

# Arguments
- `manager::ProgressManager`: The progress manager
- `current_step::Int`: Current step number (must be >= 0 and <= total_steps)
- `info::String=""`: Optional status message
"""
function update!(manager::ProgressManager, current_step::Int; info::String="")
    current_time = time()
    elapsed = current_time - manager.start_time
    
    # Validate step
    current_step = max(0, min(current_step, manager.total_steps))
    
    # Throttle database writes
    if (current_time - manager.last_update_time) * 1000 >= manager.update_frequency_ms
        # Get or create handle
        tls = task_local_storage()
        if !haskey(tls, :mpm_db_handle)
            tls[:mpm_db_handle] = Database.init_db!(manager.db_path)
        end
        db_handle = tls[:mpm_db_handle]
        
        Database.record_progress!(db_handle, manager.experiment_id, current_step, elapsed)
        manager.last_update_time = current_time
    end
    
    manager.last_step = current_step
    
    return nothing
end

"""
    finish!(manager::ProgressManager; message::String="Completed successfully")

Mark the experiment as completed.

# Arguments
- `manager::ProgressManager`: The progress manager
- `message::String="Completed successfully"`: Completion message
"""
function finish!(manager::ProgressManager; message::String="Completed successfully")
    # Record final progress
    update!(manager, manager.total_steps; info=message)
    
    # Get handle
    tls = task_local_storage()
    if !haskey(tls, :mpm_db_handle)
        tls[:mpm_db_handle] = Database.init_db!(manager.db_path)
    end
    db_handle = tls[:mpm_db_handle]
    
    # Mark as finished
    Database.finish_experiment!(db_handle, manager.experiment_id; message=message)
    
    # Close handle
    Database.close_db!(db_handle)
    delete!(tls, :mpm_db_handle)
    
    @info "Experiment completed: $message"
    
    return nothing
end

"""
    fail!(manager::ProgressManager, error::Exception; message::String=nothing)

Mark the experiment as failed.

# Arguments
- `manager::ProgressManager`: The progress manager
- `error::Exception`: The exception that caused the failure
- `message::String=nothing`: Optional custom error message
"""
function fail!(manager::ProgressManager, error::Exception; message::Union{String,Nothing}=nothing)
    error_msg = message !== nothing ? message : sprint(showerror, error)
    
    # Get handle
    tls = task_local_storage()
    if !haskey(tls, :mpm_db_handle)
        tls[:mpm_db_handle] = Database.init_db!(manager.db_path)
    end
    db_handle = tls[:mpm_db_handle]
    
    Database.fail_experiment!(db_handle, manager.experiment_id, error_msg)
    
    # Close handle
    Database.close_db!(db_handle)
    delete!(tls, :mpm_db_handle)
    
    @error "Experiment failed: $error_msg"
    
    return nothing
end

"""
    fail!(manager::ProgressManager, error_message::String)

Mark the experiment as failed with a message.
"""
function fail!(manager::ProgressManager, error_message::String)
    # Get handle
    tls = task_local_storage()
    if !haskey(tls, :mpm_db_handle)
        tls[:mpm_db_handle] = Database.init_db!(manager.db_path)
    end
    db_handle = tls[:mpm_db_handle]
    
    Database.fail_experiment!(db_handle, manager.experiment_id, error_message)
    
    # Close handle
    Database.close_db!(db_handle)
    delete!(tls, :mpm_db_handle)
    
    @error "Experiment failed: $error_message"
    
    return nothing
end

"""
    default_db_path() -> String

Get the default database path.
Creates a UUID-named database in ./progresslogs/ if the directory exists,
otherwise uses ~/.local/share/MultiProgressManagers/
"""
function default_db_path()
    # Check if ./progresslogs exists
    if isdir("./progresslogs")
        uuid = string(UUIDs.uuid4())
        return joinpath("./progresslogs", "$uuid.db")
    else
        # Use system cache directory
        cache_dir = get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
        dir = joinpath(cache_dir, "MultiProgressManagers")
        mkpath(dir)
        return joinpath(dir, "default.db")
    end
end

"""
    get_progress(manager::ProgressManager) -> Float64

Get current progress as a fraction (0.0 to 1.0).
"""
function get_progress(manager::ProgressManager)
    return manager.last_step / manager.total_steps
end

"""
    get_speeds(manager::ProgressManager) -> NamedTuple

Get current speed metrics.

Returns (total_avg_speed, short_avg_speed) in steps per second.
"""
function get_speeds(manager::ProgressManager)
    # Get handle
    tls = task_local_storage()
    if !haskey(tls, :mpm_db_handle)
        tls[:mpm_db_handle] = Database.init_db!(manager.db_path)
    end
    db_handle = tls[:mpm_db_handle]
    
    return Database.calculate_speeds(db_handle, manager.experiment_id; 
                                    window_seconds=manager.speed_window_seconds)
end
