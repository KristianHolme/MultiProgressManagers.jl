using Test
using JSON
using MultiProgressManagers
using MultiProgressManagers.Database

const MPM = MultiProgressManagers
const CLI = MPM.CLI

function _cli_capture(args::Vector{String})
    out = IOBuffer()
    err = IOBuffer()
    code = CLI.main(args; out_io = out, err_io = err)
    return code, String(take!(out)), String(take!(err))
end

@testset "CLI list / show / tasks" begin
    folder = mktempdir()
    db_a = joinpath(folder, "alpha.db")
    db_b = joinpath(folder, "beta.db")

    manager_a = MPM.ProgressManager(
        "train_sweep",
        2;
        db_path = db_a,
        description = "sweep over lr",
        task_descriptions = ["lr=1e-3", "lr=1e-4"],
    )
    sleep(0.02)
    manager_b = MPM.ProgressManager("smoke", 1; db_path = db_b)

    try
        MPM.update!(manager_a, 1; step = 8, total_steps = 500, message = "epoch 1")
        MPM.update!(manager_a, 2; step = 500, total_steps = 500, message = "done")
        MPM.finish!(manager_a, 2)
        MPM.update!(manager_b, 1; step = 3, total_steps = 10, message = "ok")
        MPM.finish!(manager_b, 1)
        MPM.finish!(manager_b)

        # list (human)
        code, out, err = _cli_capture(["list", folder])
        @test code == 0
        @test isempty(err)
        @test occursin("train_sweep", out)
        @test occursin("smoke", out)
        @test occursin("8/1000 (0.8%)", out) || occursin("508/1000", out) || occursin("/1000", out)
        @test occursin("STATUS", out)
        @test occursin("PROGRESS", out)

        # list --status
        code, out, err = _cli_capture(["list", folder, "--status", "completed"])
        @test code == 0
        @test occursin("smoke", out)
        @test !occursin("train_sweep", out)

        code, out, err = _cli_capture(["list", folder, "--status", "running"])
        @test code == 0
        @test occursin("train_sweep", out)
        @test !occursin("smoke", out)

        # list --json
        code, out, err = _cli_capture(["list", folder, "--json"])
        @test code == 0
        @test isempty(err)
        data = JSON.parse(out)
        @test data isa Vector
        @test length(data) == 2
        names = Set(String(row["name"]) for row in data)
        @test names == Set(["train_sweep", "smoke"])
        train = only(filter(row -> row["name"] == "train_sweep", data))
        @test train["status"] == "running"
        @test train["current_step"] == 8 + 500
        @test train["total_steps"] == 1000
        @test train["completed_tasks"] == 1
        @test train["total_tasks"] == 2
        @test train["progress_pct"] ≈ 0.508 atol = 1e-9
        @test train["source_db_path"] == db_a
        @test train["started_at"] isa Real

        # show by name
        code, out, err = _cli_capture(["show", folder, "train_sweep"])
        @test code == 0
        @test occursin("Experiment: train_sweep", out)
        @test occursin("8/500 (1.6%)", out)
        @test occursin("500/500 (100.0%)", out)
        @test occursin("epoch 1", out)
        @test occursin("lr=1e-3", out)

        # show by uuid prefix
        prefix = manager_a.experiment_id[1:8]
        code, out, err = _cli_capture(["show", folder, prefix, "--json"])
        @test code == 0
        show_data = JSON.parse(out)
        @test show_data["id"] == manager_a.experiment_id
        @test show_data isa AbstractDict
        @test haskey(show_data, "tasks")
        @test length(show_data["tasks"]) == 2
        @test show_data["tasks"][1]["current_step"] == 8
        @test show_data["tasks"][1]["progress_pct"] ≈ 0.016 atol = 1e-9

        # tasks only + status filter
        code, out, err = _cli_capture(["tasks", folder, "train_sweep", "--status", "failed", "--json"])
        @test code == 0
        tasks_data = JSON.parse(out)
        @test tasks_data isa Vector
        @test isempty(tasks_data)

        code, out, err = _cli_capture(["tasks", folder, "train_sweep", "--status", "running"])
        @test code == 0
        @test occursin("8/500 (1.6%)", out)
        @test !occursin("500/500", out)

        # case-insensitive unique name
        code, out, err = _cli_capture(["show", folder, "TRAIN_SWEEP"])
        @test code == 0
        @test occursin(manager_a.experiment_id, out)

        # not found
        code, out, err = _cli_capture(["show", folder, "missing_exp"])
        @test code == 2
        @test occursin("not found", err)

        # invalid status
        code, out, err = _cli_capture(["list", folder, "--status", "nope"])
        @test code == 2
        @test occursin("Invalid --status", err)

        # missing folder arg
        code, out, err = _cli_capture(["list"])
        @test code == 2
        @test occursin("Missing <folder>", err)

        # path not found
        code, out, err = _cli_capture(["list", joinpath(folder, "does-not-exist")])
        @test code == 2
        @test occursin("Path not found", err)

        # .db file path resolves to parent
        code, out, err = _cli_capture(["list", db_a, "--json"])
        @test code == 0
        @test length(JSON.parse(out)) == 2

        # help
        code, out, err = _cli_capture(["help", "list"])
        @test code == 0
        @test occursin("mpm list", out)
    finally
        Database.close_db!(manager_a.db_handle)
        Database.close_db!(manager_b.db_handle)
        rm(folder; force = true, recursive = true)
    end
