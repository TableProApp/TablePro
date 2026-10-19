# Adding a database driver

Every engine is one crate under `crates/drivers/`, linked into the app at compile time and registered in one place. There is no plugin system ([ADR 0001](decisions/0001-no-plugin-system.md)). The contract a driver implements lives in `tablepro-core` and is described here; [ADR 0016](decisions/0016-driver-contract-v2.md) records why it has this shape. How each shipped engine meets it: [PostgreSQL](drivers/postgresql.md), [MySQL and MariaDB](drivers/mysql.md), [SQLite](drivers/sqlite.md), [SQL Server](drivers/sql-server.md), [ClickHouse](drivers/clickhouse.md).

The work, in order:

1. Choose the client library.
2. Create the crate.
3. Implement `DatabaseDriver` and its capabilities.
4. Implement `Connection` on `OwnedCalls`.
5. Write saves through a `WriteLedger`.
6. Implement `EditorSession`.
7. Implement `SqlDialect`, and `DdlDialect` where the app edits the engine's structure (section 7).
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

`crates/drivers/<engine>/`, package `tablepro-driver-<engine>`, library `tablepro_driver_<engine>`:

```toml
[package]
name = "tablepro-driver-<engine>"
edition.workspace = true
rust-version.workspace = true
license.workspace = true
publish.workspace = true

[dependencies]
tablepro-core.workspace = true
tablepro-net.workspace = true
async-trait.workspace = true
secrecy.workspace = true
tokio = { workspace = true, features = ["rt"] }
tokio-util.workspace = true
tracing.workspace = true

[dev-dependencies]
tablepro-test-fixtures.workspace = true
tablepro-test-support.workspace = true
tokio = { workspace = true, features = ["test-util"] }

[lints]
workspace = true
```

A driver depends on `tablepro-core`, and on `tablepro-net` when it speaks TLS or dials TCP. `secrecy` reads the password of a password login. It never depends on GTK, on `tablepro-session`, on `tablepro-ssh` or on another driver. Add the crate to `members` and to `[workspace.dependencies]` in `linux/Cargo.toml`. A member lists only the features its workspace entry does not already name.

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

`DriverCapabilities` is a `static` the driver returns before any connection exists. The connect dialog and `DriverConnector` read `endpoint`, `auth_modes`, `tls`, `read_only` and `database_required`, and the structure review reads `ddl_writes`. The conformance suites hold `endpoint`, `dml_writes`, `ddl_writes`, `commit_resolution` and the TLS client certificate flag to what the engine does. Nothing reads `script_execution`, `row_count_estimate` or `object_kinds` yet: set them to what the engine does.

