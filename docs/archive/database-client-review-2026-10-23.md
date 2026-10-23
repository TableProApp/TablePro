# Database-client review, October 23, 2026

## Scope and evidence

Reviewed BookiE `220c68757743ef936dafdff859373d05e20595a6` against the database clients already named in the documentation. The [source inventory](../evidence/client-review-2026-10-23/manifest.json) records full pins, release observations, commit counts and selected diffs. This refresh follows the [October 20 deep review](tablepro-dbx-review-2026-10-20/README.md), [October 21 collaboration review](tablepro-collaboration-2026-10-21.md) and [October 22 GPUI review](gpui-client-review-2026-10-22.md).

Official GitHub APIs supplied default-branch pins, releases, commits since October 20, and bounded recent PR/issue feeds. High-volume commit feeds were paginated rather than capped at 100. Selected implementation and test diffs were read; a commit inventory is not a whole-repository audit. BookiE paths and existing tests were inspected, and current issues were checked before suggesting work. No third-party application, build script, database fixture or benchmark was executed. No new BookiE runtime defect is established here.

TablePro's Linux branch was deleted after its Linux tree moved into `main/linux/`; Apple changes below are behavior references only. TablePlus is a separate product reviewed through official release notes. Framework libraries, the GPUI index, disktree, hunk and seesvee retain their earlier design-reference status; they are not counted as database clients.

## Source and release refresh

| Product | Source pin | Release observed | Relevant result |
| --- | --- | --- | --- |
| TablePro | `25158fb45d` | Stable 0.82.2; 0.83.0-beta.2 separately | Linux now has MCP, Redis, Vim mode, connection tags/icons/search and bidirectional FK navigation. DuckDB PR #3806 was still unmerged at collection. |
| dbx | `209172db07` | Stable 0.6.52 | Agent-key selection, generated-table SQL inspection, cached sidebar search, pagination reversal and new keyset comparison reads. Main has changes after the release. |
| DBeaver | `39f772bd0c` | Stable 26.2.3 | Newer mainline fixes cover savepoints, PostgreSQL temporary row types, private-key staging, panel cleanup and CSV parsing. These commits are not all in 26.2.3. |
| Beekeeper Studio | `34074321fe` | Stable 6.1.6; 6.2.0-beta.3 separately | Theme-token migration, SQLite explicit creation and edit/navigation event propagation. Beta is not the stable release. |
| TablePlus | Official changelogs; no source pin | macOS 27.1.0 (October 20); Linux 1.7.0 (August 22) | macOS notes mention polish and settings without enough detail for a concrete port. No newer Linux release was listed. |
| pgAdmin | `ea293b335e` | Official latest documentation 9.18 | Recent Statistics-node template fix; request deduplication and generated-script assertions remain useful regression patterns. No GitHub Release object was returned. |
| DB Browser for SQLite | `92f7127b6f` | Stable 3.13.1; moving continuous/nightly tags separately | Static AppImage runtime and corrected CI/download links. No new database behavior inferred from packaging commits. |
| dbflux | `a3e051f452` | Stable 0.8.12; 0.9.0-rc.0 separately | FK labels now include referenced-column identity; MCP runs connection hooks. |
| dbui | `6b98db2eeb` | 0.5.1 | Same source as October 22 review; no new implementation to adopt. |
| dbdelve | `14b761c23c` | 0.5.1 | Selection-only formatting with undo, grouped connection form, scoped palette and tighter CI cache permissions. |
| based | `db046228e3` | 2026.10.0 | Same source as October 22 review; earlier count-error and pagination observations remain hypotheses for BookiE. |
| fluxDB | `670b2b4a41` | 0.1.11 | SQL Server integration, Unicode completion offset fix and compact summary layout. A commit removes live SQL Server tests; feature presence alone is insufficient acceptance. |
| navop | `6773a65b73` | 0.21.1 | Safer settings recovery and reconnect/replay handling. Prior custom-license concerns remain; no reuse clearance is implied. |
| pgui | `d01aed7838` | 0.1.23 | Unchanged since October 22 review. Prior row-copy and missing-license observations remain dated findings. |

