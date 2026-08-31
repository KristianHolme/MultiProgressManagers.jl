# AirspeedVelocity.jl suite for MultiProgressManagers.
#
# `local_spin` matches the throughput investigation: `Threads.@spawn` callers,
# a 3 ms busy-spin per step, and an `mpm` vs `baseline` (no ProgressManager)
# trial at each caller count.
#
# `ultrafast` is the same progress-reporting loop with a single caller and no
# spin, so it measures `update!` / listener overhead instead of compute.
#
# `remote_spin` is the Distributed analog of `local_spin`: real `addprocs`
# workers, the same 3 ms busy-spin × 100 steps, and `mpm` vs `baseline`.
# Caller counts stay small (`1` and `4`) so the suite still fits 2-CPU CI
# runners. Workers are started once and reused; they are not removed during
# the suite.
#
# `remote_ultrafast` is one Distributed worker running the no-spin loop, so it
# measures remote `update!` / IPC / listener overhead rather than an in-process
# `RemoteChannel`.
#
# Worker step code lives in `BenchSteps.jl`, loaded into `Main` here and on
# each `addprocs` worker via `@everywhere` (Julia manual, "Code Availability
# and Loading Packages"). AirspeedVelocity includes this file into
# `Main.AirspeedVelocityRunner`; `remotecall` looks up functions by module, so
# the worker methods cannot be the ones defined in that wrapper.
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
const REMOTE_SPIN_CALLERS = (1, 4)
const ULTRAFAST_STEPS = 10_000

const _BENCH_STEPS_PATH = joinpath(@__DIR__, "BenchSteps.jl")
const _BENCH_STEPS_SRC = read(_BENCH_STEPS_PATH, String)
const _REMOTE_BENCH_READY_NPROCS = Ref(0)

if !isdefined(Main, :BenchSteps)
    include_string(Main, _BENCH_STEPS_SRC, _BENCH_STEPS_PATH)
end

using Main.BenchSteps: run_steps!

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

function _worker_exeflags()
    project = Base.active_project()
    if project === nothing
        return ``
    end
    return `--project=$(project)`
end

function _load_bench_steps!(pids::AbstractVector{Int})
    src = _BENCH_STEPS_SRC
    file = _BENCH_STEPS_PATH
    remote_pids = filter(pid -> pid != myid(), collect(Int, pids))
    if isempty(remote_pids)
        return nothing
    end
    # `@everywhere` evaluates under `Main` on the given workers. Interpolate
    # `$src` / `$file` so the source is sent with the expression (same pattern
    # as `include_string` in the Julia distributed-computing manual).
    # Do not put `using` in this block: `@everywhere` lifts imports to a
    # `toplevel` expression, which is illegal inside a function.
    @everywhere remote_pids include_string(Main, $src, $file)
    return nothing
end

function ensure_remote_workers!(n::Int)
    extra = nprocs() - 1
    if extra < n
        added = addprocs(n - extra; exeflags = _worker_exeflags())
        _load_bench_steps!(added)
        _REMOTE_BENCH_READY_NPROCS[] = nprocs()
    elseif _REMOTE_BENCH_READY_NPROCS[] < nprocs()
        _load_bench_steps!(workers())
        _REMOTE_BENCH_READY_NPROCS[] = nprocs()
    end
    pids = workers()
    if length(pids) < n
        error("need $n extra Distributed workers, have $(length(pids))")
    end
    return pids[1:n]
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

function setup_remote_experiment(n_callers::Int)
    pids = ensure_remote_workers!(n_callers)
    state = setup_experiment(n_callers; task_type = :remote)
    return merge(state, (; pids))
end

function setup_remote_workers_only(n_callers::Int)
    pids = ensure_remote_workers!(n_callers)
    return (; pids)
end

function run_remote_callers!(
        pids::Vector{Int},
        n_steps::Int,
        spin_ns::UInt64,
        tasks::Vector,
    )
    @sync for (i, pid) in enumerate(pids)
        task = tasks[i]
        @async remotecall_wait(run_steps!, pid, n_steps, spin_ns, task)
    end
    return nothing
end

function run_remote_callers!(
        pids::Vector{Int},
        n_steps::Int,
        spin_ns::UInt64,
        ::Nothing,
    )
    @sync for pid in pids
        @async remotecall_wait(run_steps!, pid, n_steps, spin_ns, nothing)
    end
    return nothing
end

function run_remote_ultrafast_mpm!(state)
    remotecall_wait(
        run_steps!,
        only(state.pids),
        ULTRAFAST_STEPS,
        zero(UInt64),
        only(state.tasks),
    )
    wait_for_listener(state.manager)
    return nothing
end

function run_remote_ultrafast_baseline!(state)
    remotecall_wait(
        run_steps!,
        only(state.pids),
        ULTRAFAST_STEPS,
        zero(UInt64),
        nothing,
    )
    return nothing
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
    suite["remote_spin"] = BenchmarkGroup()
    suite["remote_ultrafast"] = BenchmarkGroup()

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

    for n_callers in REMOTE_SPIN_CALLERS
        group = BenchmarkGroup()
        group["mpm"] = @benchmarkable(
            run_remote_callers!(state.pids, $SPIN_STEPS, $SPIN_NS, state.tasks),
            setup = (state = setup_remote_experiment($n_callers)),
            teardown = (teardown_experiment(state)),
            evals = 1,
            samples = 3,
            seconds = 60
        )
        group["baseline"] = @benchmarkable(
            run_remote_callers!(state.pids, $SPIN_STEPS, $SPIN_NS, nothing),
            setup = (state = setup_remote_workers_only($n_callers)),
            evals = 1,
            samples = 3,
            seconds = 60
        )
        suite["remote_spin"][n_callers] = group
    end

    suite["remote_ultrafast"]["mpm"] = @benchmarkable(
        run_remote_ultrafast_mpm!(state),
        setup = (state = setup_remote_experiment(1)),
        teardown = (teardown_experiment(state)),
        evals = 1,
        samples = 5,
        seconds = 30
    )
    suite["remote_ultrafast"]["baseline"] = @benchmarkable(
        run_remote_ultrafast_baseline!(state),
        setup = (state = setup_remote_workers_only(1)),
        evals = 1,
        samples = 5,
        seconds = 30
    )

    return suite
end

const SUITE = create_benchmark()
