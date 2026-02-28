# Speed Tracking Example
#
# This example demonstrates how the short-horizon vs total average
# speed tracking works with varying task speeds.

using MultiProgressManagers

# Create tasks with different speeds
function fast_task(x::Int)
    sleep(0.005)  # 5ms - very fast
    return x * 2
end

function medium_task(x::Int)
    sleep(0.02)   # 20ms - medium
    return x * 2
end

function slow_task(x::Int)
    sleep(0.05)   # 50ms - slow
    return x * 2
end

function variable_task(x::Int, phase::Symbol)
    if phase == :fast
        sleep(0.005 + 0.005 * rand())
    elseif phase == :medium
        sleep(0.02 + 0.01 * rand())
    else  # slow
        sleep(0.05 + 0.02 * rand())
    end
    return x * 2
end

function main()
    println("="^60)
    println("Speed Tracking Demonstration")
    println("="^60)
    println()
    println("This example shows how total vs short-horizon speeds differ")
    println("when task speeds change over time.")
    println()
    
    db_path = "./progresslogs/speed_demo.db"
    
    # Create manager with a short window to see speed changes quickly
    manager = create_progress_manager(
        "Speed Demo",
        600;  # 600 tasks total
        description = "Demonstrating speed tracking with variable tasks",
        db_path = db_path,
        update_frequency_ms = 50,
        speed_window_seconds = 5  # 5 second window for responsive changes
    )
    
    println("Phase 1: Fast tasks (200 iterations, ~5ms each)")
    println("Expected: ~200 it/s")
    println()
    
    for i in 1:200
        fast_task(i)
        update!(manager, i)
    end
    
    speeds = get_speeds(manager)
    println("After Phase 1:")
    println("  Total avg: $(round(speeds.total_avg_speed, digits=1)) it/s")
    println("  Short avg: $(round(speeds.short_avg_speed, digits=1)) it/s")
    println()
    sleep(1)
    
    println("Phase 2: Slow tasks (200 iterations, ~50ms each)")
    println("Expected: ~20 it/s (10x slower)")
    println()
    
    for i in 201:400
        slow_task(i)
        update!(manager, i)
    end
    
    speeds = get_speeds(manager)
    println("After Phase 2:")
    println("  Total avg: $(round(speeds.total_avg_speed, digits=1)) it/s " *
            "(average of fast + slow)")
    println("  Short avg: $(round(speeds.short_avg_speed, digits=1)) it/s " *
            "(reflecting current slow speed)")
    println()
    sleep(1)
    
    println("Phase 3: Medium tasks (200 iterations, ~20ms each)")
    println("Expected: ~50 it/s")
    println()
    
    for i in 401:600
        medium_task(i)
        update!(manager, i)
    end
    
    speeds = get_speeds(manager)
    println("After Phase 3:")
    println("  Total avg: $(round(speeds.total_avg_speed, digits=1)) it/s " *
            "(average of all phases)")
    println("  Short avg: $(round(speeds.short_avg_speed, digits=1)) it/s " *
            "(reflecting current medium speed)")
    println()
    
    finish!(manager; message = "Speed demo complete")
    
    println("="^60)
    println("Summary:")
    println("  - Total avg speed: Average over entire experiment")
    println("  - Short avg speed: Average over last 5 seconds (configurable)")
    println()
    println("The short speed is more responsive to recent changes,")
    println("making it better for ETA calculations.")
    println()
    println("View dashboard: mpm $db_path")
    println("="^60)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