| Field | Meaning |
|---|---|
| `endpoint` | `Network { default_port }` or `File`. A file engine gets a path row instead of host, port, TLS and SSH. The picker's file subtitle and opening a file from Files look for the id `sqlite` (`is_sqlite` in `crates/app/src/services/saved_connection_object.rs`, `file_driver` in `crates/app/src/ui/session_window/resolve_file_identity.rs`), so a second file engine changes those too. |
| `auth_modes` | The `AuthMode`s the driver can log in with. `Kerberos` only where `connect` maps it to a real integrated login. |
| `tls` | `TlsCapabilities`: the `TlsMode`s offered, whether a CA file and a client certificate are accepted, and where a server name override works (`ServerNameOverride`). `None` for an engine with no TLS. |
| `read_only` | How a read-only connection is held: `EngineEnforced` (the engine refuses every write), `SessionDefault` (a statement can lift it) or `LoginPrivileges` (only the login's grants hold). The connect dialog says which one the user gets. |
| `dml_writes`, `ddl_writes` | `WriteAtomicity` of row changes and of schema changes: `Transactional` or `StatementByStatement`. |
| `script_execution` | `NativeBatch` (a run takes a whole script) or `SingleStatement` (one statement per run). |
| `commit_resolution` | How an unanswered commit can be resolved: `ServerTransactionStatus`, `QueryLog` or `Unavailable`. |
| `row_count_estimate` | `Statistics` ("about N"), `ExactMetadata` or `Unavailable`. |
| `object_kinds` | The `ObjectKind`s `list_objects` returns. |
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
- In `run_read`, an error the engine raised to acknowledge the stop reads as what asked for it: `Cancelled`, or `Timeout { phase: Statement, server_cancelled: true }`. `run_write` passes the work's result through, so a write maps an acknowledged stop itself, as `acknowledged_stop` does in the PostgreSQL driver's `write_batch.rs` and the SQL Server driver's `cancel.rs`.

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

The driver adds its own rules on top, and its engine page says which: [PostgreSQL](drivers/postgresql.md#workspace-calls), [MySQL](drivers/mysql.md#stops-and-timeouts), [SQL Server](drivers/sql-server.md#stops-and-timeouts).

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

An engine with no COMMIT hands its token over with `ledger.attach_token(token)` before the first statement, as the ClickHouse driver does.

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

A discarded session leaves nothing behind on a transactional engine, because a COMMIT that was never written cannot land once the session is gone. `WriteLedger::failed` and `WriteLedger::guard_failed` give the outcome of a statement the server refused and of a guard mismatch, with the same rules. The full tables are the `a_lost_transaction_rolls_back_until_its_commit_is_sent` and `a_lost_statement_by_statement_write_keeps_what_was_confirmed` tests in `crates/core/src/write_ledger.rs`.

A transactional COMMIT that the server answers with an error rolled back; only a COMMIT with no answer is `CommitOutcomeUnknown`.

### `resolve_commit`

Where the engine can answer later, the ledger carries a `CommitToken`:

- `PostgresXid { xid, legacy_txid }`: `pg_current_xact_id()` (or `txid_current()` before PostgreSQL 13), read inside the transaction before COMMIT, and asked back with `pg_xact_status` (or `txid_status`).
- `ClickHouseQuery { query_ids, first_unconfirmed, table }`: the query id of every statement, looked up in `system.query_log`, and the table they write, which finds a mutation in `system.mutations`.

`resolve_commit` answers with a `CommitResolution`: `Applied`, `NotApplied`, `PartiallyApplied`, `StillRunning` or `Unresolvable`. A commit the engine keeps no record of is `Unresolvable`, never an error, so where `commit_resolution` is `Unavailable` (MySQL, SQL Server, SQLite) every answer is `Unresolvable`.

After a save ends in `CommitOutcomeUnknown` with a token, the workspace asks `resolve_commit` once (`crates/app/src/workspace/workspace_handle.rs`). `Applied` reads as saved, `NotApplied` as rolled back and `PartiallyApplied` as partly applied. `StillRunning`, `Unresolvable` or a failed question leave the outcome unknown, and the user reloads to see what landed.

## 6. `EditorSession`

An editor tab holds one session for as long as it is open, because the state a user builds there lives on that connection and nowhere else: an open transaction, a temporary table, a session setting.

- `open_editor_session` takes `EditorSessionOptions`, whose `statement_timeout` bounds each statement when set.
- It is never pooled and never reopened behind the user's back. `state()` is `Ready`, `Running` or `Lost`. A lost connection is `EditorSessionState::Lost`, and the tab opens a new session on its next run.
- One run at a time: a second `run` fails with `EditorSessionBusy`.
- `transaction_state(options)` answers what the session holds now, outside a run.
- `run(sql, options, sink)` takes `UserSql` as typed and `RunOptions`: `row_limit`, `deadline` and `cancel`. A caller stops a run through `RunOptions::cancel`.
- A dropped caller is a cancel. The run goes on a task of its own, or an actor's, and `run` arms `options.cancel.clone().drop_guard()` until the outcome arrives, so the stop still goes out and the session settles to `Ready` or `Lost`. `MysqlEditorSession::run` is the shape to copy.
- The app's editor splits a script with the engine's grammar and sends one statement per run, or one `GO` batch on SQL Server. A driver still runs whatever text it is given, a whole script included.
- A statement the server refused ends the run with `RunEnd::Failed` in the `RunSummary`; an `Err` from `run` means the session itself failed.
- `RunSummary` carries `elapsed`, the `RunEnd` (`Completed`, `Failed`, `Cancelled`, `TimedOut { server_cancelled }`) and the `TransactionState` after the run. `Unknown` is an answer of its own: the tab's close guard warns instead of guessing.
- `close` stops a running statement, then closes the connection within `close_timeout`.

### `ResultSink` and backpressure

A run streams `ResultEvent`s into a `ResultSink`:

- `ResultSetStarted { columns }` opens a result set.
- `ColumnsResolved { set_index, columns }` replaces the columns of a set whose types the driver could only learn from its rows (SQLite).
- `Rows` carries a batch of rows, 256 in the shipped drivers.
- `RowLimitReached { retained }` comes once per set, before `ResultSetFinished`.
- `ResultSetFinished { retained, total_rows, truncation }` closes the set. `Truncation` is `Complete`, `ServerStopped` or `ReadPastLimit`, and `total_rows` is `None` when the driver did not read the rest.
- `CommandCompleted { rows_affected }` reports a statement that returned no rows; `None` is "not reported", not zero.
- `Notice` passes on a server notice or warning.

`ResultSink::accept` is awaited before the next rows are read off the wire, so a grid that cannot keep up slows the read instead of growing a queue the size of the result. `SinkFlow::ConsumerGone` ends the run with `RunEnd::Cancelled`. PostgreSQL, MySQL, SQL Server and ClickHouse then stop the statement on the server, and SQLite stops stepping it. `stream_read` uses the same sink and events, without a row limit.

## The row-limit rule

`RowLimit` wraps a `NonZeroU64`; `RowLimit::EDITOR_DEFAULT` is 10,000.

- `query_bound` keeps at most the limit and reads one more row to mark the result truncated.
- An editor run keeps at most the limit in each result set and sends `RowLimitReached` once. A set the server cut at one row past the limit ends with `Truncation::ServerStopped` and no `total_rows`: PostgreSQL reports it when its cursor stopped the set, MySQL when `sql_select_limit` did. A set read past the limit ends with `Truncation::ReadPastLimit`. Where the engine allows, the rest of the set is stopped on the server rather than read: a `FETCH` of one row past the limit (PostgreSQL), `sql_select_limit` (MySQL), `KILL QUERY` (ClickHouse). SQLite stops stepping, so the rest is never produced. Otherwise the rows past the limit are counted without being decoded (SQL Server, and MySQL where `sql_select_limit` does not apply).
- The limit never ends the script, the user's transaction or the statements after the limited one. The conformance case `row_limit_keeps_transaction_and_later_statements` checks this on every engine with editor transactions.
- The driver never rewrites the user's SQL to add a `LIMIT`.
- `stream_read` has no limit.

## 7. Dialects

`Connection::dialect()` returns the engine's `SqlDialect`, built from `ServerInfo` at connect. Every builder in `tablepro-core` (pages, filters, row edits, exports) goes through it: quoting, placeholders, literals, the page window, keyset comparison, the engine's row address and type parsing. A dialect never reads session state. `SqlDialect::ddl()` returns the engine's `DdlDialect`, or `None` where the app does not edit the engine's structure. Never match on a driver id in core; add a dialect method.

`SqlDialect::grammar()` names the engine's `SqlGrammar`, which the editor's split and completion, filter and default validation, and the history check read. `SqlGrammar` is closed: an engine with its own lexical rules adds a variant, and the compiler lists every match to extend, starting with its rules in `crates/core/src/sql_syntax/script/script_rules.rs`. Each rule gets a named case in `crates/core/tests/script_corpus.rs` ([testing.md](testing.md#the-script-planner)). An engine with its own error numbering adds a `ServerCode` variant the same way ([error-handling.md](error-handling.md#serverdiagnostics)).

`SqlDialect::history_recording` says whether SQL the user ran may go into the query history. Implement it as `classify_for_history(<grammar>, &CREDENTIAL_RULES, sql)`, with a `CredentialRules` const next to the dialect naming the engine's statements, conditional statements and functions that can carry a password or a connection string, and test each one ([storage.md](storage.md#what-goes-into-the-history)).

### Structure changes

`DdlDialect` lives in the driver's `ddl` module, as `crates/drivers/postgres/src/ddl.rs` or, once it spans files, `crates/drivers/sqlite/src/ddl/`, implemented on the dialect type itself, so `ddl()` returns `Some(self)`. It plans every structure change the Structure tab makes, against the `TableDefinition` that `fetch_table_definition` returned:

| Method | What it does |
|---|---|
| `capabilities` | The table-level `DdlCapabilities`. The tab offers only what is on. `table_capabilities` narrows them for one table, and defaults to `capabilities`. |
| `sql_dialect` | The `SqlDialect` that quotes, binds and parses for the plans. Return `self`. |
| `column_capabilities` | A `Permission` per change to one column. Start from `ColumnCapabilities::standard`, which refuses a restatement that would drop a generated expression or an unmodeled attribute, a default on a numbered column, a drop of a column another table's foreign key points at, and any primary-key change while a foreign key points at the key. Add the engine's own refusals on top, each with its `RefusalReason`. An engine that writes the whole column again, as MySQL does for every change and SQL Server for a type or nullability change, refuses those changes where it cannot write the column back as it is. One that restates a generated column's expression checks `ColumnCapabilities::modeled` in place of `restatement`. |
| `type_suggestions`, `default_column_type`, `referential_actions`, `references_other_schemas` | What the tab's type menu, new columns and foreign-key dialog offer. Every suggestion has to parse through `parse_type`. The last two have defaults: every action, and keys across schemas. |
| `plan_create_table(&TableDraft)` | Starts with `draft.check_create(self)?`. Foreign keys go inside CREATE TABLE. |
| `plan_alter_table(&TableDefinition, &TableChanges)` | Starts with `changes.check(self, original)?`, then writes the changes in the order the engine needs: one combined ALTER TABLE where the engine takes one, and every statement after a table rename against the new name. A table rename keeps the table in its schema. An engine that renames one column per statement takes them from `changes.ordered_renames(original)`, which runs a swap through a temporary name. It ends with `DdlPlan::for_changes`, which refuses a change that came to no statement. |
| `plan_drop_table` | The default writes `DROP TABLE [IF EXISTS] <table> [CASCADE]`. |
| `create_table_script` | The server's own CREATE statement where the engine keeps one, and `NoTableSource` when the definition carries none; the default writes it from the definition. |

Plans quote every name through the dialect, splice a catalogue type unchanged and a typed one only after `parse_type` accepts it, and write a literal default through `SqlDialect::literal`. `tablepro_core::ddl::ddl_sql` has the pieces most engines share. The golden tests for each plan sit in that module, and the driver's integration target runs `ddl_conformance_suite!` (see [testing.md](testing.md#ddl-conformance)).

## 8. Registration

Add the crate to `crates/app/Cargo.toml` and register it in `build_registry` in `crates/app/src/lib.rs`:

```rust
fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(tablepro_driver_clickhouse::ClickhouseDriver));
    r.register(Arc::new(tablepro_driver_mssql::MssqlDriver));
    r.register(Arc::new(tablepro_driver_mysql::MysqlDriver));
    r.register(Arc::new(tablepro_driver_postgres::PgDriver));
    r.register(Arc::new(tablepro_driver_sqlite::SqliteDriver));
    r
}
```

Without this step the crate compiles and the app never offers it.

## 9. Tests

The layout every driver follows:

- Unit tests next to the code, for pure logic: the dialect, error mapping, decoders, statement classification.
- One integration target with one module per topic, as `crates/drivers/postgres/tests/integration/main.rs`: `support.rs` (start a fixture, connect, run), `conformance_engine.rs`, `tls.rs` for a network engine, and the engine's own behaviour (`metadata.rs`, `write_batch.rs`, `cancellation.rs` and so on). A network engine's test starts its own container and is `#[ignore = "requires docker"]`.
- A container fixture in `crates/test-fixtures` for anything the default image cannot do: TLS from the generated PKI, a second principal that logs in with a client certificate.

The conformance suites are the contract's own tests. The driver's `conformance_engine.rs` invokes the connection and DDL suites, plus the large-table suite for a network engine, its `value_corpus.rs` the value corpus, and a network engine's `tls.rs` the TLS suite. [testing.md](testing.md#conformance) has the adapter traits, the flags and the cases, with the [DDL](testing.md#ddl-conformance), [large-table](testing.md#large-table-conformance), [value corpus](testing.md#value-corpus) and [TLS](testing.md#tls-conformance) suites after them.

Behaviour the suites do not cover gets a test of its own against the real engine: the engine's stop, its error mapping, what a pooler does to it, each write outcome the ledger can produce.

A new package with Docker tests also needs its nextest group and CI matrix entry, and runs one package at a time ([testing.md](testing.md#running-the-docker-tests)).

## Checklist

- [ ] The client library is on crates.io, unforked, and uses aws-lc-rs.
- [ ] `capabilities()` matches what the engine does; the suite flags agree.
- [ ] Every stream comes from the transport, and TLS checks `tls_server_name()`.
- [ ] Every call runs under `OwnedCalls` with the engine's stop, and a connection-scoped stop never releases an unsettled connection.
- [ ] `probe` never waits for a pool slot; `stream_read` never holds one.
- [ ] Saves record every step in a `WriteLedger`, and the stop is held while a commit is in flight.
- [ ] Editor sessions are one connection per tab, one run at a time, with `ResultSink` backpressure and the row-limit rule.
- [ ] Errors map to `DriverError` by the engine's code ([error-handling.md](error-handling.md)).
- [ ] The client library's log target is in `SILENCED_LIBRARIES` in `crates/app/src/logging.rs`, so no statement text reaches the journal ([error-handling.md](error-handling.md#logging)).
- [ ] Registered in `build_registry`; added to the workspace and to `crates/app/Cargo.toml`.
- [ ] The connection, DDL, large-table, value corpus and TLS conformance suites run; the CI matrix and nextest groups include the package.
- [ ] `build-aux/update-third-party-licenses.sh` ran and its output is committed; `cargo deny check` passes.
- [ ] A page in `docs/drivers/` covers timeouts, stops, the server codes the driver maps, read-only, writes, trust and the engine's limits.
- [ ] `meson devenv -C _build cargo clippy --locked --workspace --all-targets -- -D warnings` passes, and again with `--no-default-features`.
