# MySQL and MariaDB

Driver id `mysql`, crate `crates/drivers/mysql`. One driver serves both servers through sqlx 0.9 (`mysql`, `mysql-rsa`, `tls-rustls-aws-lc-rs`) with a deadpool 0.13 pool. `MySqlFlavour` tells them apart from `VERSION()` (MariaDB says so in it), because they name their timeouts, error numbers and catalogue columns differently. The integration suite runs against MySQL 8.4 and MariaDB 11.4, and CI runs it again on MySQL 8.0 with MariaDB 10.11 and on MySQL 9.7 with MariaDB 12.3 ([supported servers](../../README.md#supported-servers)). The contract it implements is in [adding-drivers.md](../adding-drivers.md).

A connection needs a database name (`database_required`).

## Connections

| Connection | Used for | Session |
|---|---|---|
| Workspace pool, 4 connections (`WORKSPACE_POOL_MAX_SIZE`) | The sidebar, the grid, counts, saves | Workspace |
| One login per call | `stream_read` (exports), and `probe` when every pool slot is busy | Workspace without a statement timeout, or Control |
| One connection per editor tab | `EditorSession` | Editor |
| One control connection per workspace and per editor session | `KILL QUERY` | Control: nothing changed |

A pool member is handed out again only after it answers a ping within the probe timeout.

## Route

sqlx dials its own sockets and takes no stream, so the driver passes it the transport's route:

- A direct route is the host and port, dialled by sqlx.
- An SSH forward is the Unix socket OpenSSH listens on. sqlx connects to the socket, and its `host` carries the name TLS checks: the service's own, or the override.

Nothing relays bytes in between. The whole login, dial included, is bounded by the connect and login timeouts together (25 s). sqlx 0.9 sets no `TCP_NODELAY` and no keepalive on its own dial, so on a direct route a dead peer is found by the probe and by each call's deadline, not by the kernel.

## Session statements

Every workspace and editor session starts the same way, so a statement means the same thing on each:

```sql
SET NAMES utf8mb4
SET SESSION TRANSACTION READ ONLY                     -- read-only connections only
SET SESSION max_execution_time = 60000                -- MySQL, milliseconds
SET SESSION max_statement_time = 60                   -- MariaDB, seconds
SET SESSION lock_wait_timeout = 10
SET SESSION innodb_lock_wait_timeout = 10
```

- `SET NAMES utf8mb4` names no collation, so the server picks its default for the charset: MySQL's `default_collation_for_utf8mb4`, MariaDB's `character_set_collations`. That is what the mysql client gets too.
- The statement timeout is the workspace's 60 s. MySQL's `max_execution_time` bounds only read-only `SELECT`s; MariaDB's `max_statement_time` bounds every statement, which is why a schema change lifts it (below). An editor session sets it only when the session has a statement timeout of its own.
- Lock waits get the workspace's 10 s, in whole seconds rounded up.
- Numbers are sent as integers, never floats a server could read in another locale.

A workspace session also pins what the app's generated SQL depends on:

- `time_zone = '+00:00'` for reads, so a `TIMESTAMP` reads as the instant it names. UTC repeats no hour, so the read is exact.
- `sql_mode` without `NO_BACKSLASH_ESCAPES`, because generated DDL writes literals such as `COMMENT '...'` that have no hex form.
- `sql_mode` with `STRICT_ALL_TABLES`. Without strict mode the server stores what it can and only warns: a too-long string is cut, an unknown `ENUM` label becomes `''`, a number out of range is clamped, and a column made `NOT NULL` turns its NULLs into `0` or `''`. Strict mode makes each of these an error, so a save, an import or a schema change stores what it was given or fails.

An editor session keeps the server's own zone and `sql_mode`, as the mysql client would.

sqlx's own session statements (`PIPES_AS_CONCAT`, `NO_ENGINE_SUBSTITUTION`, its `SET NAMES`) are turned off. Its time zone is off too, except on a workspace session, where sqlx's `time_zone` option sends the `+00:00` above. Its statement cache is 0 so no prepared statement outlives its call, and its statement logging is off.

### Time zone of a write

A save or a schema change runs in the server's own zone, `@@GLOBAL.time_zone`, and the batch puts `+00:00` back when it ends; a connection where that fails is closed. In UTC, `DATETIME DEFAULT CURRENT_TIMESTAMP` would store UTC wall time, 7 hours off on a `+07:00` server, and an `ALTER` from `DATETIME` to `TIMESTAMP` would shift every value.

- A `TIMESTAMP` value binds as its UTC wall time inside `CONVERT_TZ(?, '+00:00', @@session.time_zone)`, which does nothing on a read and gives the server's wall time on a write.
- In the hour a daylight-saving zone repeats, one wall time names two instants and the server picks one, so a key compared there can match the other row. Before a write sends anything, each instant it binds goes to the server's zone and back; one that changes refuses the batch. A zone written as an offset (`+07:00`) skips the check.
- A `TIMESTAMP` column's constant default is read from `SHOW CREATE TABLE` and converted to the server's zone, so a `MODIFY` restates the same instant. MySQL's `COLUMN_DEFAULT` keeps the text in the zone of whoever last altered the table, so it is not used for this.

`crates/drivers/mysql/src/server_zone.rs` has the reasoning.

## TLS

- `Disable` connects without TLS. A server with `require_secure_transport` answers with error 3159, reported as `ServerRequiresTls`. MariaDB before 11.2 answers 1045, Access denied, as it does for a wrong password ([MDEV-30178](https://jira.mariadb.org/browse/MDEV-30178)), so on 10.11 the refusal reads as an authentication failure.
- `Require` encrypts without checking the certificate. A server that does not offer TLS is reported as `ServerRefusedTls`.
- `VerifyFull` is sqlx's `VerifyIdentity`. It trusts the system's CA store and the connection's CA file, which sqlx takes only as PEM, so the driver hands it both as one bundle; sqlx adds the Mozilla roots compiled into it ([Trust](../../ARCHITECTURE.md#trust)). `Require` checks no certificate, so it loads neither.
- The name checked is the host sqlx dials, so a server name override works only through an SSH forward, where the dial goes to a socket path (`ServerNameOverride::SshForwardOnly`).
- A client certificate and key are sent when set, for `REQUIRE X509` logins.
- With TLS off, the password is safe only from a passive observer. `caching_sha2_password` encrypts it with an RSA key the server sends in band, which nothing authenticates. sqlx 0.9 also takes the login plugin the first handshake names without checking it against `enable_cleartext_plugin`, which it checks only on an auth switch, so a man in the middle can ask for `mysql_clear_password` and receive the password in clear. The mysql client refuses both by default (`--enable-cleartext-plugin`, `--get-server-public-key`). sqlx has no option to refuse either, so the driver cannot: on a network you do not trust, use TLS.

## Stops and timeouts

A stop is `KILL QUERY <connection id>` on the control connection, which reaches the server over the same route as the connection it stops. The id comes from `CONNECTION_ID()` at login. It names the connection, not the statement: `StopDelivery::OutOfBand(StopScope::Connection)`. A pool connection goes back to the pool only when the server confirmed the stop (the statement ended with 1317, or with the server's own timeout after the `KILL` landed) and the `KILL` itself finished; a call stopped between statements also gives up its connection, since a `KILL` may be on its way to it. Error 1094 (no such thread) counts as delivered: there was nothing left to stop. A control connection the server closed since the last stop, at its `wait_timeout` or a restart, is replaced and the `KILL` sent again.

| Server answer | Reported as |
|---|---|
| 1317 | `Cancelled`, or `Timeout { server_cancelled: true }` when the deadline asked for it |
| 3024 (MySQL), 1969 (MariaDB) | `Timeout { phase: Statement, server_cancelled: true }` |
| 1205 | `Timeout { phase: LockWait }` |
| 1792 | `ReadOnly(ServerRejected)` |
| 1045 | `Auth` |
| 1040 | `Busy(NoFreeConnection)` |
| 3159 | `Tls { failure: ServerRequiresTls }` |
| 1053, 1927 (MariaDB), 4031 (MySQL) | `ConnectionLost` |

A call that timed out or lost its connection is checked before the link is declared lost, as [adding-drivers.md](../adding-drivers.md#deciding-that-the-link-is-lost) describes, with the `KILL` as the stop and a login of its own as the check.

### Through ProxySQL

`KILL QUERY` stops the server thread `CONNECTION_ID()` named at login. Behind a proxy that multiplexes client connections over server connections, as ProxySQL does by default, the client may not be on that thread any more, and the `KILL` can miss or stop another client's statement. The driver has no proxy detection. What it does guarantee: a stop counts as confirmed only when the statement itself reported it, and a connection whose stop was not confirmed within the cancel grace is closed, so the app never claims a cancel that did not happen. Point TablePro at a ProxySQL user or query rule with multiplexing off, or at the server directly.

## Read-only

`ReadOnlyEnforcement::SessionDefault`: `SET SESSION TRANSACTION READ ONLY` on every session. Saves are refused before anything is sent, and a write through generated SQL fails with 1792. At Safe Mode Read-Only the app refuses every editor statement that does not read before it is sent, `SET TRANSACTION READ WRITE` included; a function a `SELECT` calls is the server's to refuse. For a guarantee, connect with a login that has no write privileges.

An export, on any connection, runs in `START TRANSACTION READ ONLY` and refuses user SQL that Safe Mode would not count as a read (`tablepro_core::sql_syntax::statement_access`). The text protocol runs every statement a text holds, so user SQL is first prepared, which the server parses with multiple statements off: a text it reads as two fails there, and one it parses but does not prepare (1295, such as some `SHOW`) still runs.

Safe Mode reads text every way the client or a server may read it, and the strictest reading stands (`tablepro_core::sql_syntax::script::ScriptPlan::server_readings`):

- A `/*!`, `/*!NNNNN` or `/*M!` comment as MySQL up to 8.0, MySQL 8.1 and later, MariaDB and a MariaDB Galera node run or skip it, at every version the text names. A comment that runs is code up to the first `*/` outside a string, a quoted name or a line comment. One that a version skips ends at the first `*/` past one nested `/* */`. MySQL reads `/*M!` as a plain comment, MariaDB skips `/*!50700` to `/*!99999`, and Galera runs `/*!99997`.
- `$tag$ ... $tag$` as a quote, as MySQL 8.1 and later read it.
- A `DELIMITER` line as SQL, since only a client reads it as a directive.
- With backslash escapes on and off, `"` as a name (ANSI_QUOTES), and `[name]` as a name (MariaDB's MSSQL mode).
- Whole, and as each piece a `DELIMITER` line cuts it into, since the editor and the driver send those apart.

Text with more readings than are worth lexing before a run, 16 versions or about 32 MiB of lexing in all, counts as destructive.

## Writes

Whether a write can be undone depends on the table's storage engine, not on the server. Before a row change the driver reads the table's engine and whether that engine supports transactions (`information_schema.TABLES` joined to `ENGINES`):

| Change | Engine | How it runs |
|---|---|---|
| Row changes | Transactional (InnoDB) | One transaction. A failure rolls back. |
| Row changes | Not transactional (MyISAM, MEMORY, ARCHIVE, CSV, MariaDB's Aria), or a view | Every probe first, then statement by statement. Each statement lands on its own, and the `WriteLedger` reports how far it got. |
| Schema changes | Any | Statement by statement: each DDL statement commits on its own. |

- An exact row guard relies on `CLIENT_FOUND_ROWS`, which sqlx turns on: an `UPDATE` reports the rows it matched, also the ones it left unchanged.
- On a non-transactional table, a statement whose connection drops before its answer may have run, so it is reported as unknown, not as refused.
- A trigger on an InnoDB table can write into a non-transactional one. A `ROLLBACK` then leaves those rows, and the server says so with warning 1196. The driver reads `SHOW WARNINGS` after every rollback, and a 1196 makes the outcome `PartiallyApplied` instead of `RolledBack`. A MySQL server that enforces GTID consistency, as 9.7 does by default, refuses such a save with 1785 before anything lands, and it reads as `RolledBack`.
- MariaDB's `max_statement_time` would stop a long `ALTER` the way it stops a `SELECT`, so a schema change on MariaDB lifts it for the batch and puts it back after. A connection where it cannot be put back is closed. MySQL's bound covers only `SELECT`.
- Every step is prepared, also one with no parameters, so a stray `;` in generated SQL fails instead of running a second statement. The prepared statement is closed after it runs. A step with no parameters that the server cannot prepare (error 1295, such as `CREATE TRIGGER`) is sent again over the text protocol.
- MySQL cannot suspend foreign keys for one batch, so a batch that asks for it is refused before anything is sent.
- There is nothing to ask the server about a lost `COMMIT` (`CommitResolutionSupport::Unavailable`). `CommitOutcomeUnknown` carries no token, and the user reloads to see what landed.

## Table options

The structure tab edits a table's default character set and collation, converts every column to them, sets the next AUTO_INCREMENT value, and picks a column's own character set and collation (`column_collations`, `table_options`).

| Read | Source |
|---|---|
| Default character set and collation | `information_schema.TABLES.TABLE_COLLATION`, which is live on both servers. The character set is the collation's first word. |
| Next AUTO_INCREMENT, MySQL | The options line of SHOW CREATE TABLE. `TABLES.AUTO_INCREMENT` is cached for up to a day (`information_schema_stats_expiry`). |
| Next AUTO_INCREMENT, MariaDB | `TABLES.AUTO_INCREMENT`, which is live. `NO_TABLE_OPTIONS`, part of `sql_mode = ORACLE`, prints SHOW CREATE TABLE without its options line. |
| Character sets | `information_schema.CHARACTER_SETS`, with collations from `COLLATIONS`, or on MariaDB 10.10 and later from `COLLATION_CHARACTER_SET_APPLICABILITY.FULL_COLLATION_NAME`, told apart by that column. MariaDB lists a UCA 14 collation such as `utf8mb4_uca1400_ai_ci` in `COLLATIONS` once, with no character set. |

- Neither server prints AUTO_INCREMENT= while the counter is 1, so a table with an AUTO_INCREMENT column and no clause reads as 1, and one without such a column has no counter.
- A view and an NDB table carry no options, so `table_capabilities` turns them off.
- A new default is `DEFAULT CHARACTER SET = cs COLLATE = coll` in the combined ALTER. Both clauses always go: a character set alone resets the collation to its default. Existing columns keep theirs, and a column added in the same ALTER takes the new one.
- A convert, `CONVERT TO CHARACTER SET cs COLLATE coll`, is a statement of its own after the `DROP FOREIGN KEY` and before the combined ALTER. A foreign key on a converted column refuses it (MySQL 3780, MariaDB 1832), and so can an index the wider characters make too long (1071), so a save that drops indexes or columns runs those drops in an ALTER ahead of the convert.
- A convert can widen a type, as a latin1 `TEXT` becomes `MEDIUMTEXT` in utf8mb4, and a MODIFY after it restates the old one. It also converts a primary key before a change in the same save moves it, which can push the key past the 3072-byte index limit. So a convert refuses a change to an existing column or to the primary key in the same save, and the tab says so before Save. Columns added in the same save come after it and take its pair unless the user picked one.
- The review lists a convert, and a column given another character set, as destructive.
- The counter is `AUTO_INCREMENT = n` in the combined ALTER. A counter set before a MODIFY that turns AUTO_INCREMENT on is lost, in the same ALTER it is kept. The server raises a value at or below the largest key to that key plus one, without a warning, so the tab reads the table again after a save.
- A column takes CHARACTER SET and COLLATE only when its type holds text: `CHAR`, `VARCHAR`, the `TEXT` types, `ENUM` and `SET`, in any spelling the type parser takes, such as `character varying(64)` or `VARCHAR (64)`. A national spelling (`NCHAR`, `NVARCHAR`) refuses CHARACTER SET, so none is written for it.
- A restated `ON UPDATE CURRENT_TIMESTAMP`, and a `CURRENT_TIMESTAMP` default as the catalogue read it, take the precision of the column's type, since MySQL refuses any other (1294, 1067). A default the user typed goes as written.

## Editor sessions

- The editor sends one statement per run. Text with several statements is split where the mysql client splits it, at each `;` or at the delimiter a `DELIMITER` line sets, and goes one statement per round trip. Sent whole, the server starts each next statement as soon as the last one's result is written, read or not, so a stop could not keep it from running. A `/*!` or `/*M!` comment is code to the split, as it is to the mysql client, so each `/*!40101 ... */;` line of a dump is a statement of its own and a `/*!50100 PARTITION BY ... */` stays with its table.
- Text without `DELIMITER` lines goes as written, as the server's own batch, when it holds one statement, or when only the server can tell where its statements end: a statement that does not open with a word known to start one with no body, such as a stored program or a compound statement, a `/*!` comment, or text the session's `sql_mode` reads its own way (a backslash in a string, `[name]`, `$$` quotes).
- The row limit is `SET SESSION sql_select_limit = <limit + 1>`, sent when the limit changes. The server stops a plain `SELECT` there, and the set ends with `Truncation::ServerStopped` and no total. A `SELECT` with a `LIMIT` of its own, or one inside a routine, is read to its end: the rows past the limit are counted, never decoded, and the set ends with `Truncation::ReadPastLimit` and its total. A set that ends exactly one row past the limit reads as `ServerStopped` either way.
- A stop sends `KILL QUERY` on the session's own control connection and gives the statement the cancel grace to end, and nothing after it is sent, whatever the `KILL` did. A statement that has not ended by then ends the session, because its answer is still on the way, and so does a `KILL` that has not answered, because it may still land on whatever runs next. The row limit's `SET` is watched the same way.
- A run stopped at its deadline reads as `TimedOut { server_cancelled: true }` only when the statement ended with 1317 or the server's own timeout. A bare `SELECT SLEEP(n)` the `KILL` stopped returns 1 with no error, so it reads as `false`.
- When the grid stops reading, the run sends the same `KILL QUERY` and ends as cancelled. The statement already sent is read to its end, unshown, and nothing after it is sent.
- sqlx describes a result column by its type alone, with no fractional digits and no BIT length. A run shows a DATETIME(6) holding `12:00:00.5` as `12:00:00.5` and a BIT(1) in the whole byte it arrived in, `00000001`. A table tab and its export take both from the catalogue and show `12:00:00.500000` and `1`.
- The transaction state after each run comes from `@@in_transaction` on MariaDB and from `performance_schema.events_transactions_current` on MySQL. On MySQL before 8.0.16, with `performance_schema` off, or for a login that cannot read it, the state is `Unknown`, and the tab's close guard warns instead of guessing.
