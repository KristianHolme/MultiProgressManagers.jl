# Simple Monitor Example
#
# A minimal demonstration of the multi-task API.
# Creates 5 tasks and tracks their progress with minimal code.

using MultiProgressManagers

# Generate unique database path (appends _2, _3, etc. if file exists)
base_db_path = "./progresslogs/simple_monitor.db"
db_path = base_db_path
counter = 2
while isfile(db_path)
    global db_path = replace(base_db_path, ".db" => "_$counter.db")
    global counter += 1
end

# Create experiment with 5 tasks (task_descriptions appear in dashboard "Desc" column)
manager = ProgressManager(
    "Simple Monitor",
    5;
    db_path = db_path,
    task_descriptions = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"],
)

println("Running 5 tasks...")

# Process each task
for task_num in 1:5
    # Each task has 50 steps
    total_steps = 50
    for step in 1:total_steps
        sleep(0.01)  # Simulate work
        update!(manager, task_num; step = step, total_steps = total_steps)
    end
    finish!(manager, task_num)
    println("  Task $task_num complete")
end

# Finish experiment
finish!(manager)

println()
println("Done! View with: mpm $db_path")
