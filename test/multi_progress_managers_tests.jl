@testsnippet CommonImports begin
    using Distributed
    using ProgressMeter
    using Base: devnull
    new_manager(n) = MultiProgressManager(n, devnull)
end

@testsnippet CallbackSetup begin
    using DRiL
    const DRiLExt = Base.get_extension(MultiProgressManagers, :MultiProgressManagersDRiLExt)
    struct _Env
        n_envs::Int
    end
    DRiL.number_of_envs(env::_Env) = env.n_envs
end

@testitem "create_dril_callback without DRiL loaded" setup = [CommonImports] begin
    # This needs to be first, otherwise the DRiL extension will be loaded!?
    manager = new_manager(1)
    @test_throws ErrorException create_dril_callback(manager.worker_channel)
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "create_dril_callback with DRiL loaded" setup = [CommonImports, CallbackSetup] begin
    manager = new_manager(1)
    callback = create_dril_callback(manager.worker_channel)
    @test callback isa DRiLExt.DRiLWorkerProgressCallback
    @test callback.worker_channel === manager.worker_channel
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Constructor defaults" setup = [CommonImports] begin
    manager = MultiProgressManager(5)
    @test manager.main_meter.n == 5
    @test manager.main_meter.counter == 0
    @test isempty(manager.worker_meters)
    @test manager.main_channel isa RemoteChannel
    @test manager.worker_channel isa RemoteChannel
    @test isopen(manager.main_channel)
    @test isopen(manager.worker_channel)
    expected = Dict(worker_id => findfirst(==(worker_id), workers()) for worker_id in workers())
    @test manager.worker2index == expected
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Constructor with io" setup = [CommonImports] begin
    io = IOBuffer()
    manager = MultiProgressManager(3, io)
    @test manager.main_meter.output === io
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Constructor with tty" setup = [CommonImports] begin
    mktemp() do path, _
        ty = open(path, "w")
        try
            ioctx = IOContext(ty, :color => true)
            manager = MultiProgressManager(2, ioctx)
            @test manager.main_meter.output === ioctx
            close(manager.main_channel)
            close(manager.worker_channel)
        finally
            close(ty)
        end
    end
end

@testitem "Constructor with main_desc" setup = [CommonImports] begin
    mktemp() do path, _
        ty = open(path, "w")
        try
            ioctx = IOContext(ty, :color => true)
            manager = MultiProgressManager(2, ioctx, main_desc = "experiment 1")
            @test manager.main_meter.desc == "experiment 1"
            close(manager.main_channel)
            close(manager.worker_channel)
        finally
            close(ty)
        end
    end
end
@testitem "Worker index expansion" setup = [CommonImports] begin
    manager = new_manager(2)
    msg = ProgressStart(9999, 10, "Worker 9999")
    update_progress!(manager, msg)
    @test haskey(manager.worker2index, 9999)
    @test haskey(manager.worker_meters, 9999)
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Progress update within bounds" setup = [CommonImports] begin
    manager = new_manager(1)
    update_progress!(manager, ProgressStart(9999, 5, "Worker"))
    update_progress!(manager, ProgressStepUpdate(9999, 2, "info"))
    meter = manager.worker_meters[9999]
    @test meter.counter == 2
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "get_task returns ProgressTask" setup = [CommonImports] begin
    manager = new_manager(1)
    task = get_task(manager, 7, :remote)
    @test task isa ProgressTask
    @test task.task_number == 7
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Unified update! with manager and task number" setup = [CommonImports] begin
    manager = new_manager(2)
    update!(manager, 7; step = 0, total_steps = 5, message = "starting")
    update!(manager, 7; step = 3, total_steps = 5, message = "midway")

    status = get_worker_status(manager, 7)
    @test status.exists == true
    @test status.counter == 3
    @test status.total == 5
    @test manager.main_meter.counter == 0

    finish!(manager, 7; message = "done")
    @test manager.main_meter.counter == 1
    @test manager.task_states[7] == :finished

    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Unified update! auto-finishes completed task" setup = [CommonImports] begin
    manager = new_manager(1)
    update!(manager, 1; step = 4, total_steps = 4, message = "done")
    @test manager.main_meter.counter == 1
    @test manager.task_states[1] == :finished
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Unified update! with ProgressTask" setup = [CommonImports] begin
    manager = new_manager(1)
    t_main = create_main_meter_tasks(manager)
    t_worker = create_worker_meter_task(manager)
    task = get_task(manager, 11, :local)

    update!(task; step = 1, total_steps = 3, message = "one")
    update!(task; step = 3, total_steps = 3, message = "done")
    sleep(0.2)

    status = get_worker_status(manager, 11)
    @test status.exists == true
    @test status.counter == 3
    @test manager.main_meter.counter == 1
    @test manager.task_states[11] == :finished

    stop!(manager, t_main..., t_worker)
end

