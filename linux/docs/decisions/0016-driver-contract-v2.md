# 0016: Driver contract v2

- **Status**: Accepted
- **Date**: 2026-10-13

## Context

Until the switch to this contract, drivers implemented the first `Connection` trait: `list_tables`, `fetch_rows`, `query`, `execute` and `execute_in_transaction`, with no deadline or cancel on any call. A cancel dropped the caller's future and left the statement running on the server, holding its locks. A save was one `execute_in_transaction` call that returned row counts or an error, never how far it had got. PostgreSQL ran on sqlx, which cannot send a cancel request, caches statements under names a transaction pooler hands to other clients, and dials its own sockets. The 2026-09-14 audit traced lost edits, runaway statements and pooler breakage to these gaps (F-001, F-008, F-012, F-013, F-041, F-047, F-058, F-109).

## Decision

Every driver implements the v2 contract in `tablepro-core`: a `DatabaseDriver` that states its `DriverCapabilities`, a `Connection` whose calls run under `OwnedCalls` with the engine's own stop, writes that record their progress in a `WriteLedger`, one `EditorSession` per editor tab, and a `RowLimit` the engine enforces where it can, each built on the engine's maintained client from crates.io with no fork.

## Rationale

**Owned calls.** Dropping a future does not stop a server. Each call runs on a task the connection owns, which carries a `StopRequest` into the work, sends the engine's own stop (`EngineStop`) and decides afterwards whether the connection is clean enough to reuse (`CallResource`). A stop that names a connection rather than a statement, as PostgreSQL's cancel request and MySQL's `KILL QUERY` do, can land late on whatever runs next, so that connection goes back to the pool only once the stop has settled and the server has acknowledged it. tiberius borrows its client for the whole request, so SQL Server's attention is sent in band by the task that owns the client.

**Phase-aware write outcomes.** After a failed save the only question is what is in the database. The work records each step in a `WriteLedger` (statement sent, statement confirmed, commit sent), so an interrupted write becomes `RolledBack`, `PartiallyApplied` or `CommitOutcomeUnknown` from what was actually sent, not from a guess. The engine's stop is held while a commit, or a statement the engine cannot take back, is in flight. Where the server can answer later, the ledger keeps a `CommitToken` for `resolve_commit`: PostgreSQL's transaction id, ClickHouse's query ids.

**Row limit.** `RowLimit` cannot be zero, and the editor keeps 10,000 rows by default. The limit stops the read on the server where the engine allows it without changing the statement: a cursor fetch on PostgreSQL, `sql_select_limit` on MySQL, `KILL QUERY` on ClickHouse once the limit is passed. SQL Server counts the rows past the limit without keeping them, and SQLite stops stepping the statement. The limit never ends the script or the user's transaction.

**PostgreSQL on tokio-postgres.** sqlx-postgres keeps the backend's process id and secret key private, so it has no cancel request, and `pg_cancel_backend` from another session reaches the wrong backend behind PgBouncer. It also dials its own sockets and builds its own TLS configuration. tokio-postgres 0.7.18 logs in over any stream (`Config::connect_raw`), sends a cancel request over any stream (`CancelToken::cancel_query_raw`), supports SCRAM channel binding through tokio-postgres-rustls 0.14, and pipelines a transaction, its statement and its COMMIT into one round trip. deadpool-postgres 0.14.2 manages the pool.

**PgBouncer safety.** Nothing is prepared under a name: generated SQL runs on the unnamed statement (`query_typed_raw`, `execute_typed`). No session-level setting is sent: workspace bounds are `SET LOCAL` inside each call's transaction, and editor sessions apply read-only per transaction and enforce deadlines with cancel requests. The driver therefore works behind transaction pooling with `max_prepared_statements = 0`. Read-only mode and timeouts as startup parameters were rejected because a default PgBouncer refuses startup parameters it does not track.

**No forks.** The plan of 2026-09-14 carried forks of rust-postgres and tiberius. Both were dropped: tokio-postgres, postgres-types and postgres-protocol come from crates.io, and tiberius 0.13.0 is published with `Client::cancel_query`, `trust_cert_ca` and `hostname_in_certificate`. What upstream lacks is handled in the driver until the upstream change lands:

| Upstream gap | Until it closes |
|---|---|
| tokio-postgres drops the transaction status of ReadyForQuery | The editor follows the status statement by statement, with a `SAVEPOINT` probe where the rules leave it open |
| tokio-postgres gives simple-query columns no type (rust-postgres #1358) | Editor result columns are text |
| tiberius takes no rustls `ClientConfig` | SQL Server TLS failures are classified from rustls's message text |
| tiberius stops reading at the first end of message, so an attention sent while the server is still waiting is never acknowledged (tiberius-rs/tiberius#459) | The connection is dropped after such a stop, and three cancel tests are held in `.config/nextest.toml` |

The editor's row limit on PostgreSQL is a `DECLARE` and `FETCH` cursor. tokio-postgres offers a row-limited portal only inside a `Transaction` it opens itself, which would wrap every statement in BEGIN and COMMIT and refuse VACUUM.

**MySQL without a relay.** sqlx dials a TCP endpoint or a Unix socket itself, and an SSH forward is a Unix socket OpenSSH listens on ([ADR 0013](0013-openssh-client-transport.md)), so the MySQL driver dials the transport's route and nothing relays bytes in between.

**Trust per engine.** The engines' TLS stacks take trust anchors in different forms, so `NetworkTarget` carries the `TlsConfig` and each driver builds its own trust from it. PostgreSQL and ClickHouse share `tablepro_net::tls::build_client_config`; SQL Server and MySQL use what their clients accept. [ARCHITECTURE.md](../../ARCHITECTURE.md#trust) has the table.

## Consequences

- A new driver implements the whole contract and runs both conformance suites ([testing.md](../testing.md#conformance)). `suite_flags_match_driver_capabilities` keeps a driver from skipping a case by declaring less.
- PostgreSQL editor results are text until rust-postgres #1358 ships. The `SAVEPOINT` probe outside a transaction writes an ERROR line (25P01) to the server log. A cursor read plans for its first rows and never uses a parallel plan. Statement pooling is unsupported.
- Trust differs by engine until sqlx and tiberius take a rustls `ClientConfig`: MySQL trusts the Mozilla roots compiled into sqlx, not the system store.
- SQL Server TLS failures are classified more coarsely than the other engines', and three cancel tests stay held until tiberius-rs/tiberius#459 ships.
- [ADR 0009](0009-crypto-provider-and-sources.md) allowed `tiberius-rs/tiberius` as a git source until tiberius 0.13 was published. It is on crates.io now, and `allow-git` in `deny.toml` is empty.
- What each engine does with the contract is in `docs/drivers/`: [PostgreSQL](../drivers/postgresql.md), [MySQL and MariaDB](../drivers/mysql.md), [SQLite](../drivers/sqlite.md), [SQL Server](../drivers/sql-server.md), [ClickHouse](../drivers/clickhouse.md).

## Alternatives considered

- **Forks of rust-postgres and tiberius**: they closed the gaps above in the client, but each is a second codebase to keep current and patched ([ADR 0005](0005-supply-chain-policy.md)).
- **sqlx-postgres with `pg_cancel_backend`**: reaches the wrong backend behind PgBouncer, and sqlx dials its own sockets.
- **libpq through FFI**: a second TLS stack and a C dependency.
- **A private socket relay for MySQL**: no purpose once an SSH forward is a Unix socket.
- **Cancel by dropping the caller's future**: leaves the statement running on the server.
- **A `LIMIT` added to the user's SQL**: changes what the statement means, and does nothing for a statement that is not a `SELECT`.
