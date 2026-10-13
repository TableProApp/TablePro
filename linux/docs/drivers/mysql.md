# MySQL and MariaDB

Driver id `mysql`, crate `crates/drivers/mysql`. One driver serves both servers through sqlx 0.9 (`mysql`, `mysql-rsa`, `tls-rustls-aws-lc-rs`) with a deadpool 0.13 pool. `MySqlFlavour` tells them apart from `VERSION()` (MariaDB says so in it), because they name their timeouts, error numbers and catalogue columns differently. The integration suite runs against MySQL 8.4 and MariaDB 11.4. The contract it implements is in [adding-drivers.md](../adding-drivers.md).

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

A workspace session also pins two things the app's generated SQL depends on: `time_zone = '+00:00'`, so a `TIMESTAMP` reads as the instant it names, and `sql_mode` without `NO_BACKSLASH_ESCAPES`, because generated DDL writes literals such as `COMMENT '...'` that have no hex form. An editor session keeps the server's own zone and `sql_mode`, as the mysql client would.

sqlx's own session statements (`PIPES_AS_CONCAT`, `NO_ENGINE_SUBSTITUTION`, its `SET NAMES`, its time zone) are turned off, its statement cache is 0 so no prepared statement outlives its call, and its statement logging is off.

## TLS

- `Disable` connects without TLS. A server with `require_secure_transport` answers with error 3159, reported as `ServerRequiresTls`.
- `Require` encrypts without checking the certificate. A server that does not offer TLS is reported as `ServerRefusedTls`.
- `VerifyFull` is sqlx's `VerifyIdentity`. It trusts the system's CA store and the connection's CA file, which sqlx takes only as PEM, so the driver hands it both as one bundle; sqlx adds the Mozilla roots compiled into it ([Trust](../../ARCHITECTURE.md#trust)). `Require` checks no certificate, so it loads neither.
- The name checked is the host sqlx dials, so a server name override works only through an SSH forward, where the dial goes to a socket path (`ServerNameOverride::SshForwardOnly`).
- A client certificate and key are sent when set, for `REQUIRE X509` logins.
- With TLS off, `caching_sha2_password` sends the password encrypted with the server's RSA key, never in clear text, also over an SSH forward's socket.

## Stops and timeouts

