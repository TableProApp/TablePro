# DuckDB

Driver id `duckdb`, crate `crates/drivers/duckdb`. It runs on the duckdb crate 1.20000.1 with `bundled`, so DuckDB 2.0.0 is compiled from the crate's sources into the app, with the `json` and `parquet` extensions linked in ([ADR 0025](../decisions/0025-bundled-duckdb.md), [ADR 0031](../decisions/0031-duckdb-2.md)). The contract it implements is in [adding-drivers.md](../adding-drivers.md).

There is no network, login or TLS: the target is a `FileEndpoint`, an absolute path with a `FileOpenMode`. A file is a DuckDB database when it holds `DUCK` at byte 8, which is how a file opened from Files or the command line finds this driver; `.duckdb` and `.ddb` are its suffixes for the file chooser and an empty file. shared-mime-info has no DuckDB type, so the desktop entry does not list one.

## Opening a file

DuckDB keeps one database instance per open file, and every connection is a new connection to that instance. The driver keeps one instance per file in the process: the workspace's pool, every editor tab and every export of every window on the file share it. Two instances of one file in one process would each keep a catalogue and a write-ahead log, and DuckDB's file lock does not keep them apart, since a POSIX lock belongs to the process. The instance closes, and DuckDB checkpoints the file, when the last connection to it goes, editor tabs included.

