# 0010: DDL plans against table definitions

- **Status**: Accepted
- **Date**: 2026-10-13

## Context

The structure tab wrote its SQL through one builder in `tablepro-core`, keyed by driver id. It quoted names itself, matched on `"mysql"` or `"mssql"` to pick a spelling, and turned each edit into one statement per operation. That could not express MySQL's single combined ALTER, SQL Server's drop of a named default before a type change, ClickHouse's `RENAME TABLE`, or SQLite's limits, and the UI offered changes the engine then refused at Save. The 2026-09-14 audit traced wrong and refused DDL to it (F-021, F-045, F-050, F-054, F-117).

## Decision

Each engine plans structure changes through its own `DdlDialect`, reached from `SqlDialect::ddl()`, against the `TableDefinition` one `fetch_table_definition` call returned, and the plan is what the preview shows and what the save runs.

## Rationale

**One change, the engine's order.** The tab edits a `TableDraft`. `diff_table` turns it into `TableChanges`: the table rename, the columns dropped, renamed, altered and added, the primary-key move, and the indexes and foreign keys dropped and added. `plan_alter_table` writes them in the order the engine needs: one combined ALTER TABLE on PostgreSQL, the foreign keys around one ALTER on MySQL, separate statements with the named default dropped first on SQL Server, native ALTER TABLE only on SQLite, one ALTER per change on ClickHouse. A `DdlPlan` carries the statements and the `ForeignKeyMode`, and becomes the `WriteBatch`.

**Refused before Save.** `DdlCapabilities` and `ColumnCapabilities` answer which changes the engine takes, each refusal with a `RefusalReason` the tab shows beside the control it turns off. A primary key another table's foreign key points at cannot move on any engine, and a column such a key references cannot be dropped. Every plan runs the same checks first, so a caller that skips the UI gets `BuildDdlError::Refused` or `Unsupported` rather than SQL the server rejects.

**Nothing spliced unchecked.** A catalogue type is spliced as the server gave it. A typed one is spliced only after `SqlDialect::parse_type` accepts it, a typed default only after `parse_expression` does, and a literal default goes through `SqlDialect::literal`. Every name goes through the dialect's quoting.

**The connection that runs it.** The save plans again inside the session operation, with the dialect of the lease that writes it, so a reconnect to another server version between edit and Save cannot send SQL spelled for the old one.

**Tested on the server.** Each driver's `src/ddl.rs` holds golden tests for its plans, and `ddl_conformance_suite!` runs the plans against every engine: each change applies and reads back as drafted, a failed batch ends as `ddl_writes` says, and `create_table_script` recreates the table.

## Consequences

- An engine's DDL is one file in its driver crate, and core has no branch on a driver id.
- The structure tab's controls follow the capabilities, so a change the engine cannot make is never offered.
- Primary-key identity on PostgreSQL, SQLite table rebuilds and the full restatement of MySQL and SQL Server column attributes are plans of their own, added to the same dialects later. Until then their capabilities are off.

## Alternatives considered

- **sea-query.** It covers only MySQL, PostgreSQL and SQLite in its open-source backends, and cannot express MySQL's MODIFY, SQLite rebuilds or SQL Server default constraints.
- **One method per operation on `DdlDialect`.** Per-operation statements cannot be merged into MySQL's single ALTER or reordered around SQL Server's default constraints, which is why the plan takes the whole change.
