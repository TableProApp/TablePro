# 0005: Cancellation must reach the database

- **Status**: Accepted
- **Date**: 2026-08-21

## Context

`OperationControl` carries a cancellation token and an optional deadline into every `*_controlled` driver call. When this decision was written, only the PostgreSQL driver acted on it. Other drivers inherited the default in `tablepro-core`, which races the operation against the token with `tokio::select!` and drops the losing future.

Dropping a future closes the client side of the statement. It does not stop the server. The statement can keep holding locks, keep writing rows, and keep consuming a worker until it finishes on its own. Because the caller cannot know what happened, the default returns `OperationOutcomeUnknown`, and `PolicyGuard` treats that as poisoning: one Stop or one timeout on a write disabled governed writes for the rest of the session while the write was possibly still in flight.

So the same defect produced two user-visible faults at once: a Stop button that did not stop, and a session that refused further writes after using it.

## Decision

A driver that offers `*_controlled` must ask the server to stop the statement, and must report a terminal outcome only when the server confirms it.

Three rules follow.

**One shared interruption sequence.** `tablepro_core::run_server_cancellable` owns the sequence: run the operation; on cancel or deadline, dispatch the engine's cancellation request; wait for the operation to settle; classify the result. Drivers supply only the three engine-specific parts — how to identify the running session, how to ask the server to stop it, and which error proves the server stopped it. The timings (2s to set up, 2s to dispatch, 5s of grace) are shared so behaviour does not drift between engines.

**Only the engine's own abort error is a terminal outcome.** `Cancelled` and `TimedOut` are returned when the statement fails with the error the engine raises for a statement it aborted: SQLSTATE `57014` on PostgreSQL, `70100` (`ER_QUERY_INTERRUPTED`) on MySQL. Any other error, and any statement that does not settle within the grace period, stays `OperationOutcomeUnknown`. A cancellation request that is dispatched but unconfirmed is not proof.

This is deliberately strict. If the operation wins the initial race, its result is returned. Once cancellation or timeout wins, a later normal result is still `OperationOutcomeUnknown`; it does not prove whether a write committed.

**SQLite interrupts in process.** It has no second session to kill from, so the driver keeps the raw `sqlite3` handle for the life of the operation and calls `sqlite3_interrupt`, which SQLite documents as safe from another thread. sqlx's progress handler was rejected as the mechanism: it only fires between virtual-machine instructions, so it cannot stop a statement waiting on a database lock, which is one of the cases a Stop has to cover. The unsafe call is isolated in one module holding one pointer and one function.

**SQL Server did not support this at the time of the decision.** The then-used Tiberius 0.12 defined the TDS attention packet but exposed no way to send one. Abandoning a statement left it running on the server and left the client with a half-read token stream; attempts to reuse that client could block behind its mutex. The current driver retires the affected connection or session instead, so later operations fail fast.

