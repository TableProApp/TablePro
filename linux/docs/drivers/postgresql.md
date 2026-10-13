# PostgreSQL

Driver id `postgres`, crate `crates/drivers/postgres`. It runs on tokio-postgres 0.7.18 with postgres-types and postgres-protocol, deadpool-postgres 0.14.2 for the pool and tokio-postgres-rustls 0.14 for TLS, all from crates.io ([ADR 0016](../decisions/0016-driver-contract-v2.md)). The integration suite runs against PostgreSQL 17, with the catalogue also checked on 13 and 18. The contract it implements is in [adding-drivers.md](../adding-drivers.md).

## Connections

| Connection | Used for | Opened |
|---|---|---|
| Workspace pool, 4 connections (`WORKSPACE_POOL_MAX_SIZE`) | The sidebar, the grid, counts, saves | The first at connect, the rest on demand |
| One connection per call | `stream_read` (exports), and `probe` when every pool slot is busy | For that call, closed after it |
| One connection per editor tab | `EditorSession` | When the tab first runs SQL |
| One stream per stop | The cancel request | For that request |

Every connection logs in with `Config::connect_raw` over a stream from the transport, so a direct route and an SSH forward behave the same. The login sends only the user, the password, the database, `application_name = TablePro` and `channel_binding = prefer`, under the 15 s login timeout. Startup options are never used: a transaction pooler refuses parameters it does not track.

## TLS

- `Disable` sends no SSLRequest. `Require` and `VerifyFull` both send it and refuse to continue in plaintext; they differ only in the certificate check.
- `VerifyFull` trusts the system store plus the connection's CA file ([Trust](../../ARCHITECTURE.md#trust)), and checks the name from `NetworkTarget::tls_server_name()`.
- A client certificate is offered when one is set, for `cert` authentication in `pg_hba.conf`.
- A server that answers the SSLRequest with `N` is reported as `ServerRefusedTls`, never as a certificate problem: the TLS connector records whether the handshake started.
- SCRAM channel binding (`tls-server-end-point`) is preferred, never required. It is used when the server's certificate is signed with RSA (SHA-1 to SHA-512) or ECDSA with SHA-256 or SHA-384. With any other signature, such as Ed25519 or ECDSA with SHA-512, tokio-postgres-rustls has no hash to bind with, and the login goes ahead without binding.

## Workspace calls

Each read is one pipelined flight on a pool connection: the transaction, the work and the COMMIT go out together and the answers come back in one round trip.

```sql
START TRANSACTION READ ONLY; SET LOCAL statement_timeout = <ms>; SET LOCAL lock_timeout = 10000
-- the call's statement
COMMIT
```

- Reads always run in a `READ ONLY` transaction, also on a read-write connection.
- `statement_timeout` is the nearer of the call's deadline and the workspace's 60 s. `lock_timeout` is 10 s, so a blocked edit reports the lock instead of a generic timeout.
- `SET LOCAL` ends with the transaction, so nothing is left on a server connection a pooler shares.
- Generated SQL runs on the unnamed statement (`query_typed_raw`, `execute_typed`) with typed parameters. Nothing is prepared under a name.
- A connection whose flight did not end with an acknowledged COMMIT or ROLLBACK is taken out of the pool, because deadpool's recycle check (`RecyclingMethod::Verified`) passes inside a half-finished transaction.
- A read that returns no rows still has its columns: the statement runs once more as a subquery right-joined to one row on a false condition, in a read-only transaction of its own.
- A column of a type tokio-postgres does not know (an enum, `citext`, a domain) would make it prepare a type lookup under a name. Pages project such columns as text, so a read never does.

`probe` takes a pool slot without waiting; when every slot is busy it opens a connection of its own and runs `SELECT 1`. `stream_read` opens a connection of its own, runs `START TRANSACTION READ ONLY` with no statement timeout, and refuses user SQL that would end that transaction (transaction control, `CALL`, `DO`) before sending anything.

