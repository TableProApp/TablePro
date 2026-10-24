# Native PostgreSQL 100,000-row profiles before and after #1568

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

## Pre-#1568 linux-head retention failure

After the package-build tests, the extracted binary from the package built at `cc0f1cac1e6ccc08d752a23eb0b80ace8a6e1bf9` was launched on the native Hyprland desktop. It was not installed. The saved PostgreSQL connection was open in a 922 × 1150 window with an empty SQL editor and results pane. Over 31.219 seconds without input, RSS varied by 16 KiB, PSS by 28 KiB, process CPU increased by 0.01 seconds, and `/proc/<pid>/io` block-read and block-write counters did not change. This is an idle sample, separate from the query profile above; it does not measure a query or database socket traffic.

- [Current-head window screenshot](native-current-head-postgres-open.png)
- [Current-head idle process samples](native-current-head-postgres-idle-31s.json)

The same current-head process then ran `SELECT generate_series(1, 100000) AS n;` on the native desktop. The UI reported 98 ms, 100,000 received rows and 20 pages. The result retained rows 80,001–100,000. I navigated Previous to rows 80,001–85,000; Previous disabled there, while Next returned to the next retained page. This reproduces the documented forward-only retention boundary on the current source head.

On the source head tested before #1568, this was a product gap: the first 80,000 rows were not reachable after the query finished, although this narrow result had only 20 pages. The fixed four-page count, rather than confirmed byte-budget exhaustion, was the observed boundary. The capture demonstrates the pre-fix regression surface; it does not establish the memory cost of retaining all 20 pages.

A 31.015-second sample began after the query had completed, with the grid on the newest retained page and no input. RSS stayed at 125.2 MiB, PSS varied by 13 KiB, Private Dirty decreased by 12 KiB, process CPU advanced by 0.02 seconds, and block-read/write counters did not change. This measures the retained-result idle state, not query execution or socket traffic. The earlier 30-second sample above covers a separate run that included query and UI work; the samples are not a controlled comparison.

- [Current-head oldest-retained-page screenshot](native-current-head-100k-oldest-retained.png)
- [Current-head completed-result process samples](native-current-head-postgres-100k-31s.json)

## BookiE branch verification after byte-budget retention change

The release-mode BookiE binary built from the `ux/stream-result-full-navigation` worktree ran the query against the local PostgreSQL 17.11 lab after a fresh app launch and connection. The UI reported completion in 161 ms and received 100,000 rows in 20 pages. I navigated backward from the newest page to rows 1–5,000; the grid displayed values starting at 1. This confirms that the former four-page cutoff no longer hides pages when the estimated row storage fits within the cache budget.

The process was sampled every 250 ms for 31.254 seconds, starting immediately before Run. RSS rose from 119,087,104 bytes (113.6 MiB) to a 145,596,416-byte peak (138.9 MiB), a 25.3 MiB increase. PSS rose from 91.2 MiB to a 116.5 MiB peak; private dirty memory rose from 28.1 MiB to 50.0 MiB. The peak occurred about 7.6 seconds into the sample, after the UI reported completion. Process CPU increased by 0.25 seconds; block reads increased by 16 KiB and writes by 124 KiB. The block-I/O counters do not include PostgreSQL socket traffic. This is one narrow synthetic query on one local machine, not a general benchmark or process-memory ceiling. It does not qualify results that exceed the 64 MiB estimated row-storage budget.

- [Page 1 screenshot](native-bookie-branch-100k-page1.png)
- [31-second baseline-to-peak process sample](native-bookie-branch-100k-first-run-31s.json)

## Current linux-head MySQL browse capture

The same extracted binary opened the saved Manual Lab MySQL connection and loaded the `people` table (2 rows). During a 31.238-second idle sample, RSS stayed at 124.2 MiB, PSS varied by 6 KiB, Private Dirty stayed at 36.0 MiB, CPU advanced by 0.02 seconds, and process block-read/write counters did not change. This is a small-table browse sample, not a cross-engine benchmark; the app binary was extracted from the Arch package and was not installed.

- [MySQL people table screenshot](native-current-head-mysql-people.png)
- [MySQL browse process samples](native-current-head-mysql-people-31s.json)

## Current linux-head SQL Server idle capture

