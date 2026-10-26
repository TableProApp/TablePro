# UI, defect and performance checks, 2026-10-25

## Source and runtime

- Source: `linux` at `f115dd12de6eb89dc4fc4e29214c0ab25bf1f377`; working tree was clean before this evidence packet.
- Runtime binary: local `target/release/tablepro-app`, built with Rust 1.98.1 from that source; SHA-256 `a65b244d9d1637308aed3e9274cec21b4033be409fc149791c84e81037296424`.
- Host: Arch Linux / Omarchy, kernel `7.2.8-9-omarchy`, Hyprland 0.56.2, GTK 4.24.1, libadwaita 1.10.0, GtkSourceView 5.22.0.
- Native session: Wayland, eDP-1 at 1920x1200, scale 1, dark appearance. The app was kept open on workspace 5.
- Test database: disposable development-profile SQLite file `/tmp/bookie-native-ui-20261024.sqlite`.

## Results

- Installed GTK safety harness: **118/118 scenarios passed** on the release binary under Xvfb/AT-SPI. The artifacts are in ignored `target/quality/gtk-safety-2026-10-25-no-portals/`. `GDK_DEBUG=no-portals` was required because the host file chooser portal interface was unavailable. This is Xvfb coverage, not native Wayland acceptance.
- GTK widget tier: **165 tests passed** under Xvfb (`scripts/test-gtk-widgets.sh`). The run emitted Mesa DRI3 warnings from software rendering.
- Deterministic performance regressions: stream-page tests **6 passed**; preview matrix **1 passed** (32 configured combinations); completion tests **50 passed**.
- Synthetic SQLite grid profile: `scripts/profile-row-retention.sh`, 10k, 100k and 300k requested rows, three runs each and 1,000 scroll steps. All nine scenario runs passed their correctness checks. Raw samples are in ignored `target/quality/row-retention-2026-10-25.jsonl`.

| Requested rows | Retained rows | Query duration shown by app | First-result wall time | Peak RSS range | Scroll middle / end / return to top |
|---:|---:|---:|---:|---:|---:|
| 10,000 | 10,000 | 34–40 ms | 0.89–0.98 s | 195.3–195.5 MiB | 8.37–8.45 / 8.43–8.54 / 15.89–16.99 s |
| 100,000 | 100,000 | 358–366 ms | 1.35–1.39 s | 232.9–233.8 MiB | 24.53–24.90 / 24.96–25.45 / 40.65–42.27 s |
| 300,000 | 209,754 | 731–769 ms | 1.76 s | 279.4–280.8 MiB | 41.81–46.83 / 43.15–43.64 / 73.66–74.80 s |

The 300k result displayed the truncation notice and the profile reached the last retained rows. Timings and RSS are host-specific Xvfb observations, not limits or a PostgreSQL benchmark. The script uses a synthetic SQLite fixture.

## Native Wayland checks

On the native app window, keyboard input replaced the editor query and Ctrl+Return ran it. `SELECT 42 AS native_check;` returned `42` with no error. `SELECT * FROM no_such_table;` displayed “Statement 1 failed” and the SQLite `no such table` error. A subsequent `SELECT 7 AS recovered;` ran successfully, confirming recovery after the query error.

A second query loaded both fixture rows and displayed `nullable_text`, `empty_text`, and `exact_decimal`. The NULL cell used the null marker, the empty string cell remained blank, a non-empty string remained visible, and numeric values appeared as `123456789.0123` and `0.000001`. A direct `sqlite3` query against the same file confirmed those source values and lengths.

Ctrl+J hid the results panel and a second press restored it with the two-row result unchanged. This also worked after Tab focus moved into the result grid; the selected row and values remained intact after restoring. Ctrl+E opened a new query tab; `SELECT 11 AS fresh_tab;` ran and returned 11; Ctrl+W closed the new tab and restored the previous query and its two-row result. Tab focus reached the result grid and Errors control.

F10 opened the app menu and Escape closed it. Ctrl+, opened Preferences; the Appearance and Editor pages were navigable with arrow keys and Enter, and Escape closed the window. No preference values were changed. The app showed System appearance, Default theme, 12-point editor text, Vim keys off, and a 60-second query timeout.

