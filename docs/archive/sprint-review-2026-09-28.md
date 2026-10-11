# Archived sprint review: 2026-09-26 to 2026-09-28

Reviewed branch: `linux`. Frozen review tip: `85fecbe0b1d86d2deac3c040c63f24712333854a`.
Source version: 0.1.5; target sprint: 0.2.0. A version or changelog section does
not establish publication or release qualification.

Window: commits reachable from `refs/heads/linux` with committer timestamps from
2026-09-26 00:00 Europe/Vienna through the review tip on September 28. This covers
the two recent work days plus today's follow-ups. The inventory contains **117
commits: 115 non-merge commits and two merges**. Author dates can precede this
window. Merged side-branch commits are included once.

Review method: all commit subjects and changed-file inventories, current sprint,
B3 type/value evidence, B4 board and CI audit; selected source and diffs for current
transport, session, credential-cache, packaging and UI risks. This is a planning
review, not a line-by-line security audit of every diff. No application tests,
containers, hosted jobs or installed desktop checks were rerun during this review.
Existing results below belong to their recorded revisions and environments.

The [active continuation plan](../bookie-0.2-sprint.md#current-continuation)
owns new work. This file archives delivered changes and their remaining limits;
it does not close B3, B4 or approve a release.

## What the work achieved

| Area | Delivered in this window | What remains |
| --- | --- | --- |
| B2 / integration | Preserved local safeguards on the remote sprint foundation; preference migration marker, durable mirrors, history tests and owned MCP shutdown | Installed migration and rollback at the candidate SHA |
| B3 PostgreSQL | Wide NUMERIC and scale, arrays/dimensions/lower bounds, 24:00/timetz, eras/infinities, interval fields and vectors; independent server/wire oracles | Calendar extremes, remaining native families, exact editing and consumer parity |
| B3 other drivers | MySQL zero/extended temporals, BIT/spatial/decimal values and SQL-mode-safe literals; SQL Server wide decimals and stored offsets; ClickHouse precision/scale/named zones; DuckDB native decimal/temporal bindings; SQLite affinity imports; MongoDB canonical Extended JSON, nested and top-level edits, binary subtype preservation | Remaining targets in the [type matrix](../type-contract-strategy.md), mixed-type editing and installed grid acceptance; refusal and text fallback must remain explicit |
| B3 consumers | Exact XLSX numeric/temporal/nested text; CSV empty/NULL distinction; XML/HTML character rules; binary SQL export, incomplete-row refusal, parser and mixed-binding regressions; MongoDB MCP/file round trips | Cross-format/consumer parity, generated boundaries and unresolved mutation findings |
| B4 SSH | Built-in auth/two-hop tests, keepalive and closed-state API; OpenSSH caller cancellation, parent-death cleanup, ProxyJump and real auth/key tests; unused auth mode removed | Built-in trust prompt, closed-tunnel monitor wiring and installed prompt/cleanup checks |
| B4 TLS | Service-name verification fixes for ClickHouse/MongoDB/Redis; SQL Server TLS fixture and no-plaintext-fallback regressions | MySQL and SQL Server TLS-through-SSH proof (C6); keep engine-specific claims |
| B4 sessions / daemon | Retired-session refusal, transaction terminal/audit corrections, real PostgreSQL D1/D2/D8 tests, fault-sink notification, post-connect cache digest, MCP shutdown deadline and unknown-key refusal | Shared-connection transaction rules, GUI lifecycle/identity, per-connection write recovery, unverifiable-cache refusal and daemon OpenSSH acceptance |
| UI | Full long-cell edit seeding, driver-specific form defaults, connection header and browse shortcut labels | Render the final layout and exercise defaults/shortcuts under Arch/Omarchy Wayland; an earlier centered-title commit was superseded by a left-aligned header with grouped actions |
| Build / evidence | Rust/toolchain/build reuse, layered runners, focused change-contract selection, immutable CI pins, strict result/artifact gates, SSH tier ownership and mutation shards | Evidence for the final tip, unresolved mutation survivors/timeouts, installed Arch package and candidate soak |
| Maintenance | ClickHouse helper split, MongoDB module split and function-size refactors | Requalify affected behavior; refactoring is not additional feature acceptance |

Detailed historical evidence remains in [value contracts](../value-contracts.md),
[CI audit](ci-audit-2026-09-27.md), [B4 board](../b4-task-board.md) and
[September 26 reconciliation](reconciliation-2026-09-26.md).

## Findings that affect the next plan

1. B3 and B4 remain open. The roadmap's previous statement that only qualification
   remained understated the open policy, GUI and transport implementation tasks.
2. B4 A5 delivered keepalive and `SshTunnel::is_closed()`, but `Tunnel` and the
   connection monitor do not consume that API. Retain the follow-up as F9.
3. Built-in GUI SSH still initializes `UnknownHostKey::Learn` in
   `app/src/services/database_service.rs`; F6 must implement user confirmation
   for initial connect and reconnect. Agentd's refusal is already separate.
4. Editor `SessionState(bool)` has no session identity; late completion can relabel
   a replacement session. F3 remains open. Close uses detached cleanup; F2 must
   settle rollback before window exit/disconnect.
5. `agentd/src/lib.rs` still reuses a healthy cache entry after material-digest
   failure, and can keep the pre-connect digest when post-connect verification
   fails. G3 must cover both failure points; G2 fixed the successful rotation case.
6. `scripts/build-deb.sh` builds/installs askpass, but
   `packaging/debian/rules` does not. I1 remains a Debian recipe/validator task,
   scheduled in the required GNOME/Debian phase after Arch acceptance. Do not redo the helper script.
7. The sprint's old Flatpak fallback text conflicts with recorded B4 decision 2.
   Implement and document explicit refusal (I2); do not infer it from missing tools.
8. CI audit records failed/incomplete broader mutation scopes. Focused successes
   do not close that triage. Old Xvfb/driver evidence cannot certify the review tip
   or native Wayland appearance.

## Complete commit inventory

Newest first, by Git traversal. Date is the committer date with its stored timezone offset. Area is a planning
classification, not a pass result. Each non-merge row records its delivered change
and the number of touched files; merge rows preserve their actual parents.

| Commit | Committed | Area | Change / archived outcome | Files |
| --- | --- | --- | --- | --- |
| `85fecbe0b` | 2026-09-28 07:32:16Z | B3 / shared consumers | refactor: split functions that exceed the 60-line body limit | 3 |
| `07137ecec` | 2026-09-28 07:28:00Z | B3 / shared consumers | refactor(plugin-mongodb): split the driver into connection, shell, update, codec, and error modules | 5 |
| `34ea8c0a8` | 2026-09-27 23:09:44Z | Documentation | docs(changelog): move 0.1.5 notes out of Unreleased | 1 |
| `2b2698d55` | 2026-09-27 23:07:03Z | B3 / shared consumers | fix(ui): name the browse keys the grid uses | 4 |
| `8d66449c8` | 2026-09-27 22:51:30Z | UI | fix(ui): apply driver defaults and draw browse shortcut keys | 14 |
| `daff036d1` | 2026-09-28 00:21:58+02:00 | B3 / shared consumers | test(mongodb): cover nested numeric and text values | 6 |
| `6b18f9e60` | 2026-09-28 00:13:46+02:00 | Documentation | docs(b4-task-board): close Lane D's real-Postgres gap for D1/D2/D8 | 1 |
| `01f892ac2` | 2026-09-28 00:13:25+02:00 | B4 | test(policy): reproduce D1/D2/D8 policy-session fixes against real PostgreSQL | 4 |
| `6b8297616` | 2026-09-28 00:08:54+02:00 | Documentation | docs(b4-task-board): mark H4 done | 1 |
| `0aef65e82` | 2026-09-28 00:08:20+02:00 | B4 | fix(policy): report Disconnected results to the connection fault sink | 4 |
| `73f5b4e08` | 2026-09-28 00:03:26+02:00 | Integration | Merge remote-tracking branch 'origin/linux' into linux | parents: `5e4870c68`, `3b80fab4d` |
| `3b80fab4d` | 2026-09-27 23:59:11+02:00 | B3 / shared consumers | feat(mongodb): allow editing top-level bson values | 8 |
| `5e4870c68` | 2026-09-27 23:57:30+02:00 | Integration | Merge remote-tracking branch 'origin/linux' into b4-b3-merge-test | parents: `9a16fb789`, `49244e663` |
| `49244e663` | 2026-09-27 23:55:07+02:00 | B3 / shared consumers | test(mongodb): verify mcp and ejson round trips | 10 |
| `9a16fb789` | 2026-09-27 23:54:06+02:00 | Documentation | docs(bookie): record B4 wave 1 lane completions on the task board | 1 |
| `cb84d0ec3` | 2026-09-27 23:51:01+02:00 | B4 | test(driver-tls-tests): add SQL Server TLS coverage and no-fallback regressions | 11 |
| `4009e22d7` | 2026-09-27 23:48:22+02:00 | B3 / shared consumers | feat(mongodb): support nested grid edits | 10 |
| `f248ec6d9` | 2026-09-27 23:46:15+02:00 | B4 | fix(ssh): remove the unselectable keyboard-interactive OpenSSH auth mode | 3 |
| `e53e3c58e` | 2026-09-27 21:42:38Z | B3 / shared consumers | test(mongodb): require nested date and binary in the xlsx cell | 1 |
| `528f5b3ad` | 2026-09-27 23:42:04+02:00 | B4 | test(ssh): add real ssh-tier coverage for a changed host key and key-based auth | 2 |
| `bfa4be264` | 2026-09-27 23:42:04+02:00 | B4 | test(ssh): prove a ProxyJump line in the ssh config reaches the target | 2 |
| `9746d9a05` | 2026-09-27 23:41:48+02:00 | B4 | fix(ssh): pass the caller's cancellation token into an OpenSSH connect | 3 |
| `7576bcf21` | 2026-09-27 23:30:49+02:00 | Documentation | docs(b3): reconcile changelog and value coverage | 8 |
| `8b46b573d` | 2026-09-27 23:14:24+02:00 | B3 / shared consumers | test(mongodb): verify nested bson xlsx export | 7 |
| `f41893c2a` | 2026-09-27 22:59:38+02:00 | B3 / shared consumers | fix(sqlite): preserve text during numeric affinity imports | 6 |
| `95ad582f1` | 2026-09-27 22:57:13+02:00 | B3 / shared consumers | test(xlsx): preserve nested extended json values | 5 |
| `800eb4a39` | 2026-09-27 22:54:04+02:00 | B3 / shared consumers | test(sqlite): cover numeric affinity transitions | 5 |
| `b0011decb` | 2026-09-27 22:50:08+02:00 | B3 / shared consumers | test(mongodb): parse nested BSON CSV export | 7 |
| `ade0c0990` | 2026-09-27 22:47:50+02:00 | B3 / shared consumers | test(mcp): preserve MongoDB extended JSON values | 5 |
| `2d9903fae` | 2026-09-27 22:45:58+02:00 | B3 / shared consumers | test(mongodb): verify nested JSON export values | 5 |
| `c459a828e` | 2026-09-27 22:40:15+02:00 | B3 / shared consumers | fix(mongodb): retain binary subtype metadata | 6 |
| `656ea8e65` | 2026-09-27 22:32:25+02:00 | B3 / shared consumers | refactor(clickhouse): split query helpers | 3 |
| `1ffd0616a` | 2026-09-27 22:24:36+02:00 | B3 / shared consumers | fix(mongodb): preserve nested BSON type details | 6 |
| `3a813456c` | 2026-09-27 22:01:19+02:00 | Build / evidence | Add focused change contract gate | 6 |
| `ac1d830db` | 2026-09-27 21:21:01+02:00 | B3 / shared consumers | fix(values): reject incomplete rows in value paths | 3 |
| `056c8e68f` | 2026-09-27 21:07:28+02:00 | UI | fix(ui): center connection dialog title | 3 |
| `fca84b7d0` | 2026-09-27 20:52:22+02:00 | B3 / shared consumers | test(clickhouse): cover named timezone round trips | 2 |
| `018c8a454` | 2026-09-27 20:42:45+02:00 | B3 / shared consumers | fix(clickhouse): satisfy preflight clippy | 2 |
| `7ffdc002e` | 2026-09-27 20:36:27+02:00 | B3 / shared consumers | fix(clickhouse): preserve named timezone instants | 11 |
| `eb3682068` | 2026-09-27 19:53:58+02:00 | B4 | fix(mcp): keep the shutdown deadline ahead of an in-flight write | 3 |
| `256bf0572` | 2026-09-27 19:53:18+02:00 | B4 | fix(agentd): cache sessions under post-connect key material | 1 |
| `2c7321638` | 2026-09-27 19:53:05+02:00 | B4 | test(driver-mysql): confirm a cancelled session query leaves the session usable | 3 |
| `29b0a6b02` | 2026-09-27 19:52:27+02:00 | B4 | fix(policy): correct session commit terminal states and close batches after a definite failure | 3 |
| `6ae98c0ed` | 2026-09-27 19:51:06+02:00 | B4 | fix(policy): audit a session commit that only rolled back an aborted postgres transaction | 3 |
| `33ed55080` | 2026-09-27 19:51:05+02:00 | B4 | test(drivers): confirm DuckDB and MongoDB timeouts report an unknown outcome | 2 |
| `1059edfb6` | 2026-09-27 19:49:58+02:00 | B4 | test(drivers): lock in the open_session refusal for session-less engines | 4 |
| `8428263d3` | 2026-09-27 19:48:48+02:00 | B4 | fix(policy): refuse statements on a retired session and malformed transaction control | 3 |
| `8fd527f2f` | 2026-09-27 19:48:27+02:00 | B4 | fix(driver-redis): verify TLS certificate against the service hostname | 80 |
| `543bed77d` | 2026-09-27 19:48:16+02:00 | B4 | test(ssh): cover password, key rejection and two-hop chain auth | 2 |
| `e3fb19ac7` | 2026-09-27 19:46:06+02:00 | B3 / shared consumers | test(clickhouse): cover DateTime64 precision scales | 2 |
| `96cd2f8f7` | 2026-09-27 19:41:47+02:00 | B4 | fix(release-tests): prove agentd refuses an unknown SSH host key | 1 |
| `6fca02c24` | 2026-09-27 19:40:53+02:00 | B4 | fix(ssh): send keepalives and expose tunnel loss | 4 |
| `b83e62618` | 2026-09-27 19:40:02+02:00 | B4 | fix(driver-mongodb): verify TLS certificate against the service hostname | 5 |
| `676ca504b` | 2026-09-27 19:38:42+02:00 | B3 / shared consumers | fix(clickhouse): reject out-of-range DateTime64 values | 8 |
| `608525079` | 2026-09-27 19:35:58+02:00 | B4 | fix(driver-clickhouse): verify TLS certificate against the service hostname | 5 |
| `12bd158de` | 2026-09-27 19:35:17+02:00 | B4 | fix(ssh): report keyboard-interactive-only servers plainly | 2 |
| `d8e3479fc` | 2026-09-27 19:32:39+02:00 | B4 | fix(ssh): correct unknown-host-key advice to not suggest ssh | 2 |
| `349d9fc82` | 2026-09-27 19:17:56+02:00 | B4 | docs(bookie): record the B4 transport and session decisions | 1 |
| `7d61a44b7` | 2026-09-27 19:13:32+02:00 | B3 / shared consumers | fix(mysql): refuse unsafe backslash comments | 5 |
| `86fc51355` | 2026-09-27 19:04:38+02:00 | B4 | docs(bookie): add the B4 transport and session task board | 2 |
| `1a9295a01` | 2026-09-27 18:57:47+02:00 | B3 / shared consumers | fix(mysql): make packed BIT grid edits safe | 12 |
| `5fac54059` | 2026-09-27 16:05:25+02:00 | Build / evidence | build(linux): bump version to 0.1.5 | 15 |
| `5b2af60e7` | 2026-09-27 16:04:46+02:00 | B3 / shared consumers | test(driver-postgres): move the vector contract into its support module | 2 |
| `d45ecbfa6` | 2026-09-27 15:53:12+02:00 | B3 / shared consumers | refactor(core): share PostgreSQL era text and hex encoding | 3 |
| `b41711ab1` | 2026-09-27 15:51:07+02:00 | B3 / shared consumers | fix(driver-mysql): decode BIT and spatial values exactly | 6 |
| `5ccdd0d13` | 2026-09-27 15:50:53+02:00 | B3 / shared consumers | fix(core): export MySQL text with backslashes as charset-tagged hex | 7 |
| `af54554bd` | 2026-09-27 15:50:30+02:00 | B3 / shared consumers | fix(driver-mssql): keep the stored offset of datetimeoffset values | 6 |
| `8f41fcf99` | 2026-09-27 15:39:42+02:00 | B3 / shared consumers | test(core): share the numeric parser value contract | 5 |
| `f531c3d4c` | 2026-09-27 15:35:19+02:00 | B3 / shared consumers | fix(core): export ClickHouse timezone timestamps as parseable literals | 5 |
| `708ec165a` | 2026-09-27 15:35:08+02:00 | B3 / shared consumers | fix(driver-clickhouse): keep fractional seconds in bound timestamps | 4 |
| `a35c6a5bd` | 2026-09-27 15:35:08+02:00 | B3 / shared consumers | fix(driver-clickhouse): keep decimal trailing zeroes at the declared scale | 5 |
| `4e717c7a3` | 2026-09-27 15:26:35+02:00 | B3 / shared consumers | refactor(driver-duckdb): resolve zoned columns once and use chrono era years | 2 |
| `3be260936` | 2026-09-27 15:26:35+02:00 | B3 / shared consumers | fix(driver-duckdb): bind dates, times and microsecond timestamps as native values | 5 |
| `61f0c8717` | 2026-09-27 15:18:19+02:00 | B3 / shared consumers | test(driver-postgres): share one wire round-trip check across value contracts | 6 |
| `cbec405da` | 2026-09-27 15:15:21+02:00 | B3 / shared consumers | fix(driver-postgres): render int2vector and oidvector as space-separated values | 4 |
| `f6bd14a8f` | 2026-09-27 15:06:52+02:00 | Documentation | docs(bookie): record the B3 commit audit and remaining driver gaps | 2 |
| `3cb6e1127` | 2026-09-27 14:45:18+02:00 | B3 / shared consumers | fix(driver-mssql): keep sign and digits of wide decimal text | 2 |
| `2753caf4f` | 2026-09-27 14:45:18+02:00 | B3 / shared consumers | fix(driver-duckdb): bind and read decimals as exact numbers | 6 |
| `4196f4eaa` | 2026-09-27 14:40:17+02:00 | B3 / shared consumers | fix(driver-mssql): decode datetimeoffset values at their stored instant | 4 |
| `01d5227de` | 2026-09-27 14:40:17+02:00 | B3 / shared consumers | fix(core): cast SQL Server datetime literals through datetime2 | 4 |
| `f6d17d873` | 2026-09-27 14:40:17+02:00 | B3 / shared consumers | fix(export): keep empty CSV text distinct from NULL | 2 |
| `bc9b3b5fb` | 2026-09-27 14:40:17+02:00 | B3 / shared consumers | fix(export): preserve HTML carriage returns and refuse NUL text | 4 |
| `b2945ea9f` | 2026-09-27 14:28:19+02:00 | B3 / shared consumers | fix(driver-postgres): keep int2vector and oidvector values undecodable instead of array text | 3 |
| `9d750f1e1` | 2026-09-27 14:28:19+02:00 | B3 / shared consumers | test(driver-postgres): expect temporal infinities as text in the undecodable regression | 1 |
| `918424984` | 2026-09-27 14:14:32+02:00 | Build / evidence | ci(linux): share one script harness and write one report per layer | 5 |
| `77ac3afbf` | 2026-09-27 14:02:59+02:00 | B3 / shared consumers | fix(driver-mysql): preserve zero dates, signed and extended times and years | 8 |
| `54e55ad45` | 2026-09-27 13:52:28+02:00 | B3 / shared consumers | fix(driver-sqlite): bind exact decimal parameters as real numbers | 3 |
| `7b7e3352e` | 2026-09-27 13:50:38+02:00 | Build / evidence | build(linux): share one toolchain and trim dev debug info | 3 |
| `093f68968` | 2026-09-27 13:22:53+02:00 | B3 / shared consumers | fix(postgres): preserve interval fields and temporal arrays | 13 |
| `31fab5fa8` | 2026-09-27 13:00:55+02:00 | B3 / shared consumers | fix(duckdb): preserve native temporal values and enum labels | 8 |
| `1fb6d33de` | 2026-09-27 12:34:16+02:00 | B3 / shared consumers | fix(export): preserve XML text and refuse lossy characters | 13 |
| `5f2347a42` | 2026-09-27 12:17:00+02:00 | B3 / shared consumers | test(linux): cover mixed bindings and failure propagation | 12 |
| `39198f1df` | 2026-09-27 11:59:24+02:00 | B3 / shared consumers | fix(export): refuse lossy workbooks and cover GTK export flows | 12 |
| `6bd5afd33` | 2026-09-27 11:31:32+02:00 | Build / evidence | test(ci): retain evidence for successful GTK scenarios | 6 |
| `0378bfea0` | 2026-09-27 11:31:22+02:00 | B3 / shared consumers | fix(core): preserve temporal precision in spreadsheet exports | 5 |
| `422c5a4d7` | 2026-09-27 01:39:10+02:00 | Build / evidence | ci(linux): add shared validation layers and agent playbook | 13 |
| `1b771214d` | 2026-09-27 01:18:53+02:00 | B3 / shared consumers | fix(core): preserve PostgreSQL eras and require complete test evidence | 22 |
| `c57ac7715` | 2026-09-26 23:12:01+02:00 | B3 / shared consumers | fix(driver-postgres): preserve times and enforce regression evidence | 18 |
| `6de5351ee` | 2026-09-26 22:55:06+02:00 | B3 / shared consumers | fix(driver-postgres): preserve scalar arrays and dimensions | 9 |
| `7cb2fe3ca` | 2026-09-26 22:39:02+02:00 | Documentation | docs: prioritize B3 regressions from external client test suites | 2 |
| `2eb9414c2` | 2026-09-26 22:29:28+02:00 | B3 / shared consumers | fix(driver-postgres): preserve wide numeric values and scale | 7 |
| `28df4581c` | 2026-09-26 22:00:46+02:00 | B3 / shared consumers | fix(core): preserve exact integers and decimals in XLSX exports | 6 |
| `49981d123` | 2026-09-26 21:44:09+02:00 | B3 / shared consumers | fix(core): enforce scalar value contracts across all drivers | 34 |
| `9b7a996ca` | 2026-09-26 20:02:59+02:00 | B3 / shared consumers | test(app): isolate persistent settings for each GTK scenario | 2 |
| `5d243251a` | 2026-09-26 20:00:12+02:00 | B3 / shared consumers | fix(drivers): preserve decimal precision and exported values | 15 |
| `3f73b8c6c` | 2026-09-26 15:38:33+02:00 | B3 / shared consumers | fix(core): preserve binary SQL exports and reject unrepresentable literals | 13 |
| `541074adb` | 2026-09-26 15:34:49+02:00 | Build / evidence | test(packaging): include and require the settings schema in Debian fixtures | 1 |
| `41fd9876d` | 2026-09-26 15:25:35+02:00 | B2 / B3 integration | fix(linux): reconcile local B2 and B3 safeguards with remote sprint work | 31 |
| `8ae99ad66` | 2026-09-26 13:24:11+02:00 | Documentation | docs(bookie): log the audit review, MariaDB fix and long-text edit fix, add manual checks | 2 |
| `2485cd0ba` | 2026-09-26 12:56:05+02:00 | B3 / shared consumers | fix(app): seed grid cell edits from the full value instead of truncated display text | 7 |
| `b7e57490c` | 2026-09-26 03:05:40+02:00 | B3 / shared consumers | style(app): keep the connect dialog tests after its helpers | 1 |
| `259c5bcdf` | 2026-09-26 03:05:40+02:00 | B3 / shared consumers | fix(driver-mysql): keep a MariaDB column default as reported instead of quoting it again | 3 |
| `d8a89e6d5` | 2026-09-26 03:05:03+02:00 | B3 / shared consumers | test(drivers): pin grid row edits keyed by uuid, composite and wide bigint primary keys | 9 |
| `87c8e79c2` | 2026-09-26 03:05:03+02:00 | B3 / shared consumers | test(app): pin that duplicating a row copies full long values into the insert | 1 |
| `36bb30425` | 2026-09-26 03:05:03+02:00 | B3 / shared consumers | fix(app): label a binary value in the activity view by its byte count | 4 |
| `7f5949d34` | 2026-09-26 03:05:03+02:00 | B3 / shared consumers | fix(drivers): report a column default as its DEFAULT clause so empty, NULL and absent stay distinct | 12 |
| `fc3964218` | 2026-09-26 03:04:45+02:00 | B4 | test(ssh): pin that the tunnel relay stops once either peer closes | 1 |
