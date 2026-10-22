# GTK dialog title accessibility, October 22

Scope: the dialog wait used by the installed GTK scenarios in [PR #1414](https://github.com/cozyGarage/BookiE/pull/1414). Baseline: Linux `303422aacd739835e3b9e992804e980c8b28a0a8`.

## Failure evidence

Forgejo run 891 tested `77811693cfc523e60c8d568994941155da2e0d1f`. GTK shard 1 failed `columns_dialog_hides_a_column_and_keeps_the_last_one`. Shard 2 failed `sqlite_grid_context_menu_columns_action_is_reachable_via_atspi` and `view_value_opens_the_whole_cell_with_pretty_json`.

The failure snapshots contain the opened dialogs: Columns exposes its title label and column checkboxes; the value viewer exposes its `payload` title label and Copy value button. The wait required an accessible node with `ROLE_DIALOG`, which those snapshots do not expose. The snapshots establish a test discovery failure; they do not establish that dialog activation failed.

The earlier menu-navigation diagnosis was refuted by these snapshots. An attempted SQLite menu-index change selected Export Results in local testing and was removed. The final change preserves the existing menu interactions and accepts either the dialog role or the exact title label. Existing assertions still check column visibility, preservation of the final visible column, pretty JSON content, the Copy value button, and closing the dialog.

The separate consumers failure in run 891 was a MySQL container startup timeout, `WaitContainer(StartupTimeout)`. This change does not address container startup.

## Local validation

A release binary was rebuilt from this checkout using the shared Cargo target directory. With an isolated D-Bus session and Xvfb, all three named scenarios passed without retries: 2.080 s, 2.836 s and 3.683 s respectively. These local results exercise the installed desktop stack; Forgejo must verify the runner stack separately.

The full preflight passed again after the final helper correction: 2,056 unit tests and 2,059 sandbox tests, the Redis cancellation subprocess check, guards, formatting, Clippy and the script harness. Debian package validation was skipped locally because dpkg-deb is unavailable. GitHub checks on the preceding PR revision do not certify this revision; a new Forgejo gate remains required.
