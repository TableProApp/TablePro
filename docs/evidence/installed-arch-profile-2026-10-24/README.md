# Installed BookiE 0.2.0 on Arch and Omarchy

## Identity and installation

The tested source was `c21a05a37bab72b4fa90d38f0466abea3de6eeed` on `linux`, with a clean tracked tree. The installed package is `bookie 0.2.0-1` for x86_64. Its archive SHA-256 is `7d951d40e4c6944ec0eed83df64089c74584f89490c125b32c4e9dddfecbce0f`; `/usr/bin/bookie` is `6c4522efb43060977a442a36ac7d1147087b6a0f3a8e878f67a8b9f8f69cf7e7`. `pacman -Qkk bookie` reports 28 files and zero altered files. Pacman reports 72.59 MiB installed size.

The host is x86_64 Arch Linux / Omarchy, kernel `7.2.8-9-omarchy`, GTK 4.24.1, libadwaita 1.10.0, Hyprland 0.56.2, Rust 1.98.1. The package was built from the recorded source; its `makepkg check()` and package validator passed. The build script's final `namcap` invocation could not import `namcap` through mise's Python. A manual package scan ran with system Python and emitted warnings only. `pacman -Qkk` showed no content changes.

The installed binary was launched in the live Hyprland session. It opened the saved “Manual Lab - SQL Server” connection and logged a ready workspace with three tables. Using Wayland keyboard input, `Ctrl+T` opened the SQL editor and `Ctrl+Enter` executed its default read-only `SELECT 1;`; the grid displayed `1` and the app logged completion in 1 ms. The connection log warned that TLS was turned off after login, so this is not evidence for secure transport. A later native session used the saved “Manual Lab - PostgreSQL” profile on PostgreSQL 17.11. It opened `public.people`, displayed two rows, and showed the column names with `INT8`, `TEXT` and `BOOL` types in their headers. No table rows were modified. See [the PostgreSQL grid capture](native-postgres-people.png).

Native pointer checks now use Hyprland input and do not depend on the broken AT-SPI socket. The sidebar was opened and closed, the table was opened from its sidebar row, Split showed two editor panes, and a second Split activation returned to one pane. The bottom-right results control restored the editor when results filled the window. The table Filter panel opened in SQL and rule-editor modes; no filter was applied. Sidebar resizing, export, reconnect, light theme, enlarged text and accessibility behavior remain unverified. The split states are captured in [split](native-editor-split.png) and [unsplit](native-editor-unsplit.png); the filter modes are shown in [the filter capture](native-postgres-filter.png). The full GTK safety and widget suites ran separately under Xvfb.

## Functional checks

All checks below ran against source commit `c21a05a` unless noted. The executable GTK checks used the installed `/usr/bin/bookie`.

| Check | Result |
| --- | --- |
| `scripts/preflight.sh` via the `full` layer | Passed; 2,875 nextest cases plus sandbox checks |
| `scripts/ci-local.sh integration` | Passed; 619 driver, SSH, socket, MCP and policy integration cases across the report summaries |
| GTK widget tier | 154 registered widget tests passed |
| Installed GTK safety suite | 108 scenarios passed, zero failed |
| Value contracts | Passed: app 70, core 64, ClickHouse 8, DuckDB 35, MongoDB 17, SQL Server 8, MySQL 33, PostgreSQL 200 |
| App server, driver TLS, PostgreSQL release, keyring, rollback and security-policy layers | Passed |
| Harness checks | Passed |
| Installed Wayland launch | Window opened and the saved SQL Server connection became ready with three tables |

The first GTK safety attempt reported 14 import/export dialog failures because the desktop file chooser portal had no implementation. A focused retry with `GDK_DEBUG=no-portals` passed, followed by the complete installed-binary suite with the same setting. The initial failures were test-environment portal interception, not a product fix. Some isolated socket tests also needed to run outside the restricted sandbox; the reruns passed. Full run reports and logs are in local ignored `target/quality/` directories and `/tmp/bookie-installed-gtk-c21a05/`.

