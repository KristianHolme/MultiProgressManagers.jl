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
    db_path = unique_db_path("./progresslogs/basic.db")
    manager = ProgressManager("Basic Example", 5; db_path = db_path)

    for task_num in 1:5
        total_steps = 100
        for step in 1:total_steps
            sleep(0.01)
            update!(manager, task_num; step = step, total_steps = total_steps)
        end
        finish!(manager, task_num)
    end

    finish!(manager)
    return println("Done! View with: view_dashboard(\"$db_path\")")
end

main()
