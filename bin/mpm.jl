#!/usr/bin/env julia

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using MultiProgressManagers

function main()
    return MultiProgressManagers.CLI.main(String.(ARGS))
end

exit(main())
