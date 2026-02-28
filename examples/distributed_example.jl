# Distributed Computing Example
# 
# This example shows how to use MultiProgressManagers with Julia's
# distributed computing capabilities to track progress across multiple workers.
#
# Usage:
#   julia -p 4 distributed_example.jl   # Run with 4 workers

using Distributed
using MultiProgressManagers

# Check if we have workers
if nworkers() == 0
    println("Error: No workers available.")
    println("Run with: julia -p N distributed_example.jl")
    println("   where N is the number of worker processes")
    exit(1)
end

println("="^60)
println("Distributed Computing Example")
println("Workers: $(nworkers())")
println("="^60)
println()

# Make sure all workers have MultiProgressManagers
@everywhere using MultiProgressManagers

# Define the dummy task on all workers
@everywhere function distributed_dummy_task(x::Int)
    # Simulate work based on worker ID
    worker_id = myid()
    
    # Workers do different amounts of work
    base_sleep = 0.01 * (1 + (worker_id % 3))
    sleep_time = base_sleep + 0.02 * rand()
    sleep(sleep_time)
    
    # Simulate occasional slow task
    if rand() < 0.05
        sleep(0.2)
    end
    
    return (worker = worker_id, input = x, output = x^2, sleep_time = sleep_time)
end

function main()
    total_tasks = 1000
    tasks_per_worker = ceil(Int, total_tasks / nworkers())
    db_path = "./progresslogs/distributed_example.db"
    
    println("Total tasks: $total_tasks")
    println("Tasks per worker: ~$tasks_per_worker")
    println()
    
    # Create progress manager with worker support
    println("Creating progress manager...")
    manager = create_progress_manager(
        "Distributed Example",
        total_tasks;
        description = "Processing $total_tasks tasks across $(nworkers()) workers",
        db_path = db_path,
        worker_count = nworkers(),
        update_frequency_ms = 100,
        speed_window_seconds = 30
    )
    
    println()
    println("Starting distributed computation...")
    println("To view dashboard, run: mpm $db_path")
    println()
    
    # Start worker listener task on master
    worker_task = MultiProgressManagers.create_worker_task(manager)
    
    # Distribute work using @distributed
    println("Processing...")
    
    # Track which tasks are assigned to which workers
    task_counter = Threads.Atomic{Int}(0)
    
    results = @distributed (vcat) for i in 1:total_tasks
        # Do the work
        result = distributed_dummy_task(i)
        
        # Update progress via worker channel
        Threads.atomic_add!(task_counter, 1)
        current = task_counter[]
        
        MultiProgressManagers.worker_update!(
            manager.worker_channel,
            current;
            info = "Worker $(myid()) task $i",
            worker_id = myid()
        )
        
        result
    end
    
    println()
    println("Distributed computation complete!")
    println("Results collected: $(length(results))")
    
    # Signal workers are done
    for w in workers()
        MultiProgressManagers.worker_done!(
            manager.worker_channel,
            "Worker $w completed";
            worker_id = w
        )
    end
    
    # Wait for worker task to finish
    sleep(1)  # Give time for final updates
    close(manager.worker_channel)
    
    # Finish the experiment
    finish!(manager; message = "Distributed processing complete: $(length(results)) results")
    
    # Show some statistics
    worker_stats = Dict{Int, Int}()
    for r in results
        worker_stats[r.worker] = get(worker_stats, r.worker, 0) + 1
    end
    
    println()
    println("Worker distribution:")
    for (worker, count) in sort(collect(worker_stats))
        println("  Worker $worker: $count tasks")
    end
    
    println()
    println("="^60)
    println("View dashboard with: mpm $db_path")
    println("="^60)
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
