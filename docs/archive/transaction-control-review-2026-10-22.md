# Transaction-control proposal review, October 22

Status: review complete. [DBF-5 / #1359](https://github.com/cozyGarage/BookiE/issues/1359) needs no new prompt or product change. Current user behavior belongs in the [SQL editor guide](../user-guide.md#run-sql).

Reviewed BookiE Linux source: `303422aacd739835e3b9e992804e980c8b28a0a8`. The proposal asked whether running a lone transaction statement under the cursor could leave an untracked transaction on a shared connection. Source inspection confirms the owned-session routing in `crates/policy/src/guard/session.rs`; shared dispatch remains guarded.

Six existing `tablepro-policy` unit regressions passed on that source:

- `transaction_control_on_the_shared_connection_is_denied_before_dispatch`: query and execute refuse transaction control without driver dispatch across PostgreSQL, MySQL, SQLite and SQL Server.
- `a_session_runs_its_own_transaction_and_audits_the_rollback_against_its_batch`: BEGIN opens tracked session state and rollback closes it with its audit outcome.
- `a_committed_session_transaction_records_the_commit`: commit closes the tracked transaction and records its outcome.
- `commit_without_a_preceding_begin_is_refused`: the driver receives no statement.
- `transaction_control_hidden_in_a_script_is_refused_and_never_reaches_the_database`: refusal preserves the existing transaction.
- `sql_server_tran_statements_drive_the_session_transaction`: SQL Server spellings follow the owned transaction path.

The repository-pinned nextest run was `f85112ef-7831-468b-a605-a80db53fdcbd`: six selected tests passed, 325 were skipped by the filter. A separate `cargo test --locked -p tablepro-policy --lib transaction_control` run passed six classification/shared/session tests. These use controlled test doubles; they are not fresh real-engine or native desktop acceptance. The earlier Xvfb/SQLite cursor-action observation remains in the issue comments with its original scope.

No rule, test, driver, dependency or UI behavior changed. The conditional prompt acceptance does not apply because the suspected unguarded case is already refused. DBF-6 keyboard coverage remains open separately in [#1360](https://github.com/cozyGarage/BookiE/issues/1360).
