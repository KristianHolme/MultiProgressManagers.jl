@testsnippet CommonImports begin
    using Distributed
    using ProgressMeter
    using Base: devnull
    new_manager(n) = MultiProgressManager(n; io = devnull)
end

@testsnippet CallbackSetup begin
    using DRiL
    const DRiLExt = Base.get_extension(MultiProgressManagers, :MultiProgressManagersDRiLExt)
    struct _Env
        n_envs::Int
    end
    DRiL.number_of_envs(env::_Env) = env.n_envs
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
    manager = MultiProgressManager(3; io = io)
    @test manager.main_meter.output === io
    close(manager.main_channel)
    close(manager.worker_channel)
end

@testitem "Constructor with tty" setup = [CommonImports] begin
    mktemp() do path, _
        ty = open(path, "w")
        try
            ioctx = IOContext(ty, :color => true)
            manager = MultiProgressManager(2; io = ioctx)
            @test manager.main_meter.output === ioctx
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
    t_periodic, t_update = create_main_meter_task(manager)
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
    tasks = Tuple(create_main_meter_task(manager))
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
    t_main = create_main_meter_task(manager)
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
