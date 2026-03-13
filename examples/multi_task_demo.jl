using MultiProgressManagers

function unique_db_path(base_db_path::String)
    db_path = base_db_path
    counter = 2
    while isfile(db_path)
        db_path = replace(base_db_path, ".db" => "_$counter.db")
        counter += 1
    end

    return db_path
end

function simulate_task_work(task_num::Int, step::Int, total_steps::Int)
    base_sleep = 0.005
    variance = 0.01 * rand()
    sleep(base_sleep + variance)

    if rand() < 0.05
        sleep(0.02)
    end

    return nothing
end

function main()
    db_path = unique_db_path("./progresslogs/multi_task_demo.db")
    println("="^60)
    println("Multi-Task Experiment Demo")
    println("="^60)
    println()
    println("This example creates an experiment with 10 independent tasks.")
    println("Each task has 100 steps and progresses independently.")
    println()

    num_tasks = 10
    steps_per_task = 100

    println("Creating experiment with $num_tasks tasks...")
    task_descriptions = ["Pipeline stage $i" for i in 1:num_tasks]
    manager = ProgressManager(
        "Multi-Task Demo",
        num_tasks;
        description = "Demonstration of $num_tasks parallel tasks with progress tracking",
        db_path = db_path,
        task_descriptions = task_descriptions,
    )
    println("✓ Experiment created: $(manager.experiment_id)")
    println()

    println("Starting $num_tasks tasks...")
    println("Each task has $steps_per_task steps")
    println()

    for task_num in 1:num_tasks
        println("  Task $task_num: Starting...")
        for step in 1:steps_per_task
            simulate_task_work(task_num, step, steps_per_task)
            update!(manager, task_num; step = step, total_steps = steps_per_task)

            if step % 25 == 0
                pct = round(step / steps_per_task * 100, digits = 0)
                print("    Progress: $pct%\r")
            end
        end

        # Mark this task as complete
        finish!(manager, task_num)
        println("  Task $task_num: ✓ Complete                    ")
    end

    println()
    finish!(manager)

    println("="^60)
    println("All tasks completed!")
    println()
    println("View the dashboard with:")
    println("  mpm $db_path")
    println()
    println("Or from Julia:")
    println("  using MultiProgressManagers")
    println("  view_dashboard(\"$db_path\")")
    return println("="^60)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
