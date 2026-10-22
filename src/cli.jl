module CLI

using ..MultiProgressManagers: view_dashboard

include("cli_query.jl")

function _help_text()
    return """
    mpm - MultiProgressManagers

    Usage:
      mpm list <folder> [--status STATUS] [--json]
                             List experiments in a folder of .db files
      mpm show <folder> <exp> [--json]
                             Show one experiment and its tasks
      mpm tasks <folder> <exp> [--status STATUS] [--json]
                             List tasks for one experiment
      mpm <folder>           Open the interactive Tachikoma dashboard
      mpm .                  Dashboard for the current directory
      mpm --help             Show this help message
      mpm help [cmd]         Show help (query commands: list, show, tasks)

    Experiment lookup (<exp>): UUID, unique UUID prefix (≥4 chars), or unique name.

    Examples:
      mpm list ./progresslogs
      mpm list ./progresslogs --status running --json
      mpm show ./progresslogs train_sweep
      mpm tasks ./progresslogs train_sweep --status failed
      mpm ./progresslogs

    Keyboard Shortcuts (in dashboard):
      [1-2]     Switch tabs (Runs, Details)
      [↑↓]      Navigate lists
      [Enter]   Select / Open
      [r]       Refresh experiment list
      [q]       Quit
    """
end

function _resolve_dashboard_path(path::String)
    resolved = path == "." ? abspath(".") : abspath(path)

    if isfile(resolved)
        return dirname(resolved)
    end

    if isdir(resolved)
        return resolved
    end

    println("Error: Path not found: $path")
    return nothing
end

function print_help(io::IO = stdout)
    println(io, _help_text())
    return nothing
end

function main(args::Vector{String} = String.(ARGS); out_io::IO = stdout, err_io::IO = stderr)
    if isempty(args) || args[1] in ("-h", "--help")
        print_help(out_io)
        return 0
    end

    if args[1] == "help"
        if length(args) >= 2 && args[2] in _QUERY_COMMANDS
            cmd_help(out_io)
            return 0
        end
        print_help(out_io)
        return 0
    end

    if args[1] in _QUERY_COMMANDS
        return dispatch(args[1], args[2:end]; out_io = out_io, err_io = err_io)
    end

    resolved_path = _resolve_dashboard_path(args[1])
    if resolved_path === nothing
        return 1
    end

    try
        println(out_io, "Loading dashboard for: $resolved_path")
        println(out_io, "Press 'q' to quit, '1-2' for tabs")
        view_dashboard(resolved_path)
        return 0
    catch err
        if err isa InterruptException
            println(out_io, "\nInterrupted.")
            return 0
        end
        println(err_io, "Error: $err")
        return 1
    end
end

function (@main)(ARGS)
    return main(String.(ARGS))
end

end
