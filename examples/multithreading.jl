using MultiProgressManagers
using Base.Threads

function unique_db_path(base_db_path::String)
    db_path = base_db_path
    counter = 2
    while isfile(db_path)
        db_path = replace(base_db_path, ".db" => "_$counter.db")
        counter += 1
    end

    return db_path
end

function worker_task(task::ProgressTask, total_steps::Int)
    for step in 1:total_steps
        sleep_time = 0.3 + 0.6 * rand()
        sleep(sleep_time)

        progress_frac = step / total_steps
        msg = if progress_frac <= 0.25
            "warming up (step $step)"
        elseif progress_frac <= 0.75
            "processing (step $step/$(total_steps))"
        else
            "finalizing (step $step)"
        end

        update!(task; step = step, total_steps = total_steps, message = msg)
    end

    finish!(task)
    return println("  Task $(task.task_number) complete ($(total_steps) steps)")
end

function main()
    db_path = unique_db_path("./progresslogs/multithreading.db")
    println("="^60)
    println("Multithreading Progress Tracking Example")
    println("="^60)
    println()

    println("Running with $(nthreads()) threads")
    println()

    num_tasks = 40

    println("Creating experiment with $num_tasks tasks...")
    task_descriptions = ["Thread $i" for i in 1:num_tasks]
    manager = ProgressManager(
        "Multithreading Demo",
        num_tasks;
        description = "40 concurrent tasks with random durations (1-4 min each)",
        db_path = db_path,
        task_descriptions = task_descriptions,
    )
    println("  Experiment ID: $(manager.experiment_id)")
    println()

    task_durations = rand(80:240, num_tasks)
    println("Task durations: ~$(minimum(task_durations))-$(maximum(task_durations)) steps each (~1-4 min)")
    println()

    println("Starting all $num_tasks tasks...")
    progress_tasks = [get_task(manager, task_number, :local) for task_number in 1:num_tasks]
    tasks = Vector{Task}(undef, num_tasks)
    for task_num in 1:num_tasks
        total_steps = task_durations[task_num]
        tasks[task_num] = @spawn worker_task(progress_tasks[task_num], total_steps)
    end

    println("  All tasks spawned, waiting for completion...")
    println()

    for task_num in 1:num_tasks
        wait(tasks[task_num])
    end

    finish!(manager)

    println()
    println("="^60)
    println("All tasks completed!")
    println("="^60)
    println()
    println("View dashboard:")
    println("  ./bin/mpm.jl $db_path")
    println("Or:")
    println("  julia -e 'using MultiProgressManagers; view_dashboard(\"$db_path\")'")
    return println()
end

main()
