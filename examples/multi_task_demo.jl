# Multi-Task Demo Example
#
# This example demonstrates the multi-task experiment API where each
# experiment consists of multiple parallel or sequential sub-tasks.
# Each task has its own progress tracking within the overall experiment.

using MultiProgressManagers

# Simulate work on a single task
function simulate_task_work(task_num::Int, step::Int, total_steps::Int)
    # Variable sleep time to simulate different workloads
    base_sleep = 0.005
    variance = 0.01 * rand()
    sleep(base_sleep + variance)

    # Occasionally add extra delay (simulating complex operations)
    if rand() < 0.05
        sleep(0.02)
    end

    return nothing
end

function main()
    println("="^60)
    println("Multi-Task Experiment Demo")
    println("="^60)
    println()
    println("This example creates an experiment with 10 independent tasks.")
    println("Each task has 100 steps and progresses independently.")
    println()

    # Configuration
    num_tasks = 10
    steps_per_task = 100
    db_path = "./progresslogs/multi_task_demo.db"

    # Create the multi-task experiment
    println("Creating experiment with $num_tasks tasks...")
    manager = ProgressManager(
        "Multi-Task Demo",
        num_tasks;
        description = "Demonstration of $num_tasks parallel tasks with progress tracking",
        db_path = db_path
    )
    println("✓ Experiment created: $(manager.experiment_id)")
    println()

    println("Starting $num_tasks tasks...")
    println("Each task has $steps_per_task steps")
    println()

    # Process each task sequentially (could be parallel in real use)
    for task_num in 1:num_tasks
        println("  Task $task_num: Starting...")

        # Simulate work on this task
        for step in 1:steps_per_task
            simulate_task_work(task_num, step, steps_per_task)

            # Update progress for this specific task
            # Update progress for this specific task
            update!(manager, task_num, step; total_steps=steps_per_task)

            # Print milestone updates
            if step % 25 == 0
                pct = round(step / steps_per_task * 100, digits = 0)
                print("    Progress: $pct%\r")
            end
        end

        # Mark this task as complete
        finish_task!(manager, task_num)
        println("  Task $task_num: ✓ Complete                    ")
    end

    println()

    # Mark the entire experiment as finished
    finish_experiment!(manager)

    println("="^60)
    println("All tasks completed!")
    println()
    println("View the dashboard with:")
    println("  mpm $db_path")
    println()
    println("Or from Julia:")
    println("  using MultiProgressManagers")
    println("  view_dashboard(\"$db_path\")")
    println("="^60)
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
