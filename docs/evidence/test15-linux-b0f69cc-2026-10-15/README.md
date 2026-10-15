# TEST-15 current Linux lost-ack recheck

Source: `b0f69cc663604c20e43f28174a9bf0466a99b024` (`linux`). Environment: Rust/Cargo 1.98.1, Docker Engine 29.7.2. The six ignored Docker selectors ran serially, each with one test thread, using the shared Cargo target directory.

| Engine | Result |
| --- | --- |
| PostgreSQL | 1 passed, 0 failed; 274 filtered |
| MySQL | 1 passed, 0 failed; 123 filtered |
| Redis | 1 passed, 0 failed; 13 filtered |
| ClickHouse | 1 passed, 0 failed; 36 filtered |
| SQL Server | 1 passed, 0 failed; 43 filtered |
| MongoDB | 1 passed, 0 failed; 52 filtered |

Exact selectors, from the repository root:

```bash
cargo test --locked -p tablepro-driver-postgres --test integration disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect -- --include-ignored --exact --test-threads=1 --nocapture
cargo test --locked -p tablepro-driver-mysql --test integration disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect -- --include-ignored --exact --test-threads=1 --nocapture
cargo test --locked -p tablepro-driver-redis --test integration disconnection::a_lost_eval_ack_is_not_replayed_after_redis_reconnects -- --include-ignored --exact --test-threads=1 --nocapture
cargo test --locked -p tablepro-driver-clickhouse --test integration disconnection::a_committed_insert_with_a_lost_http_ack_is_not_replayed -- --include-ignored --exact --test-threads=1 --nocapture
cargo test --locked -p tablepro-driver-mssql --test integration disconnection::a_committed_update_with_a_lost_ack_is_not_replayed -- --include-ignored --exact --test-threads=1 --nocapture
cargo test --locked -p tablepro-driver-mongodb --test integration disconnection::a_committed_update_with_a_lost_ack_is_not_replayed_after_reconnect -- --include-ignored --exact --test-threads=1 --nocapture
```

This is local current-tip selector evidence. It is not the maintainer-designated frozen-candidate Forgejo driver layer, PostgreSQL release layer or nightly/soak, so TEST-15 remains open for those acceptance results.