## Resource observations

Five focused scenarios ran with the installed binary under Xvfb, private D-Bus and AT-SPI. Each used a temporary profile and SQLite fixture. A process sampler recorded BookiE CPU, peak RSS, and `/proc/PID/io` counters. These are automated-test observations, not native-desktop benchmarks. RSS is not PSS; sampled I/O does not measure all cached or filesystem writes.

| Scenario | Workload | Scenario time | Process CPU | Peak RSS | Temporary profile peak | SQLite fixture |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| New connection form | Open and inspect form | 7.29 s | 6.70 s | 173.0 MiB | 2.71 MiB | 16 KiB |
| Large result search | 5,000-row recursive query and keyboard search | 9.90 s | 8.65 s | 184.7 MiB | 2.13 MiB | 16 KiB |
| Wide result navigation | 300-column result and keyboard navigation | 38.41 s | 38.72 s | 195.5 MiB | 2.75 MiB | 16 KiB |
| Current-page CSV export | 150 rows | 5.57 s | 4.74 s | 201.5 MiB | 2.10 MiB | 16 KiB |
| Restart and restore | Restore active editor and connection | 16.32 s | 15.56 s | 356.4 MiB | 3.32 MiB | 20 KiB |

Temporary profile totals include config, data, state and cache; the approximately 2.0 MiB cache was mostly GTK/font cache. The restart scenario used two app processes and had the highest peak RSS. The 300-column case used close to one CPU core during accessibility-driven navigation. Xvfb rendering, accessibility enumeration, scenario setup and the sampler contribute to both timings and resource use. Do not compare these values directly with interactive desktop use.

One additional sample used the live Wayland process on a connected PostgreSQL profile with the editor open and no query run by the sampler. Over 31 seconds at a 922×1150 tiled window size, CPU time increased by 0.76 seconds (2.45% of one core). RSS ranged from 309.1 to 309.3 MiB, PSS from 282.5 to 282.8 MiB, and private dirty memory from 192.9 to 193.0 MiB. `/proc/PID/io` recorded 0 bytes of block reads and 962,560 bytes of block writes during the sample. User profile directories measured 1,056,262 bytes in `~/.config/tablepro` and 419,297 bytes in `~/.local/share/tablepro`; no `tablepro` cache or state directory existed. This is one short observation from an already-running session, not a repeated idle baseline. Raw one-second samples are in [native-idle-31s.json](native-idle-31s.json).

A second live sample measured a settled `public.people` browse on the same connected PostgreSQL profile, at a 922×1150 tiled window size. Across 31 samples over 30.0 seconds, CPU increased by 0.02 seconds. RSS stayed at 316.5 MiB, PSS ranged from 290.2 to 290.3 MiB, and private dirty memory stayed at 198.8 MiB. `/proc/PID/io` recorded 0 block reads and 0 block writes; process character I/O increased by 480 bytes read and 496 bytes written. At the end of this sample, `~/.config/tablepro` measured 55,480 bytes and `~/.local/share/tablepro` measured 422,917 bytes. This is a short static browse sample, not a workload benchmark. Raw one-second samples are in [native-postgres-browse-31s.json](native-postgres-browse-31s.json).

During the full GTK safety suite, the sampler observed 118 app processes over 602.9 seconds. Median per-process peak RSS was 178.7 MiB and the 95th percentile was 207.5 MiB. The largest sampled process peak was 336.5 MiB in the restart scenario. These suite aggregates are descriptive only; scenarios create and close separate app processes.

## Limits and follow-up

This run does not establish broad interactive Wayland acceptance, visual behavior at multiple scales, repeated idle resource use, or performance on large real database results. The live checks above cover startup, PostgreSQL browse, filter-panel modes, sidebar toggle and editor split/unsplit only. Sidebar resizing could not be confirmed; it remains open along with export, reconnect, light theme, larger text and accessibility checks. Continue the [manual verification checklist](../../manual-verification-0.2-features.md). Keep native measurements separate from the Xvfb profile.
