#!/usr/bin/env julia

"""
mpm - MultiProgressManager CLI

Usage:
  mpm <database_file.db>     View single experiment database
  mpm <folder_path>          View folder of experiment databases
  mpm .                      View ./progresslogs/ folder (if exists)
  mpm --help                 Show this help message

Examples:
  mpm ./progresslogs/experiment1.db
  mpm ./progresslogs/
  mpm ~/.local/share/MultiProgressManagers/default.db
"""

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using MultiProgressManagers
using Tachikoma

function main()
    args = ARGS

    if isempty(args) || args[1] in ("-h", "--help", "help")
        println(
            """
            mpm - MultiProgressManager Dashboard

            Usage:
              mpm <database_file.db>     View single experiment database
              mpm <folder_path>          View folder of experiment databases  
              mpm .                      View ./progresslogs/ folder (if exists)
              
            Examples:
              mpm ./progresslogs/experiment1.db
              mpm ./progresslogs/
              mpm ~/.local/share/MultiProgressManagers/default.db
              
            Keyboard Shortcuts (in dashboard):
              [1-4]     Switch tabs
              [↑↓]      Navigate lists
              [Enter]   Select / Open
              [q]       Quit
              
            Admin Tab:
              [e]       Edit experiment
              [c]       Mark as completed
              [r]       Reset to running
              [d]       Delete experiment
            """
        )
        return 0
    end

    path = args[1]

    # Handle special case: mpm . -> look for ./progresslogs/
    if path == "."
        if isdir("./progresslogs")
            path = "./progresslogs"
        else
            # Try to find default database
            cache_dir = get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
            default_path = joinpath(cache_dir, "MultiProgressManagers", "default.db")
            if isfile(default_path)
                path = default_path
            else
                println(stderr, "Error: No ./progresslogs/ folder found and no default database exists.")
                println(stderr, "Run 'mpm --help' for usage information.")
                return 1
            end
        end
    end

    # Validate path
    if !isfile(path) && !isdir(path)
        println(stderr, "Error: Path not found: $path")
        return 1
    end

    # Check for .db extension if it's a file
    if isfile(path) && !endswith(path, ".db")
        println(stderr, "Warning: File doesn't have .db extension: $path")
    end

    # Launch dashboard
    try
        println("Loading dashboard for: $path")
        println("Press 'q' to quit, '1-4' for tabs")

        view_dashboard(path)

        return 0
    catch e
        if e isa InterruptException
            println("\nInterrupted.")
            return 0
        else
            println(stderr, "Error: $(sprint(showerror, e))")
            return 1
        end
    end
end

main()