Release sources: [TablePro](https://github.com/TableProApp/TablePro/releases), [dbx](https://github.com/t8y2/dbx/releases/tag/v0.6.52), [DBeaver](https://dbeaver.io/2026/10/18/dbeaver-26-2-3/), [Beekeeper](https://github.com/beekeeper-studio/beekeeper-studio/releases), [TablePlus macOS](https://tableplus.com/blog/2017/02/changelogs.html), [TablePlus Linux](https://tableplus.com/blog/2020/01/changelogs-linux.html), [pgAdmin](https://www.pgadmin.org/docs/pgadmin4/9.18/release_notes_9_18.html), [DB Browser](https://github.com/sqlitebrowser/sqlitebrowser/releases). Full repository and release URLs for the remaining clients are in the inventory.

## Corrections to earlier comparisons

- BookiE `linux-v0.2.0` was [published October 23](https://github.com/cozyGarage/BookiE/releases/tag/linux-v0.2.0). The October 17 comparison's release-blocker language is historical. The [completion page](../bookie-0.2-sprint.md) and [backlog](../backlog.md) own current status. Native Wayland observations exist in the [October 23 installed run](../evidence/installed-wayland-0.2.0-2026-10-23/README.md); they do not satisfy every still-open acceptance issue.
- TablePro Linux is no longer missing MCP, Redis or Vim. Its [MCP ADR](https://github.com/TableProApp/TablePro/blob/25158fb45de5e0a9b8d75afa5508e0d5f4e72343/linux/docs/decisions/0022-ai-assistant-and-mcp-server.md) chooses loopback HTTP, a bearer token, per-connection access levels and interactive write approval. BookiE retains stdio, scoped tokens, allowlists and PolicyGuard. Similar capability names do not establish identical security contracts.
- dbx [#13256](https://github.com/t8y2/dbx/pull/13256) removes the MySQL N+1 page probe previously highlighted in #12522. A filtered query can return its requested page quickly but scan all remaining input to find one more match. BookiE should retain known-count pagination and explicit unknown totals rather than adopting that removed probe. Exact-page correctness and query latency both need acceptance.
- BookiE's savepoint recovery fixes #1186/#1187 are closed; DBeaver's new savepoint fix is a regression reference, not a reason to reopen the same work.
- Earlier research completion does not mean the associated BookiE defects were fixed. Issues #1173 through #1181 remain open at this snapshot; preserve their individual acceptance and recorded lane.

## Correctness and security lessons

### 1. A foreign-key navigation filter must find the same row as the constraint

TablePro Linux [#3807](https://github.com/TableProApp/TablePro/pull/3807) checks comparison semantics as well as column order. SQLite foreign-key matching can use parent affinity/collation while a filter uses another column's rules. Its MySQL path compares type parameters, signedness and collation and refuses ENUM/SET cases it cannot represent faithfully. The patch also checks that converting a stored key into editable filter text preserves its meaning.

BookiE `apps/linux/app/src/ui/browse_tab/reference.rs` correctly pairs composite key columns and rejects NULL, hidden or unsupported values. It converts keys into text filters through `crates/core/src/filter.rs::equality_rule`; the inspected path does not establish source/target comparison compatibility. This is a source gap requiring a real-engine reproduction, not demonstrated wrong-row navigation. Under existing FK work #549, test SQLite parent NOCASE versus child BINARY, affinity changes, MySQL padded strings and ENUM/SET, composite order, and exact decimal/float keys. A mismatch should produce a clear refusal or a proven equivalent query.

dbflux [#1160](https://github.com/0xErwin1/dbflux/pull/1160) fixes a different identity error: `(schema, table, value)` is insufficient for label caches because `users.id = 7` and `users.legacy_id = 7` can denote different rows. Include referenced columns, effective database, typed key and generation if BookiE adds label previews. No equivalent BookiE label cache was found in the inspected path; add no cache merely to copy the feature.

### 2. Stopping a script includes preventing its next statement

TablePro Linux [#3780](https://github.com/TableProApp/TablePro/pull/3780) stops sending later statements after cancellation and distinguishes a finished request from a server-confirmed stop. Its MySQL control link checks liveness before sending KILL rather than replaying KILL after an uncertain failure.

BookiE runs planned statements through `editor/outcomes.rs` with a shared `OperationControl` and separate server-cancellation contracts. Different machinery means no direct driver port. Extend existing #1316/#593/#850 coverage with `slow statement; INSERT sentinel`, cancel between statements and during setup, then query the stored sentinel through another connection. Include normal completion racing the deadline and cancellation while a transaction is open. A returned cancellation error alone cannot prove the later write was not sent.

navop [commit f3e1b979ba](https://github.com/feigeCode/navop/commit/f3e1b979ba) removes bare `connection closed` from safe-to-replay detection: identical text can describe a request that was never sent or a lost response after execution. BookiE should preserve typed uncertain outcomes, retirement and no write replay. A preflight liveness check does not prove a later send cannot fail; do not replace the operation outcome contract with error-text heuristics.

### 3. SQL dialect support is a contract, not a permissive parser setting

TablePro Linux [#3790](https://github.com/TableProApp/TablePro/pull/3790) interprets MySQL/MariaDB executable comments according to server flavor/version, including history and editor consumers. BookiE `policy/input_refusal.rs` explicitly refuses executable comments, with classifier coverage. That safe refusal is existing behavior, not a bypass to fix. Supporting dumps that depend on these comments requires one shared server-aware lexical contract across planning, policy and history, under #571/#983; removing the refusal alone is unsafe.

fluxDB [commit 0b17dd018e](https://github.com/fluxdb-alt/fluxDB/commit/0b17dd018e) converts parser character columns to UTF-8 byte boundaries. BookiE already converts GTK cursor characters to bytes in `statement_cursor.rs`, floors boundaries in completion and tests Unicode cursors. Keep diagnostics, run selection, alias completion and insertion in the same Unicode matrix; no matching defect was demonstrated.

### 4. Transaction recovery, metadata discovery and secret staging need explicit outcomes

DBeaver [#42492](https://github.com/dbeaver/dbeaver/pull/42492) distinguishes `ROLLBACK TO SAVEPOINT` from a full rollback. BookiE already has `guard_tests_session/savepoint_recovery.rs` and real PostgreSQL session tests; preserve their stored-row and terminal-audit checks. DBeaver [#42534](https://github.com/dbeaver/dbeaver/pull/42534) handles unresolved PostgreSQL temporary row types with fallback and savepoint-aware metadata access. Apply that scenario to BookiE's existing session/type-cache tests; absence of a visible type must not silently become NULL or abort an unrelated user transaction.

DBeaver [#42441](https://github.com/dbeaver/dbeaver/pull/42441) stages private keys with owner-only permissions and atomic replacement and tests nonregular/symlink targets. BookiE #1181 already owns TLS material hardening. Verify its actual materialization paths before copying a helper; keep secrets out of the review artifacts. DBeaver [#42548](https://github.com/dbeaver/dbeaver/pull/42548) detaches result-panel listeners at close. This reinforces #1032/#1321 teardown tests for old grids, pins, result references and late completions.

## UI, performance and development lessons

| Source | Useful behavior or method | BookiE application |
| --- | --- | --- |
| dbx [#13187](https://github.com/t8y2/dbx/pull/13187), [#13155](https://github.com/t8y2/dbx/pull/13155) | Inspect generated table SQL and show connection identity at the point of execution | Candidate under #1349. Open generated SQL in a separate draft; retain owning database/session and normal policy checks. Show enough context to distinguish same-named connections. |
| dbx [#13300](https://github.com/t8y2/dbx/pull/13300) | Keyset reads avoid repeated OFFSET scans in data comparison | Future comparison input, not a reason to add comparison now. Stable keys, NULLs, budget and concurrent mutation matter; count disagreement does not establish a snapshot. |
| dbx [#13246](https://github.com/t8y2/dbx/pull/13246) | Preview fallback rewrites only generated wrappers, not arbitrary user SQL | Preserve BookiE's budgets and no-replay contracts. Do not retry user statements based solely on error strings. |
| Beekeeper [#4858](https://github.com/beekeeper-studio/beekeeper-studio/pull/4858) | Carry Enter/Shift+Enter/Tab events through editor commit and navigation | Extend #1029/#1031 with edit, commit/cancel, movement and native stored-value checks. Do not translate Vue event plumbing into GTK. |
| Beekeeper [#4865](https://github.com/beekeeper-studio/beekeeper-studio/pull/4865) | Separate intentional SQLite creation from reopening a missing file | Reinforces existing #1173; test driver refusal plus explicit UI create/save/reopen. |
| dbdelve [#135](https://github.com/ShayanAbbas1/dbdelve/pull/135) | Format the selection and make programmatic editor rewrites undoable | Test the current BookiE formatting action: selected range, Unicode, cursor/selection, one undo restoring original text. Feature candidate only if the installed path lacks it. |
| dbdelve [#134](https://github.com/ShayanAbbas1/dbdelve/pull/134) and scoped palette #131 | Group connection fields and preserve keyboard-first discovery | First fix BookiE's observed keyboard and popover ownership issue #1488. Additional form rearrangement needs narrow-window and focus evidence. |
| pgAdmin [9.18](https://www.pgadmin.org/docs/pgadmin4/9.18/release_notes_9_18.html) | Deduplicate identical metadata reads; assert generated schema-diff output instead of swallowing it | Relevant to #1487/#580. Measure request counts while typing. Share only identical work for the same effective session and generation. |
| pgAdmin [#10639](https://github.com/pgadmin-org/pgadmin4/pull/10639) | Render actual catalog SQL for combinations of optional template arguments | Rust SQL builders still need whitespace, quoting and optional-filter matrix tests; no Jinja dependency is needed. |
| DB Browser [commit 3e7c38c057](https://github.com/sqlitebrowser/sqlitebrowser/commit/3e7c38c057) | Static AppImage runtime and explicit nightly/stable links | Artifact-specific test prompt. BookiE #1325 owns missing GtkSourceView data; a runtime change cannot establish bundled highlighting correctness. |
| navop [commit e875319821](https://github.com/feigeCode/navop/commit/e875319821) | Surface corrupt settings and save atomically | BookiE `app-services/state_file.rs` already records read errors and preserves the original; storage uses atomic writes. Exercise the actual error UI before claiming equivalent recovery. |

dbx's current [crate architecture](https://github.com/t8y2/dbx/blob/209172db070715765a1b4368564782b9ebbec930/crates/ARCHITECTURE.md) still makes `dbx-core` an orchestration crate. Its `dbx-types` and parts of `dbx-sql` are closer to BookiE core; BookiE app-services and composition roots own orchestration. Useful lessons remain explicit feature forwarding, resource ownership, compatibility exports with one type identity, and valid feature combinations rather than indiscriminate `--all-features`. BookiE already has dependency guards; extend their existing matrix rather than duplicate it.

dbflux [#1139](https://github.com/0xErwin1/dbflux/pull/1139) gives MCP and GUI the same connection lifecycle hooks. The parity lesson applies to BookiE's transport/PolicyGuard seam, not to adding Bash/Python/Lua hooks. Those hooks create a new execution surface and are not selected work. fluxDB's [SQL Server live-test deletion](https://github.com/fluxdb-alt/fluxDB/commit/bd4b8a9669) is a counterexample for evidence: retain BookiE's real-engine tiers when adding engines or changing values.

No small-footprint or speed claim was independently measured. BookiE already has [its own measurements](performance-review-2026-10-23.md), including the smaller `Value` representation and `dist` profile. Compare startup, query decode, grid construction, retained ownership and installed artifact size separately. An offscreen grid or row-count cap alone proves neither bounded bytes nor low CPU cost.

## Suggested next slices

These are review recommendations, not newly selected scope or new issues.

1. **Existing destructive and security work first:** retain #1175 (ClickHouse row identity), #1176 (SQLite cascading drop), #1181 (TLS/secrets) and #1174 (TLS guidance), with native failing-before evidence. The new upstream fixes reinforce their urgency without closing them.
2. **One cross-engine FK regression packet:** under #549, reproduce comparison mismatch using the real engine before changing metadata contracts. B3 owns comparison semantics; UX owns refusal and navigation. Include composite keys and exact native values.
3. **Finish measured responsiveness work:** #1523, #1487/#1366/#580 and #1032/#1321. Keep driver latency, allocation and GTK main-loop stalls separate. Reuse the existing performance evidence and tests.
4. **Small UI fixes before broader features:** #1488 keyboard/choice state, #1326 opaque panels, #1489 conflict wording and #1490 polish. Then consider generated-SQL inspection and selection-format undo using #1349, with installed keyboard and accessibility checks.
5. **Server messages remain ordered:** #1033's cumulative driver budgets precede #1034's GTK consumer and #550's output surface. No unbounded notice queue or invented server-timing number.

No dependency, engine, framework, entitlement model or agent-client feature is adopted by this review. No issue was opened or closed, no upstream code was copied, and no release or CI gate was run.
