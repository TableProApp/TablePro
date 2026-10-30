# Regression tests

The 2026-09-13 audit rated seven findings critical. Each one has tests that fail if it comes back, and every such test carries the finding in its name: a guard for F-001 starts with `f001_`. The audit itself is not in the tree; the table below is the record of each finding.

```bash
finding=f002_
meson devenv -C _build cargo test --workspace --exclude tablepro -- "$finding"
GTK_A11Y=test GSK_RENDERER=cairo GDK_BACKEND=x11 xvfb-run -a dbus-run-session -- \
  meson devenv -C _build cargo test -p tablepro --lib -- "$finding"
meson devenv -C _build cargo nextest run --workspace --exclude tablepro --run-ignored only -E "test(/$finding/)"
```

The first two run a finding's guards that need no server. The app's are GTK tests, so they need a display, a session bus and the variables the gtk Meson suite sets. The third runs the ones that need Docker, as the integration jobs do. The app runs with `--lib` because its [application tests](testing.md#application-tests) have no test harness to filter, and `startup` needs Meson. Only F-002, F-004 and F-005 have guards in the app.

## Findings

| Finding | Failure the guards catch |
|---|---|
| F-001 | A connection marked read-only still wrote: a save, an editor statement or a schema change reached the database. |
| F-002 | A reply meant for an earlier connect attempt or a closed session reached the current one: a late connection was adopted or left open, or a late result changed a workspace that was gone. |
| F-003 | An unreadable or newer saved-connection file was overwritten by the next change, losing every saved connection. |
| F-004 | After a draft row was inserted or removed, an edit, a Set NULL or a Copy as INSERT went to the row at the old position. |
| F-005 | The grid wrote back what it displayed: text cut short for display, or a float rounded by the editor, replaced the stored value. |
| F-006 | A value the driver could not decode read as NULL, so a save keyed on it matched no row or the wrong one. |
| F-007 | The release Flatpak manifest was never built: it carried placeholder sources, and nothing built or linted it. |

## Guards

Kinds: `unit` runs in the Meson unit suite, `gtk` in the gtk suite, `docker` in the integration jobs (ignored with `requires docker`), and `conformance` is a case that `connection_conformance_suite!` emits into every driver's integration target, which for SQLite runs in the unit suite. `ci-job` is a job in the Linux workflow.

| Finding | Kind | Guard | File |
|---|---|---|---|
| F-001 | conformance | `f001_read_only_connection_refuses_writes` | [crates/test-support/src/conformance/cases/read_only.rs](../crates/test-support/src/conformance/cases/read_only.rs) |
| F-001 | docker | `f001_editor_idle_delete_fails_25006` | [crates/drivers/postgres/tests/integration/read_only.rs](../crates/drivers/postgres/tests/integration/read_only.rs) |
| F-001 | docker | `f001_read_only_insert_and_create_1792` | [crates/drivers/mysql/tests/integration/flavour_suite.rs](../crates/drivers/mysql/tests/integration/flavour_suite.rs) |
| F-001 | unit | `f001_read_only_insert_is_read_only` | [crates/drivers/sqlite/tests/integration/open_semantics.rs](../crates/drivers/sqlite/tests/integration/open_semantics.rs) |
| F-001 | docker | `f001_read_only_insert_164` | [crates/drivers/clickhouse/tests/integration/writes.rs](../crates/drivers/clickhouse/tests/integration/writes.rs) |
| F-002 | unit | `f002_accepts_only_latest_generation` | [crates/session/src/connect/connect_attempts.rs](../crates/session/src/connect/connect_attempts.rs) |
| F-002 | unit | `f002_late_reconnect_after_cancel_is_discarded_and_closed` | [crates/session/src/health/health_monitor.rs](../crates/session/src/health/health_monitor.rs) |
| F-002 | gtk | `f002_cancel_connect_discards_late_attempt` | [crates/app/src/ui/session_window/tests/mod.rs](../crates/app/src/ui/session_window/tests/mod.rs) |
| F-002 | gtk | `f002_late_show_create_reply_after_disconnect_is_dropped` | [crates/app/src/ui/session_window/tests/mod.rs](../crates/app/src/ui/session_window/tests/mod.rs) |
| F-002 | gtk | `f002_a_connect_beside_the_last_session_adopts_from_the_connecting_page_without_connecting_again` | [crates/app/src/ui/session_window/tests/sessions.rs](../crates/app/src/ui/session_window/tests/sessions.rs) |
| F-002 | gtk | `f002_stop_connecting_a_dialog_connect_beside_the_sessions_closes_its_late_connection` | [crates/app/src/ui/session_window/tests/sessions.rs](../crates/app/src/ui/session_window/tests/sessions.rs) |
| F-002 | gtk | `f002_a_late_catalog_commit_after_the_watch_drops_is_not_delivered` | [crates/app/src/ui/workspace/sidebar/catalog_watch.rs](../crates/app/src/ui/workspace/sidebar/catalog_watch.rs) |
| F-003 | unit | `f003_truncated_file_is_unavailable_and_upsert_leaves_bytes_identical` | [crates/storage/src/connections.rs](../crates/storage/src/connections.rs) |
| F-003 | unit | `f003_a_newer_version_is_never_written` | [crates/storage/src/connections.rs](../crates/storage/src/connections.rs) |
| F-004 | gtk | `f004_edit_after_draft_insert_targets_edited_row` | [crates/app/src/ui/data_grid/edit/tests/mod.rs](../crates/app/src/ui/data_grid/edit/tests/mod.rs) |
| F-004 | gtk | `f004_menu_set_null_after_draft_removal_targets_clicked_row` | [crates/app/src/ui/data_grid/edit/tests/mod.rs](../crates/app/src/ui/data_grid/edit/tests/mod.rs) |
| F-004 | gtk | `f004_copy_row_as_insert_uses_row_below_draft` | [crates/app/src/ui/browse_tab/tests/rows.rs](../crates/app/src/ui/browse_tab/tests/rows.rs) |
| F-005 | gtk | `f005_unchanged_40kb_multiline_text_records_no_edit` | [crates/app/src/ui/data_grid/row_detail/tests.rs](../crates/app/src/ui/data_grid/row_detail/tests.rs) |
| F-005 | gtk | `f005_pasted_newlines_in_text_cell_are_kept` | [crates/app/src/ui/data_grid/edit/tests/mod.rs](../crates/app/src/ui/data_grid/edit/tests/mod.rs) |
| F-005 | gtk | `f005_pressing_enter_on_float_keeps_full_precision` | [crates/app/src/ui/data_grid/edit/tests/mod.rs](../crates/app/src/ui/data_grid/edit/tests/mod.rs) |
| F-006 | conformance | `f006_unsupported_types_never_decode_as_null` | [crates/test-support/src/conformance/cases/type_fallback.rs](../crates/test-support/src/conformance/cases/type_fallback.rs) |
| F-006 | docker | `f006_round_trip_matrix` | [crates/drivers/postgres/tests/integration/decode.rs](../crates/drivers/postgres/tests/integration/decode.rs) |
| F-006 | unit | `f006_count_sum_and_expression_columns_are_typed` | [crates/drivers/sqlite/tests/integration/decode.rs](../crates/drivers/sqlite/tests/integration/decode.rs) |
| F-006 | docker | `f006_bigint_unsigned_max_id_edit_affects_one_row` | [crates/drivers/mysql/tests/integration/decode.rs](../crates/drivers/mysql/tests/integration/decode.rs) |
| F-007 | ci-job | `flatpak-devel` | [.github/workflows/build-linux.yml](../../.github/workflows/build-linux.yml) |

The read-only case runs on every engine. SQL Server leaves read-only to the login's privileges, so there it checks only the app's own refusal of a save. The type case runs on every network engine: every SQLite value is one of five storage classes, and the driver decodes all five.

## Retired helpers

A helper an audit named that no longer exists, and the tests that hold its behaviour now.

| Helper | Behaviour | Guard | File |
|---|---|---|---|
| `dec_close_after_save` | A tab or window closes only after every save started for it has settled. | `when_idle_resolves_after_last_settle` | [crates/app/src/workspace/save_ledger.rs](../crates/app/src/workspace/save_ledger.rs) |
| `dec_close_after_save` | A tab or window closes only after every save started for it has settled. | `in_flight_save_waiting_dialog_force_closes_on_settle` | [crates/app/src/workspace/close_guard.rs](../crates/app/src/workspace/close_guard.rs) |

## Keeping the map true

[test_regression_names.py](../build-aux/tests/test_regression_names.py) runs in the Meson `packaging` suite and fails when:

- a guard on this page is not a function in the file it links;
- a function whose name starts with a finding id, anywhere under `crates/`, is not on this page with its file;
- a finding has no guard, or a guard's name carries another finding than its row;
- a CI job on this page is not in the workflow. Only a checkout has the workflow, so the Flatpak and package builds skip this one.

lychee checks that every linked file exists. Rename or move a guard, and this page changes in the same commit.
