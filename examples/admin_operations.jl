# Admin Operations Example
#
# This example demonstrates how to use the admin/ops API
# to query and modify experiment data programmatically.

using MultiProgressManagers
using MultiProgressManagers.Database

function dummy_task(x::Int)
    sleep(0.01)
    return x^2
end

function main()
    println("="^60)
    println("Admin Operations Example")
    println("="^60)
    println()
    println("This example shows how to query and modify experiments")
    println("programmatically using the Database module.")
    println()
    
    # Create a database
    db_path = "./progresslogs/admin_example.db"
    
    # Run a few experiments
    println("Creating experiments...")
    
    # Experiment 1: Normal completion
    manager1 = create_progress_manager("Normal Run", 100; db_path=db_path)
    for i in 1:100
        dummy_task(i)
        update!(manager1, i)
    end
    finish!(manager1)
    println("  ✅ Experiment 1: Normal Run (completed)")
    
    # Experiment 2: Intentionally stuck (we'll fix it later)
    exp2_id = create_experiment("Stuck Experiment", 200)
    for i in 1:50
        record_progress!(exp2_id, i, i * 0.01)
    end
    # Don't finish - leave it "running"
    println("  ⚠️  Experiment 2: Stuck Experiment (running, 50/200)")
    
    # Experiment 3: Failed experiment
    manager3 = create_progress_manager("Failed Run", 100; db_path=db_path)
    for i in 1:30
        dummy_task(i)
        update!(manager3, i)
    end
    fail!(manager3, "Simulated error at step 30")
    println("  ❌ Experiment 3: Failed Run (failed at step 30)")
    
    close_db!()
    
    println()
    println("="^60)
    println("Querying Experiment Data")
    println("="^60)
    println()
    
    # Reopen database for queries
    init_db!(db_path)
    
    # Get all experiments
    all_exps = get_all_experiments()
    println("All experiments ($(length(all_exps))):")
    for exp in all_exps
        println("  - $(exp.name): $(exp.status) ($(exp.current_step)/$(exp.total_steps))")
    end
    
    println()
    
    # Get running experiments
    running = get_running_experiments()
    println("Running experiments ($(length(running))):")
    for exp in running
        println("  - $(exp.name): $(exp.current_step)/$(exp.total_steps)")
        
        # Calculate speeds for running experiments
        speeds = calculate_speeds(exp.id; window_seconds=30)
        println("    Speed: $(round(speeds.short_avg_speed, digits=1)) it/s (short)")
    end
    
    println()
    
    # Get completion histogram
    hist = get_completion_histogram(10)
    println("Completion distribution:")
    for (i, count) in enumerate(hist)
        range_start = (i-1) * 10
        range_end = i * 10
        println("  $range_start-$range_end%: $count experiments")
    end
    
    println()
    println("="^60)
    println("Admin Operations")
    println("="^60)
    println()
    
    # Fix the stuck experiment
    if !isempty(running)
        stuck_exp = running[1]
        println("Fixing stuck experiment: $(stuck_exp.name)")
        println("  Current: $(stuck_exp.current_step)/$(stuck_exp.total_steps) steps")
        println("  Status: $(stuck_exp.status)")
        println()
        
        # Mark remaining steps as complete
        println("  1. Marking remaining steps as complete...")
        update_experiment_steps!(stuck_exp.id, stuck_exp.total_steps)
        
        println("  2. Marking experiment as completed...")
        update_experiment_status!(stuck_exp.id, "completed"; 
                                   message="Manually completed via admin ops")
        
        println()
        println("  ✅ Experiment fixed!")
        
        # Verify
        updated = get_experiment(stuck_exp.id)
        println("  Updated: $(updated.current_step)/$(updated.total_steps) - $(updated.status)")
    end
    
    println()
    println("="^60)
    println("Statistics")
    println("="^60)
    println()
    
    stats = get_experiment_stats(days=1)
    println("Experiment statistics (last 24h):")
    println("  Total: $(stats.total)")
    println("  Completed: $(stats.completed)")
    println("  Failed: $(stats.failed)")
    println("  Running: $(stats.running)")
    if stats.avg_duration_seconds !== nothing
        avg_min = round(stats.avg_duration_seconds / 60, digits=1)
        println("  Average duration: $(avg_min) minutes")
    end
    
    close_db!()
    
    println()
    println("="^60)
    println("View dashboard: mpm $db_path")
    println("="^60)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
