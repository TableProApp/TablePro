# 0005: Cancellation must reach the database

- **Status**: Accepted
- **Date**: 2026-08-21

## Context

`OperationControl` carries a cancellation token and an optional deadline into every `*_controlled` driver call. Until now only the PostgreSQL driver acted on it. Every other driver inherited the default in `tablepro-core`, which races the operation against the token with `tokio::select!` and drops the losing future.

Dropping a future closes the client side of the statement. It does not stop the server. The statement can keep holding locks, keep writing rows, and keep consuming a worker until it finishes on its own. Because the caller cannot know what happened, the default returns `OperationOutcomeUnknown`, and `PolicyGuard` treats that as poisoning: one Stop or one timeout on a write disabled governed writes for the rest of the session while the write was possibly still in flight.

So the same defect produced two user-visible faults at once: a Stop button that did not stop, and a session that refused further writes after using it.

## Decision

A driver that offers `*_controlled` must ask the server to stop the statement, and must report a terminal outcome only when the server confirms it.

Three rules follow.

**One shared interruption sequence.** `tablepro_core::run_server_cancellable` owns the sequence: run the operation; on cancel or deadline, dispatch the engine's cancellation request; wait for the operation to settle; classify the result. Drivers supply only the three engine-specific parts — how to identify the running session, how to ask the server to stop it, and which error proves the server stopped it. The timings (2s to set up, 2s to dispatch, 5s of grace) are shared so behaviour does not drift between engines.

**Only the engine's own abort error is a terminal outcome.** `Cancelled` and `TimedOut` are returned when the statement fails with the error the engine raises for a statement it aborted: SQLSTATE `57014` on PostgreSQL, `70100` (`ER_QUERY_INTERRUPTED`) on MySQL. Any other error, and any statement that does not settle within the grace period, stays `OperationOutcomeUnknown`. A cancellation request that is dispatched but unconfirmed is not proof.

This is deliberately strict. A statement that completes normally during the interruption returns its result, because it did commit.

**SQLite interrupts in process.** It has no second session to kill from, so the driver keeps the raw `sqlite3` handle for the life of the operation and calls `sqlite3_interrupt`, which SQLite documents as safe from another thread. sqlx's progress handler was rejected as the mechanism: it only fires between virtual-machine instructions, so it cannot stop a statement waiting on a database lock, which is one of the cases a Stop has to cover. The unsafe call is isolated in one module holding one pointer and one function.

**SQL Server cannot do this yet, and says so.** tiberius 0.12 defines the TDS attention packet but exposes no way to send one, so there is no mechanism to abort a statement on the connection running it. Measured behaviour before this change: abandoning the statement left it running on the server *and* left the tiberius client with a half-read token stream, so - because the client sits behind a mutex - every later operation on that connection blocked forever. A hang, not an error.

So SQL Server keeps `supports_server_cancellation` false and, on an interruption, retires the connection: the outcome is reported unknown, and every later call fails fast with `Disconnected` instead of stranding the caller. The only alternative mechanism, `KILL <spid>` from a second connection, stops the statement but destroys the session, which is a different product decision - whether Stop should drop your SQL Server connection - and is tracked separately rather than decided here.

**A driver declares the capability.** `Connection::supports_server_cancellation` defaults to false. Where it is false the outcome of an interrupted operation is genuinely unknown, poisoning is correct, and the UI must not offer a Stop that cannot stop.

## Rationale

PostgreSQL's implementation was already release-verified through the fixture, so it is the reference rather than a new design. Extracting it into `core` and re-verifying it against the fixture and the container suite means the remaining drivers adopt a proven sequence instead of four independent ones.

Engines differ in mechanism but not in shape. PostgreSQL has an out-of-band cancel request; MySQL, ClickHouse and SQL Server need a second session to issue `KILL QUERY` or its equivalent; SQLite interrupts in-process. All of them need the same before/after ordering, and all of them need the same rule about what counts as confirmation.

`SLEEP()` is not a valid probe on MySQL. It returns 1 when interrupted and the statement succeeds, so a test built on it passes without proving anything. The integration tests use an interruptible cross join instead, and check the server's own process list before and after the interruption rather than trusting the client's error.

## Consequences

Accepted:

- Each driver holds a second single-connection pool for cancellation requests, so a killed session cannot block the request that kills it.
- Server cancellation is best-effort. An engine that refuses the request, or a statement that ignores it, still yields `OperationOutcomeUnknown` and still poisons governed writes. That is the honest outcome, not a regression.
- Verifying a driver needs a real server. These paths cannot be proven by unit tests.

Gained:

- Stop and query timeouts stop the statement rather than only the client's interest in it.
- A cancelled or timed-out operation no longer disables governed writes for the session on the engines that implement it.
- The connection is returned to the pool when the outcome is known and hard-closed when it is not, so an unconfirmed statement cannot be handed to the next caller.

## Alternatives considered

**Server-side statement timeouts only** (`statement_timeout`, `MAX_EXECUTION_TIME`). Rejected as the primary mechanism: it covers the deadline but not a user pressing Stop, and it is set per session rather than per statement. Worth adding later as a second layer.

**Treating a dispatched cancellation as confirmation.** Rejected. It would clear the poison flag while a write might still be running, which is the failure mode the audit rules exist to prevent.

**Leaving non-PostgreSQL drivers on the dropped-future default and hiding Stop.** Rejected for PostgreSQL, MySQL, ClickHouse and SQLite, where a real mechanism exists. Retained for SQL Server, Redis, MongoDB, and DuckDB, which declare the capability as false.

**`KILL <spid>` for SQL Server.** Deferred, not rejected. It does stop the statement and roll it back, and the session's disappearance from `sys.dm_exec_sessions` would be real confirmation. It also ends the session, so Stop would cost the user their connection, and confirmation would come from the cancellation request rather than from the statement's own error - a weaker proof than the rule above allows. Both need deciding before it ships.