Memory values in this section are sample-start readings rounded to one decimal MiB; CPU is the interval delta. With the saved Manual Lab SQL Server connection open and its schema metadata loaded, a 31.029-second sample with no BookiE input recorded RSS at 132.9 MiB, PSS at 106.2 MiB, CPU +0.02 seconds, and no process block I/O. This is a connected idle state with no query result displayed. The extracted package binary was used, not the installed package.

- [SQL Server idle process samples](native-current-head-mssql-idle-31s.json)

## Additional native engine browse captures

Each saved profile connected and displayed its sample data in the grid. These 31-second captures were taken sequentially in the same app process after switching profiles. RSS and PSS therefore include memory retained from earlier UI and connection work; they do not isolate per-engine cost. Each interval had no BookiE input and no process block-read or block-write delta.

The table uses each profile's sample-start baseline for RSS and PSS, rounded to one decimal MiB. CPU is the last-minus-first sample delta.

| Connection and view | RSS | PSS | Process CPU change | Samples |
| --- | ---: | ---: | ---: | --- |
| ClickHouse, `people` (2 rows) | 137.5 MiB | 111.4 MiB | +0.00 s | [Raw samples](native-current-head-clickhouse-people-31s.json) |
| MongoDB, `people` (2 documents) | 145.3 MiB | 119.2 MiB | +0.03 s | [Raw samples](native-current-head-mongodb-people-31s.json) |
| Redis DB 0 (5 keys) | 162.8 MiB | 135.5 MiB | +0.01 s | [Raw samples](native-current-head-redis-db0-31s.json) |
| SQLite, `people` (4 rows, mixed and null values) | 169.0 MiB | 141.7 MiB | +0.02 s | [Raw samples](native-current-head-sqlite-people-31s.json) |

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

After the ten-profile UI sweep, `du -sb` reported 125,812 bytes in `~/.config/tablepro`, 597,504 bytes in `~/.local/share/tablepro` and 4,732 bytes in `~/.cache/tablepro`. The share directory contained a 596,935-byte audit journal; the config directory contained a 5,121-byte connection file and SQLite query-history database/WAL/SHM files. The earlier capture before the full sweep was 282,903 bytes in config and 540,234 bytes in share. SQLite history files can change size as the WAL is checkpointed. These figures cover this machine's saved profiles and app data; they exclude the Docker database volumes. The Arch package is 29,886,373 bytes compressed and its metadata reports 72.61 MiB installed size. A later pacman installation and binary verification are recorded below.

## Product finding

Before installing the PR #1568 candidate, the published 0.2.0 binary retained four pages. The candidate removed that page-count cap, but still evicts older pages when estimated retained row storage exceeds 64 MiB. A 100,000-row narrow result kept all 20 pages; a 100,000-row result with 2 KiB text values retained only rows 70,001–100,000. The earliest available page was rows 70,001–75,000, with Previous disabled. The completed query still reported all 100,000 rows. This packet records source-build, extracted-package and installed-candidate observations; it does not qualify the published release. Broader memory and result-retrieval work remains under [#1032](https://github.com/cozyGarage/BookiE/issues/1032) and [#554](https://github.com/cozyGarage/BookiE/issues/554); follow-up must preserve query policy, audit, cancellation, timeout, value preservation and cleanup contracts.

## Native result-cache capture from PR commit 748c75c

On 2026-10-24, an Arch package recorded as built from PR commit `748c75c0f904e6c53f41236b1a3d36668bd079b5` was first extracted and run on the Omarchy Wayland desktop. The PR later merged at `3e9f22a70d49417935e5c034753e0e02c229f7ca` from final head `bee68f0bb93e8e5295a6bcc7cfb027565f0a14c7`. At that stage, the package had not yet been installed. Package SHA-256: `c23e787348daeeabeecc750735f0d7759c4567a663c391597ddee8cdf90fc2bd`. Extracted `bookie` SHA-256: `b406fd8055670abc230cfead154eb27ff39dbff7f46ca8a4b0f67a6c6c50b971`; the same hash was verified after installation.

