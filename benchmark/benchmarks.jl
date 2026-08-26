# AirspeedVelocity.jl suite for MultiProgressManagers.
#
# `local_spin` matches the throughput investigation: `Threads.@spawn` callers,
# a 3 ms busy-spin per step, and an `mpm` vs `baseline` (no ProgressManager)
# trial at each caller count.
#
# `ultrafast` is the same progress-reporting loop with a single caller and no
# spin, so it measures `update!` / listener overhead instead of compute.
#
# `remote_ultrafast` is the `:remote` ProgressTask path (RemoteChannel +
# Distributed extension) with the same no-spin loop.
#
# Run from the package root (needs several threads):
#
#   julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("AirspeedVelocity"); Pkg.build("AirspeedVelocity")'
#   export PATH="$HOME/.julia/bin:$PATH"
#   benchpkg --exeflags="--threads=auto" --rev=master,dirty --bench-on=dirty

using BenchmarkTools
using Distributed
using MultiProgressManagers
using MultiProgressManagers.Database

const SPIN_NS = UInt64(3_000_000)
const SPIN_STEPS = 100
const SPIN_CALLERS = (1, 4, 8, 16, 24)
const ULTRAFAST_STEPS = 10_000

const _SINK = Ref{Int}(0)

@noinline function _sink(step::Int)
    _SINK[] = step
    return nothing
end

function wait_ns(duration_ns::UInt64)
    t0 = time_ns()
    while (time_ns() - t0) < duration_ns
    end
    return nothing
end

function run_steps!(n_steps::Int, spin_ns::UInt64, task::ProgressTask)
    for step in 1:n_steps
        if spin_ns > 0
            wait_ns(spin_ns)
        end
        update!(task; step = step, total_steps = n_steps, message = "step $step")
    end
    finish!(task)
    return nothing
end

function run_steps!(n_steps::Int, spin_ns::UInt64, ::Nothing)
    for step in 1:n_steps
        if spin_ns > 0
            wait_ns(spin_ns)
        end
        _sink(step)
    end
    return nothing
end

function run_ultrafast_mpm!(state)
    run_steps!(ULTRAFAST_STEPS, zero(UInt64), only(state.tasks))
    wait_for_listener(state.manager)
    return nothing
end

function run_local_callers!(
        n_callers::Int,
        n_steps::Int,
        spin_ns::UInt64,
        tasks::Vector,
    )
    handles = Vector{Task}(undef, n_callers)
    for i in 1:n_callers
        task = tasks[i]
        handles[i] = Threads.@spawn run_steps!(n_steps, spin_ns, task)
    end
    for handle in handles
        wait(handle)
    end
    return nothing
end

function run_local_callers!(
        n_callers::Int,
        n_steps::Int,
        spin_ns::UInt64,
        ::Nothing,
    )
    handles = Vector{Task}(undef, n_callers)
    for i in 1:n_callers
        handles[i] = Threads.@spawn run_steps!(n_steps, spin_ns, nothing)
    end
    for handle in handles
        wait(handle)
    end
    return nothing
end

function setup_experiment(n_callers::Int; task_type::Symbol = :local)
    db_path = tempname() * ".db"
    manager = ProgressManager(
        "asv_bench",
        n_callers;
        description = "AirspeedVelocity benchmark",
        db_path = db_path,
    )
    tasks = [get_task(manager, i, task_type) for i in 1:n_callers]
    return (; manager, tasks, db_path)
end

function wait_for_listener(manager::ProgressManager; timeout_seconds::Float64 = 60.0)
    listener = manager._listener_task
    if listener isa Task && !istaskdone(listener)
        timedwait(() -> istaskdone(listener), timeout_seconds)
    end
    return nothing
end

function remove_db(db_path::String)
    rm(db_path; force = true)
    rm(db_path * "-wal"; force = true)
    rm(db_path * "-shm"; force = true)
    return nothing
end

function teardown_experiment(state)
    manager = state.manager
    wait_for_listener(manager)
    finish!(manager)
    Database.close_db!(manager.db_handle)
    remove_db(state.db_path)
    return nothing
end

function create_benchmark()
    suite = BenchmarkGroup()
    suite["local_spin"] = BenchmarkGroup()
    suite["ultrafast"] = BenchmarkGroup()

    for n_callers in SPIN_CALLERS
        group = BenchmarkGroup()
        group["mpm"] = @benchmarkable(
            run_local_callers!($n_callers, $SPIN_STEPS, $SPIN_NS, state.tasks),
            setup = (state = setup_experiment($n_callers)),
            teardown = (teardown_experiment(state)),
            evals = 1,
            samples = 3,
            seconds = 60
        )
        group["baseline"] = @benchmarkable(
            run_local_callers!($n_callers, $SPIN_STEPS, $SPIN_NS, nothing),
            evals = 1,
            samples = 3,
            seconds = 60
        )
        suite["local_spin"][n_callers] = group
    end

    suite["ultrafast"]["mpm"] = @benchmarkable(
        run_ultrafast_mpm!(state),
        setup = (state = setup_experiment(1)),
        teardown = (teardown_experiment(state)),
        evals = 1,
        samples = 5,
        seconds = 30
    )
    suite["ultrafast"]["baseline"] = @benchmarkable(
        run_steps!($ULTRAFAST_STEPS, zero(UInt64), nothing),
        evals = 1,
        samples = 5,
        seconds = 30
    )

    suite["remote_ultrafast"] = BenchmarkGroup()
    suite["remote_ultrafast"]["mpm"] = @benchmarkable(
        run_ultrafast_mpm!(state),
        setup = (state = setup_experiment(1; task_type = :remote)),
        teardown = (teardown_experiment(state)),
        evals = 1,
        samples = 5,
        seconds = 30
    )
    suite["remote_ultrafast"]["baseline"] = @benchmarkable(
        run_steps!($ULTRAFAST_STEPS, zero(UInt64), nothing),
        evals = 1,
        samples = 5,
        seconds = 30
    )

    return suite
end

const SUITE = create_benchmark()
