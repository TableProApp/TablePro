# Adding a database driver

Every engine is one crate under `crates/drivers/`, linked into the app at compile time and registered in one place. There is no plugin system ([ADR 0001](decisions/0001-no-plugin-system.md)). The contract a driver implements lives in `tablepro-core` and is described here; [ADR 0016](decisions/0016-driver-contract-v2.md) records why it has this shape. How each shipped engine meets it: [PostgreSQL](drivers/postgresql.md), [MySQL and MariaDB](drivers/mysql.md), [SQLite](drivers/sqlite.md), [SQL Server](drivers/sql-server.md), [ClickHouse](drivers/clickhouse.md).

The work, in order:

1. Choose the client library.
2. Create the crate.
3. Implement `DatabaseDriver` and its capabilities.
4. Implement `Connection` on `OwnedCalls`.
5. Write saves through a `WriteLedger`.
6. Implement `EditorSession`.
7. Implement `SqlDialect`, and `DdlDialect` where the app edits the engine's structure.
8. Register the driver.
9. Add a container fixture, the conformance suites and the engine's own tests.
10. Write the engine's page in `docs/drivers/`.

## 1. The client library

The library must:

- be maintained and published on crates.io, used without a fork ([ADR 0005](decisions/0005-supply-chain-policy.md)); `deny.toml` allows no git source;
- use rustls with aws-lc-rs, or no TLS of its own ([ADR 0009](decisions/0009-crypto-provider-and-sources.md));
- either take a stream the driver hands it, or dial a TCP endpoint and a Unix socket path itself, because an SSH forward is a Unix socket ([Transports](../ARCHITECTURE.md#transports));
- have a way to stop a statement already sent: a cancel request, a KILL, an attention, an interrupt;
- let the driver keep a connection clean for the next caller, with no server-side state it did not ask for.

What the shipped drivers use:

| Engine | Client | Pool | Reaches the server through |
|---|---|---|---|
| PostgreSQL | tokio-postgres 0.7.18, tokio-postgres-rustls 0.14 | deadpool-postgres 0.14.2 | `Transport::open` |
| MySQL, MariaDB | sqlx 0.9 (`mysql`) | deadpool 0.13 | `Transport::route`, dialled by sqlx |
| SQLite | sqlx 0.9 (`sqlite-unbundled`) | sqlx, one connection | a file path |
| SQL Server | tiberius 0.13 | deadpool 0.13 | `Transport::open` |
| ClickHouse | clickhouse 0.15 over hyper-util and hyper-rustls | hyper's connection pool | `Transport::open` |

Open an issue before starting an engine that is not listed, and say which library and why.

## 2. The crate

`crates/drivers/<engine>/`, package `tablepro-driver-<engine>`, library `drivers_<engine>`:

```toml
[package]
name = "tablepro-driver-<engine>"
edition.workspace = true
rust-version.workspace = true
license.workspace = true
publish = false

[lib]
name = "drivers_<engine>"
path = "src/lib.rs"

[dependencies]
tablepro-core = { path = "../../core" }
tablepro-net = { path = "../../net" }
async-trait.workspace = true
tokio = { workspace = true, features = ["macros", "rt", "sync", "time"] }
tokio-util = { workspace = true, features = ["rt"] }
tracing.workspace = true

[dev-dependencies]
tablepro-test-fixtures = { path = "../../test-fixtures" }
tablepro-test-support = { path = "../../test-support" }
tokio = { workspace = true, features = ["macros", "rt-multi-thread", "test-util"] }

[lints]
workspace = true
```

A driver depends on `tablepro-core`, and on `tablepro-net` when it speaks TLS or dials TCP. It never depends on GTK, on `tablepro-session`, on `tablepro-ssh` or on another driver. Add the crate to `members` in `linux/Cargo.toml`.

## 3. `DatabaseDriver` and capabilities

```rust
#[async_trait]
pub trait DatabaseDriver: Send + Sync {
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    fn capabilities(&self) -> &'static DriverCapabilities;
    async fn connect(
        &self,
        options: ConnectOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn Connection>, DriverError>;
}
```

`id()` is written into saved connections and never changes once shipped. The ids in use are `postgres`, `mysql`, `sqlite`, `mssql` and `clickhouse`.

### Capabilities

`DriverCapabilities` is a `static` the driver returns before any connection exists. The connect dialog and `DriverConnector` read `endpoint`, `auth_modes`, `tls`, `read_only` and `database_required`. The conformance suites hold `endpoint`, `dml_writes` and the TLS client certificate flag to what the engine does.

| Field | Meaning |
|---|---|
| `endpoint` | `Network { default_port }` or `File`. A file engine gets a path row instead of host, port, TLS and SSH. |
| `auth_modes` | The `AuthMode`s the driver can log in with. `Kerberos` only where `connect` maps it to a real integrated login. |
| `tls` | `TlsCapabilities`: the `TlsMode`s offered, whether a CA file and a client certificate are accepted, and where a server name override works (`ServerNameOverride`). `None` for an engine with no TLS. |
| `read_only` | How a read-only connection is held: `EngineEnforced` (the engine refuses every write), `SessionDefault` (a statement can lift it) or `LoginPrivileges` (only the login's grants hold). The connect dialog says which one the user gets. |
| `dml_writes`, `ddl_writes` | `WriteAtomicity` of row changes and of schema changes: `Transactional` or `StatementByStatement`. |
| `script_execution` | `NativeBatch` (the engine runs a script) or `SingleStatement` (one statement per run). |
| `commit_resolution` | How an unanswered commit can be resolved: `ServerTransactionStatus`, `QueryLog` or `Unavailable`. |
| `row_count_estimate` | `Statistics` ("about N"), `ExactMetadata` or `Unavailable`. |
| `object_kinds` | The `ObjectKind`s the sidebar can list. |
| `database_required` | Whether a connect without a database name is refused before anything is opened. |

The shipped drivers:

| | PostgreSQL | MySQL | SQLite | SQL Server | ClickHouse |
|---|---|---|---|---|---|
| `endpoint` | 5432 | 3306 | `File` | 1433 | 8123 |
| `auth_modes` | Password | Password | none | Password, Kerberos | Password |
| TLS modes | all three | all three | none | all three | all three |
| CA file | yes | yes | | yes | yes |
| Client certificate | yes | yes | | no | yes |
| Server name override | `AnyRoute` | `SshForwardOnly` | | `AnyRoute` | `AnyRoute` |
| `read_only` | `SessionDefault` | `SessionDefault` | `EngineEnforced` | `LoginPrivileges` | `EngineEnforced` |
| `dml_writes` | `Transactional` | `Transactional` | `Transactional` | `Transactional` | `StatementByStatement` |
| `ddl_writes` | `Transactional` | `StatementByStatement` | `Transactional` | `Transactional` | `StatementByStatement` |
| `script_execution` | `NativeBatch` | `NativeBatch` | `NativeBatch` | `NativeBatch` | `SingleStatement` |
| `commit_resolution` | `ServerTransactionStatus` | `Unavailable` | `Unavailable` | `Unavailable` | `QueryLog` |
| `row_count_estimate` | `Statistics` | `Statistics` | `Statistics` | `Statistics` | `ExactMetadata` |
| `database_required` | no | yes | no | no | no |

SQL Server offers Kerberos only when built with the `kerberos` feature. MySQL's `dml_writes` is what InnoDB gives; the driver reads each table's storage engine before a save and writes statement by statement on one that cannot roll back.

### Connecting

`ConnectOptions` has no default, so a connection opened with a made-up host or timeout does not compile:

- `target`: `ConnectTarget::Network(NetworkTarget)` or `ConnectTarget::File(FileEndpoint)`. A driver refuses the kind it does not serve with `DriverError::Unsupported`.
- `workspace_settings`: `WorkspaceSettings` with `read_only`, `statement_timeout` (60 s) and `lock_timeout` (10 s).
- `liveness`: `LivenessPolicy::DESKTOP` in the app; the conformance suite uses shorter values.
- `environment`: `ConnectEnvironment` with the app's version, sent next to `APPLICATION_NAME` where the protocol has room.

A `NetworkTarget` carries `transport`, `credentials`, `database` and `tls`. `connect`:

1. validates `tls` with `TlsConfig::validate(caps, transport.kind().class())` and refuses `Credentials` whose mode the driver does not support;
2. builds its TLS from `tls` (see [Trust](../ARCHITECTURE.md#trust)) and checks the certificate against `NetworkTarget::tls_server_name()`, never against the socket's address;
3. opens every stream with `transport.open()`, or dials `transport.route()` when the library dials itself;
4. logs in under `liveness.login_timeout`, with `APPLICATION_NAME` as the client name;
5. opens the first pool member before returning, so a refused password or a failed handshake is the connect's error, and gives up as soon as `cancel` fires;
6. reads `ServerInfo` and builds the dialect for that server version.

A `ConnectionLost` during login goes through `Transport::explain_closed_stream`, which turns "the stream closed" into "the SSH master exited" where that is what happened.

## 4. `Connection`

The `Connection` is a workspace's link to one server: the pool behind the sidebar, the grid and every save. Every call takes `CallOptions`, a deadline and a `CancellationToken` that travel together: a deadline with no cancel leaves the server working after the app gave up, and a cancel with no deadline hangs on a server that never answers.

| Method | Contract |
|---|---|
| `server_info`, `dialect`, `read_only` | Fixed at connect. |
| `link_state`, `lost` | A `LinkWatch` shared by every call. `lost()` resolves when the link is gone: a failed probe, or a failed call that a check outside the pool confirmed. One dead backend in the pool does not resolve it, so the session monitor can act on it. |
| `probe` | Whether the server answers. It never waits for a pool slot: with every slot busy it opens a connection of its own. |
| `list_schemas`, `list_objects`, `fetch_columns`, `fetch_indexes`, `fetch_foreign_keys`, `fetch_table_definition`, `row_identity`, `table_estimate` | Catalogue reads. `fetch_table_definition` reads columns, keys and dependents in one call so they come from the same moment. |
| `query_bound` | A generated read that keeps at most `limit` rows and reads one more to set `truncated`. |
| `count_rows` | A generated count. |
| `stream_read` | Every row of a read into a `ResultSink`, with no row limit, on a connection of its own, held read-only for its whole length. |
| `write_batch` | A save, refused before anything is sent on a read-only connection or when it asks to suspend foreign keys on an engine that cannot. |
| `resolve_commit` | What became of a commit whose answer never arrived. |
| `open_editor_session` | A tab's own connection, which outlives this one. |
| `close` | Stops every call and releases the pool. Idempotent, and never closes an editor session. |

### `OwnedCalls`

Dropping a future does not stop a server. Each call runs on a task the connection owns through `OwnedCalls::run_read` or `run_write`:

```rust
self.calls
    .run_read(options, PgCall::new(), stop.clone(), move |mut call, request| async move {
        if let Err(error) = call.acquire(&pool, &timeouts, &request, &work_stop).await {
            return (call, Err(error));
        }
        let result = flight(&call, &begin, op).await;
        (call, result)
    })
    .await
```

- The work gets the `CallResource` and a `StopRequest`, and hands the resource back with its result.
- The supervisor races the work against the caller's cancel, the deadline and `close`. The first one to fire sets the `StopReason` (`Cancelled`, `DeadlineElapsed`, `Shutdown`) on the request.
- Dropping the caller's future is a cancel: the call keeps running on its task until the stop has settled.
- After a stop the work has `LivenessPolicy::cancel_grace` (5 s) to finish. Past it the call is abandoned: the resource's abandon flag is set, a read returns `ConnectionLost`, and a write returns what its `WriteLedger` saw.
- An error the engine raised to acknowledge the stop reads as what asked for it: `Cancelled`, or `Timeout { phase: Statement, server_cancelled: true }`.

Start the resource empty and fill it inside the work, as `PgCall::acquire` and `MysqlCall::acquire` do, so the deadline and the cancel cover the wait for a pool slot. Arm the engine stop once a connection is held, then check `StopRequest::is_requested` again: a stop asked for in between sent nothing.

### `EngineStop` and `StopDelivery`

`EngineStop` is the engine's own way of stopping work already sent:

- `delivery()` says how the stop reaches the server. `OutOfBand(StopScope::Statement)` names the statement, so it cannot land on anything else. `OutOfBand(StopScope::Connection)` names the connection, so a late one can hit whatever that connection runs next. `InBand` means the running request carries it and the work sends it itself.
- `stop()` sends an out-of-band stop. `OwnedCalls` calls it at most once and polls it ahead of the work, since work waiting on the server cannot finish until the server has been told.
- `acknowledged(error)` says whether an error is the engine confirming the stop.

| Engine | Stop | Delivery |
|---|---|---|
| PostgreSQL | Cancel request over a new stream from the transport (`CancelToken::cancel_query_raw`) | `OutOfBand(Connection)` |
| MySQL | `KILL QUERY <connection id>` on a control connection over the same route | `OutOfBand(Connection)` |
| SQLite | The call's flag, read by a progress handler every 1,000 VM instructions | `OutOfBand(Statement)` |
| SQL Server | TDS attention on the request's own connection (`Client::cancel_query`) | `InBand` |
| ClickHouse | `KILL QUERY WHERE query_id = ? ASYNC` on a sessionless client | `OutOfBand(Statement)` |

### `CallResource` release rules

`CallResource` is the connection one call holds: `abandon_flag()` is what the pool's recycle and the resource's `Drop` read, and `discard()` takes the connection out of its pool and closes it. After the work returns:

| Stop delivery | The call was stopped | Released to the pool when | Otherwise |
|---|---|---|---|
| `OutOfBand(Connection)` | yes | the engine acknowledged the stop and the stop itself settled | discarded |
| any | no, or not connection-scoped | the result is not `ConnectionLost` | discarded |
| any | abandoned past the grace | never | the abandon flag is set and the resource drops out of the pool |

A connection-scoped stop holds its connection until it settles because it names the connection, not the statement: released early, a cancel request still in flight would stop the next caller's statement on that connection. `OwnedCalls` waits for the stop up to the end of the grace. A stop that has not settled by then, or that the server never acknowledged, costs the connection rather than risking someone else's statement.

The driver adds its own rules on top. PostgreSQL taints a call whose transaction did not end with an acknowledged COMMIT or ROLLBACK, because deadpool's recycle check passes inside a half-finished transaction. MySQL taints a call stopped between statements, since a `KILL` may be on its way to an idle connection. SQL Server discards a connection whose attention was not acknowledged at a token boundary.

### Deciding that the link is lost

A call that times out or loses its connection may have met a dead route or only a dead backend. Each network driver decides in its `settle`: a stop that never got through means the route is gone; one the server answered means it is not; otherwise a connection of its own answers within the cancel grace. Only a confirmed loss marks the `LinkWatch` lost and turns a statement timeout into `ConnectionLost`.

## 5. Writes and the `WriteLedger`

A `WriteBatch` is a `WriteKind` (`RowChanges` or `SchemaChanges`), the `TableRef` it changes, the `GuardedStatement` steps and a `ForeignKeyMode`. A row change runs under the workspace statement timeout where the engine can stop one safely; a schema change never does. Both stay bounded by the call's deadline and cancel.

Each step is a statement and a `RowGuard`: `None`, `AffectedExactly(n)`, or `ProbeExactly { probe, rows }`, which counts the rows with a `SELECT` before the statement runs. A mismatch means the row is not the one that was loaded, and the batch stops with `RowGuardFailed`. An engine that cannot report an affected count refuses `AffectedExactly` with `GuardUnsupported` before anything is sent.

The work records each step as it goes:

```rust
ledger.statement_sending(index);
let affected = execute(step).await?;
ledger.statement_confirmed(index);
// after the last step
ledger.commit_sending(Some(token));
```

`WriteLedger::stop_permitted` holds the engine's stop while it would turn a knowable outcome into an unknown one: on a `Transactional` engine once COMMIT is on the wire, on a `StatementByStatement` engine while a statement is in flight.

When a write is interrupted, `WriteLedger::interrupted(cause, fate)` gives the outcome from what was sent and from `SessionFate` (`RolledBack`, `Discarded`, `RollbackIncomplete { executed }`):

| Atomicity | How far it got | Outcome |
|---|---|---|
| `Transactional` | COMMIT sent | `CommitOutcomeUnknown { token }` |
| `Transactional` | COMMIT not sent, session rolled back or discarded | `RolledBack` at the statement in flight or the next one |
| `Transactional` | COMMIT not sent, rollback incomplete | `PartiallyApplied { applied: executed }` |
| `StatementByStatement` | nothing in flight, nothing confirmed | `RolledBack` at statement 0 |
| `StatementByStatement` | nothing in flight, some confirmed | `PartiallyApplied { applied: confirmed }`, the next statement `Failed` |
| `StatementByStatement` | one in flight, and nothing confirmed or a commit token held | `CommitOutcomeUnknown { token }` |
| `StatementByStatement` | one in flight, some confirmed, no token | `PartiallyApplied { applied: confirmed }`, that statement `Unknown` |

A discarded session leaves nothing behind on a transactional engine, because a COMMIT that was never written cannot land once the session is gone. `WriteLedger::failed` and `WriteLedger::guard_failed` give the outcome of a statement the server refused and of a guard mismatch, with the same rules. The full table is the `outcome_table` test in `crates/core/src/write_ledger.rs`.

A transactional COMMIT that the server answers with an error rolled back; only a COMMIT with no answer is `CommitOutcomeUnknown`.

### `resolve_commit`

Where the engine can answer later, the ledger carries a `CommitToken`:

- `PostgresXid { xid, legacy_txid }`: `pg_current_xact_id()` (or `txid_current()` before PostgreSQL 13), read inside the transaction before COMMIT, and asked back with `pg_xact_status` (or `txid_status`).
- `ClickHouseQuery { query_ids, first_unconfirmed }`: the query id of every statement, looked up in `system.query_log`.

`resolve_commit` answers with a `CommitResolution`: `Applied`, `NotApplied`, `PartiallyApplied`, `StillRunning` or `Unresolvable`. Where `commit_resolution` is `Unavailable`, SQL Server and SQLite answer `Unresolvable` and MySQL returns `Unsupported`. The app reports `CommitOutcomeUnknown` as unknown and asks the user to reload; it does not call `resolve_commit` yet.

## 6. `EditorSession`

An editor tab holds one session for as long as it is open, because the state a user builds there lives on that connection and nowhere else: an open transaction, a temporary table, a session setting.

- It is never pooled and never reopened behind the user's back. A lost connection is `EditorSessionState::Lost`, and the tab opens a new session on its next run.
- One run at a time: a second `run` fails with `EditorSessionBusy`.
- `run(sql, options, sink)` takes `UserSql` as typed and `RunOptions`: `row_limit`, `deadline` and `cancel`. Dropping the caller is a cancel.
- The app's editor splits a script with the engine's grammar and sends one statement per run, or one `GO` batch on SQL Server. A driver still runs whatever text it is given, a whole script included.
- A statement the server refused ends the run with `RunEnd::Failed` in the `RunSummary`; an `Err` from `run` means the session itself failed.
- `RunSummary` carries `elapsed`, the `RunEnd` (`Completed`, `Failed`, `Cancelled`, `TimedOut { server_cancelled }`) and the `TransactionState` after the run. `Unknown` is an answer of its own: the tab's close guard warns instead of guessing.
- `close` stops a running statement, then closes the connection within `close_timeout`.

### `ResultSink` and backpressure

A run streams `ResultEvent`s into a `ResultSink`:

- `ResultSetStarted { columns }` opens a result set.
- `ColumnsResolved { set_index, columns }` replaces the columns of a set whose types the driver could only learn from its rows (SQLite).
- `Rows` carries a batch of rows, 256 in the shipped drivers.
- `RowLimitReached { retained }` comes once per set, when the limit is passed.
- `ResultSetFinished { retained, total_rows, truncation }` closes the set. `Truncation` is `Complete`, `ServerStopped` or `ReadPastLimit`, and `total_rows` is `None` when the driver did not read the rest.
- `CommandCompleted { rows_affected }` reports a statement that returned no rows; `None` is "not reported", not zero.
- `Notice` passes on a server notice or warning.

`ResultSink::accept` is awaited before the next rows are read off the wire, so a grid that cannot keep up slows the read instead of growing a queue the size of the result. `SinkFlow::ConsumerGone` ends the run with `RunEnd::Cancelled`, and the driver stops the statement on the server where the engine has a stop for it. `stream_read` uses the same sink and events, without a row limit.

## The row-limit rule

`RowLimit` wraps a `NonZeroU64`; `RowLimit::EDITOR_DEFAULT` is 10,000.

- `query_bound` keeps at most the limit and reads one more row to mark the result truncated.
- An editor run keeps at most the limit in each result set, sends `RowLimitReached` once, and ends the set with `Truncation::ReadPastLimit`. Where the engine allows, the rest of the set is stopped on the server rather than read: a `FETCH` of one row past the limit (PostgreSQL), `sql_select_limit` (MySQL), `KILL QUERY` (ClickHouse). SQLite stops stepping, so the rest is never produced. Otherwise the rows past the limit are counted without being decoded (SQL Server, and MySQL where `sql_select_limit` does not apply).
- The limit never ends the script, the user's transaction or the statements after the limited one. The conformance case `row_limit_keeps_transaction_and_later_statements` checks this on every engine with editor transactions.
- The driver never rewrites the user's SQL to add a `LIMIT`.
- `stream_read` has no limit.

## 7. Dialects

`Connection::dialect()` returns the engine's `SqlDialect`, built from `ServerInfo` at connect. Every builder in `tablepro-core` (pages, filters, row edits, exports) goes through it: quoting, placeholders, literals, the page window, keyset comparison, the engine's row address and type parsing. A dialect never reads session state. `SqlDialect::ddl()` returns the engine's `DdlDialect`, or `None` where the app does not edit the engine's structure. Never match on a driver id in core; add a dialect method.

## 8. Registration

Add the crate to `crates/app/Cargo.toml` and register it in `build_registry` in `crates/app/src/lib.rs`:

```rust
fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(drivers_clickhouse::ClickhouseDriver));
    r.register(Arc::new(drivers_mssql::MssqlDriver));
    r.register(Arc::new(drivers_mysql::MysqlDriver));
    r.register(Arc::new(drivers_postgres::PgDriver));
    r.register(Arc::new(drivers_sqlite::SqliteDriver));
    r
}
```

Without this step the crate compiles and the app never offers it.

## 9. Tests

The layout every driver follows:

- Unit tests next to the code, for pure logic: the dialect, error mapping, decoders, statement classification.
- `tests/integration/main.rs` with one module per topic: `support.rs` (start a fixture, connect, run), `conformance_engine.rs`, `tls.rs` for a network engine, and the engine's own behaviour (`metadata.rs`, `write_batch.rs`, `cancellation.rs` and so on). A network engine's test starts its own container and is `#[ignore = "requires docker"]`.
- A container fixture in `crates/test-fixtures` for anything the default image cannot do: TLS from the generated PKI, a second principal that logs in with a client certificate.

The conformance suites are the contract's own tests. The driver's `conformance_engine.rs` implements `ConformanceEngine` and the engine traits its flags need, then invokes:

```rust
tablepro_test_support::connection_conformance_suite! {
    engine: PgEngine,
    docker: true,
    endpoint: network,
    pool: pooled,
    editor_transactions: true,
    unsupported_types: true,
    bounded_ddl: true,
}

tablepro_test_support::tls_conformance_suite! {
    engine: PgTlsEngine,
    client_identity: true,
}
```

The cases cover listing and identity, deadlines within the cancel grace, a cancelled editor run, a dropped caller stopping the server's statement, a lost transport, a busy pool's probe, read-only refusal, write atomicity, row guards, the row limit, unbounded schema changes, streaming in bounded batches, type fallback and every TLS mode. [testing.md](testing.md#conformance) lists them with their flags. `suite_flags_match_driver_capabilities` runs without Docker and fails when a flag disagrees with the driver's capabilities, so a case cannot be skipped by declaring less.

Behaviour the suites do not cover gets a test of its own against the real engine: the engine's stop, its error mapping, what a pooler does to it, each write outcome the ledger can produce.

For a new package with Docker tests, add a test group and override in `.config/nextest.toml` and an entry in the `integration` matrix of `.github/workflows/build-linux.yml`. Run them one package at a time:

```bash
cargo nextest run --locked --profile ci -p tablepro-driver-<engine> --run-ignored only
```

## Checklist

- [ ] The client library is on crates.io, unforked, and uses aws-lc-rs.
- [ ] `capabilities()` matches what the engine does; the suite flags agree.
- [ ] Every stream comes from the transport, and TLS checks `tls_server_name()`.
- [ ] Every call runs under `OwnedCalls` with the engine's stop, and a connection-scoped stop never releases an unsettled connection.
- [ ] `probe` never waits for a pool slot; `stream_read` never holds one.
- [ ] Saves record every step in a `WriteLedger`, and the stop is held while a commit is in flight.
- [ ] Editor sessions are one connection per tab, one run at a time, with `ResultSink` backpressure and the row-limit rule.
- [ ] Errors map to `DriverError` by the engine's code ([error-handling.md](error-handling.md)).
- [ ] Registered in `build_registry`; added to the workspace and to `crates/app/Cargo.toml`.
- [ ] Both conformance suites run; the CI matrix and nextest groups include the package.
- [ ] A page in `docs/drivers/` covers timeouts, stops, read-only, writes, trust and the engine's limits.
- [ ] `cargo clippy --all-targets -- -D warnings` passes with and without default features.
