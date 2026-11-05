# 0011: Truncating a table and creating or dropping a schema or database

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

The apps could change a table's structure and drop a table through each engine's `DdlDialect` (Linux [0010](../../../linux/docs/decisions/0010-ddl-plans-and-table-definitions.md)), but nothing in the core wrote TRUNCATE or CREATE and DROP for a schema or a database. Each app would have spelled them itself, once per engine. Three engine rules shape the statements: PostgreSQL and SQL Server refuse CREATE and DROP DATABASE inside a transaction, which every write batch opened; MySQL and SQL Server refuse to truncate a table another table's foreign key points at, whatever its rows; and a session whose database was dropped reconnected forever, because "database does not exist" was a plain server error.

## Decision

The catalog operations are plans like structure changes. `DdlDialect` gains `catalog_capabilities` and `plan_truncate_table`, `plan_create_schema`, `plan_drop_schema`, `plan_create_database` and `plan_drop_database`, each refusing by default what the capabilities leave out. Free functions in `tablepro_core::ddl` reach them for any dialect and write MongoDB's through its shell (`deleteMany({})`, `createCollection` in the new database, `dropDatabase`). The New Database dialog shows only the fields `DatabaseFields` names, filled from `Connection::fetch_database_choices`.

A database plan carries `WriteKind::DatabaseChanges`. A driver runs such a batch outside any transaction, one statement at a time, and reports what landed statement by statement. PostgreSQL sends no `SET LOCAL` bounds for it, since there is no transaction to scope them to; the call's deadline and stop still bound it. SQL Server drops a database with its other sessions closed in one batch, and sets it back to multi-user when the drop fails.

A login to a database the server does not have fails as `DriverError::DatabaseNotFound { database }`, category Configuration, so the health monitor parks the session with that reason instead of retrying. Each driver maps it where it logs in only, never where a statement's error is read, since `USE` of a missing database is the user's own mistake.

## Rationale

- **One plan, one review, one history entry.** A catalog operation is a `DdlPlan`, so the Safe Mode review shows the statements that run and the history records them like a structure save.
- **Refused before the server sees it.** Each plan refuses an option the engine has no syntax for, and `CatalogCapabilities` tells the UI not to offer it, as `DdlCapabilities` does for structure changes.
- **The write kind decides the wrapping.** `WriteKind` already says how a write is wrapped; a database change is the case that must not be wrapped.

## Consequences

- PostgreSQL truncates with RESTART IDENTITY and CASCADE as options, drops a database WITH (FORCE) from 13, and writes TEMPLATE template0 when a new database names an encoding or locale and no template, since template1's would conflict.
- MySQL and SQL Server truncate only a table no other table's foreign key points at; the app refuses before asking rather than turning the checks off, which would leave rows pointing at nothing. MySQL lists every database as its schemas, as ClickHouse, Cassandra and MongoDB do, so an empty one can be shown.
- ClickHouse writes ON CLUSTER only for a cluster of more than one server that `system.clusters` lists, since a single server lists `default` with no Keeper behind it.
- SQLite empties a table with DELETE and has neither schemas nor databases to create: ATTACH adds a file to one connection. DuckDB creates and drops schemas; its databases are attached files.
- Cassandra and ScyllaDB create keyspaces with a replication strategy, durable writes and, on ScyllaDB, tablets.
- Redis offers none of them: it has no tables, and its numbered databases cannot be created or dropped. FLUSHDB stays in the editor.
- Each engine names the databases and schemas it keeps for itself (`protects_database`, `protects_schema`), and a name longer than the server keeps whole is refused (`NameLimit`).
