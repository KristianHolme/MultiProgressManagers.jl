module CLI

using ..MultiProgressManagers: view_dashboard

function _help_text()
    return """
        mpm - MultiProgressManager Dashboard

        Usage:
          mpm <database_file.db>     View single experiment database
          mpm <folder_path>          View folder of experiment databases
          mpm .                      View ./progresslogs/ folder (if exists)
          mpm --help                 Show this help message

        Examples:
          mpm ./progresslogs/experiment1.db
          mpm ./progresslogs/
          mpm ~/.local/share/MultiProgressManagers/default.db

        Keyboard Shortcuts (in dashboard):
          [1-2]     Switch tabs (Runs, Details)
          [↑↓]      Navigate lists
          [Enter]   Select / Open
          [q]       Quit
        """
end

function _default_dashboard_path()
    if isdir("./progresslogs")
        return "./progresslogs"
    end
    cache_dir = get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
    default_db = joinpath(cache_dir, "MultiProgressManagers", "default.db")
    if isfile(default_db)
        return default_db
    end
    return nothing
end

function _resolve_dashboard_path(path::String)
    if path == "."
        default_path = _default_dashboard_path()
        if default_path === nothing
            println("Error: No ./progresslogs/ directory found and no default database exists.")
            println("Run an experiment first, or specify a database file path.")
            return nothing
        end
        return default_path
    end

    if isfile(path)
        return path
    end

    if isdir(path)
        db_files = filter(f -> endswith(f, ".db"), readdir(path; join = true))
        if isempty(db_files)
            println("Error: No .db files found in directory: $path")
            return nothing
        end
        return path
    end

    println("Error: Path not found: $path")
    return nothing
end

function print_help(io::IO = stdout)
    println(io, _help_text())
    return nothing
end

function main(args::Vector{String} = String.(ARGS))
    if isempty(args) || args[1] in ("-h", "--help", "help")
        print_help()
        return 0
    end

    resolved_path = _resolve_dashboard_path(args[1])
    if resolved_path === nothing
        return 1
    end

    try
        println("Loading dashboard for: $resolved_path")
        println("Press 'q' to quit, '1-2' for tabs")
        view_dashboard(resolved_path)
        return 0
    catch err
        if err isa InterruptException
            println("\nInterrupted.")
            return 0
        end
        println("Error: $err")
        return 1
    end
end

function (@main)(ARGS)
    return main(String.(ARGS))
end

end
