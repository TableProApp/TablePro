# TEST-15 local recheck at `a53a8cfc`

Date: 2026-10-15

Source: `a53a8cfcf9f9987cf9c5f2a1e3db8dbb37d02bb0` (`feat(mcp): preserve structured write outcomes (#927)`).

Environment: Rust/Cargo 1.98.1, Docker Engine 29.7.2. The six Docker-backed selectors ran serially on this machine.

| Engine | Command | Result |
| --- | --- | --- |
| PostgreSQL | `cargo test --locked -p tablepro-driver-postgres --test integration disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect -- --include-ignored --exact --test-threads=1` | 1 passed |
| MySQL | `cargo test --locked -p tablepro-driver-mysql --test integration disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect -- --include-ignored --exact --test-threads=1` | 1 passed |
| Redis | `cargo test --locked -p tablepro-driver-redis --test integration disconnection::a_lost_eval_ack_is_not_replayed_after_redis_reconnects -- --include-ignored --exact --test-threads=1` | 1 passed |
| ClickHouse | `cargo test --locked -p tablepro-driver-clickhouse --test integration disconnection::a_committed_insert_with_a_lost_http_ack_is_not_replayed -- --include-ignored --exact --test-threads=1` | 1 passed |
| SQL Server | `cargo test --locked -p tablepro-driver-mssql --test integration disconnection::a_committed_update_with_a_lost_ack_is_not_replayed -- --include-ignored --exact --test-threads=1` | 1 passed |
| MongoDB | `cargo test --locked -p tablepro-driver-mongodb --test integration disconnection::a_committed_update_with_a_lost_ack_is_not_replayed_after_reconnect -- --include-ignored --exact --test-threads=1` | 1 passed |

These current-tip local runs add confidence that lost-ack writes are not replayed after #927. They do not replace the maintainer-designated frozen-candidate run at `bbdc39a430ede9382bc5dfa7164e51a065e2bd88`, the Forgejo driver and PostgreSQL release layers, or the nightly/soak. Those acceptance items remain open on [#593](https://github.com/cozyGarage/BookiE/issues/593).
