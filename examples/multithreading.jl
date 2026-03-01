# Multithreading Example
#
# This example demonstrates running 40 tasks concurrently using Julia's multithreading.
# Each task takes between 1-4 minutes (random duration).
# Uses @spawn to start tasks and monitors progress from the main thread.
# Tasks send phase-based messages (warming up / processing / finalizing) via update!(...; message=...)
# so the dashboard "Message" column shows current phase per task.
#
# Run with: julia --threads=8 examples/multithreading.jl
# (Adjust thread count to your CPU)

using MultiProgressManagers
using Base.Threads

function worker_task(task_num::Int, total_steps::Int, manager::ProgressManager)
    """Simulate work for a task with progress updates and phase messages."""
    for step in 1:total_steps
        # Simulate variable work (0.3-0.9 seconds per step)
        sleep_time = 0.3 + 0.6 * rand()
        sleep(sleep_time)

        # Phase-based message for dashboard (visible in running tab)
        progress_frac = step / total_steps
        msg = if progress_frac <= 0.25
            "warming up (step $step)"
        elseif progress_frac <= 0.75
            "processing (step $step/$(total_steps))"
        else
            "finalizing (step $step)"
        end

        update!(manager, task_num, step; total_steps = total_steps, message = msg)
    end

    # Mark task as complete
    finish_task!(manager, task_num)
    println("  Task $task_num complete ($(total_steps) steps)")
end

function main()
    println("="^60)
    println("Multithreading Progress Tracking Example")
    println("="^60)
    println()
    
    # Check thread count
    println("Running with $(nthreads()) threads")
    println()
    
    # Configuration
    num_tasks = 40
    db_path = "./progresslogs/multithreading.db"
    
    # Create experiment
    println("Creating experiment with $num_tasks tasks...")
    manager = ProgressManager(
        "Multithreading Demo",
        num_tasks;
        description = "40 concurrent tasks with random durations (1-4 min each)",
        db_path = db_path
    )
    println("  Experiment ID: $(manager.experiment_id)")
    println()
    
    # Generate random durations for each task (~1-4 minutes worth of steps)
    task_durations = rand(80:240, num_tasks)
    println("Task durations: ~$(minimum(task_durations))-$(maximum(task_durations)) steps each (~1-4 min)")
    println()
    
    # Launch all tasks concurrently using @spawn
    println("Starting all $num_tasks tasks...")
    tasks = Vector{Task}(undef, num_tasks)
    
    for task_num in 1:num_tasks
        total_steps = task_durations[task_num]
        tasks[task_num] = @spawn worker_task(task_num, total_steps, manager)
    end
    
    println("  All tasks spawned, waiting for completion...")
    println()
    
    # Wait for all tasks to complete
    for task_num in 1:num_tasks
        wait(tasks[task_num])
    end
    
    # Finish experiment
    finish_experiment!(manager)
    
    println()
    println("="^60)
    println("All tasks completed!")
    println("="^60)
    println()
    println("View dashboard:")
    println("  ./bin/mpm.jl $db_path")
    println("Or:")
    println("  julia -e 'using MultiProgressManagers; view_dashboard(\"$db_path\")'")
    println()
end

main()
