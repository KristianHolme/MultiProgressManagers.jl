# Step loop used by local and remote AirspeedVelocity benches.
#
# This file is `include_string`'d into `Main` on the master and on every
# `addprocs` worker. AirspeedVelocity wraps `benchmarks.jl` in
# `Main.AirspeedVelocityRunner`; `remotecall` serializes functions by module
# name, so the worker code has to live in a real top-level module (`Main.BenchSteps`)
# rather than in that wrapper. See "Code Availability and Loading Packages" in
# the Julia distributed-computing manual.

module BenchSteps

using MultiProgressManagers

export run_steps!

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

end # module
