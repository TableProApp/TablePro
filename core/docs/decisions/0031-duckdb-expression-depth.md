# 0031: DuckDB's expression depth fits the stacks it runs on

- **Status**: Accepted; the Swift apps' DuckDB threads amended by 0037
- **Date**: 2026-11-15

## Context

DuckDB parses, binds, reads back, prints and saves an expression one C++ call per level of nesting. A file chooses how deep its CHECK constraints, defaults, generated columns, views and macros nest. DuckDB guards the parser, the binder and the planner with `max_expression_depth`, 1,000 by default, and nothing else: reading the catalog at open, printing an expression and writing it at a checkpoint have no limit.

Measured on the DuckDB 2.0.0 the core and the Apple apps link, clang `-O2` and `-O3` on arm64, per level: the binder about 0.95 KiB, reading the file at open about 0.84 KiB, printing and saving about 0.3 KiB, and a view in a chain about 2.9 KiB, two binder levels each.

DuckDB runs part of a query on threads of its own, created with the platform's default stack: 512 KiB on macOS and iOS, the executable's reserve on Windows (1.5 MiB in the Native AOT app, 1 MiB in a Rust test), `RLIMIT_STACK` on Linux, usually 8 MiB. `duckdb_constraints()` binds every table's constraints there, so a CHECK about 575 levels deep, under DuckDB's own limit, ended the process on macOS when any table's keys were read. The driver ran DuckDB on the runtime's 2 MiB blocking threads, and the Swift apps run it on 512 KiB cooperative threads, where opening a file whose CHECK nests 900 deep ended the process too.

## Decision

- Every DuckDB database the apps open on a user's file sets `max_expression_depth` to 250: about 240 KiB on the binder, under half of the smallest stack DuckDB runs on. Past it DuckDB refuses the statement with its own Parser or Binder error, `DriverError::Server` with the DuckDB code, which every app words. The core's own connections set it again for their session, so an editor tab's `SET GLOBAL` does not reach them.
- The core runs every DuckDB call, and the close that checkpoints the file, on a thread of 8 MiB, the stack DuckDB's command line runs on, started for the call inside the runtime's blocking task (`on_duckdb_stack`).
- The Swift apps run their DuckDB actor on a thread of 8 MiB through a custom executor (`DuckDBStackExecutor`), so an open, an ATTACH and a close get it as every query does, and the macOS isolated import runs its open, its statements and its close on one.

## Rationale

- **The limit DuckDB documents.** Its description warns that a deeper limit can overflow the stack; 250 is the value that fits the 512 KiB DuckDB gives its own threads with room to spare.
- **Not DuckDB's threads.** DuckDB runs its tasks on threads an embedder starts when `external_threads` equals `threads` (`duckdb_execute_tasks_state`). Measured, `SET threads` below that count then fails, above it DuckDB starts threads of its own with the default stack again, and those took the wake-ups `duckdb_finish_execution` sends, so a close waited for good.
- **A thread per call in the core.** Starting one costs about 40 µs; the runtime's blocking task waits on it, so a shutdown still waits for DuckDB's work.
- **An executor in the Swift apps.** An actor's custom executor is how Swift runs isolated work on a thread of the program's choosing; the cooperative pool and a dispatch queue give 512 KiB. It needs only the `UnownedJob` form, as the macOS app runs on 13.

## Consequences

- An expression, subquery or view chain nested past 250 levels fails in every app where DuckDB's own command line allows 1,000: about 240 chained `+` or `||` terms. `AND`, `OR`, `IN` lists, `CASE` and `coalesce` stay flat and are not limited. A user can raise it with `SET max_expression_depth`, and DuckDB's warning applies; in the Swift apps the app's own reads share that session, so the raised limit reaches them too.
- In a file with a CHECK nested past 250, every read that touches constraints fails, the columns of any table among them, as with a crafted table under 0029. The table list still reads.
- A file whose expressions nest past DuckDB's own limit, made by raising it, can still overflow DuckDB's threads where DuckDB prints or saves them, about 1,700 levels on macOS, and the 8 MiB open past about 9,700: DuckDB has no limit there, and only a process of its own would contain it. The core reads such a file back as far as DuckDB's command line does.
- The tests build files at 992 levels, DuckDB's own deepest, and at 3,000, and run on Linux, Windows and macOS (`core.yml`).