A stop is `KILL QUERY <connection id>` on the control connection, which reaches the server over the same route as the connection it stops. The id comes from `CONNECTION_ID()` at login. It names the connection, not the statement: `StopDelivery::OutOfBand(StopScope::Connection)`. A pool connection goes back to the pool only when the server confirmed the stop (the statement ended with 1317, or with the server's own timeout after the `KILL` landed) and the `KILL` itself finished; a call stopped between statements also gives up its connection, since a `KILL` may be on its way to it. Error 1094 (no such thread) counts as delivered: there was nothing left to stop.

| Server answer | Reported as |
|---|---|
| 1317 | `Cancelled`, or `Timeout { server_cancelled: true }` when the deadline asked for it |
| 3024 (MySQL), 1969 (MariaDB) | `Timeout { phase: Statement, server_cancelled: true }` |
| 1205 | `Timeout { phase: LockWait }` |
| 1792 | `ReadOnly(ServerRejected)` |
| 1045 | `Auth` |
| 1040 | `Busy` |
| 3159 | `Tls { failure: ServerRequiresTls }` |
| 1053, 1927 (MariaDB), 4031 (MySQL) | `ConnectionLost` |

A call that timed out or lost its connection is checked before the link is declared lost: a `KILL` that never got through means the route is gone, one the server answered means it is not, and otherwise a login of its own answers within the cancel grace.

### Through ProxySQL

`KILL QUERY` stops the server thread `CONNECTION_ID()` named at login. Behind a proxy that multiplexes client connections over server connections, as ProxySQL does by default, the client may not be on that thread any more, and the `KILL` can miss or stop another client's statement. The driver has no proxy detection. What it does guarantee: a stop counts as confirmed only when the statement itself reported it, and a connection whose stop was not confirmed within the cancel grace is closed, so the app never claims a cancel that did not happen. Point TablePro at a ProxySQL user or query rule with multiplexing off, or at the server directly.

## Read-only

`ReadOnlyEnforcement::SessionDefault`: `SET SESSION TRANSACTION READ ONLY` on every session. Saves are refused before anything is sent, a write through generated SQL fails with 1792, and an export runs in `START TRANSACTION READ ONLY` and refuses SQL that does not start with `SELECT`, `WITH`, `SHOW`, `DESCRIBE`, `DESC`, `EXPLAIN` or `TABLE`. In the editor, the user's own `SET TRANSACTION READ WRITE` or `SET SESSION TRANSACTION READ WRITE` lifts it. For a guarantee, connect with a login that has no write privileges.

## Writes

Whether a write can be undone depends on the table's storage engine, not on the server. Before a row change the driver reads the table's engine and whether that engine supports transactions (`information_schema.TABLES` joined to `ENGINES`):

| Change | Engine | How it runs |
|---|---|---|
| Row changes | Transactional (InnoDB) | One transaction. A failure rolls back. |
| Row changes | Not transactional (MyISAM, MEMORY, ARCHIVE, CSV, MariaDB's Aria), or a view | Every probe first, then statement by statement. Each statement lands on its own, and the `WriteLedger` reports how far it got. |
| Schema changes | Any | Statement by statement: each DDL statement commits on its own. |

- An exact row guard relies on `CLIENT_FOUND_ROWS`, which sqlx turns on: an `UPDATE` reports the rows it matched, also the ones it left unchanged.
- On a non-transactional table, a statement whose connection drops before its answer may have run, so it is reported as unknown, not as refused.
- A trigger on an InnoDB table can write into a non-transactional one. A `ROLLBACK` then leaves those rows, and the server says so with warning 1196. The driver reads `SHOW WARNINGS` after every rollback, and a 1196 makes the outcome `PartiallyApplied` instead of `RolledBack`.
- MariaDB's `max_statement_time` would stop a long `ALTER` the way it stops a `SELECT`, so a schema change on MariaDB lifts it for the batch and puts it back after. A connection where it cannot be put back is closed. MySQL's bound covers only `SELECT`.
- A statement with parameters is prepared and closed after it runs; one without goes over the text protocol, which accepts statements MySQL cannot prepare, such as `CREATE TRIGGER`.
- MySQL cannot suspend foreign keys for one batch, so a batch that asks for it is refused before anything is sent.
- There is nothing to ask the server about a lost `COMMIT` (`CommitResolutionSupport::Unavailable`). `CommitOutcomeUnknown` carries no token, and the user reloads to see what landed.

## Editor sessions

- The editor sends one statement per run. Text with several statements runs as the server's own multi-statement batch over the text protocol, except that mysql-client `DELIMITER` lines split it where the client would, because the server does not know the directive.
- The row limit is `SET SESSION sql_select_limit = <limit + 1>`, sent when the limit changes. The server stops a plain `SELECT` there, and the set ends with `Truncation::ServerStopped` and no total. A `SELECT` with a `LIMIT` of its own, or one inside a routine, is read to its end: the rows past the limit are counted, never decoded, and the set ends with `Truncation::ReadPastLimit` and its total.
- A stop sends `KILL QUERY` on the session's own control connection and gives the statement the cancel grace to end. A statement that has not ended by then ends the session, because its answer is still on the way.
- When the grid stops reading, the run ends as cancelled with no `KILL`, and sqlx reads the rest of the result off the wire before the next statement.
- The transaction state after each run comes from `@@in_transaction` on MariaDB and from `performance_schema.events_transactions_current` on MySQL. On MySQL before 8.0.16, with `performance_schema` off, or for a login that cannot read it, the state is `Unknown`, and the tab's close guard warns instead of guessing.
