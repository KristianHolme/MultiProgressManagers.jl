using Test
using MultiProgressManagers
using MultiProgressManagers.Database
using DataFrames
using DBInterface

const MPM = MultiProgressManagers
const TK = MPM.Tachikoma

function _wait_for_task_completion(
    manager::MPM.ProgressManager;
    timeout_seconds::Float64 = 10.0,
)
    deadline = time() + timeout_seconds
    while time() < deadline
        tasks = Database.get_experiment_tasks(manager.db_handle, manager.experiment_id)
        all_done = nrow(tasks) == manager.total_tasks &&
            all(row -> String(row.status) == "completed" && row.current_step == row.total_steps, eachrow(tasks))
        if all_done
            return tasks
        end
        sleep(0.01)
    end
    return Database.get_experiment_tasks(manager.db_handle, manager.experiment_id)
end

function _apply_script!(model::MPM.ProgressDashboard, script::TK.EventScript; fps::Int = 60)
    for (_, event) in script(fps)
        TK.update!(model, event)
    end
    return nothing
end

function _frame_for_backend(tb::TK.TestBackend)
    return TK.Frame(
        tb.buf,
        TK.Rect(1, 1, tb.width, tb.height),
        TK.GraphicsRegion[],
        TK.PixelSnapshot[],
    )
end

function _buffer_contains(tb::TK.TestBackend, text::String)
    for y in 1:tb.height
        if occursin(text, TK.row_text(tb, y))
            return true
        end
    end
    return false
end

@testset "Schema: tables and display_message column" begin
    test_db = tempname() * ".db"
    handle = Database.init_db!(test_db)
    try
        db = Database.ensure_open!(handle)
        tables = DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table'") |> DataFrame
        table_names = tables.name
        @test "experiments" in table_names
        @test "tasks" in table_names
        col_info = DBInterface.execute(db, "PRAGMA table_info(tasks)") |> DataFrame
        # Second column is the column name in SQLite PRAGMA table_info
        name_col = Symbol.(DataFrames.names(col_info))[2]
        @test "display_message" in string.(col_info[!, name_col])
    finally
        Database.close_db!(handle)
        rm(test_db, force = true)
    end
end

@testset "Create experiment" begin
    test_db = tempname() * ".db"
    manager = MPM.create_experiment("CoreTest", 3; db_path = test_db)
    try
        @test manager isa MPM.ProgressManager
        @test !isempty(manager.experiment_id)
        tasks = Database.get_experiment_tasks(manager.db_handle, manager.experiment_id)
        @test nrow(tasks) == 3
    finally
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end

@testset "Dashboard: mock inputs and headless rendering" begin
    test_db = tempname() * ".db"
    manager = MPM.create_experiment("DashMock", 3; db_path = test_db)
    try
        MPM.update!(manager, 1, 2; total_steps = 5, message = "epoch 2")
        MPM.update!(manager, 2, 1; total_steps = 3, message = "warmup")

        dashboard = MPM.ProgressDashboard(
            db_path = test_db,
            db_handle = manager.db_handle,
            poll_frequency_ms = 0,
        )
        MPM._poll_database!(dashboard)

        @test length(dashboard.admin_experiments) == 1
        selected_id = ismissing(dashboard.admin_experiments[1].id) ? "" : dashboard.admin_experiments[1].id
        @test !isempty(selected_id)

        dashboard.runs_selected = 1
        dashboard.selected_experiment_id = selected_id

        script = TK.EventScript(
            (0.0, TK.key('2')),
            (0.0, TK.key(:tab)),
            (0.0, TK.key(:down)),
            (0.0, TK.key('1')),
            (0.0, TK.key('f')),
            (0.0, TK.key(:right)),
            (0.0, TK.key(:enter)),
        )
        _apply_script!(dashboard, script)

        @test dashboard.active_tab == 1
        @test dashboard.running_focus == 2
        @test dashboard.task_scroll_offset == 1
        @test dashboard.confirm_mark_failed_id === nothing

        experiment = Database.get_experiment(manager.db_handle, manager.experiment_id)
        @test experiment !== nothing
        @test String(experiment.status) == "failed"

        dashboard.active_tab = 2
        dashboard.running_focus = 1
        dashboard.task_scroll_offset = 0
        MPM._poll_database!(dashboard)
        dashboard.runs_selected = 1
        dashboard.selected_experiment_id = selected_id

        backend = TK.TestBackend(130, 36)
        frame = _frame_for_backend(backend)
        TK.view(dashboard, frame)

        @test _buffer_contains(backend, "Tasks for DashMock")
        @test _buffer_contains(backend, "Message")
        @test _buffer_contains(backend, "epoch 2")
    finally
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end

