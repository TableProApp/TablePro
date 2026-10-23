# Results-panel focus investigation, October 23, 2026

Issue: [#556](https://github.com/cozyGarage/BookiE/issues/556). Harness source: `662ed2f76`. Executable: the optimized GTK shard 1 artifact from Forgejo run 916, built from `5b00b4ca6`.

## Observations

The unchanged results-panel scenario passed alone locally in 8.018 seconds and on its original runner in 6.025 seconds. Both used the exact failing CI executable.

The complete GTK shard 1/3 reproduced the failure locally with retries disabled: 34 scenarios passed and only `results_panel_preserves_query_results_and_keyboard_focus` failed. The accessible snapshot contains `SELECT 842` in the editor, but the expected result cell is absent after hiding the results panel and sending Ctrl+J.

A reduced sequence of the five immediately preceding active-edit scenarios followed by the results-panel scenario reproduced the failure again. All five predecessors passed. Each scenario starts a fresh application and isolated database; the sequence shares its X server and D-Bus session.

The two-scenario sequence `active_cell_edit_survives_cancelled_close_other_tabs` followed by the results-panel scenario also reproduces the failure. The predecessor passes; the results-panel scenario fails waiting for cell 842. Its log is retained at `target/quality/panel-focus-last-predecessor.log`.

These observations do not establish an application defect or harness defect. They rule out a deterministic explanation based solely on optimization or the original runner toolkit. No assertions, timeout or retry policy were changed.

## Retained evidence

Local logs are retained under `target/quality/panel-focus-exact-ci/`, `target/quality/panel-focus-exact-runner.log`, `target/quality/panel-focus-full-shard.log`, and `target/quality/panel-focus-active-predecessors.log`. Failed snapshots and per-scenario outcomes are retained in the corresponding artifact directories. These ignored paths are local evidence, not downloadable repository artifacts.

## Cause and repair

Temporary instrumentation measured the keyboard target in the failing pair: the predecessor uses the normal 1200×760 application window, while Ctrl+J in the next scenario targets a 458×50 override-redirect popup. The shared keyboard helper chooses the last mapped root child without excluding these transient windows.

The repair excludes override-redirect windows from keyboard focus selection. It changes the harness only. The same two-scenario regression passes with the exact unchanged CI executable: predecessor 3.005 seconds, results-panel case 3.796 seconds. Diagnostic logging was removed. The assertion, timeout and retry policy remain unchanged.

## Remaining work

All 35 scenarios in the complete shard passed without retries, including the results-panel scenario in 4.095 seconds. Log: `target/quality/panel-focus-fixed-shard.log`. Full preflight passed, including 2,070 unit tests and the sandbox tier. Forgejo acceptance remains pending. The change does not establish ownership filtering for unrelated normal windows; the harness uses its isolated display.
