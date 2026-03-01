using Test
using JET
using MultiProgressManagers

@testset "JET: test_package" begin
    result = test_package(
        MultiProgressManagers;
        target_modules = (MultiProgressManagers,)
    )
    @test result === nothing || result isa Test.Pass
end