@testset "Stress: rapid multithreaded ProgressTask updates" begin
    test_db = tempname() * ".db"
    total_tasks = max(4, min(16, Base.Threads.nthreads() * 4))
    updates_per_task = 250
    manager = MPM.create_experiment("StressTest", total_tasks; db_path = test_db)
    local_tasks = [MPM.get_task(manager, task_number, :local) for task_number in 1:total_tasks]
    try
        Base.Threads.@threads for task_number in 1:total_tasks
            task = local_tasks[task_number]
            for step in 1:updates_per_task
                MPM.report_progress!(
                    task,
                    step;
                    total_steps = updates_per_task,
                    message = "task $(task_number) step $(step)",
                )
            end
            MPM.finish!(task)
        end

        completed_tasks = _wait_for_task_completion(manager; timeout_seconds = 15.0)
        @test nrow(completed_tasks) == total_tasks
        @test all(row -> String(row.status) == "completed", eachrow(completed_tasks))
        @test all(row -> row.total_steps == updates_per_task, eachrow(completed_tasks))
        @test all(row -> row.current_step == updates_per_task, eachrow(completed_tasks))
        @test all(
            row -> !ismissing(row.display_message) && occursin("step", String(row.display_message)),
            eachrow(completed_tasks),
        )

        if manager._listener_task !== nothing
            wait(manager._listener_task)
        end

        MPM.finish_experiment!(manager)
        experiment = Database.get_experiment(manager.db_handle, manager.experiment_id)
        @test experiment !== nothing
        @test String(experiment.status) == "completed"
    finally
        if !isempty(local_tasks)
            shared_channel = local_tasks[1].channel
            if shared_channel isa Channel{MPM.ProgressMessage} && isopen(shared_channel)
                close(shared_channel)
            end
        end
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end

@testset "update! and display_message" begin
    test_db = tempname() * ".db"
    manager = MPM.create_experiment("MessageTest", 2; db_path = test_db)
    try
        MPM.update!(manager, 1, 5; total_steps = 10, message = "Epoch 1")
        tasks = Database.get_experiment_tasks(manager.db_handle, manager.experiment_id)
        row = tasks[1, :]
        @test row.current_step == 5
        @test row.total_steps == 10
        @test hasproperty(row, :display_message)
        @test coalesce(get(row, :display_message, missing), "") == "Epoch 1"
    finally
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end

@testset "finish_experiment!" begin
    test_db = tempname() * ".db"
    manager = MPM.create_experiment("FinishTest", 2; db_path = test_db)
    try
        MPM.finish_experiment!(manager)
        exp = Database.get_experiment(manager.db_handle, manager.experiment_id)
        @test exp !== nothing
        @test String(exp.status) == "completed"
        tasks = Database.get_experiment_tasks(manager.db_handle, manager.experiment_id)
        @test all(t -> String(t.status) == "completed", eachrow(tasks))
    finally
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end

@testset "fail_experiment!" begin
    test_db = tempname() * ".db"
    manager = MPM.create_experiment("FailTest", 1; db_path = test_db)
    try
        Database.fail_experiment!(manager.db_handle, manager.experiment_id, "error")
        exp = Database.get_experiment(manager.db_handle, manager.experiment_id)
        @test exp !== nothing
        @test String(exp.status) == "failed"
    finally
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end
