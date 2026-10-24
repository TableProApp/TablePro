# Native PostgreSQL 100,000-row profile

## Scope

This capture records one run of `SELECT generate_series(1, 100000) AS n;` in the BookiE binary extracted from the Arch package built at commit `7c2371837c4cc1b3a3fbbea014e0a7336a190ff1`. The package passed `makepkg check()` and `scripts/validate-arch-package.sh`. The extracted binary was run from the package tree; it was not installed. The installed 0.2.0 package was not used for this capture.

The query ran against the local PostgreSQL 17.11 lab connection in a 922 × 1150 window. The saved screenshot shows `done in 168 ms`, 100,000 received rows across 20 pages, and only rows 80,001–100,000 retained. The selected page is rows 80,001–85,000. Previous page is disabled, so rows 1–80,000 cannot be revisited from this result. The current full-result export action reruns the statement through a guarded cursor; it does not restore old pages to the grid.

## Process sample

`native-postgres-100k-31s.json` contains 121 samples at 250 ms intervals, starting immediately after the native Run-button click and continuing for about 30 seconds. It records `/proc/<pid>/status`, `/proc/<pid>/io` and process CPU counters.

An earlier 31-second idle sample from the same extracted process is included as `native-postgres-select1-31s.json`. It shows about 2.8 MiB of RSS variation while the `SELECT 1` result was visible and no input or query was issued. The two captures used slightly different RSS field names and sampling intervals, so compare them as context rather than as a controlled before/after benchmark.

| Metric | Before click | Peak during 30.18 s | Change |
| --- | ---: | ---: | ---: |
| RSS | 119,263,232 B (113.7 MiB) | 145,301,504 B (138.6 MiB) | +24.8 MiB |
| PSS | 104,676,352 B (99.8 MiB) | 130,714,624 B (124.6 MiB) | +24.8 MiB |
| Private dirty | 32,997,376 B (31.5 MiB) | 58,290,176 B (55.6 MiB) | +24.1 MiB |
| Process CPU time | 1.77 s | 2.77 s | +1.00 s |
| Process block reads | 96,120,832 B | 96,956,416 B | +0.8 MiB |
| Process block writes | 3,043,328 B | 3,223,552 B | +0.2 MiB |

The CPU and memory deltas cover the full 30-second sample, not just the database statement. The UI reports 168 ms, but RSS growth was gradual and reached its peak near the end of the sample. This capture therefore does not isolate query execution cost from result rendering and later UI work. `/proc/<pid>/io` block I/O does not include PostgreSQL socket traffic. This is one synthetic, narrow-row result on one local environment, not a benchmark or a process-memory ceiling.

## Artifacts

- [Screenshot](native-postgres-100k.png)
- [Raw process samples](native-postgres-100k-31s.json)
- [Idle PostgreSQL sample](native-postgres-select1-31s.json)

## Current linux-head idle capture

After the package-build tests, the extracted binary from the package built at `cc0f1cac1e6ccc08d752a23eb0b80ace8a6e1bf9` was launched on the native Hyprland desktop. It was not installed. The saved PostgreSQL connection was open in a 922 × 1150 window with an empty SQL editor and results pane. Over 31.219 seconds without input, RSS varied by 16 KiB, PSS by 28 KiB, process CPU increased by 0.01 seconds, and `/proc/<pid>/io` block-read and block-write counters did not change. This is an idle sample, separate from the query profile above; it does not measure a query or database socket traffic.

- [Current-head window screenshot](native-current-head-postgres-open.png)
- [Current-head idle process samples](native-current-head-postgres-idle-31s.json)

The same current-head process then ran `SELECT generate_series(1, 100000) AS n;` on the native desktop. The UI reported 98 ms, 100,000 received rows and 20 pages. The result retained rows 80,001–100,000. I navigated Previous to rows 80,001–85,000; Previous disabled there, while Next returned to the next retained page. This reproduces the documented forward-only retention boundary on the current source head.

