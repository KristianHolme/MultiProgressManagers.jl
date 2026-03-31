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

function main()
    db_path = unique_db_path("./progresslogs/simple_monitor.db")
    manager = ProgressManager(
        "Simple Monitor",
        5;
        db_path = db_path,
        task_descriptions = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"],
    )

    println("Running 5 tasks...")
    for task_num in 1:5
        total_steps = 50
        for step in 1:total_steps
            sleep(0.01)
            update!(manager, task_num; step = step, total_steps = total_steps)
        end
        finish!(manager, task_num)
        println("  Task $task_num complete")
    end

    finish!(manager)
    println()
    return println("Done! View with: mpm $(dirname(db_path))")
end

main()
