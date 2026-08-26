# Changelog

## Unreleased

- Speed up worker progress reporting: coalesce queued task updates on the master, flush them in a single SQLite transaction, write local tasks directly to the listener sink, run the listener on the interactive threadpool, and skip the extra per-update `SELECT` on the write path.

- [#43](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/43) Speed up the Tachikoma dashboard poll loop: stop issuing unused per-experiment speed/sparkline/ETA queries, skip the extra running-experiments query, read task snapshots without allocating DataFrames, cache the local timezone, and render at 30 fps.

## [0.1.1]

- [#15](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/15) Require Tachikoma 2 in compat
- [#17](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/17) Rename `create_dril_callback` to `create_drill_callback`
- [#18](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/18) Do not error when the log directory is empty
- [#23](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/23) Export `create_drill_callback` from the base package
- [#27](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/27) CI: remove deprecated TagBot `workflow_dispatch` lookback input
- [#28](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/28) Display dashboard timestamps in local timezone (TimeZones.jl)
- [#29](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/29) Smarter experiment ETA from per-task progress
- [#30](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/30) Folder-only dashboard and CLI; remove single-file mode
- [#35](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/35) Fix Started column time on Runs tab (DateFormat `mm` vs `MM`)
- [#36](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/36) Fix experiment duration (UTC vs local clock)
- [#37](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/37) Simplify status line (drop redundant `Folder:` prefix)
- [#41](https://github.com/KristianHolme/MultiProgressManagers.jl/pull/41) Dynamic column widths and aligned headers on Runs tab

## [0.1.0]

- Rewrite to use Tachikoma.jl
