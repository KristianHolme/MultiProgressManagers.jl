# Multiple Experiments Example
#
# This example creates several experiments to demonstrate the
# folder mode dashboard and experiment selection features.

using MultiProgressManagers

function dummy_work(iteration::Int)
    sleep(0.01 + 0.02 * rand())
    return iteration^2
end

function run_experiment(name::String, total_steps::Int, db_path::String; 
                       fail_at::Union{Int,Nothing}=nothing)
    println("  Starting: $name ($total_steps steps)")
    
    manager = create_progress_manager(
        name,
        total_steps;
        description = "Experiment: $name",
        db_path = db_path,
        update_frequency_ms = 100
    )
    
    for i in 1:total_steps
        dummy_work(i)
        update!(manager, i)
        
        # Simulate failure if requested
        if fail_at !== nothing && i == fail_at
            println("  ⚠️  Simulating failure at step $i")
            fail!(manager, "Simulated failure at step $i")
            return false
        end
    end
    
    finish!(manager; message = "$name completed successfully")
    println("  ✅ Completed: $name")
    return true
end

function main()
    println("="^60)
    println("Multiple Experiments Example")
    println("="^60)
    println()
    println("This example creates several experiments in a folder")
    println("to demonstrate the folder-mode dashboard.")
    println()
    
    # Create a folder for all experiments
    folder_path = "./progresslogs/multi_example"
    mkpath(folder_path)
    
    # Define several experiments
    experiments = [
        ("Quick Task", 100, nothing),
        ("Medium Task", 500, nothing),
        ("Long Task", 1000, nothing),
        ("Failing Task", 300, 150),  # Will fail at step 150
        ("Another Quick", 200, nothing),
    ]
    
    println("Running $(length(experiments)) experiments...")
    println()
    
    results = Bool[]
    
    for (i, (name, steps, fail_point)) in enumerate(experiments)
        db_file = joinpath(folder_path, "exp$(i)_$(lowercase(replace(name, " " => "_"))).db")
        success = run_experiment(name, steps, db_file; fail_at=fail_point)
        push!(results, success)
        println()
    end
    
    println("="^60)
    println("Results:")
    for (i, success) in enumerate(results)
        status = success ? "✅ Completed" : "❌ Failed"
        println("  Experiment $i: $status")
    end
    
    successful = count(results)
    failed = length(results) - successful
    
    println()
    println("Summary:")
    println("  Successful: $successful")
    println("  Failed: $failed")
    println()
    println("View all experiments:")
    println("  mpm $folder_path")
    println()
    println("Or view individual experiments:")
    for i in 1:length(experiments)
        println("  mpm $(joinpath(folder_path, "exp$(i)_*.db"))")
    end
    println("="^60)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
