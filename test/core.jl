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

@testset "ProgressManager constructor" begin
    test_db = tempname() * ".db"
    manager = MPM.ProgressManager("CoreTest", 3; db_path = test_db)
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

@testset "Default experiment DB path requires a unique experiment name" begin
    temp_root = mktempdir()
    try
        cd(temp_root) do
            mkpath("progresslogs")

            manager = MPM.ProgressManager("Duplicate Name", 1)
            try
                @test manager.db_path == joinpath("./progresslogs", "duplicate_name.db")
                @test isfile(manager.db_path)
                MPM.update!(manager, 1, 3; total_steps = 5, message = "resume progress")
                Database.close_db!(manager.db_handle)

                duplicate_error = try
                    MPM.ProgressManager("Duplicate Name", 1)
                    ""
                catch err
                    sprint(showerror, err)
                end
                @test occursin("Each experiment must use its own DB file", duplicate_error)

                resumed_manager = MPM.ProgressManager("Duplicate Name", 1; db_path = manager.db_path)
                try
                    @test resumed_manager.db_path == manager.db_path
                    @test resumed_manager.experiment_id == manager.experiment_id
                    @test resumed_manager.start_time == manager.start_time
                    @test resumed_manager.task_status[1].current_step == 3
                    @test resumed_manager.task_status[1].total_steps == 5
                finally
                    Database.close_db!(resumed_manager.db_handle)
                end
            finally
                Database.close_db!(manager.db_handle)
            end
        end
    finally
        rm(temp_root; force = true, recursive = true)
    end
end

@testset "Each database file can only contain one experiment" begin
    test_db = tempname() * ".db"
    manager = MPM.ProgressManager("FirstExperiment", 1; db_path = test_db)
    try
        Database.close_db!(manager.db_handle)
        resumed_manager = MPM.ProgressManager("FirstExperiment", 1; db_path = test_db)
        try
            @test resumed_manager.experiment_id == manager.experiment_id
        finally
            Database.close_db!(resumed_manager.db_handle)
        end

        @test_throws Exception MPM.ProgressManager("SecondExperiment", 1; db_path = test_db)
        @test_throws Exception MPM.ProgressManager("FirstExperiment", 2; db_path = test_db)
    finally
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end

@testset "Dashboard: mock inputs and headless rendering" begin
    test_db = tempname() * ".db"
    manager = MPM.ProgressManager("DashMock", 3; db_path = test_db)
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
        @test dashboard.runs_selected == 1
        @test dashboard.selected_experiment_id == selected_id

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

@testset "Folder dashboards aggregate all database files" begin
    folder = mktempdir()
    db_one = joinpath(folder, "alpha.db")
    db_two = joinpath(folder, "beta.db")

    manager_one = MPM.ProgressManager("FolderAlpha", 2; db_path = db_one)
    sleep(0.02)
    manager_two = MPM.ProgressManager("FolderBeta", 2; db_path = db_two)

    try
        MPM.update!(manager_one, 1, 1; total_steps = 3, message = "first-db message")
        MPM.update!(manager_two, 1, 2; total_steps = 4, message = "second-db message")

        dashboard = MPM.ProgressDashboard(
            db_path = folder,
            db_handles = Dict(
                db_one => manager_one.db_handle,
                db_two => manager_two.db_handle,
            ),
            folder_mode = true,
            folder_path = folder,
            available_dbs = [db_one, db_two],
            poll_frequency_ms = 0,
        )
        MPM._poll_database!(dashboard)

        @test length(dashboard.admin_experiments) == 2
        @test length(dashboard.running_experiments) == 2
        @test sort!(getfield.(dashboard.admin_experiments, :source_db_path)) == sort!([db_one, db_two])
        @test MPM.CLI._resolve_dashboard_path(folder) == folder
        @test dashboard.runs_selected == 1
        @test dashboard.selected_experiment_id == manager_two.experiment_id

        dashboard.active_tab = 2
        dashboard.selected_experiment_id = manager_two.experiment_id

        backend = TK.TestBackend(130, 36)
        frame = _frame_for_backend(backend)
        TK.view(dashboard, frame)

        @test _buffer_contains(backend, "Tasks for FolderBeta")
        @test _buffer_contains(backend, "second-db message")
    finally
        Database.close_db!(manager_one.db_handle)
        Database.close_db!(manager_two.db_handle)
        rm(db_one, force = true)
        rm(db_two, force = true)
        rm(folder; force = true, recursive = true)
    end
end

@testset "Stress: rapid multithreaded ProgressTask updates" begin
    test_db = tempname() * ".db"
    total_tasks = max(4, min(16, Base.Threads.nthreads() * 4))
    updates_per_task = 250
    manager = MPM.ProgressManager("StressTest", total_tasks; db_path = test_db)
    local_tasks = [MPM.get_task(manager, task_number, :local) for task_number in 1:total_tasks]
    try
        Base.Threads.@threads for task_number in 1:total_tasks
            task = local_tasks[task_number]
            for step in 1:updates_per_task
                if step == 1
                    MPM.report_progress!(
                        task,
                        step;
                        total_steps = updates_per_task,
                        message = "task $(task_number) step $(step)",
                    )
                else
                    MPM.report_progress!(
                        task,
                        step;
                        message = "task $(task_number) step $(step)",
                    )
                end
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
    manager = MPM.ProgressManager("MessageTest", 2; db_path = test_db)
    try
        MPM.update!(manager, 1, 5; total_steps = 10, message = "Epoch 1")
        MPM.update!(manager, 1, 6; message = "Epoch 2")
        MPM.update!(manager, 2, 3; message = "Warmup")
        MPM.finish_task!(manager, 2)
        tasks = Database.get_experiment_tasks(manager.db_handle, manager.experiment_id)
        row = tasks[1, :]
        @test row.current_step == 6
        @test row.total_steps == 10
        @test hasproperty(row, :display_message)
        @test coalesce(get(row, :display_message, missing), "") == "Epoch 2"
        updated_row = tasks[2, :]
        @test updated_row.current_step == 3
        @test updated_row.total_steps == 3
        @test String(updated_row.status) == "completed"
    finally
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end

@testset "finish_experiment!" begin
    test_db = tempname() * ".db"
    manager = MPM.ProgressManager("FinishTest", 2; db_path = test_db)
    try
        MPM.update!(manager, 1, 4; message = "no declared total")
        MPM.update!(manager, 2, 2; total_steps = 5, message = "known total")
        MPM.finish_experiment!(manager)
        exp = Database.get_experiment(manager.db_handle, manager.experiment_id)
        @test exp !== nothing
        @test String(exp.status) == "completed"
        tasks = Database.get_experiment_tasks(manager.db_handle, manager.experiment_id)
        @test all(t -> String(t.status) == "completed", eachrow(tasks))
        @test tasks[1, :].current_step == 4
        @test tasks[1, :].total_steps == 4
        @test tasks[2, :].current_step == 5
        @test tasks[2, :].total_steps == 5
    finally
        Database.close_db!(manager.db_handle)
        rm(test_db, force = true)
    end
end

@testset "fail_experiment!" begin
    test_db = tempname() * ".db"
    manager = MPM.ProgressManager("FailTest", 1; db_path = test_db)
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
