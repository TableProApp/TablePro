# 0011: A query result edits when its statement reads one table and its driver traces the columns

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

A result in a query tab is rows of an arbitrary statement. Editing one writes back to a table, so the app has to know which table and which column each cell came from, and that every row is one row of that table. A save that guesses writes another table's rows, or another row of the right table.

Measured on PostgreSQL 17.11, MySQL 8.4.13, MariaDB 11.8.9, SQLite 3.46.1, DuckDB 2.0.0, SQL Server 2022, ClickHouse 26.10, Cassandra 5.0.9, ScyllaDB 2026.3 and MongoDB 8.3 on 2026-11-05:

- No engine's metadata proves a result is one table's rows. PostgreSQL, MySQL, MariaDB and SQLite name both copies of a self-join as the same table; SQLite names a table for UNION arms, scalar subqueries and table-valued functions; MariaDB names a derived table's or CTE's alias; a MySQL temporary table looks like a base table; SQL Server's describe maps a view to its base table.
- What each engine can say about a column: PostgreSQL's RowDescription carries the table OID and attribute number, which tokio-postgres drops on the simple protocol and keeps on a `prepare` of the cursor's FETCH; sqlx gives MySQL's `org_table`/`org_name` and SQLite's `sqlite3_column_*_name` as `Column::origin()`, and every SQLite build we ship has column metadata; SQL Server answers `sys.dm_exec_describe_first_result_set` in browse mode; Cassandra's RESULT metadata names the table but gives an alias or a function's text as the column; DuckDB and ClickHouse say nothing; MongoDB's cursor names its collection after `$group` and `$unionWith` too.

## Decision

The statement decides whether a result is one table's rows; the driver proves which table and columns, on the connection that ran it.

- `sql_syntax::source_table` accepts one `SELECT` over one table, optionally qualified and aliased, with `WHERE`, `ORDER BY` on row expressions, `LIMIT` and locking clauses. It refuses joins, comma lists, subqueries and functions in `FROM`, CTEs, set operations, `DISTINCT`, `GROUP BY`, `HAVING`, and any function or subquery in the select list, since a function's name cannot say whether it aggregates. On ClickHouse it also refuses an alias that names another item's column, since ClickHouse substitutes the alias there. PostgreSQL's bare `current_role`, `current_schema` and their kin are expressions.
- `ResultColumn::origin` is a `ColumnOrigin { table, column }`, set by the driver only for a direct column, renamed or not, of a permanent base table, with the table qualified so any connection to the same database names it. A view, a temporary table, an expression and an untraced column carry none.
  - PostgreSQL: after the DECLARE, the statement's table resolves with `to_regclass` on the tab's connection, and counts only when the open cursor holds a lock on it, so it is the relation the statement read; relkind `r` or `p`, persistence permanent or unlogged. A `prepare` of the FETCH gives the OIDs too, but makes tokio-postgres look up every non-built-in column type by name, a round trip each.
  - MySQL and MariaDB: `Column::origin()` for a run of one statement, confirmed after it by `SHOW CREATE TABLE` on the same connection, which names a temporary table that shadows the base one.
  - SQLite: `Column::origin()`; the `temp` database carries none.
  - SQL Server: the describe, for a batch of one statement outside a transaction, with the statement's table resolving to the same object, so a view or a synonym carries none.
  - DuckDB, ClickHouse, Cassandra and ScyllaDB: the driver resolves the statement's table on its own connection, refusing a temporary table or a view, and `edit::parsed_origins` maps the columns. Cassandra's RESULT metadata names the table.
  - MongoDB and Redis: none.
- `edit::result_source` requires every origin to name one table, the one the statement names. `edit::result_target` maps each result column to the table's catalog column, refuses a table without a primary key and a result that leaves out part of it, locks expressions and a second copy of a column, and refuses a result whose wildcard no longer matches the catalog.
- A driver looks nothing up inside the user's transaction, and a lookup that fails leaves every origin empty and the run unchanged.
- PostgreSQL's editor reads text; `edit::value_for_column` turns a value of a column the driver left as server text into the catalog's type, and a key it cannot read leaves the row read-only. A value any other driver read stays as it was stored, so SQLite's ` 2024-01-01 ` is not the key `2024-01-01`.

## Rationale

- The parser is strict where the metadata is wrong, and the metadata is exact where the parser would guess, such as which schema an unqualified name resolved to on that connection.
- The save keeps the table tab's path: `save::plan_save` with its row guards over the catalog's columns, so a query result writes nothing a table tab would not.

## Consequences

- An app saves through the connection it saves a table tab with, so it refuses a result read inside an open transaction or in another database than that connection's.
- `SELECT id, upper(name) FROM t` is read-only, though its rows are one table's.
- Cassandra statements the generic SQL parser cannot read, such as `ALLOW FILTERING`, are read-only.

## Alternatives considered

- **Metadata alone.** Self-joins, UNION arms in SQLite and aliases in MariaDB would write the wrong rows.
- **The parser alone, resolving names on the save connection.** A tab's search path, database and temporary tables are not that connection's.
- **Rewriting the user's statement to qualify its table.** It changes the statement the user runs and moves its error positions; the driver's own lookup proves the same table without touching it.
