using Test
using MultiProgressManagers
using MultiProgressManagers.Database
using DataFrames
using DBInterface

const MPM = MultiProgressManagers

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