@testitem "Unified finish! with ProgressTask and manager" setup = [CommonImports] begin
    manager = new_manager(3)
    t_main = create_main_meter_tasks(manager)
    t_worker = create_worker_meter_task(manager)
    task = get_task(manager, 2)

    finish!(task; message = "done")
    sleep(0.2)
    @test manager.main_meter.counter == 1
    @test manager.task_states[2] == :finished

    finish!(manager; message = "all done")
    @test is_complete(manager)

    stop!(manager, t_main..., t_worker)
end

@testitem "Unified fail! with manager and task number" setup = [CommonImports] begin
    manager = new_manager(2)
    update!(manager, 3; step = 1, total_steps = 4, message = "running")
    fail!(manager, 3; message = "boom")
    @test manager.main_meter.counter == 1
    @test manager.task_states[3] == :failed
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Unified fail! with ProgressTask and manager" setup = [CommonImports] begin
    manager = new_manager(2)
    t_main = create_main_meter_tasks(manager)
    t_worker = create_worker_meter_task(manager)
    task = get_task(manager, 5, :remote)

    update!(task; step = 1, total_steps = 4, message = "running")
    fail!(task; message = "boom")
    sleep(0.2)
    @test manager.main_meter.counter == 1
    @test manager.task_states[5] == :failed

    fail!(manager; message = "manager failed")
    @test is_complete(manager)

    stop!(manager, t_main..., t_worker)
end

@testitem "Deprecated wrappers delegate to unified API" setup = [CommonImports] begin
    manager = new_manager(1)
    t_main = create_main_meter_tasks(manager)
    t_worker = create_worker_meter_task(manager)
    task = get_task(manager, 1)

    redirect_stderr(devnull) do
        report_progress!(task, 1; total_steps = 2, message = "one")
    end
    sleep(0.2)
    @test get_worker_status(manager, 1).counter == 1

    redirect_stderr(devnull) do
        finish_task!(manager, 1; message = "done")
    end
    @test manager.main_meter.counter == 1
    stop!(manager, t_main..., t_worker)

    manager2 = new_manager(1)
    redirect_stderr(devnull) do
        finish_experiment!(manager2; message = "done")
    end
    @test is_complete(manager2)
    close(manager2.main_channel)
    close(manager2.worker_channel)

    manager3 = new_manager(1)
    redirect_stderr(devnull) do
        fail_task!(manager3, 1, "boom")
    end
    @test manager3.main_meter.counter == 1
    close(manager3.main_channel)
    close(manager3.worker_channel)
end

@testitem "Progress step overflow clamp" setup = [CommonImports] begin
    manager = new_manager(1)
    update_progress!(manager, ProgressStart(1, 3, "Worker"))
    update_progress!(manager, ProgressStepUpdate(1, 5, "info"))
    meter = manager.worker_meters[1]
    @test meter.counter == meter.n
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Zero step handling" setup = [CommonImports] begin
    manager = new_manager(1)
    update_progress!(manager, ProgressStart(1, 3, "Worker"))
    update_progress!(manager, ProgressStepUpdate(1, 0, "info"))
    meter = manager.worker_meters[1]
    @test meter.counter == 0
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Negative step handling" setup = [CommonImports] begin
    manager = new_manager(1)
    update_progress!(manager, ProgressStart(1, 3, "Worker"))
    update_progress!(manager, ProgressStepUpdate(1, -1, "info"))
    meter = manager.worker_meters[1]
    @test meter.counter == 0
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Missing worker meter" setup = [CommonImports] begin
    manager = new_manager(1)
    update_progress!(manager, ProgressStepUpdate(1, 1, "info"))
    @test isempty(manager.worker_meters)
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "ProgressStop behavior" setup = [CommonImports] begin
    manager = new_manager(1)
    update_progress!(manager, ProgressStart(1, 3, "Worker"))
    update_progress!(manager, ProgressStop())
    @test !isopen(manager.worker_channel)
    close(manager.main_channel)
end

@testitem "Main channel closure" setup = [CommonImports] begin
    manager = new_manager(1)
    t_periodic, t_update = create_main_meter_tasks(manager)
    close(manager.main_channel)
    wait(t_periodic)
    wait(t_update)
    close(manager.worker_channel)
end

@testitem "Worker channel premature closure" setup = [CommonImports] begin
    manager = new_manager(1)
    t_worker = create_worker_meter_task(manager)
    close(manager.worker_channel)
    wait(t_worker)
    close(manager.main_channel)
end

@testitem "Stop cleanup" setup = [CommonImports] begin
    manager = new_manager(1)
    tasks = Tuple(create_main_meter_tasks(manager))
    stop!(manager, tasks...)
    @test !isopen(manager.main_channel)
    @test !isopen(manager.worker_channel)
end

@testitem "Callback start message" setup = [CommonImports, CallbackSetup] begin
    worker_channel = RemoteChannel(() -> Channel{ProgressMessage}(10), 1)
    callback = DRiLExt.DRiLWorkerProgressCallback(worker_channel)
    env = _Env(4)
    locals = Dict(:total_steps => 8, :env => env)
    DRiL.on_training_start(callback, locals)
    msg = take!(worker_channel)
    @test msg isa ProgressStart
    @test msg.total_steps == 8
    @test msg.desc == "Worker $(Distributed.myid())"
end

