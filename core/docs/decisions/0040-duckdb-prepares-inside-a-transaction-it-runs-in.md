# 0040: DuckDB prepares a statement only inside a transaction it runs in

- **Status**: Accepted
- **Date**: 2026-11-20

## Context

DuckDB 2.0 runs `duckdb_prepare`, and `duckdb_prepare_extracted_statement` the same way, as an internal PREPARE statement, and a PREPARE never writes. Binding evaluates a SET's value, a table function's arguments, an ATTACH's options and a PRAGMA's arguments, so `SET threads = nextval('seq')` or `SELECT * FROM range(nextval('seq'))` advances the sequence while it prepares. Outside a transaction the PREPARE commits on its own, DuckDB finds changes in a read-only transaction, raises an internal error and invalidates the database: every later statement fails until the file is opened again. Measured on the shipped library, `apple/scripts/probes/check-duckdb-side-effecting-prepare.sh`:

- Inside a transaction the same prepare commits nothing, running it marks the transaction as writing, and its COMMIT works. A prepare that never runs, then a COMMIT, invalidates the database too; a ROLLBACK does not.
- `duckdb_query` prepares nothing and takes the sequence value once.
- A sequence value stays taken after a ROLLBACK.
- A read left unfinished inside a transaction aborts it when it takes sequence values, and a COMMIT then ends it without an error.
- Every statement but BEGIN, COMMIT and ROLLBACK succeeds or fails alike inside BEGIN and COMMIT.

The macOS plugin prepared every statement, the iOS app prepared the reads it streams and exports, and the core's duckdb crate prepares every statement of an editor run.

## Decision

- A prepare of SQL the user wrote never commits on its own. It runs inside the session's transaction, or inside one the driver opens when DuckDB's transaction ids say the session has none, since a BEGIN inside one aborts it. The statement runs in that transaction, and the driver commits it when the result ends, reporting a failed COMMIT as the statement's error, or rolls it back when the statement fails or its reader gives it up.
- The Swift apps run a statement that takes no parameters and does not start like a SELECT (`SELECT`, `WITH`, `FROM`, `VALUES`, `TABLE`, `UNPIVOT`) through `duckdb_query`, one statement at a time on macOS, which prepares nothing. When there is no transaction to prepare in, because the state is unknown or DuckDB refused the BEGIN, a statement without parameters runs through `duckdb_query`, read whole, and the macOS plugin refuses one with parameters. The iOS app prepares a statement with values only for its own SQL, import writes and catalog reads, which binds nothing that writes.
- The core's duckdb crate has no call that runs SQL unprepared and returns its result, so an editor run opens a transaction for each statement while the session has none, except BEGIN, COMMIT and ROLLBACK, which bind nothing. A run knows the state from the session's last state read and from the transaction statements it ran; a state no read can give leaves the statement prepared as it stands.
- [ADR 0037](0037-swift-apps-own-duckdb-task-threads.md) holds: a statement other than SELECT, INSERT, UPDATE, DELETE or a transaction statement is still followed by reading the thread counts, with its type from the result on the `duckdb_query` path.

## Rationale

- Extracting the statements first, which DuckDB 1.x clients used to stream without preparing a second time, prepares the same way and invalidates the database alike.
- DuckDB's C API streams only a prepared statement, so the reads the apps stream and cut at a row limit need the prepare.
- `duckdb_query` for every other statement keeps DuckDB's own autocommit and runs an INSERT on a file in 176 µs against 450 µs prepared.
- The v2 C API's `duckdb_v2_statement_execute` runs a statement unprepared and streams, but shares no handle with the v1 API the drivers open, task threads and reader table functions use.
- Preparing outside a transaction and rolling back the prepare's effects would keep a sequence value the statement then uses again.
- Refusing the core's statements when no read can say the state would stop every run on a session whose default catalog is not DuckDB's, where `txid_current()` fails.

## Consequences

- A streamed read outside a transaction costs a state read, a BEGIN and a COMMIT, about 0.1 ms.
- A read whose binding takes a sequence value takes it once on macOS and in the core; the iOS app still binds a streamed read twice, once to plan its columns.
- A SQL `PREPARE` the user writes still commits on its own, as DuckDB runs it.
