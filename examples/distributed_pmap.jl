using Distributed
using MultiProgressManagers

if nworkers() == 0
    addprocs(4)
end

function unique_db_path(base_db_path::String)
    db_path = base_db_path
    counter = 2
    while isfile(db_path)
        db_path = replace(base_db_path, ".db" => "_$counter.db")
        counter += 1
    end

    return db_path
end

@everywhere using Distributed
@everywhere using MultiProgressManagers

@everywhere function run_worker(task::ProgressTask, total_steps::Int)
    worker_id = myid()
    for step in 1:total_steps
        sleep_time = 0.3 + 0.6 * rand()
        sleep(sleep_time)

        progress_frac = step / total_steps
        msg = if progress_frac <= 0.25
            "[Worker $worker_id] warming up (step $step)"
        elseif progress_frac <= 0.75
            "[Worker $worker_id] processing (step $step/$(total_steps))"
        else
            "[Worker $worker_id] finalizing (step $step)"
        end

        update!(task; step = step, total_steps = total_steps, message = msg)
    end

    finish!(task)
    println("  Task $(task.task_number) complete ($(total_steps) steps)")
    return nothing
end

function main()
    db_path = unique_db_path("./progresslogs/distributed_pmap.db")
    println("="^60)
    println("Distributed pmap Progress Tracking Example")
    println("="^60)
    println()

    num_tasks = 12

    println("Creating experiment with $num_tasks tasks...")
    task_descriptions = ["Task $i" for i in 1:num_tasks]
    manager = ProgressManager(
        "Distributed pmap Demo",
        num_tasks;
        description = "Tasks run on worker processes via pmap; progress via RemoteChannel",
        db_path = db_path,
        task_descriptions = task_descriptions,
    )
    println("  Experiment ID: $(manager.experiment_id)")

    task_durations = rand(40:120, num_tasks)
    println("Task durations: ~$(minimum(task_durations))-$(maximum(task_durations)) steps each")
    println()

    println("Starting $num_tasks tasks on workers (get_task(..., :remote))...")
    tasks = [get_task(manager, i, :remote) for i in 1:num_tasks]
    pmap(i -> run_worker(tasks[i], task_durations[i]), 1:num_tasks)
    println("  All tasks finished.")
    println()

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
