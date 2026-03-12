# Distributed pmap Example
#
# Runs tasks on multiple processes via pmap. The master is the only process that
# touches the DB; workers send progress updates through a RemoteChannel. Each worker
# gets a ProgressTask from get_task(manager, i, :remote) and calls update!
# and finish! so the master's listener can write to the DB.
#
# Run with: julia -p 4 examples/distributed_pmap.jl
# (Adjust worker count to your machine)

using Distributed
using MultiProgressManagers

@everywhere using MultiProgressManagers

@everywhere function run_worker(task::ProgressTask, total_steps::Int)
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
    println("  Task $(task.task_number) complete ($(total_steps) steps)")
    return nothing
end

function main()
    println("="^60)
    println("Distributed pmap Progress Tracking Example")
    println("="^60)
    println()

    num_tasks = 12
    db_path = "./progresslogs/distributed_pmap.db"

    println("Creating experiment with $num_tasks tasks...")
    manager = ProgressManager(
        "Distributed pmap Demo",
        num_tasks;
        description = "Tasks run on worker processes via pmap; progress via RemoteChannel",
        db_path = db_path,
    )
    println("  Experiment ID: $(manager.experiment_id)")
    println()

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
    println()
end

main()
