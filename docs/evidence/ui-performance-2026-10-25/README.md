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

Screenshots in this directory:

- [Successful query](native-query-success.png)
- [SQL error](native-query-error.png)
- [Successful query after the error](native-query-recovery.png)

These are focused smoke checks on a local SQLite development profile, not package-install acceptance or multi-driver coverage. The 199 items across the current manual verification checklists remain broader work; this run did not cover all dialogs, narrow layouts, light appearance, clipboard paths, Orca, SSH, or live database servers. It also does not establish PostgreSQL performance, soak behavior, or leak freedom. See [manual verification](../../manual-verification-0.2-features.md) and [performance scenarios](../../performance-acceptance-scenarios.md) for the full scope.
