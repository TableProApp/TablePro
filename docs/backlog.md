# Backlog after 0.2.0

BookiE 0.2.0 was published on 2026-10-23. The 0.2.0 delivery sprint is closed; remaining work from that period stays in the existing issue backlog below. This page orders post-0.2.0 work and candidates for 0.2.1. The exact 0.2.1 scope is not committed here: Project #3 and the owning issues keep status and acceptance, and a release scope should be set from selected issues before release qualification. The [completion handoff](archive/bookie-0.2-completion-handoff-2026-10-18.md) preserves the former release checklist.

The [capability review](capability-review.md) records general evaluation
criteria and current technical boundaries. An item becomes backlog work only
after selection; add an owner, acceptance layer and GitHub issue when promoting
it. Do not treat a capability gap as a release commitment.

## Completed Linux code-adoption packets

The nine selected packets under [#1149](https://github.com/cozyGarage/BookiE/issues/1149), [#1140](https://github.com/cozyGarage/BookiE/issues/1140) through [#1148](https://github.com/cozyGarage/BookiE/issues/1148), are closed. Their native-driver investigations, conformance, paging, lifecycle checks, notices, release-input checks and tooling evaluations are completed packets, not the active queue. The [dated review](archive/upstream-linux-adoption-2026-10-18.md) preserves the selection rationale. Their completion does not publish a release or close separate qualification issues.

## Current development order

Finish existing pull requests first, then address destructive operations [#1176](https://github.com/cozyGarage/BookiE/issues/1176) and [#1175](https://github.com/cozyGarage/BookiE/issues/1175), value preservation [#1177](https://github.com/cozyGarage/BookiE/issues/1177), and the security findings and 0.2.0 acceptance follow-ups below. Reproduce each report before changing behavior. Keep one lane-owned fix and one serialized Forgejo gate at a time.

## Remaining 0.2.0 acceptance follow-ups

These rows remained open after the 0.2.0 delivery decision and are now part of the post-release backlog. They do not reopen the 0.2.0 milestone or define the final 0.2.1 scope. Project #3 and the linked issues own current status and acceptance.

| Rows | Issue | Lane | Follow-up |
|---|---|---|---|
| AUD-2 | [#598](https://github.com/cozyGarage/BookiE/issues/598) | B4 | Bound GUI approval waits and agent SQL previews |
| AUD-9 | [#600](https://github.com/cozyGarage/BookiE/issues/600) | B4 | Prevent agent masking leaks through hidden SQL lineage |
| TEST-15 | [#593](https://github.com/cozyGarage/BookiE/issues/593) | B4 | Verify lost-ack writes are not replayed after reconnect |
| B4-7, B4-16, B4-22 | [#566](https://github.com/cozyGarage/BookiE/issues/566) | B4 | Finish installed acceptance for tunnel audit, session invalidation, and bundle audit |
| TEST-31 | [#556](https://github.com/cozyGarage/BookiE/issues/556) | UX | Triage intermittent installed GTK runs and gather the required full-run evidence |
| TEST-32 | [#594](https://github.com/cozyGarage/BookiE/issues/594) | UX | Review test-oracle provenance independently of production code |
| TEST-6 | [#575](https://github.com/cozyGarage/BookiE/issues/575) | Maintainer | Triage and run the remaining manual verification checklist |
| PKG-1 | [#574](https://github.com/cozyGarage/BookiE/issues/574) | Maintainer | Verify native Wayland install, upgrade, and rollback on Arch/Hyprland |

Continue existing dependency chains after those fixes: object write capabilities #1065 before shared grid guards #1031, and bounded server messages #1033 before the GTK consumer #1034. Edit ownership #1029 and stream budgets #1032 retain their acceptance. New features remain selected separately; issue status and lane belong to Project #3.

## TablePro and dbx review defects

The [October 20 TablePro and dbx review](archive/tablepro-dbx-review-2026-10-20/README.md) found these through upstream fixes. Each is source reading only: start with the failing regression test, and close the issue with that test as evidence if current code already passes. Two further findings went to existing issues: the ClickHouse `readonly=1` connect path to [#983](https://github.com/cozyGarage/BookiE/issues/983) and the version mismatch to [#1146](https://github.com/cozyGarage/BookiE/issues/1146). The review's feature waves stay candidates in the [feature comparison](0.2-feature-comparison.md).

| ID / issue | Defect | Lane | Acceptance focus |
|---|---|---|---|
| RV-3 / [#1173](https://github.com/cozyGarage/BookiE/issues/1173) | Missing SQLite or DuckDB file becomes a new empty database | B3 | Driver refusal on a missing path; explicit create through UX |
| RV-4 / [#1174](https://github.com/cozyGarage/BookiE/issues/1174) | Every TLS error advises disabling TLS | B4 | Typed failure kinds; only "server has no TLS" suggests Disabled |
| RV-5 / [#1175](https://github.com/cozyGarage/BookiE/issues/1175) | ClickHouse edit keys on a non-unique sorting key | B3 | One edit changes one row or is refused |
| RV-6 / [#1176](https://github.com/cozyGarage/BookiE/issues/1176) | SQLite Drop Table runs child ON DELETE actions | B3 | Child rows unchanged or drop refused |
| RV-7 / [#1177](https://github.com/cozyGarage/BookiE/issues/1177) | MySQL binary-collation text and MariaDB JSON decode as bytes | B3 | Charset-based decode under ADR 0007 |
| RV-8 / [#1178](https://github.com/cozyGarage/BookiE/issues/1178) | MySQL `CALL` loses result sets; text retry returns no rows | B3 | Real-engine multi-result and `EXECUTE` cases |
| RV-9 / [#1179](https://github.com/cozyGarage/BookiE/issues/1179) | Policy reads a body's trailing `END` as COMMIT and refuses DDL | B4 | Allowed compound DDL; unclosed transactions still refused |
| RV-10 / [#1180](https://github.com/cozyGarage/BookiE/issues/1180) | Redis browse loads whole values | B3 | Bounded previews and memory on large keys |
| RV-11 / [#1181](https://github.com/cozyGarage/BookiE/issues/1181) | TLS material files, `CLONE` history, MCP lockout, system trust store | B4 | One failing test per finding |

The [newest-code follow-up](archive/upstream-next-slices-2026-10-20.md) records the native PostgreSQL and failure-report probes behind RV-14 to RV-16, the latest Apple-side upstream lessons, and a proposed sequence before server notices and PostgreSQL extension work. Its candidate order does not add a release commitment.

## Audit and dbflux follow-ups

From the 2026-10-22 dbflux review and the audit of closed issues. Each is an issue with its own acceptance; none is a release commitment. Start with the failing regression test where a defect is suspected.

| ID / issue | Item | Lane |
|---|---|---|
| PERF-11 / [#580](https://github.com/cozyGarage/BookiE/issues/580) | Reopened: catalog scoping, many-schema performance, restricted-role metadata | UX |
| DBF-1 / [#1355](https://github.com/cozyGarage/BookiE/issues/1355) | Error toasts carrying the operation id (the audit viewer shipped in #1378) | UX |
| DBF-2 to DBF-4 / [#1356](https://github.com/cozyGarage/BookiE/issues/1356), [#1357](https://github.com/cozyGarage/BookiE/issues/1357), [#1358](https://github.com/cozyGarage/BookiE/issues/1358) | Measure PostgreSQL row-cap drain, SQLite early cancel, verify-ca hostname per engine | B3 / B4 |
| B4-24 / [#1365](https://github.com/cozyGarage/BookiE/issues/1365) | Decide the TLS fingerprint pin | B4 |
| UI-43 / [#1366](https://github.com/cozyGarage/BookiE/issues/1366) | Completion through the session search_path | UX |

The [#1327](https://github.com/cozyGarage/BookiE/issues/1327) keyring prompt, [#1333](https://github.com/cozyGarage/BookiE/issues/1333) close handling, [#1180](https://github.com/cozyGarage/BookiE/issues/1180) and [#1251](https://github.com/cozyGarage/BookiE/issues/1251) carry the dbflux design notes as comments. Vendored dependency patches: see [upstream patches](proposals/upstream-patches.md); `mongodb` SCRAM hunk can be dropped after the release containing [mongo-rust-driver#1833](https://github.com/mongodb/mongo-rust-driver/pull/1833).

## 0.2.x features

The approved native workflow improvements are tracked by [UI-44 / #1349](https://github.com/cozyGarage/BookiE/issues/1349): session transaction actions, visible run scopes, bounded sidebar fields and resizing, exact header metadata and scope-first export. The [workspace spec](../specs/database-workspace/spec.md) owns behavior; the issue and PR own implementation and acceptance. This does not duplicate the pending sidebar-overlay fix #1346.

| Row | What | Notes |
|---|---|---|
| SNAP-2 to SNAP-4 | Database snapshots: PostgreSQL, SQL Server, then SQLite and DuckDB file copies | ADR 0015 records the accepted design; this is post-0.2.0 implementation work, not a release commitment; limit 5 snapshots per database |
| UI-1b | Edit SSH jump chains in the form | Storage, transport, bundle v2 and per-hop passphrase coverage merged in #490, #492, #494 and #528; GTK editing stays refused until its complete path passes |
| UI-19 | Foreign key value picker, estimated counts | FK navigation, paste TSV and the ENUM and SET pickers (PostgreSQL, MySQL, MariaDB) landed |
| UI-39 | Pending grid edit cues that work without color and are announced to assistive technology | Modified, inserted and deleted rows need persistent visible state cues, accessible descriptions, and coverage for revert and widget recycling ([#1126](https://github.com/cozyGarage/BookiE/issues/1126)) |
| UI-20 | Server output (NOTICE, PRINT) and a timing breakdown | with PERF-4 |
| UI-22, UI-23, UI-26 | Multi-cursor editing, typed PostgreSQL activity console, reusable SSH profiles | accepted for later; preview tabs, split panes, SQL code folding and the docked query history panel have landed (#618, #630, #754, #619); PostgreSQL catalog objects are already built (UI-23) |
| PKG-2 | Debian and GNOME desktop pass (UI-D1 to D4; [#557](https://github.com/cozyGarage/BookiE/issues/557)) | the packages keep building and passing the distro floor in CI; this is the desktop acceptance |
| PKG-4, PKG-8 | Flatpak Flathub submission and screenshots, and the file-access decision ([#558](https://github.com/cozyGarage/BookiE/issues/558); `--filesystem=home` or portal only) | A Debian 13 guest build/install/launch check is recorded in [platforms](platforms.md#flathub); it does not qualify current source. Not part of 0.2.0; decide PKG-8 before PKG-4 |

## Performance

| Row | What |
|---|---|
| PERF-2, PERF-7, PERF-8 | A native 100,000-row PostgreSQL query now retains all 20 pages within the estimated-byte budget and can navigate back to rows 1–5,000. #1032 tracks broader ownership and memory-budget acceptance; #554 tracks access to results that exceed the in-memory budget. Other engines and comparable memory profiling still need qualification. |
| PERF-3 | MongoDB browse on large collections | Compatible `_id` keyset seek landed in #493; supported server-side sorting landed in #837. Other sorted pages and keyless deep pages still use offset pagination; installed and representative-network acceptance remain |
| PERF-4 | Server time next to elapsed time |
| PERF-5, PERF-6 | Idle memory and binary size, accepted for now |

## Quality and tooling

| Row | What |
|---|---|
| TEST-2 | Maintain the selected-package mutation audit in the [Forgejo nightly workflow](../.forgejo/workflows/nightly.yml) and triage survivors under [#559](https://github.com/cozyGarage/BookiE/issues/559). Expected-value provenance is tracked separately by [TEST-32 / #594](https://github.com/cozyGarage/BookiE/issues/594) and [oracle-review](oracle-review.md); dated package results remain in [evidence](evidence/test-quality-2026-10-11/). |
| AUD-11 consolidation | Finish the single AST walk for classification, masking and blast-radius planning. Behavioural fixes are closed on the current policy suite; shared analysis landed in #506. Structural consolidation follows 0.2.0. |
| TEST-12 | Verify sample and page-observed type union, plus acceptance evidence, against the bounded 128-document non-snapshot contract in [ADR 0007](decisions/0007-type-and-value-preservation.md) |
| APP-MOD | Keep the app layer thin: finish the staged moves of [ADR 0018](decisions/0018-headless-app-services-crate.md) (completion, workspace and browse/edit models, scoped filter and mapping stores, preference data, quick-switcher ranking and retry decisions are now headless; translated errors and the TabView handshake stay in app adapters; continue the remaining service moves), and replace hard-coded driver-name branches in the app layer with driver capabilities, starting with `browse_tab/value_parse.rs` |
| UI-21, TEST-28 | Fake connection for the GTK tier, native Ubuntu AT-SPI menu reachability ([#560](https://github.com/cozyGarage/BookiE/issues/560)) |
| TEST-30 | Triage remaining SonarCloud and CodeQL findings; close confirmed false positives with a reason |
| TEST-36 | Record duration for each installed GTK scenario and retry so suite growth can be measured before changing timeouts or shard layout (origin [#1075](https://github.com/cozyGarage/BookiE/issues/1075) is closed and no open issue owns this row; open one before selecting it); retain current limits until there is measurement evidence |
| AUD-5 | Move nonessential Rust comments into documentation under the repository comment-line rule ([#563](https://github.com/cozyGarage/BookiE/issues/563)) |
| DOC-3, DOC-5 | Orca, keyboard-only and high-contrast acceptance; verify typed values and pending edits remain understandable across display and interaction paths ([#561](https://github.com/cozyGarage/BookiE/issues/561)). The [visual matrix](manual-verification-0.2-features.md#visual-audit-matrix) records the proposed acceptance recipe. |
| PEER-2 | One per-dialect lexer profile (backslash escapes, `E''` strings, `--` rule, quote characters) shared by statement splitting, classification and export quoting, so those paths cannot interpret the same SQL differently |
| PEER-3 | A Redis command table with arity and safety class that fails closed on unknown commands, instead of relying on the SQL classifier |
| B4-9, B4-11, B4-17, B4-21 | Route and TLS acceptance evidence, failed-batch rollback on optional MySQL engines and package acceptance, native multi-hop trust flow, SQL Server Kerberos Windows AD interoperability and package acceptance |

## Peer-review delivery

The [peer-review tracker #1026](https://github.com/cozyGarage/BookiE/issues/1026) and its child issues own the sequence, dependencies, lane and acceptance for the [October 16 review](archive/linux-peer-review-2026-10-16.md). Check the live project and issue before selecting work; this page does not duplicate child-issue status.

## Development tooling

- Improve CI feedback time and reliability based on measured workload and available capacity ([#573](https://github.com/cozyGarage/BookiE/issues/573)).
- Folder layout: done on 2026-10-11 (`crates/`, `apps/linux/`, `tests/`; see [ARCHITECTURE](../ARCHITECTURE.md#repository-layout)). Moving every per-crate integration test out of its crate stays a separate, larger step if wanted.

## Issue and lane status

Project #3 owns live scheduling and lane assignment. `docs/known-issues.md` maps ledger IDs to issues; issue bodies own scope and acceptance. Check those sources before treating a row above as open or selecting it.
