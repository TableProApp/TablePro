# ClickHouse

Driver id `clickhouse`, crate `crates/drivers/clickhouse`. It speaks ClickHouse's HTTP interface through the official `clickhouse` crate 0.15 with its default features off, on a hyper-util client whose connector dials through the transport and whose TLS is hyper-rustls with the driver's own rustls config. The integration suite runs against ClickHouse 25.8. The contract it implements is in [adding-drivers.md](../adding-drivers.md).

The default port is 8123, the plain HTTP port. With TLS on, use the server's HTTPS port (8443 by default); a TLS connect to the HTTP port fails.

## Requests and connections

HTTP has no login and no long-lived session, so there is no pool of logins:

- hyper keeps idle HTTP connections for 2 s, shorter than the server's keep-alive (3 s before 23.11, 10 s after), so a reused connection is never one the server is about to close.
- Every connection is a stream from `Transport::open`. The URL names only the service, for the `Host` header and the TLS name, so an SSH forward never needs a DNS lookup of a name only the far side can resolve.
- The connect is the first request, `SELECT version(), currentDatabase()`, within the connect and login timeouts together. A refused password or a failed handshake shows up there.
- `probe` is one more request, `SELECT 1`, on the control client.

Three clients share that connection pool:

| Client | Used for | Settings beyond the common ones |
|---|---|---|
| Workspace | Catalogue reads, pages, counts, exports, write probes, editor sessions | `readonly=2` and `allow_ddl=0` on a read-only connection |
| Writes | The statements of a save | `wait_end_of_query=1`, `max_execution_time=0` |
| Control | `KILL QUERY`, `SYSTEM FLUSH LOGS`, commit resolution | None. It is not held read-only, because a `KILL` is not a read, and it runs only SQL the driver wrote. |

Every request carries these settings:

| Setting | Why |
|---|---|
| `output_format_decimal_trailing_zeros=1` | A Decimal keeps the scale it was stored with. |
| `http_write_exception_in_output_format=0` | An error after the first rows arrives as exception text, not as one more row. |
| `output_format_json_quote_denormals=1` | NaN and infinity arrive as words instead of null. |
| `output_format_json_validate_utf8=0` | A String that is not UTF-8 arrives byte for byte. |
| `mutations_sync=1` | A save waits for its mutation, so the grid refetches what the save wrote. |
| `cancel_http_readonly_queries_on_client_close=1` | A read whose HTTP connection the app dropped stops on the server even when no `KILL` got through. |

The client names itself to the server as TablePro with the app's version (`with_product_info`).

Results stream as `JSONCompactEachRowWithNamesAndTypes`, and each cell is read by the type the server named for it. Values go to the server as typed `{pN:Type}` parameters, never spliced into the SQL. SQL the user typed goes through `query_raw`, so a `?` in it stays a `?`.

## TLS

- `VerifyFull` trusts the system store plus the connection's CA file ([Trust](../../ARCHITECTURE.md#trust)) and checks the name from `NetworkTarget::tls_server_name()`. `Require` encrypts without checking the certificate.
- With a client certificate set, the driver sends `X-ClickHouse-SSL-Certificate-Auth: on` and no password, and the server logs the user in by the certificate's common name (`ssl_certificates` in the user's configuration).
- The crate's own TLS features stay off, so there is one TLS stack.

## Read-only

`ReadOnlyEnforcement::EngineEnforced`. A read-only connection sends `readonly=2` and `allow_ddl=0` with every workspace and editor request, and the server refuses a write whatever the SQL says (error 164, or 392 for DDL). `readonly=2` still lets a session change settings, which the editor needs. Every workspace read also carries `readonly=2`, on any connection, with its time bound. Saves on a read-only connection are refused before anything is sent.

## Stops and timeouts

A read carries `max_execution_time` (the nearer of the call's deadline and the workspace's 60 s, in whole seconds rounded up) with `timeout_overflow_mode=throw`, so the server stops it on time on its own (error 159).

A stop is `KILL QUERY WHERE query_id = ? ASYNC` on the control client. Each query the driver sends carries a query id of its own, and the id is bound by the client, never written into the SQL. The `KILL` names that one query, so a late one cannot hit the next: `StopDelivery::OutOfBand(StopScope::Statement)`. The server answers the stopped query with error 394, which reads as `Cancelled`, or as `Timeout { server_cancelled: true }` when the deadline asked for it.

