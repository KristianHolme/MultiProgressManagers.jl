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
        println("""
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
              [1-2]     Switch tabs (Runs, Details)
              [↑↓]      Navigate lists
              [Enter]   Select / Open
              [q]       Quit
            """)
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
            default_db = joinpath(cache_dir, "MultiProgressManagers", "default.db")
            if isfile(default_db)
                path = default_db
            else
                println("Error: No ./progresslogs/ directory found and no default database exists.")
                println("Run an experiment first, or specify a database file path.")
                return 1
            end
        end
    end

    # Determine if path is file or folder
    if isfile(path)
        # Single database mode
        db_path = path
    elseif isdir(path)
        # Folder mode - find all .db files
        db_files = filter(f -> endswith(f, ".db"), readdir(path; join=true))
        if isempty(db_files)
            println("Error: No .db files found in directory: $path")
            return 1
        end
        db_path = first(db_files)
        if length(db_files) > 1
            println("Note: Multiple databases found, using: $(basename(db_path))")
        end
    else
        println("Error: Path not found: $path")
        return 1
    end

    # Launch dashboard
    try
        println("Loading dashboard for: $path")
        println("Press 'q' to quit, '1-2' for tabs")

        view_dashboard(db_path)

        return 0
    catch e
        if e isa InterruptException
            println("\nInterrupted.")
            return 0
        else
            println("Error: $e")
            return 1
        end
    end
end

exit(main())