## Stops and timeouts

A stop is PostgreSQL's cancel request (`CancelToken::cancel_query_raw`) over a new stream from the transport, so it goes through the SSH forward too. It names the backend, not the statement: `StopDelivery::OutOfBand(StopScope::Connection)`. The connection it chases goes back to the pool only when the server answered with SQLSTATE 57014 and the cancel request itself finished; otherwise the connection is closed, because a late cancel request would stop the next caller's statement.

| Server answer | Reported as |
|---|---|
| 57014 after our cancel request | `Cancelled`, or `Timeout { server_cancelled: true }` when the deadline asked for it |
| 57014 with "statement timeout" | `Timeout { phase: Statement, server_cancelled: true }` |
| 55P03 | `Timeout { phase: LockWait }` |
| 25006 | `ReadOnly(ServerRejected)` |
| 28P01, 28000 | `Auth` |
| 53300 | `Busy` |
| 57P01, 57P02, 57P03 | `ConnectionLost` |

A call that timed out or lost its connection is checked before the link is declared lost: a cancel request that never got through means the route is gone, one the server answered means it is not, and otherwise a connection of its own answers within the cancel grace.

## Read-only

`ReadOnlyEnforcement::SessionDefault`. Read-only is a property of each transaction the driver opens, never a session setting:

- Workspace reads run in `READ ONLY` transactions, and saves are refused before anything is sent (`ReadOnly(ClientGuard)`).
- In the editor, a statement run outside a transaction is wrapped in `START TRANSACTION READ ONLY` and `COMMIT`. After the user's own `BEGIN`, the driver sends `SET TRANSACTION READ ONLY`.
- A statement that cannot run inside a transaction block, such as `VACUUM`, fails inside the wrapper with 25001 and is reported as refused by read-only mode. `PREPARE TRANSACTION`, `COMMIT PREPARED` and `ROLLBACK PREPARED` are refused before sending.
- `SET default_transaction_read_only = off` does not escape, because each transaction is opened read-only explicitly.
- A user's own `SET TRANSACTION READ WRITE` inside their transaction can still lift it. For a guarantee, connect with a role that cannot write.

## Writes

`WriteAtomicity::Transactional` for row and schema changes. A save is one transaction:

1. `START TRANSACTION READ WRITE` with `SET LOCAL lock_timeout` of 10 s and `SET LOCAL statement_timeout` of 60 s for row changes, 0 (none) for schema changes. A schema change stays bounded by the call's deadline and cancel.
2. Each step: its probe, if any; then the statement with `execute_typed`; then the affected-row check.
3. The transaction id, `pg_current_xact_id()` (or `txid_current()` before PostgreSQL 13), read before COMMIT.
4. `COMMIT`.

A COMMIT the server answers with an error (a deferred constraint, a serialization failure) rolled back. A COMMIT that gets no answer is `CommitOutcomeUnknown` with `CommitToken::PostgresXid`, and `resolve_commit` asks `pg_xact_status` (or `txid_status`):

| Status | `CommitResolution` |
|---|---|
| `committed` | `Applied` |
| `aborted` | `NotApplied` |
| `in progress` | `StillRunning` |
| NULL, the record aged out of the commit log | `Unresolvable` |

PostgreSQL cannot suspend foreign keys, so a batch that asks for it is refused before anything is sent.

### Row identity

The grid names a row by, in order: the primary key; a valid unique index with no predicate and no expressions over `NOT NULL` columns; or, for a table or a materialised view with neither, the row's physical address. The address is `ctid` with `xmin`, plus `tableoid` for a partitioned table, where a `ctid` is unique only within one partition. `xmin` is bound as `$n::xid`: after `VACUUM` a freed `ctid` can hold a new row, and `xmin` makes a save against the old row match nothing instead of the new one. Anything else is read-only in the grid.

## Editor sessions

