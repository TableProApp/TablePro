# Merge baseline validation, October 23

## Workspace persistence compile failure

Forgejo run 902 tested Linux `248735cc30d98790dfdcc5ab456f1d7a1ea572ba`. Its Clippy, unit and sandbox jobs reported the same Rust E0308 error: a workspace persistence test passed a reference to a function that takes an owned workspace state. This is a source defect. The failure does not establish an infrastructure outage.

[PR 1444](https://github.com/cozyGarage/BookiE/pull/1444) changes that test call without changing its assertions or production behavior. On fix head `d473126a55c694dc1ed4ab3cfe53db77ebccad20`:

- `cargo test --locked -p tablepro-app-services --lib workspace_disk::` passed all four selected tests, including persistence of editor text for a database that is not current.
- `bash scripts/preflight.sh` passed, including guards, formatting, Clippy, non-GTK unit tests and sandbox tests.

Merged Linux `e54b62b49bf3cbb869e2e34cd2c4462e19618551` has an identical source tree to the tested fix head. Forgejo run 903 targets that merged baseline. Its final acceptance was pending when this record was prepared.

## Independent completion popup timeout

Run 902's widget job also failed `populated_completion_is_presented_after_the_editor_is_rooted`: the five-second visibility/allocation wait expired. The original failure does not identify which input or popup condition remained unmet. Its cause is unresolved in [issue 1445](https://github.com/cozyGarage/BookiE/issues/1445).

Five consecutive isolated local executions passed with the diagnostic change at `751d56993`. Each used a separate D-Bus session and Xvfb process. The selected test was `ui::editor::completion_provider::tests::populated_completion_is_presented_after_the_editor_is_rooted`, run with `--ignored --exact --test-threads=1`.

[PR 1446](https://github.com/cozyGarage/BookiE/pull/1446) reports input, expected visibility, mapping, focus and popup dimensions on timeout. It preserves the deadline and assertions. The local passes do not establish runner acceptance or explain the failure. Diagnostic coverage is not a fix for issue 1445.