- A missing file is `FileNotFound`. DuckDB would create it, so the driver opens only a path that exists.
- A read-only workspace opens the instance with `access_mode = READ_ONLY`. One instance is opened one way, so a window that asks the other way while another window holds the file gets `Busy(FileLocked)`.
- Another process holding the file gets `Busy(FileLocked)`: DuckDB's lock lets one writer, or any number of readers, open a file.
- A file is known by its device and inode, so a hard link or a second path joins the instance already open. A file an editor tab has attached counts as open, and an editor's `ATTACH` of a file open in another window is refused as `Busy(FileLocked)`: either way DuckDB would make a second database on the file. DuckDB reads the `ATTACH` path itself, then the driver expands it as DuckDB opens it, so escapes, continued strings, `~`, `file:` URLs, links and `..` all name the file. An `ATTACH` with the `HIDDEN` option, quoted or not, is refused unless its value is false: DuckDB lists such a database nowhere, so no window could see it is open.
- A file SQLite has open in the app, through a connection or an `ATTACH`, is `Busy(FileLocked)`, as is an `ATTACH` of one: DuckDB would close it again on finding no database of its own, which drops SQLite's POSIX locks. DuckDB claims its own files, and every file a tab attaches, until the database closes (`tablepro_core::claim_file`), so SQLite refuses them in turn.
- `autoinstall_known_extensions` and `autoload_known_extensions` are off ([Extensions](#extensions)).
- `storage_compatibility_version` is `v0.10.2`, DuckDB 1.x's default, so a file the driver creates or an `ATTACH` makes stays readable by DuckDB 1.x. A file that already exists keeps its own version.
- A file DuckDB cannot read as a database is `NotADatabase`, a directory too; one the user may not read is `FileAccessDenied`.

The connect reads `version()`, which also proves the file opened. The app names a table with the file's catalogue as well, `"sales"."main"."t"`: a schema may share a name with the catalogue, and DuckDB refuses `"sales"."t"` as ambiguous then. An export and a foreign key's `REFERENCES` leave the catalogue out (`portable_name`), since the file may be replayed under another name and DuckDB refuses a catalogue there; a foreign key inside a schema named like the file cannot be written at all. A database DuckDB could not replay fails the connect.

### New databases

`FileOpenMode::CreateNew` builds an empty database next to the target, checkpoints and closes it, sets mode 0600, renames it over the path and syncs the folder. A reader sees the old file or the new one.

- The driver takes the lock DuckDB takes on the file it replaces and holds it through the rename. A file another process has open, or this one, is `Busy(FileLocked)`: its writer would go on logging to `<path>.wal` beside the new file.
- The old file's `<path>.wal` moves aside before the rename and is removed after it, since DuckDB would replay it into the new database. When the rename fails it goes back, so the old database keeps the changes only its log holds.

### Where the file lives

DuckDB relies on the POSIX lock on the file and writes its log to `<path>.wal` beside it. On NFS or SMB the lock can fail without an error, and a FUSE mount, the Flatpak document portal's included, may not implement it, so two writers can corrupt the file. The open dialog asks before opening a file on such a mount read-write, as it does for SQLite.

## Connections

| Connection | Used for |
|---|---|
| A pool of up to 4 (`WORKSPACE_POOL_MAX_SIZE`) | The sidebar, the grid, counts, saves |
| One connection per call | `stream_read` (exports), and the probe when every pool slot is busy |
| One connection per editor tab | `EditorSession` |

DuckDB runs the queries of one instance side by side, so a slow page does not hold up the sidebar. A tab's `SET default_collation` reaches every connection to the instance, so the pool's connections and the per-call ones set it back to none for their own session: the grid compares a key byte for byte, as DuckDB keeps it unique. Calls wait for a slot for up to the pool wait (5 s), then fail as `Busy(NoFreeConnection)`. Each call ends its own transaction. A save that cannot show its connection is out of a transaction, and a call given up while DuckDB still runs it, take the connection out of the pool.

The health probe runs `SELECT 1` on a free slot, or on a connection of its own when none is free. It never waits for a slot.

## Stops and timeouts

DuckDB has no statement timeout. `duckdb_interrupt` sets a flag on the connection that the running statement checks as it works, and the statement fails with `INTERRUPT Error: Interrupted!`. DuckDB clears the flag as each statement starts, so a stop that lands between two statements would be lost. A stop therefore sends the interrupt every 10 ms while the call's work can be stopped, and the work checks the stop request before it sends anything. Cleanup, a rollback or a COMMIT, holds stops off first. The flag is the connection's: `StopDelivery::OutOfBand(StopScope::Connection)`.

The workspace statement timeout (60 s) becomes a deadline the interrupt enforces on reads and row saves. A structure change runs as long as it takes, since one stopped halfway only rolls back.

DuckDB numbers no error. Each message starts with its kind, as in `Constraint Error: ...`, and the kind is the `ServerCode::DuckDb` the app shows.

| DuckDB answer | Reported as |
|---|---|
| `INTERRUPT` after our stop | `Cancelled`, or `Timeout { server_cancelled: true }` at the deadline |
| `Invalid Input` or `TransactionContext` naming read-only mode | `ReadOnly(ServerRejected)` |
| `FATAL`, or any error after the database was invalidated | `ConnectionLost`: DuckDB refuses everything after a fatal error |
| `IO` "Could not set lock on file" at open | `Busy(FileLocked)` |
| `IO` "not a valid DuckDB database file" at open | `NotADatabase` |
| `IO` "Permission denied" at open | `FileAccessDenied` |
| Anything else | `Server`, with the kind as its code |
| No pool slot within the pool wait | `Busy(NoFreeConnection)` |

## Read-only

`ReadOnlyEnforcement::EngineEnforced`: a read-only workspace opens the file read-only, so DuckDB refuses every write, `ReadOnly(ServerRejected)`. Saves on it are refused before anything is sent.

An export runs on a connection of its own inside `BEGIN TRANSACTION READ ONLY`, which DuckDB holds against every write to a database. The user's SQL in an export may not begin, commit or roll back a transaction, since that would leave the read-only one: such SQL is refused as `ReadOnly(ClientGuard)` before it runs.

## Writes

`WriteAtomicity::Transactional` for row and schema changes. A save is one `BEGIN TRANSACTION` with each step probed, sent and checked, then `COMMIT`. DuckDB checks a write against other connections' writes at COMMIT, so a conflict refuses the COMMIT, which has rolled back; the save fails as `RolledBack`. A statement that fails aborts DuckDB's transaction, so the save stops there and rolls back.

A `COMMIT` never crosses a network, so nothing is left to resolve afterwards (`CommitResolutionSupport::Unavailable`). Foreign keys cannot be suspended for a batch.

### Row identity

The grid names a row by its primary key, then by a UNIQUE constraint whose columns are all `NOT NULL`. A key over a column declared with a `COLLATE` does not count: DuckDB keeps it unique byte for byte, while `=` and ORDER BY compare under the collation, so `'ABC'` and `'abc'` are two rows one predicate finds. A table with no key that counts is read-only in the grid. DuckDB's `rowid` names a storage position, and a checkpoint that compacts the table after deletes hands rows new ones (`tests/integration/catalog.rs`), so an edit by rowid could change another row.

## Structure changes

DuckDB takes one action per `ALTER TABLE`, and the plan sends one statement per change. What it refuses, measured on DuckDB 1.5 in `tests/integration/ddl.rs`, the Structure tab does not offer:

- A table that something depends on, an index made with `CREATE INDEX` or another table's foreign key, takes only an added column, a column's default, a comment and its indexes. Renaming the table or a column, dropping a column, and changing a type or NULL are refused with the dependents named.
- A column's type cannot change while a key, index, CHECK or generated column uses it, and a column a foreign key holds cannot be renamed.
- A column with a CHECK of its own drops with it. A column a CHECK shares with another cannot be dropped.
- `ADD COLUMN` takes no constraint, so a required column is added, then set `NOT NULL`.
- A primary key can be added to a table that has none. DuckDB drops and changes no key, and adds no foreign key to an existing table, so those are offered only in a new table.
- Partial indexes and descending keys are not offered: DuckDB takes `DESC` in an index key and keeps it ascending (`descending_index_keys`).
- The index of a UNIQUE key is listed with the table's indexes and cannot be removed: DuckDB drops no constraint.
- A foreign key acts only as `NO ACTION`, and names a table in its own schema.

DuckDB names a foreign key itself, `<table>_<columns>_<referenced>_fkey`, whatever the CREATE TABLE called it. A generated column is read from the table's stored SQL, since `duckdb_columns()` reports its expression as a default.

DuckDB matches a foreign key byte for byte and refuses one whose two sides differ in type. A column declared with a `COLLATE` on either side finds other rows with `=` than the key matches, so its key is not followed toward that side (`child_compares_alike`, `parent_compares_alike`). `duckdb_columns()` lists no collation, so it is read from the stored SQL too.

## Editor sessions

- A script is split where DuckDB's parser ends a statement, with nested block comments and `$tag$` strings. Text the splitter cannot finish goes to DuckDB whole, so the error is DuckDB's own.
- A statement's rows stream a chunk at a time, so the row limit stops the read one row past the limit and the set ends with `Truncation::ReadPastLimit`. A row change without `RETURNING` reports its count. What `EXECUTE` and `CALL` return stays rows, since the prepared statement or the function decides it.
- A stop interrupts the statement and keeps the run from starting another; past the cancel grace the tab's connection is given up. So is a transaction state read that runs past the cancel grace or that its caller gives up, and the tab is `Lost`.
- The transaction state after a run comes from `txid_current()`, read twice: it stays the same between two statements only inside an explicit transaction, and an aborted transaction refuses it (`Failed`).
- A temporary table belongs to the tab that made it.

## Exports

DuckDB's indexes do not order a scan, so ORDER BY the key would sort the whole table in memory before the first row is written. An export with no sort of the user's keeps the order of a plain scan, which `preserve_insertion_order` makes the same for an unchanged table (`key_order_sorts_the_table`). With a sort of the user's, DuckDB sorts every row the export selects.

## Values

Integers to 128 bits, decimals at their scale, dates and timestamps to their extremes and infinities, intervals, UUIDs, blobs, bits, JSON and enums read losslessly. `TIMESTAMPTZ` reads in UTC: the bundled build has no ICU, so the session time zone is UTC.

An interval past about 292 years is the exception. DuckDB hands an interval to Arrow in nanoseconds, multiplying its microseconds in 64 bits, which wraps. The driver shows a wrapped value as unreadable; one past about 73,000 years can wrap to a whole number of microseconds and read as another interval.

Lists, arrays, structs, maps and unions read as DuckDB's own text, the text `CAST(... AS VARCHAR)` gives, and are read-only in the grid. DuckDB's text for a UNION names no member and reads back as the first member it fits, so a table tab reads a UNION, or a value holding one, as an editor run does, and a SQL export writes it as a marked `NULL` rather than as that text. A `TIME WITH TIME ZONE` inside one is unreadable there, as in an editor run. `TIME WITH TIME ZONE` loses its offset in DuckDB's Arrow result, so an editor run shows it as unreadable, and a table tab reads it as DuckDB's text. `VARIANT` columns are refused by the storage version a new database gets.

## Extensions

`json` and `parquet` are linked in. No other extension is installed or loaded on its own, so a query that needs one, `httpfs` for an S3 path or `icu` for a time zone name, fails with DuckDB's error instead of a download. `INSTALL` and `LOAD` in an editor tab work as DuckDB documents, from the user's own SQL. The history leaves out `CREATE SECRET`, `ATTACH`, Parquet keys and the settings that hold a credential, whether `SET` or `PRAGMA` sets them.
