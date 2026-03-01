# AGENTS.md

## Cursor Cloud specific instructions

This is a Julia package (`MultiProgressManagers.jl`) — no external services, databases, or Docker required.

### Quick reference

| Action | Command |
|---|---|
| Instantiate deps | `julia --project=. -e 'using Pkg; Pkg.instantiate()'` |
| Run tests | `julia --project=. -e 'using Pkg; Pkg.test()'` |
| Load package | `julia --project=. -e 'using MultiProgressManagers'` |

### Known issues

- 4 test items (`Callback start message`, `Callback step message`, `create_dril_callback with DRiL loaded`, `create_dril_callback integration`) fail because the test file references `using DRiL` but the package is registered as `Drill`. These are pre-existing failures unrelated to the environment. The remaining 49 tests pass.

### Notes

- Julia is installed via `juliaup` at `~/.juliaup/bin`. Ensure `PATH` includes this directory (the update script handles it).
- The package requires Julia >= 1.11 (due to `Distributed` compat).
- No linter is configured for this project. Julia does not have a standard lint command like `eslint` or `ruff`; the closest would be `Runic.jl` for formatting, but it is not listed as a dependency.
- This is a library, not an application — there is no dev server to start. Testing is done via `Pkg.test()` and loading the module.
