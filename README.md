# MultiProgressManagers.jl

Utilities for coordinating multiple [`ProgressMeter.jl`](https://github.com/timholy/ProgressMeter.jl) progress bars across distributed Julia workers.

The core type, `MultiProgressManager`, owns the shared `Progress` meters and the `RemoteChannel`s that workers use to publish status updates. Helper functions spawn housekeeping tasks that keep the aggregate meters responsive without blocking your workloads.

## Key Concepts

- `MultiProgressManager(n_jobs; io=stderr, tty=nothing)` creates the top-level meter plus per-worker bookkeeping. 
- Workers communicate via `ProgressMessage`s: `ProgressStart`, `ProgressStepUpdate`, `ProgressFinished`, and `ProgressStop`.
- `create_main_meter_task(manager)` returns a pair of housekeeping tasks; `create_worker_meter_task(manager)` returns the listener task that processes worker messages.
- `stop!(manager, tasks...)` closes channels and waits for the spawned tasks to finish cleanly.

## Basic Usage

```julia
using Distributed
@everywhere using MultiProgressManagers

n_jobs = 16
manager = MultiProgressManager(n_jobs)
t_periodic, t_update = create_main_meter_tasks(manager)
t_worker = create_worker_meter_task(manager)

# initialise a worker meter
put!(manager.worker_channel, ProgressStart(Distributed.myid(), 100, "Worker $(Distributed.myid())"))

# report progress from workers
for _ in 1:25
    put!(manager.worker_channel, ProgressStepUpdate(Distributed.myid(), 1, "batch done"))
end

# notify the aggregate meter that a job finished
put!(manager.main_channel, true)

# display a message for a worker process (0 steps)
put!(manager.worker_channel, ProgressStepUpdate(Distributed.myid(), 0,"<useful information>"))

stop!(manager, t_periodic, t_update, t_worker)
```

### Terminal Snapshot

```
Total Progress:  47%|██████████▎           |  ETA: 0:01:53 (14.10  s/it)
   Jobs: 7 / 15
Worker 2 100%|█████████████████████████████| Time: 0:01:13 (11.97 ms/it)
   6144 / 6144: Evaluating...
Worker 3 100%|█████████████████████████████| Time: 0:00:07 ( 1.24 ms/it)
   6144 / 6144: Evaluating...
Worker 4   2%|▌                            |  ETA: 0:00:30 ( 5.42 ms/it)
   96 / 5552:
Worker 5   2%|▌                            |  ETA: 0:01:03 (11.61 ms/it)
   96 / 5552:
Worker 6  31%|█████████                    |  ETA: 0:00:11 ( 2.52 ms/it)
   1904 / 6144:
Worker 7  41%|███████████▊                 |  ETA: 0:01:50 (33.31 ms/it)
   2256 / 5552:
Worker 8  41%|████████████                 |  ETA: 0:01:57 (35.80 ms/it)
   2288 / 5552:
Worker 9   2%|▌                            |  ETA: 0:00:59 (10.84 ms/it)
   96 / 5552:
Worker 10 100%|████████████████████████████| Time: 0:01:10 (11.43 ms/it)
   6144 / 6144: Evaluating...
```


## DRiL Integration

An optional extension (`MultiProgressManagersDRiLExt`) defines `DRiLWorkerProgressCallback`, which plugs into the [`DRiL`](https://github.com/KristianHolme/DRiL.jl) RL training loop. It uses `ProgressStart`, `ProgressStepUpdate`, and `ProgressFinished` messages that mirror the training lifecycle across parallel environments.

Enable the extension by loading DRiL alongside this package, then do something like:

```julia
n_jobs = 42
manager = MultiProgressManager(n_jobs)
t_periodic, t_update = create_main_meter_tasks(manager)
t_worker = create_worker_meter_task(manager)
worker_channel = manager.worker_channel

mgmDRiLExt = Base.get_extension(MultiProgressManagers, MultiProgressManagersDRiLExt)
callback = mgmDRiLExt.DRiLWorkerProgressCallback(worker_channel)
```

