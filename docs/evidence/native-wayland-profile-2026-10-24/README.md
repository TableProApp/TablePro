# Installed Omarchy profile: PostgreSQL result sizes

This capture records an installed BookiE build running in the maintainer's Omarchy Arch and Hyprland session. It measures one local PostgreSQL connection in several states. It is a workload sample, not a performance benchmark or a process-memory limit.

## Build and host

- Package: `bookie 0.2.0-1`, installed size 72.63 MiB.
- Installed executable: 42,395,816 bytes; SHA-256 `3d86d7f99c851c90365afb3c4147f1b3f87eb07d56756b2673546b8f030684f1`.
- Package build source: `d9b5aaca6af5889f7a67025c6a878cf732a92ac7`. The native profile was captured while Linux was at `b5dafaef164d19bf014ce5b286259ac630dfcd34`; the hotfix worktree was later synced with Linux `5ccddc7f7` and its post-sync checks are listed below.
- Host: Omarchy Arch Linux, Hyprland, Wayland, 1920×1200 at scale 1.0.
- Database: local PostgreSQL 17.11 in the existing Manual Lab container.
- Process: `/usr/bin/bookie`, PID 1900468, using a fresh isolated XDG profile under `/tmp/bookie-native-fresh-20261024`.

The sampler read process CPU ticks, RSS, PSS, private dirty memory, swap and process block I/O from `/proc`. RSS is resident memory; PSS apportions shared pages; Private Dirty is private resident memory. Compressed JSON samples and test logs are in [raw](raw/).

## Workload observations

| State | UI/query observation | CPU time in sample | Peak RSS | Peak PSS | Peak Private Dirty | Process I/O |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Connected idle, 31.1 s | Restored `SELECT 1`; no query result work | +0.00 s | 118,760 KiB | 103,344 KiB | 31,776 KiB | 0 B read / 0 B written |
| Narrow query, 100,000 integers, 40.1 s sample | Query showed 471 ms; all 20 pages remained navigable back to rows 1–5,000 | +0.57 s | 145,216 KiB | 129,645 KiB | 55,096 KiB | +61,440 B read / 0 B written |
| Export of the 100,000-row result, 45 s sample | CSV contains 100,000 data rows plus header; file is 588,897 B | +0.24 s across the full sampling interval, including dialog time | 155,580 KiB | 140,012 KiB | 65,460 KiB | +16,384 B read / 0 B written |
| Wide query, 100,000 rows with 2,048 `x` characters each, 40.1 s sample | Query showed 1,689 ms; only rows 70,001–100,000 remained available | +2.30 s | 298,024 KiB | 278,382 KiB | 207,404 KiB | 0 B read / 0 B written |
| Wide result retained, then idle for 31 s | Earliest retained page was 70,001–75,000; Previous was disabled | +0.01 s | 298,024 KiB | 277,853 KiB | 207,404 KiB | 0 B read / 0 B written |

The export sampler spans interaction before and after the save, so its CPU delta is not export-only. Query durations are application-reported UI times, not measured server execution times. The retained wide result kept its memory footprint through the following idle sample.

The isolated XDG profile totaled about 4.4 MiB after the queries and export: config 145,873 B, data 82,608 B, cache 4,376,533 B and state 0 B. The generated CSV was 588,897 B. This excludes the installed application package and database container storage.

## Screenshots

- [Narrow result on the first page](narrow-100k-first-page.png): all 20 pages were present and navigation returned to rows 1–5,000.
- [Wide result at its oldest retained page](wide-100k-oldest-retained.png): rows 70,001–75,000 are shown, with earlier rows reported as unavailable.
- [Sidebar before the fix](sidebar-fields-stuck-before-fix.png): three expanded PostgreSQL tables remained on “Loading fields…”. The maintainer confirmed the state persisted for more than one hour.

The sidebar issue was reproduced in the installed package and by the new `expanding_a_sidebar_table_loads_its_columns` GTK scenario before the fix. The scenario failed after 16.7 seconds because `id` and `note` never appeared; the captured baseline is [here](raw/sidebar-columns-before-fix.log.gz). PostgreSQL remained healthy and had no active metadata query. The request path returned `ColumnReply` as the factory command output, but `drop_on_shutdown()` intentionally discards that output. The factory now uses `oneshot_command`, which forwards the returned reply to `update_cmd`. The focused regression and full GTK safety script exited 0 against the rebuilt source binary before the Linux sync. After syncing with Linux `5ccddc7f7`, the rebuilt exact-head binary also passed the focused regression; its log is [here](raw/sidebar-columns-after-fix.log.gz).

## UI and test coverage

The native Wayland session was used to run the two queries, navigate the result pages, and export the CSV. No database rows were modified. Native pointer checks for Split and sidebar toggle/resize remain incomplete. A native accessibility probe was blocked because the session advertised an AT-SPI bus socket that did not exist; GTK automation ran in its isolated Xvfb and private D-Bus setup instead.

Completed local test layers on this checkout:

- Driver integration: 619 passed, 0 failed (`scripts/ci-local.sh integration`).
- GTK widgets: 164 passed, 0 failed (`scripts/test-gtk-widgets.sh`).
- Installed GTK safety: 112 passed, 0 failed against `/usr/bin/bookie` (`GDK_DEBUG=no-portals TABLEPRO_GTK_BINARY=/usr/bin/bookie scripts/test-gtk-safety.sh`, system Python on `PATH`).
- GTK safety after the sidebar fix: full suite exited 0 against the rebuilt source binary before the Linux sync; the exact post-sync binary passed the focused sidebar scenario. The installed `/usr/bin/bookie` package has not yet been replaced with the fixed build.
- Preflight after syncing with Linux `5ccddc7f7`: passed, including 2,081 unit tests and 2,093 sandbox tests; 16 unit tests and 65 sandbox tests were skipped by their configured filters.
- GTK widgets after syncing with Linux `5ccddc7f7`: 164 passed, 0 failed.
- GTK database scenarios: ClickHouse enum grid edit, MySQL approval and dispatch, and MongoDB cursor/grid edit all passed on this checkout (`scripts/test-gtk-clickhouse.sh`, `scripts/test-gtk-mysql-approval.sh`, and `scripts/test-gtk-mongodb.sh`, launched through `run-test-layer.py`). Compressed logs and run reports are in [raw](raw/).
- App-server database contracts: 38 isolated cases passed (`scripts/run-isolated-tests.py app-server`, launched through `run-test-layer.py`). The compressed log and run report are in [raw](raw/).
- PostgreSQL release acceptance: 7 tests passed, including mTLS, SSH host-key refusal/audit, tunnel loss and multi-hop SSH (`scripts/test-postgres-release.sh`, launched through `run-test-layer.py`). The compressed log and run report are in [raw](raw/).

Forgejo run 951 for the exact Linux head failed before tests: guards, sandbox and widgets could not check out the repository because the Forgejo runner reported `No space left on device`. Unit and Clippy passed; downstream jobs were skipped. This is runner checkout evidence, not a product test failure. The local Git object pack is 344.48 MiB and the tracked `docs/evidence` working tree is 63 MiB, so this evidence does not establish that repository size caused the runner's disk exhaustion.