An editor tab runs SQL the way psql does:

- The script is split on the client with the PostgreSQL grammar and sent one statement per message, stopping at the first failure. When a statement changes `standard_conforming_strings`, the rest of the script is split again with the new rule.
- No session-level `SET` is ever sent. The run's deadline and the session's statement timeout are enforced with cancel requests, and nothing new goes to the server until an outstanding cancel request has finished. A statement that has not ended by the end of the cancel grace ends the session.
- Notices (`RAISE NOTICE`, warnings) arrive as `ResultEvent::Notice`.
- `COPY FROM STDIN` and `COPY TO STDOUT` are refused with `Unsupported`.
- Result columns are text: the simple protocol gives a column no type, so every value arrives as `Value::Text`. Typed columns wait on rust-postgres #1358.

### The row limit

A statement that returns rows (`SELECT`, `VALUES`, `TABLE`, `WITH`, or one that opens with a parenthesis) is read through a cursor, so a result larger than the limit stops on the server:

```sql
BEGIN                                -- or START TRANSACTION READ ONLY, or SAVEPOINT tablepro_cursor_savepoint in the user's transaction
DECLARE tablepro_cursor NO SCROLL CURSOR FOR
<the statement>
FETCH FORWARD <limit + 1> FROM tablepro_cursor
CLOSE tablepro_cursor
COMMIT                               -- or RELEASE SAVEPOINT tablepro_cursor_savepoint
```

- One row past the limit tells a full result from a cut one. A cut result has `total_rows: None`.
- Each step goes as its own message, so a trailing `--` comment in the statement cannot swallow the `FETCH`.
- A `DECLARE` the server refuses because the statement cannot be a cursor (a data-modifying `WITH`: 0A000; `SELECT INTO`: 42601) is rolled back to the savepoint or out of the driver's transaction, and the statement runs again as a plain statement. Inside the user's transaction any other failure aborts their transaction, as it would without the limit.
- Error positions are corrected for the `DECLARE` prefix, so they count from the start of the user's statement.
- A cursor plans for its first rows (`cursor_tuple_fraction`, 0.1 by default) and never uses a parallel plan, so a statement can run with a different plan than in psql.

### Transaction state

tokio-postgres drops the transaction status the server sends with every ReadyForQuery, so the driver follows it from what each statement was and whether it succeeded, under PostgreSQL's own rules. Where the rules leave it open (`CALL` and `DO`, which can commit inside, `COMMIT AND CHAIN`, a failed `COMMIT`, and after any stop) it asks the server:

```sql
SAVEPOINT tablepro_probe          -- succeeds inside a transaction, then RELEASE SAVEPOINT tablepro_probe
                                  -- 25P01 outside a transaction, 25P02 in an aborted one
```

Outside a transaction this probe fails by design, and the server logs it as an ERROR line (25P01). `RunSummary::transaction_state` is never `Unknown` on PostgreSQL.

## Connection poolers

The driver works behind PgBouncer in transaction pooling with `max_prepared_statements = 0`: it prepares nothing under a name and sets nothing on the session. The integration suite runs against `edoburu/pgbouncer` in all three modes (`tests/integration/pgbouncer.rs`).

| PgBouncer `pool_mode` | Workspace | Editor |
|---|---|---|
| `session` | Works | Works, including the user's own `SET`, temporary tables and prepared statements across runs |
| `transaction` | Works | Each statement and each transaction works. A `SET`, a temporary table or a `PREPARE` lasts only until the user's transaction ends: the next statement may reach another server connection, and a session-level `SET` stays behind for whoever gets that one next. Use session pooling for those. |
| `statement` | Unsupported: reads and saves run in transaction blocks, which the pooler refuses, and a save fails with the pooler's message | Unsupported: the cursor flight is a transaction block |

Cancel requests go to the pooler like any other connection, and PgBouncer forwards them to the server connection the client is using.
