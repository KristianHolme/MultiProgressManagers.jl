using TestItemRunner

@testsnippet NewAPICore begin
    using MultiProgressManagers
    using MultiProgressManagers.Database
    using Dates
    using SQLite
    using DBInterface
end

@testitem "Database Initialization" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    
    # Initialize database
    db = init_db!(test_db)
    @test db isa SQLite.DB
    
    # Verify tables exist
    tables = DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table'") |> DataFrame
    table_names = tables.name
    @test "experiments" in table_names
    @test "progress_snapshots" in table_names
    @test "worker_assignments" in table_names
    
    # Verify views exist
    views = DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='view'") |> DataFrame
    @test "v_daily_experiments" in views.name
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Experiment Creation" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    init_db!(test_db)
    
    # Create experiment
    exp_id = create_experiment("Test Experiment", 1000; 
                               description="Test description",
                               worker_count=4)
    
    @test exp_id isa String
    @test length(exp_id) > 0
    
    # Verify experiment exists
    exp = get_experiment(exp_id)
    @test exp !== nothing
    @test exp.name == "Test Experiment"
    @test exp.description == "Test description"
    @test exp.total_steps == 1000
    @test exp.current_step == 0
    @test exp.status == :running
    @test exp.worker_count == 4
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Progress Recording" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    init_db!(test_db)
    
    exp_id = create_experiment("Progress Test", 500)
    
    # Record progress at various intervals
    record_progress!(exp_id, 50, 2.0)
    record_progress!(exp_id, 100, 5.0)
    record_progress!(exp_id, 150, 8.0)
    
    # Verify experiment updated
    exp = get_experiment(exp_id)
    @test exp.current_step == 150
    
    # Verify history
    history = get_experiment_history(exp_id)
    @test length(history) == 3
    
    # Check delta calculations
    @test history[1].delta_steps == 50  # Most recent
    @test history[end].delta_steps == 50  # First snapshot
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Speed Calculations" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    init_db!(test_db)
    
    exp_id = create_experiment("Speed Test", 1000)
    
    # Record progress with known timing
    record_progress!(exp_id, 100, 10.0)  # 100 steps in 10 seconds = 10 steps/sec
    record_progress!(exp_id, 200, 15.0)  # 100 steps in 5 seconds = 20 steps/sec
    record_progress!(exp_id, 300, 25.0)  # 100 steps in 10 seconds = 10 steps/sec
    
    # Calculate speeds
    speeds = calculate_speeds(exp_id; window_seconds=30)
    
    # Total average should be 300 steps / 25 seconds = 12 steps/sec
    @test speeds.total_avg_speed ≈ 12.0 atol=1.0
    
    # Get recent speeds for sparkline
    sparkline = get_recent_speeds(exp_id; n=10, window_seconds=60)
    @test length(sparkline) == 2  # Two speed measurements (from deltas)
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Experiment Completion" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    init_db!(test_db)
    
    exp_id = create_experiment("Completion Test", 100)
    record_progress!(exp_id, 50, 5.0)
    
    # Finish experiment
    finish_experiment!(exp_id; message="Test completed successfully")
    
    # Verify status
    exp = get_experiment(exp_id)
    @test exp.status == :completed
    @test exp.final_message == "Test completed successfully"
    @test exp.finished_at !== nothing
    @test exp.current_step == 50  # Should preserve last known step
    
    # Verify no longer in running list
    running = get_running_experiments()
    @test length(running) == 0
    
    # Verify in all experiments list
    all_exps = get_all_experiments()
    @test length(all_exps) == 1
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Experiment Failure" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    init_db!(test_db)
    
    exp_id = create_experiment("Failure Test", 100)
    record_progress!(exp_id, 30, 3.0)
    
    # Mark as failed
    fail_experiment!(exp_id, "Out of memory error")
    
    exp = get_experiment(exp_id)
    @test exp.status == :failed
    @test exp.final_message == "Out of memory error"
    @test exp.finished_at !== nothing
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Completion Histogram" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    init_db!(test_db)
    
    # Create experiments at different progress levels
    for i in 1:20
        exp_id = create_experiment("Exp $i", 100)
        step = i * 5  # 5, 10, 15, ..., 100
        record_progress!(exp_id, step, 1.0)
        if step == 100
            finish_experiment!(exp_id)
        end
    end
    
    hist = get_completion_histogram(10)
    @test length(hist) == 10
    @test sum(hist) == 20
    @test hist[1] == 2   # 0-10%: 5, 10
    @test hist[10] == 1 # 90-100%: 100 (completed)
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Statistics" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    init_db!(test_db)
    
    # Create various experiments
    for i in 1:5
        exp_id = create_experiment("Exp $i", 100)
        record_progress!(exp_id, 100, 10.0)
        if i <= 3
            finish_experiment!(exp_id)
        elseif i == 4
            fail_experiment!(exp_id, "Error")
        end
        # Leave one running
    end
    
    stats = get_experiment_stats(days=1)
    @test stats.total == 5
    @test stats.completed == 3
    @test stats.failed == 1
    @test stats.running == 1
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Admin Operations" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    init_db!(test_db)
    
    exp_id = create_experiment("Admin Test", 100)
    record_progress!(exp_id, 50, 5.0)
    
    # Manual status update
    update_experiment_status!(exp_id, "failed"; message="Manual failure")
    
    exp = get_experiment(exp_id)
    @test exp.status == :failed
    @test exp.final_message == "Manual failure"
    @test exp.finished_at !== nothing
    
    # Manual step update
    update_experiment_steps!(exp_id, 75)
    
    exp = get_experiment(exp_id)
    @test exp.current_step == 75
    @test exp.progress_pct == 75.0
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "ProgressManager API" setup = [NewAPICore] begin
    test_db = tempname() * ".db"
    
    # Create manager
    manager = create_progress_manager("API Test", 500;
                                     description="Testing the API",
                                     db_path=test_db,
                                     update_frequency_ms=50,
                                     speed_window_seconds=30)
    
    @test manager isa MultiProgressManagers.ProgressManager
    @test manager.total_steps == 500
    @test manager.experiment_id isa String
    @test manager.db_path == test_db
    
    # Record progress
    update!(manager, 100; info="Step 100")
    update!(manager, 250; info="Step 250")
    
    # Check progress
    @test get_progress(manager) ≈ 0.5
    
    # Get speeds
    speeds = get_speeds(manager)
    @test speeds isa NamedTuple
    @test hasfield(typeof(speeds), :total_avg_speed)
    @test hasfield(typeof(speeds), :short_avg_speed)
    
    # Finish
    finish!(manager; message="API test complete")
    
    # Verify in database
    exp = get_experiment(manager.experiment_id)
    @test exp.status == :completed
    @test exp.final_message == "API test complete"
    
    close_db!()
    rm(test_db, force=true)
end

@testitem "Default DB Path" setup = [NewAPICore] begin
    # Test that default_db_path returns a reasonable path
    path = MultiProgressManagers.default_db_path()
    @test path isa String
    @test endswith(path, ".db")
    
    # If ./progresslogs doesn't exist, should use system cache
    if !isdir("./progresslogs")
        @test occursin("MultiProgressManagers", path)
    end
end

@testitem "Multiple Databases" setup = [NewAPICore] begin
    test_db1 = tempname() * ".db"
    test_db2 = tempname() * ".db"
    
    # Initialize two separate databases
    init_db!(test_db1)
    exp1 = create_experiment("DB1 Experiment", 100)
    
    init_db!(test_db2)
    exp2 = create_experiment("DB2 Experiment", 200)
    
    # Verify isolation
    exps1 = get_all_experiments()
    @test length(exps1) == 1
    @test exps1[1].name == "DB2 Experiment"  # Most recently created in db2
    
    # Switch back to db1
    close_db!()
    init_db!(test_db1)
    
    exps2 = get_all_experiments()
    @test length(exps2) == 1
    @test exps2[1].name == "DB1 Experiment"
    
    close_db!()
    rm(test_db1, force=true)
    rm(test_db2, force=true)
end

@run_package_tests
