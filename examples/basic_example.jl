# Basic Example: Single Process Progress Tracking

using MultiProgressManagers

# Create a simple dummy task function
function dummy_task(iteration::Int)
    # Simulate some work with random sleep time
    sleep_time = 0.01 + 0.05 * rand()
    sleep(sleep_time)
    
    # Occasionally simulate variable work
    if rand() < 0.1
        sleep(0.1)  # Extra delay 10% of the time
    end
    
    return iteration^2  # Return some computed value
end

function main()
    println("="^60)
    println("Basic Single-Process Progress Tracking Example")
    println("="^60)
    println()
    
    # Configuration
    total_iterations = 500
    db_path = "./progresslogs/basic_example.db"
    
    # Create progress manager
    println("Creating progress manager...")
    manager = create_progress_manager(
        "Basic Example",
        total_iterations;
        description = "Processing $total_iterations items with dummy tasks",
        db_path = db_path,
        update_frequency_ms = 50,  # Update every 50ms
        speed_window_seconds = 10   # Calculate speed over 10 second window
    )
    
    println()
    println("Starting computation...")
    println("To view dashboard, run: mpm $db_path")
    println()
    
    # Main computation loop
    results = Float64[]
    
    for i in 1:total_iterations
        # Do the work
        result = dummy_task(i)
        push!(results, result)
        
        # Update progress
        update!(manager, i; info = "Processing item $i")
        
        # Print occasional status (in real use, you'd just use the dashboard)
        if i % 100 == 0
            progress = get_progress(manager)
            speeds = get_speeds(manager)
            println("  Progress: $(round(progress * 100, digits=1))% | " *
                    "Speed: $(round(speeds.short_avg_speed, digits=1)) it/s")
        end
    end
    
    # Finish the experiment
    finish!(manager; message = "Successfully processed $total_iterations items")
    
    println()
    println("="^60)
    println("Completed!")
    println("Results computed: $(length(results))")
    println("Average result: $(round(sum(results)/length(results), digits=2))")
    println()
    println("View dashboard with: mpm $db_path")
    println("="^60)
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
