# Disconnect and cancellation contracts

This page maps connection-loss and cancellation expectations to the automated tests and runner layers that own them. A server that refuses a new connection must remain `ConnectionRefused`; loss of an established connection is `Disconnected`. A query interrupted after it has started must never be reported as a successful partial result.

## Driver behavior matrix

| Driver | Established server loss | Recovery after restart | Cancellation result and later use |
| --- | --- | --- | --- |
| PostgreSQL | Terminated query and mid-stream backend loss return `Disconnected`; the full result fails. | The existing pool reconnects after restart. | Server cancellation returns `Cancelled`; pool and session remain usable, and cancelled transactions can roll back. |
| MySQL | Terminated query and mid-stream loss return `Disconnected`; the full result fails. | The existing pool reconnects after restart. | Server cancellation returns `Cancelled`; pool and session remain usable. A timed-out write is stopped and the pool recovers. |
| ClickHouse | Hard stop during row streaming returns `Disconnected`; graceful stop preserves the server cancellation error. | The failed connection stays retired; a fresh connection works after restart. | The query is killed server-side, returns `Cancelled`, and the same client remains usable. |
| SQL Server | Loss during a multi-result stream returns `Disconnected` with no partial result. | A fresh connection works after restart. | BookiE does not yet use Tiberius 0.13's `cancel_query` API. Interruption returns `OperationOutcomeUnknown`, retires that connection or session, and leaves the shared connection usable after a session interruption. Real-server verification is tracked in [B4-23](https://github.com/cozyGarage/BookiE/issues/850). |
| MongoDB | Loss before an operation and loss during cursor `getMore` return `Disconnected`; no partial cursor result is returned. | The existing client recovers after restart at the same mapped endpoint. | Cancellation returns `OperationOutcomeUnknown(Cancelled)`; after cancellation the same client can list collections. |
| Redis | Loss during a browse page returns `Disconnected`; the incomplete page is rejected. | A later browse through the same driver object obtains a fresh operation-local connection and returns the complete row. | Local socket cancellation returns `OperationOutcomeUnknown`; ordinary commands remain usable and interrupted browse operations do not change their database selection. |

The session policies differ by protocol, so the expected result is recorded per driver. The tests check server state or returned values where available; they do not assume that every driver can cancel a server operation or reuse a physical socket after interruption.

PostgreSQL sessions are retired when an established backend is lost. A private one-slot session pool must not reconnect transparently and present a new backend as the same session, because its temporary tables, settings and transaction state are gone. The regression `disconnection::a_disconnected_session_is_retired_without_affecting_the_shared_pool` terminates the session backend, requires `Disconnected`, verifies that session handle is unusable, and checks the ordinary shared pool can still recover.

MySQL and SQL Server sessions follow the same rule. MySQL must not reacquire a replacement backend from its one-slot pool after `KILL CONNECTION`; SQL Server must discard its client after the server disappears. Their regressions are `a_disconnected_session_is_retired_without_affecting_the_shared_pool` in the MySQL integration suite and `a_disconnected_session_is_retired_after_server_loss` in the SQL Server integration suite. Each test first observed the old behavior with a failing assertion, then passed after the lifecycle fix.

## Test ownership

Run the six Docker-backed driver suites, including ignored fixtures, with:

```sh
python3 scripts/run-test-layer.py drivers
```

The runner invokes `scripts/ci-local.sh integration`, which executes the full PostgreSQL, MySQL, SQL Server, ClickHouse, Redis and MongoDB integration targets with `--include-ignored --test-threads=1`. The focused connection-loss, mid-stream, restart and server-cancellation cases are included in those targets.

Redis cancellation uses a local RESP fixture in the separate `cancellation` integration target. It is owned by the sandbox layer:

```sh
python3 scripts/run-test-layer.py sandbox
```

That layer runs `scripts/test-sandbox.sh`, which invokes the Redis cancellation target explicitly after the sandbox crate tests. MongoDB's cancellation and same-client recovery cases can be run individually:

```sh
cargo test --locked -p tablepro-driver-mongodb --test integration a_lost_mongodb_server_is_reported_as_disconnected -- --ignored --exact --test-threads=1
cargo test --locked -p tablepro-driver-mongodb --test integration a_cancelled_mongodb_read_leaves_the_client_usable -- --ignored --exact --test-threads=1
```

These suites are separate from the strict shared value-contract filter. A green value layer alone does not prove disconnect, cancellation, or reconnect behavior.

Historical full-layer runs from October 1 are listed in the [archived verification record](archive/disconnection-contracts-history-2026-10-01.md). They are not current acceptance evidence.
