# TEST-15 current Linux recheck

Source: `4fbaf5c92ee8efab1194a11c147ab35a6e70ac86` (`fork/linux`).

Environment: Rust and Cargo 1.98.1, Docker Engine 29.7.2. The six selectors ran serially with `CARGO_TARGET_DIR=/home/trung/Projects/tablepro/target`.

| Engine | Selector | Result |
| --- | --- | --- |
| PostgreSQL | `disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect` | 1 passed |
| MySQL | `disconnection::a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect` | 1 passed |
| Redis | `disconnection::a_lost_eval_ack_is_not_replayed_after_redis_reconnects` | 1 passed |
| ClickHouse | `disconnection::a_committed_insert_with_a_lost_http_ack_is_not_replayed` | 1 passed |
| SQL Server | `disconnection::a_committed_update_with_a_lost_ack_is_not_replayed` | 1 passed |
| MongoDB | `disconnection::a_committed_update_with_a_lost_ack_is_not_replayed_after_reconnect` | 1 passed |

Each command was `cargo test --locked -p <driver-package> --test integration <selector> -- --include-ignored --exact --test-threads=1`. All six exited 0; no test failed. Each fixture's assertion covers independent stored state or request count after the lost acknowledgement and reconnect.

This is local Docker-backed evidence on current Linux. It does not replace the maintainer-designated frozen-candidate Forgejo driver and PostgreSQL release layers, Forgejo nightly/soak, or installed Arch/Hyprland acceptance. The MongoDB fixture does not qualify replica-set retryable-write modes.
