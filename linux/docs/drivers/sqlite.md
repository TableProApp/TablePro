# SQLite

Driver id `sqlite`, crate `crates/drivers/sqlite`. It runs on sqlx 0.9 with `sqlite-unbundled`, so it links the system's libsqlite3 rather than a second copy, and calls `libsqlite3-sys` directly twice: `sqlite3_get_autocommit`, until sqlx exposes a connection's transaction state, and `sqlite3_busy_handler`, so a stop reaches a statement waiting for a lock. The library must be SQLite 3.37.0 or newer (`SQLITE_MIN_VERSION`), which the driver checks when it opens the file. The contract it implements is in [adding-drivers.md](../adding-drivers.md).

There is no network, login or TLS: the target is a `FileEndpoint`, an absolute path with a `FileOpenMode`.

## Opening a file

Every connection to the file opens with the same options:

- The path is a file name, never a URI, so `?` and `%41` in it are part of the name.
- A missing file is `FileNotFound`; the driver never creates one by accident (`create_if_missing` is off).
- A read-only connection opens the file with `SQLITE_OPEN_READONLY`.
- `busy_timeout` is the workspace's lock timeout, 10 s: how long SQLite waits for another connection's lock before it reports `Busy(FileLocked)`. A call replaces it with a busy handler that waits as long and also ends at a stop ([Stops and timeouts](#stops-and-timeouts)).
- `foreign_keys = ON`, and `trusted_schema = OFF`, so a view or trigger in a file from elsewhere cannot run SQL functions with side effects.
- The statement cache is off, because sqlx keeps a statement's columns from its first prepare and SQLite prepares it again with more columns after an `ALTER TABLE`.
- sqlx's statement logging is off.
- A file DuckDB has open in the app is `Busy(FileLocked)`, and an `ATTACH` of one is refused by an authorizer every connection installs: SQLite would close the file again on finding no database in it, which drops the POSIX locks DuckDB holds on it (`tablepro_core::claimed_by_another`). The authorizer sees a file name the `ATTACH` spells as a string.

The connect reads `sqlite_version()` and counts `sqlite_schema` once, so a file that is not a database fails the connect (`NotADatabase`) rather than the first page. Either statement can be the one that finds out: SQLite 3.51 reads the schema before it compiles a connection's first SELECT, while 3.46 waits for a statement that names a table. SQLite only says it could not open a file; the driver tells a moved file (`FileNotFound`) from one the user may not read (`FileAccessDenied`) by looking at the path.

### New databases

`FileOpenMode::CreateNew` is what the New Database flow sends after the save dialog has asked about replacing a file. The driver writes an empty file next to the target with mode 0600, syncs it, renames it over the path, removes any `-wal`, `-shm` or `-journal` file left beside the old database (it would be replayed into the new one), and syncs the folder so the rename is durable. A reader sees the old file or the new one, never half of one. An existing file is replaced, not refused, unless this process has it open: the rename would pull it out from under the window or the DuckDB database using it, so that is `Busy(FileLocked)`.

A reconnect uses `FileEndpoint::for_reopen`, which is always `OpenExisting`, so reconnecting never empties a database the user just created.

### Where the file lives

SQLite relies on POSIX file locks and, for a database in WAL mode, on shared memory in the `-shm` file beside it. Both work on a local file system. On NFS or SMB, locks can fail without an error, and two writers can then corrupt the file. A FUSE mount may not implement the locks at all. A file chosen through the Flatpak document portal sits on the portal's own FUSE file system, which exposes the chosen file rather than its folder, so the journal and WAL files SQLite keeps beside it may not work there.

The driver does not detect any of these. Open such a file read-only, or copy it to a local folder first. Under the development Flatpak, which grants the home folder, `/media`, `/run/media` and `/mnt`, a file under any of them is opened at its real path, not through the portal.

## Connections

| Connection | Used for |
|---|---|
| One workspace connection (`WORKSPACE_POOL_MAX_SIZE` is 1) | The sidebar, the grid, counts, saves |
| One read-only connection per call | `stream_read` (exports) |
| One connection per editor tab | `EditorSession` |

One workspace connection is enough because SQLite takes one writer at a time anyway, and it keeps a temporary table or an attached database where the next call can see it. Calls wait for it for up to the pool wait (5 s).

The health probe runs `SELECT 1` on the workspace connection when it is free. When it is busy, the probe opens a read-only connection of its own and closes it again without running a statement: opening runs only pragmas that set connection flags, which need no lock, whereas its first SELECT would read the schema on SQLite 3.51 and so wait for any lock another connection holds, often the one the busy call is waiting for too.

## Stops and timeouts

SQLite has no statement timeout and no out-of-band cancel. Each call installs a fresh flag, and a progress handler checks it every 1,000 virtual-machine instructions; when the flag is up the statement ends with `SQLITE_INTERRUPT`. The flag names the call, not the connection, so a stop that arrives late cannot reach the next call: `StopDelivery::OutOfBand(StopScope::Statement)`. `sqlite3_interrupt` is not used, because sqlx's handle to the connection waits for the worker thread to finish its current command, which is the statement the stop was meant for.

A statement waiting for another connection's lock runs no instructions, so each call also installs a busy handler in place of `busy_timeout`. It sleeps the steps SQLite's own would, up to the lock timeout, and gives up as `Busy(FileLocked)` once the flag is up, which reads as the stop.

The workspace statement timeout (60 s) becomes a deadline the flag enforces. The flag is lowered before a rollback runs, so the rollback is never interrupted by the stop that caused it.

| SQLite answer | Reported as |
|---|---|
| 9 (`SQLITE_INTERRUPT`) after our stop | `Cancelled`, or `Timeout { server_cancelled: true }` when the deadline asked for it |
| 5 (`SQLITE_BUSY`) | `Busy(FileLocked)`: another connection held the lock past the lock timeout |
| 6 (`SQLITE_LOCKED`) | `Server`: without a shared cache it is a conflict inside one connection, which no other program causes |
| 8 (`SQLITE_READONLY`) | `ReadOnly(ServerRejected)` |
| 14 (`SQLITE_CANTOPEN`) at open | `FileNotFound`, or `FileAccessDenied` when the file is there |
| 26 (`SQLITE_NOTADB`) at open | `NotADatabase` |
| The workspace connection not free within the pool wait | `Busy(NoFreeConnection)` |

## Read-only

`ReadOnlyEnforcement::EngineEnforced`: the file is opened read-only, so SQLite refuses every write, whatever the SQL (`SQLITE_READONLY`, reported as `ReadOnly(ServerRejected)`). Saves on a read-only connection are refused before anything is sent. Exports always open their connection read-only.

A read-only open still lets SQLite attach another file and write a copy with `VACUUM INTO`, and a pragma such as `foreign_keys` or `hard_heap_limit` changes the connection while SQLite compiles it, `EXPLAIN PRAGMA` included. The connection `stream_read` opens for user SQL (exports and MCP reads) therefore allows no attached database (`SQLITE_LIMIT_ATTACHED` 0), its authorizer denies ATTACH and every pragma but the reporting ones, and the text must prepare to one statement with nothing but comments after it, since sqlx runs every statement a text holds.

## Writes

`WriteAtomicity::Transactional` for row and schema changes. A save is one transaction that starts with `BEGIN IMMEDIATE`, which takes the write lock before the first probe reads anything. Grid saves, structure changes and imports all go through it. Another connection holding the lock shows up in one of two places, each as `Busy(FileLocked)` after the lock timeout, and the file keeps none of the save:

- At `BEGIN IMMEDIATE`, when another connection is writing: the save fails as `Busy(FileLocked)` before anything has run.
- At `COMMIT`, in a file in rollback-journal mode (the default; not WAL), when another connection has a read transaction open: the COMMIT needs the file to itself, so the save fails as `RolledBack` with `Busy(FileLocked)` as its cause. In WAL mode a reader does not hold up a save.

An editor run that writes, a read while another connection holds the file exclusively (in rollback-journal mode, while it commits), and opening such a file wait the same way and fail as `Busy(FileLocked)`. `tests/integration/file_locked.rs` covers each path.

SQLite is the one engine that can suspend foreign keys for a batch (`ForeignKeyMode::SuspendedThenVerified`), which a table rebuild needs for its copy:

1. `PRAGMA foreign_keys = OFF` before `BEGIN`, since the pragma does nothing inside a transaction.
2. `PRAGMA foreign_key_check` on the named tables before the batch and after it.
3. Only violations the batch introduced fail it, and the batch rolls back. A file can hold violations from long before, written while foreign keys were off, and those do not count.
4. `PRAGMA foreign_keys = ON` after the `COMMIT` or `ROLLBACK`.

A `COMMIT` never crosses a network, so nothing is left to resolve afterwards (`CommitResolutionSupport::Unavailable`).

### Row identity

The grid names a row by its primary key, then by a unique index whose columns are all `NOT NULL`, then by `rowid`. A `WITHOUT ROWID` table with neither key, or a table with a column named `rowid` that hides the real one, is read-only in the grid.

## Structure changes

`ALTER TABLE` renames a table or a column, adds a column, and drops one. The DDL dialect uses it where SQLite allows the change: an added column with no key, a constant default, and NOT NULL only with a default; a dropped column that has no key or UNIQUE of its own. Every other change rebuilds the table, following the procedure in [lang_altertable.html](https://www.sqlite.org/lang_altertable.html#otheralter), in one batch under `ForeignKeyMode::SuspendedThenVerified`:

1. Drop the views, and the triggers on other tables, that name the table, since the rename in step 5 checks every one of them.
2. Create `_tablepro_rebuild_<table>` from the stored CREATE TABLE with only the edited parts replaced: a column's type, NULL, DEFAULT and key, the key itself, and the foreign keys added or dropped. A COLLATE, CHECK, generated expression, conflict clause, comment or `WITHOUT ROWID` the edit did not touch stays as it was written. A removed constraint takes the spaces before it but not a newline, which may end a `--` comment.
3. Copy the rows with `INSERT OR ABORT`, so an `ON CONFLICT IGNORE` or `REPLACE` the table declares fails the save rather than dropping a row. Rowids come along unless the table has none or a copied column becomes the rowid. A generated column is computed again.
4. With AUTOINCREMENT on both sides, carry the `sqlite_sequence` mark, so a deleted number is not handed out again.
5. Drop the old table and rename the new one into its place.
6. Make the indexes, triggers and views again from their stored SQL, in the order the schema first made them.
7. Rename columns, then the table, natively, so SQLite carries the new names into every index, trigger, view and foreign key.

Before step 1, inside the same transaction, the plan's `DdlPrecondition` counts what differs from the schema the plan was built from: the table's CREATE TABLE, its own indexes and triggers, the views and triggers elsewhere the rebuild makes again, and the key columns of other tables that point at it. Anything but zero refuses the save as `RowGuardFailed`, since the rebuild would write the table again without that change. The Structure tab then reads the table again on Discard.

The foreign key check covers the rebuilt table and every table whose keys point at it, and fails the save only for a violation the save introduced. Where a column becomes the `INTEGER PRIMARY KEY`, its values become the rowids, so the rebuilt table's violations compare by count rather than by rowid. A rebuild refuses to drop a column that a kept index, CHECK, generated column, foreign key, trigger or view still names; in a trigger on another table, `new.x` and `old.x` are that table's columns and do not count. A table whose CREATE TABLE the reader cannot follow, such as a virtual table, keeps the native changes, offers no foreign key or key change, and refuses the rest as `UnreadableDefinition`.

SQLite always numbers its rowid column, a lone `INTEGER PRIMARY KEY` not declared `PRIMARY KEY DESC` on the column itself, and takes AUTOINCREMENT only there. So numbering turns off only together with a change of the column's type or of the key (`AlwaysNumbered` otherwise), and a column that keeps AUTOINCREMENT keeps the type `INTEGER` (`NotAnInteger`).

SQLite's pragmas do not report a foreign key's constraint name, so the definition reads it from the CREATE TABLE text, and a key declared without one is named `fk_<table>_<n>` after its position.

## Definitions

The sidebar lists every schema's triggers, each with the table it fires on. A trigger's definition is its text from `sqlite_schema`, which SQLite stores without the schema before the trigger's name. For a trigger in an attached or temporary schema the driver puts it back (`CREATE TRIGGER "archive".audit ...`), so the text run from any tab makes the trigger where it was: the table after `ON` takes the trigger's schema.

## Editor sessions

- A script is split where SQLite itself would end a statement, so the semicolons inside a trigger body do not end it. Text the splitter cannot finish, such as an unterminated string, goes to SQLite whole, so the error is SQLite's own. The splitter is tested against `sqlite3_complete` (`tests/script_plan_matches_sqlite3_complete.rs`).
- Each statement is prepared first, so a `SELECT` that finds nothing still has its columns. A column with no declared type gets its type from the first row, sent as `ResultEvent::ColumnsResolved`.
- The row limit stops the read one row past the limit, and the set ends with `Truncation::ReadPastLimit`. SQLite computes a row only when it is stepped, so the rest of the result is never produced.
- A stop raises the run's flag and gives the statement the cancel grace to notice it; past that its read is dropped. The flag reaches a statement only every 1,000 instructions, so the run also reads it before each statement and starts none after a stop. A run stopped between statements reads as `Cancelled`, or `TimedOut { server_cancelled: false }` at its deadline.
- The transaction state after a run comes from `sqlite3_get_autocommit`.
