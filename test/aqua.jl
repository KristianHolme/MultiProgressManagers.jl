using Test
using Aqua
using MultiProgressManagers

@testset "Aqua: undefined exports" begin
    Aqua.test_undefined_exports(MultiProgressManagers)
end

@testset "Aqua: stale deps" begin
    Aqua.test_stale_deps(MultiProgressManagers)
end

@testset "Aqua: deps compat" begin
    Aqua.test_deps_compat(MultiProgressManagers)
end

@testset "Aqua: project extras" begin
    Aqua.test_project_extras(MultiProgressManagers)
end
