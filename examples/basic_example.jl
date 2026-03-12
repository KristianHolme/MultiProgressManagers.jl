# Basic Example: Multi-task Progress Tracking
#
# This example demonstrates the new multi-task API.
# It creates one experiment with 5 parallel tasks.

using MultiProgressManagers

# Create experiment with 5 tasks using the new constructor
manager = ProgressManager("Basic Example", 5; db_path = "./progresslogs/basic.db")

# Simulate work for each task
for task_num in 1:5
    total_steps = 100
    for step in 1:total_steps
        sleep(0.01)  # simulate work
        update!(manager, task_num; step = step, total_steps = total_steps)
    end
    finish!(manager, task_num)
end

# Complete the entire experiment
finish!(manager)

println("Done! View with: view_dashboard(\"./progresslogs/basic.db\")")
# Notes:
# - The API uses the new constructor: ProgressManager(name, num_tasks; db_path=...)
# - update!(manager, task_number; step=..., total_steps=...)
# - finish!(manager, task_number)
# - finish!(manager)
# - This example creates 5 tasks, each with 100 steps.
