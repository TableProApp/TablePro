# Shared grid pointer routing experiment

Related work: [#1315](https://github.com/cozyGarage/BookiE/issues/1315). Baseline: `9f749bb7c34d91458a9272a75127cde90bfee13e`, the keyboard-routing change accepted in #1519. The candidate replaces per-cell secondary-button gestures with one capture-phase handler on the grid. It picks the clicked widget and follows its ancestors to the existing typed cell metadata. Native label text selection remains enabled, and an active cell editor retains its native menu.

The registered isolated menu test failed before the fix because each cell retained its own secondary-button controller. It passes after the change, including pointer routing while focus is outside the grid, updated row identity and active-editor handling. All 153 isolated GTK tests and strict app Clippy passed locally. The installed `grid_pointer_menu_uses_the_clicked_result_cell` scenario passed without retries in 3.742 seconds: focus starts on the first row, a physical secondary-button click targets the second row, and View value must show the second value. Full preflight passed. Forgejo acceptance is pending.

Both executables were built with the same development profile, dependency set and source checkout path. The baseline production files were restored from the recorded commit for its build, then the candidate files were restored immediately. Immutable executable hashes and production-source hashes are in [binary identities](binaries.json). Three fresh processes per variant ran in alternating order under isolated Xvfb/Cairo with 100 generated SQLite rows and 257 columns. Each waited for the first value, then settled for two seconds.

| Median | Baseline | Shared pointer handler |
| --- | ---: | ---: |
| Loaded RSS, KiB | 639544 | 609100 |
| RSS growth, KiB | 435760 | 407920 |
| First value, seconds | 4.665 | 4.389 |

Loaded RSS fell by 30444 KiB, or 29.7 MiB (4.76%). These [raw measurements](measurements.json) support this fixture only. No general latency, release-build, PostgreSQL or leak conclusion is established. Substantial wide-grid memory remains.

Reproduce using the [probe](probe.py) and the existing [isolated runner adaptation](../grid-keyboard-menu-routing-2026-10-23/runner.patch), with the baseline and candidate immutable executables selected through TABLEPRO_GTK_BINARY, zero scenario retries and a 45-second wait bound. Process identity was checked by the owned-application helper.