end

@testset "CLI skips failed databases with warning" begin
    folder = mktempdir()
    good_db = joinpath(folder, "good.db")
    bad_db = joinpath(folder, "bad.db")
    manager = MPM.ProgressManager("GoodExperiment", 1; db_path = good_db)
    open(bad_db, "w") do io
        write(io, "not a sqlite database")
    end

    try
        MPM.update!(manager, 1; step = 1, total_steps = 3, message = "ok")

        code, out, err = _cli_capture(["list", folder, "--json"])
        @test code == 0
        @test occursin("Warning", err)
        @test occursin("bad.db", err)
        data = JSON.parse(out)
        @test length(data) == 1
        @test data[1]["name"] == "GoodExperiment"
    finally
        Database.close_db!(manager.db_handle)
        rm(folder; force = true, recursive = true)
    end
end

@testset "CLI fails when every database is unreadable" begin
    folder = mktempdir()
    bad_db = joinpath(folder, "broken.db")
    open(bad_db, "w") do io
        write(io, "not a sqlite database")
    end

    try
        code, out, err = _cli_capture(["list", folder])
        @test code == 1
        @test occursin("No usable databases", err)
        @test occursin("Warning", err)
    finally
        rm(folder; force = true, recursive = true)
    end
end

@testset "CLI ambiguous experiment name" begin
    folder = mktempdir()
    db1 = joinpath(folder, "one.db")
    db2 = joinpath(folder, "two.db")
    m1 = MPM.ProgressManager("dup", 1; db_path = db1)
    m2 = MPM.ProgressManager("dup", 1; db_path = db2)

    try
        code, out, err = _cli_capture(["show", folder, "dup"])
        @test code == 2
        @test occursin("Ambiguous", err)
        @test occursin(m1.experiment_id, err)
        @test occursin(m2.experiment_id, err)
    finally
        Database.close_db!(m1.db_handle)
        Database.close_db!(m2.db_handle)
        rm(folder; force = true, recursive = true)
    end
end

@testset "discover_db_files shared helper" begin
    folder = mktempdir()
    try
        touch(joinpath(folder, "a.db"))
        touch(joinpath(folder, "B.DB"))
        touch(joinpath(folder, "skip.txt"))
        found = MPM.discover_db_files(folder)
        @test length(found) == 2
        @test all(endswith(lowercase(p), ".db") for p in found)
        @test issorted(found)
    finally
        rm(folder; force = true, recursive = true)
    end
end