On PostgreSQL 17.11, `SELECT generate_series(1, 100000) AS n;` completed in 160 ms and returned 100,000 rows across 20 pages. The UI navigated from the last page back to rows 1–5,000. This confirms the PR #1568 source build removes the four-page behavior measured in the published 0.2.0 build for this result. It does not test results that exceed the 64 MiB estimated in-memory page budget.

The app process was at 107,472 KiB RSS, 96,537 KiB PSS and 39,044 KiB private dirty before Run. After the query, navigating to the first page and then sitting idle for 31.72 seconds, it held 239,190,016 B RSS, 227,978,240 B PSS and 168,579,072 B private dirty. RSS and private dirty were unchanged across that idle sample; PSS varied by 8 KiB. CPU rose by 0.02 seconds. `/proc/<pid>/io` block-read and block-write counters did not change. The RSS increase includes fetched pages and GTK result rendering; this profile does not isolate those costs.

At the end of the run, `du -sb` reported 123,365 bytes in `~/.config/tablepro`, 675,264 bytes in `~/.local/share/tablepro` and 4,732 bytes in `~/.cache/tablepro`. These are whole-directory totals for the existing user profile, not per-query deltas. The screenshot records the first page after backward navigation: [native PR #1568 100,000-row result](native-pr1568-100k-page1.png).

The byte-budget boundary was tested with `SELECT n, repeat('x', 2048) AS payload FROM generate_series(1, 100000) AS n;` on the same PostgreSQL 17.11 server. It completed in 2,024 ms. The UI received 100,000 rows in 20 pages but retained only rows 70,001–100,000; Previous became disabled on rows 70,001–75,000. A [native screenshot](native-pr1568-100k-wide-budget-boundary.png) records that state. This reproduces the remaining navigation loss on the PR candidate.

After that wide query, the process held 384,832 KiB RSS, 373,697 KiB PSS and 316,180 KiB private dirty. A 42-second idle sample held RSS and private dirty steady; PSS changed by 11 KiB. Block-read/write counters stayed at 2,019,328 and 2,793,472 bytes. The user profile totals were 189,285 bytes in config, 722,490 bytes in share and 4,732 bytes in cache, unchanged during the idle sample. On a repeat run, `/proc/<pid>/stat` advanced by 230 CPU ticks over a three-second sample (2.30 CPU seconds); the UI reported 1,891 ms. RSS rose by 10,772 KiB from the preceding stable sample. The user profile totals then rose to 222,245 bytes in config and 744,941 bytes in share, with cache unchanged. These directory totals include history and audit state and are not query-result-only storage measurements.

I repeated the wide query on the same extracted candidate later in the native session. The UI reported 1,741 ms and 100,000 rows across 20 pages. After five Previous clicks, the pager stopped at rows 70,001–75,000 with Previous disabled. A 31.0-second sample spanning query execution and page navigation measured RSS from 134.5 MiB to 329.5 MiB and process CPU growth of 3.76 seconds. During the following 31.0-second idle sample on that retained page, RSS stayed at 382.5 MiB, PSS at about 358.0 MiB, private dirty memory at 309.6 MiB, CPU grew by 0.01 seconds and process block I/O did not change. The profile directories then measured 222,490 bytes in config, 832,967 bytes in share and 4,732 bytes in cache. The query/navigation sample includes UI work and the idle sample starts after the five page changes; these are sequential observations, not a controlled comparison. Both raw samples and the [oldest reachable page capture](native-pr1568-current-wide-oldest.png) are preserved here.

## Native UI spot checks

On the same live desktop, clicking Split opened a second editor pane; clicking it again returned to one pane. The [split](native-pr1568-split-on.png) and [unsplit](native-pr1568-split-unsplit.png) states were captured. The sidebar toggle opened and closed the panel. At full-window width, dragging its divider widened it from about 260 px to about 400 px; hiding and showing the sidebar preserved the resized width ([capture](native-pr1568-sidebar-resized.png)). In the side-by-side layout, the pane stayed near 260 px when dragged wider, consistent with the editor's 600 px minimum-width constraint at that window size.

With `SELECT 1;` displayed in the query editor and its result visible, opening the sidebar hid the result grid and its pager while leaving the query tab and SQL visible. Closing the sidebar restored the result without rerunning the query. This reproduced in two open/close cycles on the native desktop; it shows a temporary presentation-state change, not lost result data. The [sidebar-open capture](native-pr1568-sidebar-open-result-hidden.png) and [sidebar-closed capture](native-pr1568-sidebar-closed-result-restored.png) show one pair of states. Track this UI observation with [#1490](https://github.com/cozyGarage/BookiE/issues/1490).

In a separate browse check on the same candidate and PostgreSQL profile, `sales.orders` loaded five rows and rendered column names and types. Expanding the table row in the sidebar left `Loading fields…` visible for more than a minute. At inspection time, the BookiE PostgreSQL sessions were idle; this does not identify whether the command result was dropped in the app or failed elsewhere.

The same native build then showed `Loading fields…` after expanding SQLite `people`. It remained visible for about 3.5 minutes, including after rerunning the read-only `SELECT 1;` query. The independent SQLite CLI returned seven columns from `PRAGMA table_info(people)` and a count of two rows from the same 8,192-byte fixture. Closing the sidebar restored the query result grid; metadata loading was still pending when the panel was closed. During a 31.005-second sample while the sidebar remained in this state, RSS stayed at 264.3 MiB, PSS at 243.0 MiB, private dirty memory at 182.2 MiB, CPU increased by 0.01 seconds and process block reads and writes did not change. `/proc` reported 146.9 MiB of process pages in swap. This was a warm process after prior multi-engine and large-result work, so the memory and swap figures are cumulative; the sample does not localize the stalled metadata request. The profile directories measured 93,028 bytes in config, 885,017 bytes in share and 4,732 bytes in cache. This is not a pass for the guarded, cancellable lazy sidebar-column behavior in [#1349](https://github.com/cozyGarage/BookiE/issues/1349). See the [PostgreSQL capture](native-pr1568-sidebar-fields-loading.png), [SQLite capture](native-pr1568-sqlite-sidebar-fields-loading.png) and [31-second process samples](native-pr1568-sqlite-sidebar-loading-31s.json).

The stream export dialog labeled its scope **All query rows (run again)** and warned that data may have changed. Exporting `SELECT generate_series(1, 1000) AS n;` through the native file chooser completed, showed a toast for 1,000 rows, and produced a 3,895-byte CSV with 1,001 lines including the header, values 1 through 1,000. The file was saved in `/tmp` and then removed. Immediately before export, the whole profile measured 123,610 bytes in config, 836,625 bytes in share and 4,732 bytes in cache; afterward those totals were 123,610, 840,322 and 4,732 bytes. The 3,697-byte share increase is an unattributed profile change, not a query-only storage measurement. Captures: [export scope](native-pr1568-stream-export-scope.png) and [completion toast](native-pr1568-stream-export-toast.png).

The isolated Xvfb GTK safety scenario `bundle_export_records_sanitized_audit_outcome` did not complete. The private D-Bus session activated the GNOME/GTK portal backends, but `xdg-desktop-portal` reported no `org.freedesktop.impl.portal.FileChooser` interface. The test could not find the app's “Export connections” dialog. This is an incomplete UI gate caused by the headless portal setup; it does not establish an application failure or a native Wayland export result.

## Fresh-process idle profile

I relaunched the extracted PR candidate on the native Wayland desktop with no query run. The startup log reached “main window activated” 59 ms after process start and “workspace ready” 174 ms after process start. These are internal log markers, not a measured first-frame time. GTK emitted a critical that the user-session accessibility bus was missing, but the window and PostgreSQL workspace still loaded.

At 15 seconds, RSS was 113,916 KiB, PSS 102,359 KiB and private dirty 45,677 KiB. At 69 seconds, RSS remained 113,916 KiB, PSS was 102,396 KiB and private dirty 45,645 KiB. During the following 30-second idle sample, CPU ticks did not increase; RSS and private dirty stayed at 113,916 and 45,636 KiB. Block-read and block-write counters stayed at 770,048 and 2,043,904 bytes.

The whole profile directories measured 90,373 bytes in config, 747,606 bytes in share and 4,732 bytes in cache, unchanged during the idle sample. These are saved-profile totals, not data attributable to one launch. The run used the extracted candidate; the pacman-installed application is still 0.2.0-1.

## Native SQLite values and query-editor smoke check

On the native Omarchy Wayland desktop, the extracted PR #1568 binary opened the temporary SQLite file `/tmp/bookie-native-ui-20261024.sqlite` (8,192 bytes) and displayed its `people` table. The visible sample distinguishes a Boolean, exact decimal values, NULL and empty text. No rows were edited. A query tab opened with Ctrl+E; running `SELECT 1;` displayed one result row (`1`), `Errors (0)`, and a UI elapsed time of 0 ms. The elapsed display is below useful timing resolution and is not a performance benchmark.

- [SQLite mixed-value table](native-pr1568-sqlite-people.png)
- [Query editor and SELECT 1 result](native-pr1568-sqlite-select1.png)

The desktop captures include a notification reporting a `ydotool` helper crash. The BookiE process remained live throughout these checks; the notification is not an application crash report.

With the SQLite table open and no input, a 31.005-second process sample recorded RSS at 310,489,088 bytes (296.1 MiB), PSS at 279,380,992 bytes (266.4 MiB), and private dirty memory at 224,063,488 bytes (213.7 MiB). The values stayed constant at the reported precision; CPU increased by 0.01 seconds and process block reads and writes did not change. `/proc` reported 125,095,936 bytes (119.3 MiB) of BookiE pages in swap. The host had 7.8 GiB available RAM, 4.9 GiB used in zram, and zero average memory-pressure stalls at capture time. This does not identify when or why BookiE pages entered swap. The process had been running during prior multi-engine and 100,000-row tests, so this is a cumulative warm-process state, not a fresh SQLite baseline.

At the same time, the existing user profile directories measured 126,020 bytes in config, 884,110 bytes in share, and 4,732 bytes in cache. The extracted candidate package tree occupied 76,183,256 bytes; this is not the installed package size. Pacman still reported `bookie 0.2.0-1`, so at this capture the candidate was extracted rather than installed. The sample records persistent profile totals after this UI test, not bytes attributable to SQLite or `SELECT 1;`.

- [31-second idle process samples](native-pr1568-sqlite-table-idle-31s.json)

## SQLite query-session toggle

On the same SQLite connection, I opened the editor's Session mode, ran the existing read-only `SELECT 1;` successfully, and toggled Session off. The toolbar then showed `Closing session…` while Run was enabled. A 31-second sample taken in that display state recorded RSS at 270,784 KiB, swap at 150,424 KiB, a two-tick CPU increase (about 0.02 seconds), and no process block reads or writes. The BookiE process remained sleeping. Running `SELECT 1;` again succeeded and replaced the stale status with `done in 0 ms`; this confirms the session close had completed and the lingering text was presentation state, not a blocked session close. No database rows were changed. The 0 ms display is below useful timing resolution and is not a performance result.

- While Session mode was open and idle, a separate 31.006-second sample held RSS at 277,282,816 bytes, PSS at 254,826,496 bytes, private dirty memory at 191,217,664 bytes and swap at 154,034,176 bytes. CPU increased by 0.01 seconds; process block reads and writes did not change. These are cumulative warm-process figures after earlier UI and result tests, not the isolated cost of a SQLite session.
- [31-second process samples while Session mode was open](native-pr1568-sqlite-session-idle-31s.json)
- [Toolbar showing stale closing status with Run enabled](native-pr1568-session-closing-status.png)
- [SELECT 1 succeeds after Session is toggled off](native-pr1568-session-close-query-success.png)
- [31-second process sample while the closing status remained visible](native-pr1568-session-close-status-31s.json)

After closing the extracted candidate, the existing profile directories measured 158,980 bytes in config, 886,809 bytes in share and 4,732 bytes in cache. The SQLite fixture remained 8,192 bytes. The extracted candidate package tree occupied 76,183,256 bytes. These are cumulative profile and package-tree sizes, not storage attributable to the session test. At capture time pacman still reported 0.2.0-1 and the PR package installation was waiting for authentication; the later installed-package verification is below.

## Installed package from PR commit 748c75c and 100,000-row SQLite run

The package `bookie-0.2.0-1-x86_64.pkg.tar.zst` was installed through the desktop PolicyKit authorization at 2026-10-24 09:34 UTC. Pacman reports version `0.2.0-1` and installed size 72.61 MiB. `pacman -Qk bookie` found all 28 package files present. SHA-256 of `/usr/bin/bookie` and `usr/bin/bookie` inside the package both equals `b406fd8055670abc230cfead154eb27ff39dbff7f46ca8a4b0f67a6c6c50b971`. The installed `/usr/bin/bookie` binary launched on workspace 3 and was moved to workspace 4 for the remaining checks.

After launch, `SELECT 1;` completed with no errors. A 31.003-second startup-settling sample recorded RSS rising from 112,528 to 152,236 KiB, PSS from 95,804 to 128,069 KiB, and private dirty memory from 28,504 to 49,208 KiB; swap stayed at zero. CPU rose by 137 ticks (about 1.37 seconds), process reads by 749,568 bytes and writes by 3,137,536 bytes. This is the first idle interval after launch and includes startup work; it is not a steady-state idle baseline.

On the same installed process, the SQLite CLI confirmed that a recursive CTE generated 100,000 rows. BookiE ran the query in 84 ms and displayed `Errors (0)`. The grid scrolled from row 1 through row 100,000, so the last row was reachable. The grid uses continuous scrolling here; it does not show the 20-page pager seen in the PostgreSQL test. The result column type label showed `NULL` while its cells contained integers; this capture does not establish whether that label is intended for an expression without a declared SQLite type. Screenshots record the first and last rows. The query was read-only and the 8,192-byte fixture was unchanged.

A 31.005-second idle sample after the query recorded RSS from 169,504 to 168,540 KiB, PSS from 145,257 to 144,293 KiB and private dirty memory from 64,020 to 64,008 KiB. Swap stayed at zero, CPU rose by two ticks (about 0.02 seconds), and process block reads and writes did not change. Whole profile directories measured 223,011 bytes in config, 891,433 bytes in share and 4,732 bytes in cache after this query; these totals include the pre-existing profile, history and audit data. The fixture remained 8,192 bytes.

- [Installed SQLite result at row 1](native-pr1568-installed-sqlite-100k-first.png)
- [Installed SQLite result at row 100,000](native-pr1568-installed-sqlite-100k-last.png)
- [Installed Split on](native-pr1568-installed-split-on.png) and [Split off after the second click](native-pr1568-installed-split-off.png)
- [Installed result with sidebar hidden](native-pr1568-installed-sidebar-hidden.png) and [restored](native-pr1568-installed-sidebar-restored.png); the result remained visible in both states.
- [Installed startup and post-query process samples](native-pr1568-installed-100k-process-samples.json)

## GTK safety rerun

The full Xvfb/AT-SPI GTK safety suite ran against the same extracted candidate with `TABLEPRO_TEST_MCP_HTTP_PORT=19433` to avoid colliding with the native app's MCP listener. All 111 scenarios passed; the script exited 0. The log ends with four D-Bus disconnect messages during fixture teardown, after the final passing scenario. This is automated GTK evidence and does not replace the native Wayland checks above.

- [GTK safety run log](gtk-safety-xvfb-20261024.txt)

## Provenance note for the installed PR #1568 capture

The installed-package sample records package version `0.2.0-1` but not a source commit. Its archive digest matches the extracted package recorded above, and the installed executable and package member match that package's recorded binary digest. The package record attributes the binary to PR commit `748c75c0f904e6c53f41236b1a3d36668bd079b5`, which appears in the PR history. The `stream_pages.rs` implementation and its performance tests are byte-identical between that commit and merged commit `3e9f22a70`. The archive digest differs from the published `linux-v0.2.0` Arch asset. This pins the installed capture to the earlier PR package and cache implementation, but does not qualify the final merged UI build or the published release.

## Installed package GTK rerun

The installed `bookie 0.2.0-1` package was retested after PR #1568 merged. The installed executable SHA-256 was `b406fd8055670abc230cfead154eb27ff39dbff7f46ca8a4b0f67a6c6c50b971`; the package archive SHA-256 was `c23e787348daeeabeecc750735f0d7759c4567a663c391597ddee8cdf90fc2bd`. The run used `/usr/bin/bookie`, an isolated D-Bus session and Xvfb, and port 19434 for the MCP listener. The log records 111 passing scenarios and no failed scenarios; it does not record the script's final exit status.

The default test wrapper sets `XDG_CURRENT_DESKTOP=GNOME`. On this host, the GNOME portal exposed no FileChooser interface under Xvfb, so an initial run passed 95 scenarios and could not reach file-picker dialogs in 16. A focused CSV-export scenario passed after setting `XDG_CURRENT_DESKTOP=Hyprland`; the full installed-package rerun used the same setting and logged 111 passing scenarios. This isolates the earlier failures to portal selection in the headless test environment. The run log ends with D-Bus disconnects and two `rm` errors while removing runtime subdirectories, so cleanup completion is unverified.

- [Installed-package GTK safety run log](gtk-safety-installed-hyprland-xvfb-20261024.txt)

## Installed SQLite table filter

On the same installed `bookie 0.2.0-1` process, the `people` table showed its column names with SQLite type labels. I opened the filter panel, expanded the rule editor, added `id = 1`, and applied it. The grid displayed only Ada Lovelace and the footer showed one row. Clearing the filter restored both fixture rows. This read-only check did not modify the database. It confirms the basic rule-editor apply and clear path on the native desktop; it does not cover every operator, type conversion, saved-filter behavior or keyboard navigation.

- [Rule editor with an `id = 1` rule](native-installed-filter-rule-editor.png)
- [Applied filter with one matching row](native-installed-filter-applied.png)
- [Cleared filter with both rows restored](native-installed-filter-cleared.png)

## Installed live-process background idle sample

The installed `/usr/bin/bookie` process (PID 583534, SHA-256 `b406fd8055670abc230cfead154eb27ff39dbff7f46ca8a4b0f67a6c6c50b971`) remained open on the local SQLite `people` table while another workspace was focused. A 31.814-second sample at 250 ms intervals recorded RSS at 159,208 KiB and PSS at 128,913 KiB throughout. Private dirty memory stayed at 70,060 KiB, swap at zero, process CPU advanced by two ticks (0.02 seconds), and process block read/write counters did not change. The table showed two rows and the database fixture remained 8,192 bytes. This is a warm background-idle sample after earlier UI and 100,000-row checks; it does not measure first-launch or query cost, nor attribute retained memory to a specific view.

Whole BookiE profile directories measured 58,633 bytes in config, 906,861 bytes in share and 4,732 bytes in cache after the sample. These totals include pre-existing history and audit state.

- [Raw background-idle process samples](native-installed-background-idle-31s.json)

## Installed appearance and editor font controls

In Preferences → Appearance, changing the app appearance from System to Light changed the window to a light palette; returning it to System restored the dark palette used by this desktop. The Theme value remained Default. In Preferences → Editor, the SQL editor font size changed from 12 to 13 and back to 12. The query and result remained open throughout. This verifies the preference controls and their reversible state on this display; it does not test system text scaling, high-DPI behavior or accessibility tooling.

- [Light appearance selected](native-installed-preferences-light.png)
- [Editor font size set to 13](native-installed-editor-font-13.png)
- [Editor returned to its 12-point setting](native-installed-editor-font-restored.png)

## Installed 600x400 native window observation

On the installed `bookie 0.2.0-1` binary above, I changed the window to a 600 × 400 floating size on the 1920 × 1200 Hyprland desktop. The saved local SQLite fixture remained unchanged. A recursive CTE targeting 100,000 integers completed and the app showed `done in 82 ms` and `Errors (0)`. At this height, the result grid and row navigation were not visible in the captured state; only the Results and Errors controls remained at the bottom. This records query completion, not successful inspection or navigation of the result.

The SQL editor line extended past the right edge. Run, Session, Explain and Split remained visible, while Fold block and Unfold all were absent from the toolbar. Opening the sidebar displayed it as an overlay over much of the editor; closing it restored the editor view. The toggle worked in both directions, but the overlay left little room for SQL and results at this width. This is a forced narrow-window observation, not a declared minimum-size test or a responsive-layout pass. It does not replace the separate full-width test showing row 100,000 reachable in SQLite.

- [600 × 400 window after the 100,000-row query](native-installed-narrow-600x400-100k.png)
- [Sidebar open at 600 × 400](native-installed-narrow-600x400-sidebar-open.png) and [closed](native-installed-narrow-600x400-sidebar-closed.png)
