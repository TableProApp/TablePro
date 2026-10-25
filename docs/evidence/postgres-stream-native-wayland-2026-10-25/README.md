# PostgreSQL large-result profile on native Wayland

This measurement follows [issue 1272](https://github.com/cozyGarage/BookiE/issues/1272) on Linux source commit `58805ca17fcf4e450a43cde9207287741bbaa53d`. It uses a release build of that source, a disposable PostgreSQL 16.15 container, and the issue's 2,000,000-row, ten-column `SELECT * FROM big` workload. The application ran on Arch Linux / Omarchy through native Wayland on Hyprland 0.56.2. Build, executable, runtime, and fixture identities are in [build.json](build.json). Raw per-cycle process CPU and `/proc/PID/smaps_rollup` samples are in [profile.json](profile.json).

Timers measure the application through its visible terminal state under the AT-SPI harness; they are not PostgreSQL-only timings.

## Results

| Measure | Cycle 1 | Cycle 2 | Cycle 3 |
| --- | ---: | ---: | ---: |
| Query completion | 11.607 s | 11.494 s | 12.713 s |
| Process CPU through completion | 11.94 s | 11.58 s | 13.39 s |
| RSS before query | 154.7 MiB | 439.8 MiB | 448.8 MiB |
| RSS after query and page navigation settled | 423.4 MiB | 453.5 MiB | 453.5 MiB |
| RSS three seconds after editor close | 439.4 MiB | 448.5 MiB | 448.5 MiB |

The first cycle raised RSS by about 285 MiB after closing the editor. The next two cycles settled at about 448.5 MiB after close, with no further increase between them. This three-cycle sample shows a plateau after the first cycle in this run. It does not establish long-session leak freedom or explain which live allocations, caches, or toolkit resources account for the resident memory.

All three queries received 2,000,000 rows. The grid reported 400 pages and retained rows `1,855,001–2,000,000`; earlier rows were unavailable. The retained interval is 145,000 rows (29 pages at 5,000 rows per page). The profile navigated four adjacent pages backwards and forwards within that interval. It did not traverse the entire retained interval. This confirms the current product's bounded-history behavior and leaves the earlier-row navigation limitation unresolved; see [issue 554](https://github.com/cozyGarage/BookiE/issues/554) for streamed-result product work.

## Scope and limits

- This is a source-built release binary running on native Wayland. It is not an installed Arch package run.
- The run used a private D-Bus session and a temporary Secret Service keyring. It did not read or write the user's desktop keyring.
- Native keyboard injection did not close the query tab in this harness. The profile adapter used the accessible `Close Tab` button for the same close operation.
- Cancellation, very long idle periods, full traversal of the retained interval, and heap attribution were not measured here.
- No product code changed for this measurement. The first harness attempt exposed missing test-session Secret Service setup; the successful run used an isolated keyring and a separate MCP port.

The [existing probe](../postgres-stream-current-2026-10-24/probe-original-table.py) contains the shared query, pager, CPU, and RSS checks. The native run also moved the test window to workspace 4 and used the Wayland-specific close-button adapter described above.
