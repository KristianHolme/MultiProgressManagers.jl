"""
    discover_db_files(folder_path::String) -> Vector{String}

Return sorted absolute paths of `*.db` / `*.DB` files in `folder_path`.
Shared by the Tachikoma dashboard and headless CLI.
"""
function discover_db_files(folder_path::String)
    db_files = filter(readdir(folder_path; join = true)) do file_path
        return endswith(lowercase(file_path), ".db")
    end
    sort!(db_files)
    return db_files
end