@testitem "Callback step message" setup = [CommonImports, CallbackSetup] begin
    worker_channel = RemoteChannel(() -> Channel{ProgressMessage}(10), 1)
    callback = DRiLExt.DRiLWorkerProgressCallback(worker_channel)
    env = _Env(4)
    locals = Dict(:env => env)
    DRiL.on_step(callback, locals)
    msg = take!(worker_channel)
    @test msg isa ProgressStepUpdate
    @test msg.step == 4
    @test msg.info == ""
end

@testitem "Channel capacity stress" setup = [CommonImports] begin
    manager = new_manager(1)
    t_worker = create_worker_meter_task(manager)
    update_progress!(manager, ProgressStart(1, 1000, "Worker"))
    for _ in 1:100
        put!(manager.worker_channel, ProgressStepUpdate(1, 1, ""))
    end
    sleep(0.1)
    close(manager.worker_channel)
    wait(t_worker)
    close(manager.main_channel)
end

@testitem "Full lifecycle" setup = [CommonImports] begin
    manager = new_manager(3)
    t_main = create_main_meter_tasks(manager)
    t_worker = create_worker_meter_task(manager)
    update_progress!(manager, ProgressStart(1, 5, "Worker"))
    for _ in 1:4
        put!(manager.worker_channel, ProgressStepUpdate(1, 1, ""))
    end
    put!(manager.main_channel, true)
    stop!(manager, t_main..., t_worker)
    @test !isopen(manager.main_channel)
    @test !isopen(manager.worker_channel)
end

@testitem "Iteration string" setup = [CommonImports] begin
    manager = new_manager(1)
    progress = Progress(5)
    @test MultiProgressManagers.iteration_string(0, progress) == "0 / 5"
    progress.counter = 2
    @test MultiProgressManagers.iteration_string(1, progress) == "3 / 5"
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "ProgressStart reset behavior" setup = [CommonImports] begin
    manager = new_manager(1)
    update_progress!(manager, ProgressStart(1, 5, "Worker"))
    first_progress = manager.worker_meters[1]
    update_progress!(manager, ProgressStart(1, 10, "Worker"))
    second_progress = manager.worker_meters[1]
    @test second_progress !== first_progress
    @test second_progress.n == 10
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "n_jobs validation" setup = [CommonImports] begin
    @test_throws ArgumentError MultiProgressManager(0)
    @test_throws ArgumentError MultiProgressManager(-1)
    @test_throws ArgumentError MultiProgressManager(-10)
    # Positive values should work
    manager = new_manager(1)
    @test manager.main_meter.n == 1
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "is_complete returns false initially" setup = [CommonImports] begin
    manager = new_manager(5)
    @test !is_complete(manager)
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "is_complete returns true when all jobs done" setup = [CommonImports] begin
    manager = new_manager(3)
    manager.main_meter.counter = 3
    @test is_complete(manager)
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "is_complete with partial progress" setup = [CommonImports] begin
    manager = new_manager(10)
    manager.main_meter.counter = 5
    @test !is_complete(manager)
    manager.main_meter.counter = 10
    @test is_complete(manager)
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "get_progress returns fraction" setup = [CommonImports] begin
    manager = new_manager(10)
    @test get_progress(manager) == 0.0
    manager.main_meter.counter = 5
    @test get_progress(manager) == 0.5
    manager.main_meter.counter = 10
    @test get_progress(manager) == 1.0
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "get_worker_status non-existent worker" setup = [CommonImports] begin
    manager = new_manager(1)
    status = get_worker_status(manager, 999)
    @test status.exists == false
    @test status.counter === nothing
    @test status.total === nothing
    @test status.progress === nothing
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "get_worker_status existing worker" setup = [CommonImports] begin
    manager = new_manager(1)
    update_progress!(manager, ProgressStart(1, 10, "Worker"))
    status = get_worker_status(manager, 1)
    @test status.exists == true
    @test status.counter == 0
    @test status.total == 10
    @test status.progress == 0.0

    update_progress!(manager, ProgressStepUpdate(1, 5, ""))
    status = get_worker_status(manager, 1)
    @test status.counter == 5
    @test status.progress == 0.5

    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "create_dril_callback integration" setup = [CommonImports, CallbackSetup] begin
    manager = new_manager(1)
    callback = create_dril_callback(manager.worker_channel)

    # Test that callback works with DRiL lifecycle
    env = _Env(4)
    locals_start = Dict(:total_steps => 12, :env => env)
    @test DRiL.on_training_start(callback, locals_start) == true

    # Check that ProgressStart message was sent
    msg = take!(manager.worker_channel)
    @test msg isa ProgressStart
    @test msg.total_steps == 12

    # Test step callback
    locals_step = Dict(:env => env)
    @test DRiL.on_step(callback, locals_step) == true
    msg = take!(manager.worker_channel)
    @test msg isa ProgressStepUpdate
    @test msg.step == 4

    # Test end callback
    @test DRiL.on_training_end(callback, Dict()) == true
    msg = take!(manager.worker_channel)
    @test msg isa ProgressFinished

    close(manager.main_channel)
    close(manager.worker_channel)
end
