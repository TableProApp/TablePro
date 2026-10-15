# B4 rollback layer on current Linux

Source: `0700d0e48cdc7f23c6c25ccd7b0249aaeceed98d` (`fork/linux`). The layer report records a clean tracked tree.

Command: `python3 scripts/run-test-layer.py b4-rollback`.

Environment: Rust/Cargo 1.98.1 and Docker Engine 29.7.2. The runner executed both steps serially.

| Step | Result |
| --- | --- |
| MySQL `cargo test --locked -p tablepro-driver-mysql --test integration mysql_atomic -- --include-ignored --test-threads=1` | 32 passed, 0 failed, 92 filtered; 241.675 seconds |
| PostgreSQL `cargo test --locked -p tablepro-driver-postgres --test integration rollback_failure::a_batch_reports_rollback_failure_after_postgres_terminates_its_backend -- --include-ignored --test-threads=1` | 1 passed, 0 failed, 273 filtered; 22.464 seconds |

The MySQL selection includes MySQL/MariaDB atomicity, trigger and nontransactional side-effect cases, including the optional storage-engine coverage. Both steps exited 0; the complete layer passed.

The full current `mysql_atomic` selector passed locally, including its optional-engine, trigger, session/lock and other nontransactional cases. B4-11 remains open for exact-candidate and Forgejo acceptance; this current-tip local run does not qualify the release or prove requirements outside this selector.
