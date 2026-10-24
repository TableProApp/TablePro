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

## Product finding

The four-page cache and forward-only cursor are operating as designed under [ADR 0011](../../decisions/0011-paged-query-results.md), but a completed query can report all rows while making the earlier rows unavailable in the grid. This is a usability limitation, not a paging-control defect. Keep the memory bound while evaluating a way to revisit results, such as a scrollable cursor under the same guarded snapshot or a bounded disk-backed page spool. Any design must preserve the existing query policy, audit, cancellation, timeout, value-preservation and cleanup contracts. Broader large-result acceptance remains tracked by [#554](https://github.com/cozyGarage/BookiE/issues/554).