The current workspace uses Tiberius 0.13, which exposes [`Client::cancel_query`](https://docs.rs/tiberius/0.13.0/tiberius/struct.Client.html#method.cancel_query) to send TDS Attention and drain the acknowledgement. A real-server probe waited until SQL Server reported the tagged query in `WAITFOR`, then cancelled it; Tiberius returned a protocol error because it received no `DONE_ATTN` acknowledgement. Bookie keeps `supports_server_cancellation` false, returns `OperationOutcomeUnknown`, and retires the affected connection or session. B4-23 tracks the read/write verification required before this capability can change.

**A driver declares the capability.** `Connection::supports_server_cancellation` defaults to false. Where it is false the outcome of an interrupted operation is genuinely unknown, poisoning is correct, and the UI must not offer a Stop that cannot stop.

## Rationale

PostgreSQL's implementation was already release-verified through the fixture, so it is the reference rather than a new design. Extracting it into `core` and re-verifying it against the fixture and the container suite means the remaining drivers adopt a proven sequence instead of four independent ones.

Engines use different cancellation mechanisms. PostgreSQL sends `pg_cancel_backend` through a separate single-connection control pool. MySQL uses `KILL QUERY` through a separate single-connection pool. ClickHouse tags the request with a unique query id and sends `KILL QUERY` through its client. SQLite calls `sqlite3_interrupt` in-process. SQL Server's Tiberius cancellation API did not return an acknowledgement in the real-server probe, and Redis, MongoDB and DuckDB do not report confirmed server cancellation. The shared coordinator still enforces the same ordering and confirmation rule.

`SLEEP()` is not a valid probe on MySQL. It returns 1 when interrupted and the statement succeeds, so a test built on it passes without proving anything. The integration tests use an interruptible cross join instead, and check the server's own process list before and after the interruption rather than trusting the client's error.

## Consequences

Accepted:

- PostgreSQL and MySQL use a separate single-connection pool for cancellation requests, so a busy query cannot block the request that stops it. ClickHouse uses its client to send a second request; SQLite interrupts its active connection in-process.
- Server cancellation is best-effort. An engine that refuses the request, or a statement that ignores it, still yields `OperationOutcomeUnknown` and still poisons governed writes. That is the honest outcome, not a regression.
- Verifying a driver needs a real server. These paths cannot be proven by unit tests.

Gained:

- On engines with confirmed cancellation, Stop and query timeouts stop the statement rather than only the client's interest in it.
- A cancelled or timed-out operation no longer disables governed writes for the session on the engines that implement it.
- Drivers report `Cancelled` or `TimedOut` only after the server confirms the abort. An unconfirmed result stays `OperationOutcomeUnknown`; stateful connections are discarded where required, and `PolicyGuard` blocks governed writes after an ambiguous write.

## Alternatives considered

**Server-side statement timeouts only** (PostgreSQL `statement_timeout`; MySQL `max_execution_time` or its `MAX_EXECUTION_TIME(N)` hint for supported `SELECT`s). Rejected as the primary mechanism: deadline controls do not handle a user pressing Stop, and MySQL's hint does not cover every statement type. They may still be useful as a second layer ([MySQL optimizer hints](https://dev.mysql.com/doc/refman/8.4/en/optimizer-hints.html), [MySQL system variables](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html)).

**Treating a dispatched cancellation as confirmation.** Rejected. It would clear the poison flag while a write might still be running, which is the failure mode the audit rules exist to prevent.

**Leaving non-PostgreSQL drivers on the dropped-future default and hiding Stop.** Rejected for PostgreSQL, MySQL, ClickHouse and SQLite, where a real mechanism exists. Retained for SQL Server, Redis, MongoDB, and DuckDB, which declare the capability as false.

**`KILL <spid>` for SQL Server.** Deferred, not rejected. It ends the session and rolls back transactions still associated with it, which can take time ([Microsoft documentation](https://learn.microsoft.com/en-us/sql/t-sql/language-elements/kill-transact-sql)). It cannot prove an autocommit write had not committed before the kill took effect. The session's disappearance from `sys.dm_exec_sessions` would confirm the session ended, but Stop would cost the user their connection and a write outcome could remain unknown. Both need deciding before it ships.

**Switching the PostgreSQL client library to fix cancellation.** Not done. Upstream's switch made editor results text-only (simple-query metadata has no native types), inferred transaction status through `SAVEPOINT` probes and changed cursor planning. A migration must explicitly preserve typed result metadata, codecs, TLS service identity, session semantics, cursor behavior and `PolicyGuard` ([upstream movement review](../archive/upstream-linux-movement-2026-10-18.md), section 6.1).

**Returning a connection to the pool before its stop settles.** Rejected. A connection-scoped stop can arrive late and hit the next request. Cancellation tests cover the race matrix and assert server and reuse behaviour, not only the returned error: caller drop, deadline during cancel dispatch, a delayed stop after the work completed, stop transport failure, pool reuse and shutdown (same review, section 6.2).