This is a product gap for a completed result: the first 80,000 rows are not reachable after the query finishes, even though this narrow result has only 20 pages. The fixed four-page count, rather than a user-visible decision or a confirmed byte-budget exhaustion, is the observed boundary. The issue is tracked in [#1032](https://github.com/cozyGarage/BookiE/issues/1032). The capture demonstrates the regression surface; it does not establish the memory cost of retaining all 20 pages.

A 31.015-second sample began after the query had completed, with the grid on the newest retained page and no input. RSS stayed at 125.1 MiB, PSS varied by 13 KiB, Private Dirty decreased by 12 KiB, process CPU advanced by 0.02 seconds, and block-read/write counters did not change. This measures the retained-result idle state, not query execution or socket traffic. The earlier 30-second sample above covers a separate run that included query and UI work; the samples are not a controlled comparison.

- [Current-head oldest-retained-page screenshot](native-current-head-100k-oldest-retained.png)
- [Current-head completed-result process samples](native-current-head-postgres-100k-31s.json)

## Current linux-head MySQL browse capture

The same extracted binary opened the saved Manual Lab MySQL connection and loaded the `people` table (2 rows). During a 31.238-second idle sample, RSS stayed at 124.2 MiB, PSS varied by 6 KiB, Private Dirty stayed at 36.0 MiB, CPU advanced by 0.02 seconds, and process block-read/write counters did not change. This is a small-table browse sample, not a cross-engine benchmark; the app binary was extracted from the Arch package and was not installed.

- [MySQL people table screenshot](native-current-head-mysql-people.png)
- [MySQL browse process samples](native-current-head-mysql-people-31s.json)

## Current linux-head SQL Server idle capture

With the saved Manual Lab SQL Server connection open and its schema metadata loaded, a 31.029-second sample with no BookiE input recorded RSS at 132.8 MiB, PSS at about 106.1 MiB, CPU +0.02 seconds, and no process block I/O. This is a connected idle state with no query result displayed. The extracted package binary was used, not the installed package.

- [SQL Server idle process samples](native-current-head-mssql-idle-31s.json)

## Additional native engine browse captures

Each saved profile connected and displayed its sample data in the grid. These 31-second captures were taken sequentially in the same app process after switching profiles. RSS and PSS therefore include memory retained from earlier UI and connection work; they do not isolate per-engine cost. Each interval had no BookiE input and no process block-read or block-write delta.

| Connection and view | RSS | PSS | Process CPU change | Samples |
| --- | ---: | ---: | ---: | --- |
| ClickHouse, `people` (2 rows) | 137.5 MiB | 111.3 MiB | +0.00 s | [Raw samples](native-current-head-clickhouse-people-31s.json) |
| MongoDB, `people` (2 documents) | 145.3 MiB | 119.2 MiB | +0.03 s | [Raw samples](native-current-head-mongodb-people-31s.json) |
| Redis DB 0 (5 keys) | 162.8 MiB | 135.5 MiB | +0.01 s | [Raw samples](native-current-head-redis-db0-31s.json) |
| SQLite, `people` (4 rows, mixed and null values) | 168.9 MiB | 141.7 MiB | +0.02 s | [Raw samples](native-current-head-sqlite-people-31s.json) |

The native UI sweep used the extracted package binary and the ten saved Manual Lab profiles. Each connection opened and its data view rendered successfully; no rows were changed.

| Saved profile | Native UI result |
| --- | --- |
| PostgreSQL | Ran the 100,000-row generator query; 100,000 rows were received and the newest retained rows rendered. |
| PostgreSQL Extra | Opened `people`; 2 rows rendered. |
| MySQL | Opened `people`; 2 rows rendered. |
| MySQL Extra | Opened `people`; 2 rows rendered. |
| SQL Server | Opened `dbo.people`; 2 rows rendered. `SELECT 1;` returned `1`. |
| ClickHouse | Opened `people`; 2 rows rendered. |
| MongoDB | Opened `people`; 2 documents rendered. |
| Redis | Opened DB 0; 5 keys rendered. |
| Redis DB 1 | Opened DB 1; 1 key rendered. |
| SQLite | Opened `people`; 4 rows rendered, including null and mixed-value examples. |

After switching through all ten profiles, I sampled the same process for another 31.162 seconds with SQL Server selected and an editor tab open. RSS held at 185.6 MiB, PSS at about 156.5 MiB, Private Dirty at 82.0 MiB, CPU increased by 0.02 seconds, and block-read/write counters did not change. This is the cumulative warm-process state after the full UI sweep, not an engine-isolated memory cost.

- [Post-sweep process samples](native-current-head-multi-engine-after-sweep-31s.json)

## Local storage footprint

After the ten-profile UI sweep, `du -sb` reported 125,812 bytes in `~/.config/tablepro`, 597,504 bytes in `~/.local/share/tablepro` and 4,732 bytes in `~/.cache/tablepro`. The share directory contained a 596,935-byte audit journal; the config directory contained a 5,121-byte connection file and SQLite query-history database/WAL/SHM files. The earlier capture before the full sweep was 282,903 bytes in config and 540,234 bytes in share. SQLite history files can change size as the WAL is checkpointed. These figures cover this machine's saved profiles and app data; they exclude the Docker database volumes. The current Arch package is 29,886,373 bytes compressed, the extracted application binary is 42,385,896 bytes, and package metadata reports 72.61 MiB installed size. Installation is still pending, so the new package's actual installed footprint has not been measured with pacman.

## Product finding

The four-page cache and forward-only cursor are operating as designed under [ADR 0011](../../decisions/0011-paged-query-results.md), but a completed query can report all rows while making the earlier rows unavailable in the grid. This is a usability limitation, not a paging-control defect. Keep the memory bound while evaluating a way to revisit results, such as a scrollable cursor under the same guarded snapshot or a bounded disk-backed page spool. Any design must preserve the existing query policy, audit, cancellation, timeout, value-preservation and cleanup contracts. Broader large-result acceptance remains tracked by [#554](https://github.com/cozyGarage/BookiE/issues/554).
