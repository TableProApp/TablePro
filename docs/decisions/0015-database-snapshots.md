# 0015: Database snapshots and restore

- **Status**: Accepted (2026-10-09); scheduled for 0.2.x, after 0.2.0
- **Date**: 2026-10-08

## Context

Analysts want to try changes on real data and go back if the result is wrong,
without writing SQL or using `pg_dump`-style tools. BookiE has no way to save or
restore a database state: exports and the connection bundle cover rows and
connections, not a whole database. Each engine offers a different native
mechanism, and most need privileges an analyst account may lack.

## Decision

BookiE offers a per-connection **Snapshots** panel: take a snapshot, list
snapshots, restore one, delete one. The user never types SQL.

1. **Capability per engine.** `Driver::snapshot_support()` in `core` reports
   `Unsupported`, `TemplateCopy`, `NativeSnapshot` or `FileCopy`. The panel is
   shown only when the engine supports it and a pre-flight check proves the
   account has the privilege; otherwise it explains what is missing.
   - PostgreSQL, `TemplateCopy`: a snapshot is
     `CREATE DATABASE <name> TEMPLATE <db>`, issued from the maintenance
     database. PostgreSQL requires that no other session is connected to the
     source, so BookiE releases its own pool first and refuses with a clear
     message when other sessions remain.
   - SQL Server, `NativeSnapshot`: `CREATE DATABASE … AS SNAPSHOT OF` with one
     sparse file per data file, and restore with
     `RESTORE DATABASE … FROM DATABASE_SNAPSHOT`. Supported editions only;
     restore requires that no other snapshot of the database exists.
   - SQLite and DuckDB, `FileCopy`: a consistent copy of the database file
     (SQLite `VACUUM INTO`), later.
   - MySQL, ClickHouse, MongoDB and Redis: `Unsupported` until a tested design
     exists.
2. **Names are generated.** Snapshot names are
   `<db>__bookie_<UTC timestamp>` and validated against the engine's identifier
   rules before use; a user label is stored separately and never enters SQL.
3. **Restore keeps a safety copy.** PostgreSQL restore renames the current
   database aside, creates it again from the snapshot, reconnects, and drops the
   aside copy only after the user confirms. SQL Server restore is a native
   operation and is preceded by a confirm dialog naming what will be replaced.
4. **Guarded and audited.** Each snapshot, restore and delete runs as one
   administrative operation through `PolicyGuard`: refused on read-only
   connections and for agent principals, approval required where the
   environment's rules ask for it, an ADR 0010 intent written before and an
   outcome after, with no database names, paths or secrets in events. Long
   operations carry an `OperationControl` (ADR 0005).
5. **Bounded.** A per-database snapshot limit of 5, a size estimate shown before
   taking a snapshot, and no automatic retention: deleting is explicit.

## Rationale

Native engine mechanisms are the only way to snapshot a whole database
quickly and exactly. Generated names, one guarded operation per action and a
safety copy on restore keep a destructive feature usable by people who do not
read SQL.

## Consequences

- Privileges: `CREATEDB` on PostgreSQL, `CREATE DATABASE` and edition support on
  SQL Server. Accounts without them see why the panel is unavailable.
- A PostgreSQL snapshot or restore briefly disconnects BookiE from the source
  database and fails while other clients are connected.
- Snapshots use server disk space; SQL Server snapshot files grow as the source
  changes.
- Each engine needs Docker contract tests that change data after a snapshot,
  restore, and compare the native rows with the snapshot state, plus refusal
  tests for read-only connections, missing privileges and other sessions.

## Alternatives considered

- `pg_dump`, `mysqldump`, `mongodump`: external binaries, passwords on command
  lines or temp files, slow on large databases, and a new dependency.
- Row exports as snapshots: not a database state (no schema objects, sequences
  or constraints) and subject to the ADR 0014 snapshot rule.
- Transactions or savepoints: only last as long as one session and cannot cover
  DDL on MySQL; useful for one experiment, not a saved state.