Ctrl+O opened the native SQL file chooser. A temporary SQL file was selected through the chooser location entry, opened in a tab, edited from `SELECT 202 AS file_ui;` to `SELECT 203 AS file_ui;`, saved, and run; the editor returned 203 and the saved file contained the edited statement. This verifies native open, edit, save, and execution for an existing SQL file.

Save As on a new untitled tab exposed a reproducible data-loss defect. The new tab displayed the default `SELECT 1;`; after Save As to `/tmp/bookie-native-save-as-2026-10-25.sql`, the app showed “Saved” but the created file was 0 bytes. This was observed before later editing that test file, and is independent of the subsequent split-editor save. Keep this as a release-blocking defect until fixed and covered by regression tests.

The test binary predates the fix. Commit `7c0a5c85f` initializes new editor tabs with the same default query used by the visible editor buffer and adds a GTK safety scenario that checks Save As writes `SELECT 1;`. The fix remains on the separate `ux/save-as-default-query` branch, which is being brought up to the current Linux tip. The original native Wayland failure remains valid for the recorded `f115dd12` source. This packet does not claim the fix is on `linux` or that it has been retested on native Wayland.

The combined fix branch at `c99410476905af92790a4a3eae82c53b3d1f56d1` includes Linux `27bee0b66c74f51178a2b8aec6fc7a6e8435bdeb`. Its focused workspace regression passed (1 passed, 1,005 filtered), and `save_default_query_as_writes_the_visible_sql` passed in the installed GTK safety harness (1/1, 5.988 seconds) under Xvfb/AT-SPI with `GDK_DEBUG=no-portals`. The test binary was `target/installed-ci/usr/bin/tablepro`, SHA-256 `758643e1c7a8b514a82f0b2df22a867db480c4dde89df36e771d69dc7770dfe2`. The GTK widget tier passed 170 tests. Preflight passed 569 harness tests, 2,138 unit tests, 291 sandbox tests, the Redis cancellation test, Clippy, formatting and guardrails. An initial GTK attempt without `GDK_DEBUG=no-portals` could not reach the chooser because the host portal lacks its file chooser interface; the configured rerun verified the saved file contains `SELECT 1;`. This validates the fix branch under Xvfb, not the native Wayland session or the current `linux` branch.

Split mode displayed two synchronized editor panes. Editing the left pane changed the right pane, Ctrl+Return ran `SELECT 404 AS split_shared;` and displayed 404, and Ctrl+S wrote the statement to disk. Keyboard Tab probes remained in the editor and inserted literal tab characters; this test input was saved only to the disposable test file and then restored. It did not establish keyboard traversal to the Split control. The screenshot captured immediately after the successful split save shows the “Saved” toast and no dirty marker; a later screenshot with a marker was explained by the appended tabs, not by a spontaneous dirty-state change.

Screenshots in this directory:

- [Successful query](native-query-success.png)
- [SQL error](native-query-error.png)
- [Successful query after the error](native-query-recovery.png)
- [Grid values compared with SQLite](native-grid-values.png)
- [Results hidden](native-results-hidden.png)
- [Results restored](native-results-restored.png)
- [New query result](native-new-query-result.png)
- [Previous result restored after closing the new tab](native-tab-close-restores-result.png)
- [Grid focused and results hidden with Ctrl+J](native-grid-focus-hidden.png)
- [Grid selection restored with Ctrl+J](native-grid-focus-restored.png)
- [App menu opened with F10](native-main-menu.png)
- [Preferences Appearance page](native-preferences-appearance.png)
- [Preferences Editor page](native-preferences-editor.png)
- [Preferences closed with Escape](native-preferences-closed.png)
- [Split editor and shared result](native-split-editor.png)
- [Split editor after save](native-split-saved.png)

These are focused smoke checks on a local SQLite development profile, not package-install acceptance or multi-driver coverage. The 199 items across the current manual verification checklists remain broader work; this run did not cover all dialogs, narrow layouts, light appearance, clipboard paths, Orca, SSH, or live database servers. It also does not establish PostgreSQL performance, soak behavior, or leak freedom. See [manual verification](../../manual-verification-0.2-features.md) and [performance scenarios](../../performance-acceptance-scenarios.md) for the full scope.