| Server answer | Reported as |
|---|---|
| 394 after our `KILL` | `Cancelled` |
| 159 | `Timeout { phase: Statement, server_cancelled: true }` |
| 164, 392 | `ReadOnly(ServerRejected)` |
| 192, 193, 194, 516; 497 on the first request | `Auth` |
| 202, 203 | `Busy` |
| 373 on an editor run | `EditorSessionBusy` |

## Writes

ClickHouse has no transactions: `WriteAtomicity::StatementByStatement` for row and schema changes. A row change is an `INSERT` or a mutation (`ALTER TABLE ... UPDATE` or `DELETE`), and a mutation is neither atomic nor reversible.

1. Every probe runs first, so a row that moved stops the save before any mutation is sent.
2. Then each statement runs to its end on the writes client, under a query id of its own. `mutations_sync=1` makes it wait for the mutation, and `max_execution_time=0` means no server-side limit, because a mutation the server stops waiting for keeps running anyway.
3. A statement in flight is never killed: a `KILL` would not undo what the mutation already changed, only hide it. A stop is honoured between statements.

The grid names a ClickHouse row by its sorting key (`RowIdentity::SortingKey`), which may match several rows. So a save proves its row with a probe before the mutation, and a batch with an exact affected-row guard is refused with `GuardUnsupported`: a mutation reports no row count. An `INSERT` reports its written rows; a mutation reports none, which is "not known", not zero. A table with no sorting key is read-only in the grid. The row-count estimate is `system.tables.total_rows`, which MergeTree keeps exact.

A failed statement is sorted by whether it can have landed. A server error that refused it (a syntax error, an unknown column) did not apply. A cancel, a timeout, an unfinished mutation wait (341), a network error, or a body with no error code may have applied, so the outcome comes from the `WriteLedger`, with a `CommitToken::ClickHouseQuery` of every statement's query id.

### Resolving an unknown outcome

`CommitResolutionSupport::QueryLog`. `resolve_commit` asks about the first statement the save could not confirm:

1. `SYSTEM FLUSH LOGS`, so the log has the latest entries. A login without the privilege skips it.
2. That query id in `system.query_log` from today and yesterday:

| What the log says | `CommitResolution` |
|---|---|
| `QueryFinish` | `Applied` |
| `ExceptionBeforeStart`, not an `ALTER` | `NotApplied` |
| `ExceptionWhileProcessing` on an `INSERT` | `Unresolvable`: some blocks may have been written |
| An `ALTER` that failed while its mutation may live on (cancelled, timed out, the wait gave up, or failed while processing) | The mutation, below |
| Started, never ended | `StillRunning` if `system.processes` still lists it, else `Unresolvable` |
| No `system.query_log`, or no access to it | `Unresolvable` |

3. For a mutation: `system.mutations` has no column that links a mutation to its `ALTER`, so the driver looks for mutations on the table the log names, created between the `ALTER`'s start and end. One that is done is `Applied`; one still running is `StillRunning`. None, because someone ran `KILL MUTATION` (which removes the row and keeps the parts already changed), or more than one, is `Unresolvable`.
4. The batch's answer: statements confirmed before the unconfirmed one, or not yet sent after it, turn a whole answer into `PartiallyApplied`.

The query log and the process list are each node's own, and the driver asks the node its connection reaches; it does not query the cluster. Behind a load balancer that sends the next request to another node, that node's log has no entry for the statement and the answer is `Unresolvable`.

## Editor sessions

- An editor session is the workspace client with a `session_id` of its own and `session_timeout=3600`, so the server keeps the session's settings and temporary tables between runs. The server runs one query at a time per session, so a second run is `EditorSessionBusy`.
- One statement per run (`ScriptExecution::SingleStatement`), each with a new query id.
- The run's deadline, or the session's statement timeout, goes to the server as `max_execution_time` with `timeout_overflow_mode=throw`. A stop sends `KILL QUERY` and keeps reading, because the server answers the `KILL` by ending the response; a server that has not answered within the cancel grace is cut off.
- Past the row limit the driver sends `KILL QUERY` for the rest of the result rather than reading it.
- The server keeps a session locked until a query it was told to stop has ended, which can be after the run gave up its response, and refuses the session's next query with 373 until then. So when a stopped run gave up its response before the end, as one cut off at the cancel grace, past the row limit or at a row it could not read does, the next run first sends `KILL QUERY ... SYNC` for that query, which answers once it is gone, and waits under its own cancel and deadline. A stop the server answered by ending the response leaves nothing to wait for. A 373 that still comes is `EditorSessionBusy`, and the session stays ready.
- ClickHouse has no transaction an editor statement can leave open, so the transaction state is always `Idle`.
