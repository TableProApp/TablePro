# 0029: A catalog read keeps a byte budget

- **Status**: Accepted
- **Date**: 2026-11-15

## Context

A file engine reads its catalog from the file the user opened, and the file chooses every name in it. SQLite's pragmas repeat a name on every key that uses it: a column that carries REFERENCES thousands of times comes back with its name on every key, a child's name on every key into its parent, and a key that names no parent columns took a copy of the parent's whole primary key. SQLite also compiles `PRAGMA foreign_key_list` with a copy of those names for each key column, so a 300 KB table cost it over 300 MB before the first row, and the keys into any table ran that pragma on every table of the schema. The keys into a table carried the child's whole CREATE TABLE on each key column, in SQLite and in DuckDB, and that text grows with the keys the child declares. A file of a few hundred kilobytes made one read of a table's keys hold gigabytes.

## Decision

`CatalogBudget` in `tablepro-core` bounds what one catalog read holds at `ByteLimit::CATALOG_DEFAULT`, 64,000,000 bytes, counted as `Value::retained_bytes` counts text: a string's slot and its length. Past it the read fails with `DriverError::CatalogTooLarge { limit_bytes }`, code `driver.catalog_too_large`, category `Internal`.

- SQLite and DuckDB charge each text a read keeps as it arrives, and each copy made per key before it is made. A text read and dropped before the next one, as each child's CREATE TABLE, is released.
- Each text of the file is read once per call, and SQLite's catalog rows stream, unsorted where a sort would hold every row first.
- A SQLite catalog read runs in one read transaction, so a schema change by another connection between its statements cannot make it miss a table.
- The workspace's SQLite connections set `SQLITE_LIMIT_SQL_LENGTH` to 10,000,000 bytes, the per-connection limit sqlite.org/security.html names for untrusted files. SQLite applies it to each CREATE statement as it reads the schema, so a file with a longer one does not open: SQLite reports the schema malformed (`driver.server`, SQLite error 11). SQLite parses a stored text only to its statement's end, so a text can carry any tail after it; each catalog read that parses a stored text takes it only up to the same cap, and fails with `CatalogTooLarge` past it. The size comes from `octet_length`, which from SQLite 3.43 reads it from the record without reading the text, and only a table of at most 64 KiB has its text counted for the keys into a table.
- A parse with sqlparser runs only once the text, at 512 bytes for each byte, fits the budget. An index's statement is parsed only for an expression key or a WHERE, and a generated column's expression alone, not its table's statement.
- SQLite runs `pragma_foreign_key_list` on a table only once the key list's cost, worked out from its CREATE TABLE (`foreign_key_list_bytes`), fits the budget. The keys into a table ask every table of at most 64 KiB whose key list cannot cost more than the budget in one read; each other table is read alone, searched in linear time for the parent's name, and costed first.
- A save's foreign key check holds each checked table's name and each broken key once, and each broken row as a key index and a rowid, all charged to one budget for the checks before and after the save. Past it the save rolls back with `CatalogTooLarge`: a check by count alone could let the save move a broken key to other rows.
- DuckDB builds every table's constraint rows, a chunk at a time, before a query filters them, and holds the whole result before the first row. A constraint read runs only once both fit, bounded from `duckdb_tables()` and `duckdb_dependencies()`. It reads each child's and each parent's CREATE TABLE once, and charges the column names it keeps from them.

## Rationale

- **An error, not a cut list.** A table definition plans structure changes, and a rebuild planned from a list cut short would drop what was left out.
- **64 MB.** A schema of 5,000 tables keyed to one table reads its keys in a few megabytes, and a million table names fit under it.
- **In the driver.** The driver knows which texts it copies per key and what SQLite compiles for them, and no app has to pass a limit.
- **SQLite's limits, and where they stop.** The statement limit bounds what SQLite and the catalog reads parse, but not what `pragma_foreign_key_list` compiles: one copy of a column's name for each REFERENCES on it, so a statement of S bytes can cost about S²/52 bytes, 331 MB from a 117 KB table. `SQLITE_LIMIT_VDBE_OP` stops that compile only after its op count is spent, 153 MB at 25,000, and would refuse real queries well before it helps. `sqlite3_hard_heap_limit64` is process-wide and would cap the app's own databases. So the key list keeps its cost check, and the budget keeps bounding the copies a read makes per key, which no limit counts.
- **Parses beside SQLite's own.** SQLite holds about 54 bytes for each byte of a statement it loads with the schema, and keeps it for the connection's life. The CREATE TABLE reader holds about as much while it runs, so it reads within the statement cap. sqlparser holds up to about 420, measured on an IN list of one-digit numbers, so its parses count against the budget, and it parses only what a read needs from it.
- **10 MB.** A real CREATE TABLE is a few kilobytes, two thousand columns about a hundred, and the 5,000-table catalog reads as before. `SQLITE_LIMIT_LENGTH` stays at its default: it bounds every value, the user's own data among them. Editor sessions keep SQLite's defaults, since a script can hold a longer statement; the workspace connection has already refused such a file.

## Consequences

- Large real schemas read as before, and the keys into a table read faster: 5,000 children in 0.2 s, against 1.4 s.
- One value is read before it is charged, and sqlx queues up to 50 rows ahead of the reader. SQLite bounds a value at `SQLITE_MAX_LENGTH`, and a CREATE TABLE over 64 KiB is read alone.
- In a DuckDB file with a crafted table, every read that touches constraints fails, the columns of any table among them, since DuckDB builds the crafted table's rows for each. The table list still reads.
- DuckDB has no per-connection limit on a statement's or a schema's length; its `memory_limit` bounds the buffer manager, not what its catalog functions build. DuckDB keeps the bounds above.
- DuckDB's own catalog functions, `duckdb_columns()` and `duckdb_constraints()`, build a row for every column and constraint of every table before a filter, each with its table's name, and a column can repeat a constraint. The bound counts table names and the text, not a long column name repeated in its constraints; that work is DuckDB's.
- A save on a table with millions of rows that already break its keys rolls back rather than compare them. Its error lists the first ten tables and parents.
- Not budgeted: the schema list, reads of one value, and the SQL dumps, which read each object once.
- The apps word the code: Linux in `linux/crates/app/src/ui/error_text/driver.rs`, Windows in `Resources.resw`.
