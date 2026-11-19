# 0037: The Swift apps run DuckDB's tasks on threads of their own

- **Status**: Accepted
- **Date**: 2026-11-19

## Context

[ADR 0031](0031-duckdb-expression-depth.md) runs the Swift apps' DuckDB actor on an 8 MiB thread and leaves DuckDB's own threads at the 512 KiB Darwin gives a thread, behind a depth limit of 250. It took an ATTACH to read the attached file on the actor's thread.

An ATTACH reads the file's catalog inside a task of its statement, and `read_duckdb()` attaches each file after the first inside a scan task. DuckDB's scheduler hands a task to whichever thread takes it first: the caller or one of its own. The read costs about 0.84 KiB a level and has no limit, so a CHECK nested 600 deep, which DuckDB's own limit of 1,000 allows, overflows one of DuckDB's threads. Measured on the shipped library: 3 of 5 macOS runs of 200 ATTACHes of a file nested 900 deep died with SIGBUS on a DuckDB thread, and the iOS test that attaches that file once crashed 3 of 60 CI runs. The locked instance the macOS import runs also allows an ATTACH inside its folder.

DuckDB has no setting for its threads' stack.

## Decision

- Every DuckDB database the Swift apps open sets `threads` and `external_threads` to the processor count, so DuckDB starts no thread of its own, and starts one less than that count of 8 MiB threads that run its tasks through `duckdb_execute_tasks_state` (`DuckDBTaskThreads`).
- A statement other than SELECT, INSERT, UPDATE, DELETE or a transaction statement is followed by reading both counts on a connection of the apps' own. When it raised the count, DuckDB started threads of its own: the apps' threads stop, `external_threads` follows `threads`, which ends DuckDB's, and that many less one start again. `allowed_configs` keeps `external_threads` changeable once a statement locks the configuration.
- On iOS a text of several statements, which could raise the count and change it again before it returns, runs one statement at a time, split as the editor splits it, and keeps the result `duckdb_query` gives. A text DuckDB cannot parse, or that the split reads as another number of statements than DuckDB, runs none of them. The macOS plugin runs one statement at a time.

## Rationale

- ADR 0031 rejected `external_threads` because `SET threads` below it fails and DuckDB's own threads, started by a raise, take the wake-ups that end the apps' threads. Measured further: a change that ends DuckDB's own threads, such as a RESET after a raise, wakes only as many as it has, the apps' threads take some of those wake-ups on the same semaphore, and DuckDB's join then waits for good. Taking DuckDB's threads over right after the statement that started them leaves none for a later change to end, and stopping the apps' threads repeats the wake-up until each one is back. IMPORT DATABASE runs its folder's statements as one query, and DuckDB starts or ends threads once, after it.
- Letting a lower count through needs the statement's setting before it runs. Preparing a SET to learn it can invalidate the database when its value has a side effect, and running it to see it refused aborts an open transaction (both measured), so the lower count stays refused.
- Running only ATTACH on one thread misses `read_duckdb()` and an ATTACH inside `IMPORT DATABASE`.
- `threads = 1` keeps every task on the caller but runs every query on one core: a parallel sum took 2.63 s against 0.82 s with 12 threads.
- A DuckDB built with a larger stack for its threads would be a patched fork and a new library build.

## Consequences

- `SET threads` below the processor count, or below a count raised earlier in the session, fails with DuckDB's "Number of threads can't be smaller than number of external threads!". A raise holds until the session closes.
- A statement other than SELECT, INSERT, UPDATE, DELETE or a transaction statement reads the two counts after it runs, about 0.05 ms; one that raised the count also stops and starts the apps' threads, about 2 ms.
- The core's DuckDB driver runs an ATTACH on DuckDB's threads too. They get `RLIMIT_STACK` on Linux, 8 MiB as a rule, and the executable's reserve on Windows, 1.5 MiB in the app; an ATTACH of a file 992 deep, DuckDB's own deepest, needs about 840 KiB (clang, arm64). macOS runs the core only in tests. It is not changed here.
