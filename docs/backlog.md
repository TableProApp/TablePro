# Backlog after 0.2.0

On 2026-10-18, the maintainer recorded 0.2.0 delivery work complete while publication was pending. Check the [release page](https://github.com/cozyGarage/BookiE/releases) for current publication status. Rows here select subsequent development. Project #3 and the owning issues keep status and acceptance; this page keeps the order. The [completion handoff](archive/bookie-0.2-completion-handoff-2026-10-18.md) preserves the former release checklist.

The [capability review](capability-review.md) records general evaluation
criteria and current technical boundaries. An item becomes backlog work only
after selection; add an owner, acceptance layer and GitHub issue when promoting
it. Do not treat a capability gap as a release commitment.

## Completed Linux code-adoption packets

The nine selected packets under [#1149](https://github.com/cozyGarage/BookiE/issues/1149), [#1140](https://github.com/cozyGarage/BookiE/issues/1140) through [#1148](https://github.com/cozyGarage/BookiE/issues/1148), are closed. Their native-driver investigations, conformance, paging, lifecycle checks, notices, release-input checks and tooling evaluations are completed packets, not the active queue. The [dated review](archive/upstream-linux-adoption-2026-10-18.md) preserves the selection rationale. Their completion does not publish a release or close separate qualification issues.

## Current development order

Finish existing pull requests first, then address destructive operations [#1176](https://github.com/cozyGarage/BookiE/issues/1176) and [#1175](https://github.com/cozyGarage/BookiE/issues/1175), value preservation [#1184](https://github.com/cozyGarage/BookiE/issues/1184) and [#1177](https://github.com/cozyGarage/BookiE/issues/1177), and the security findings below. Reproduce each report before changing behavior. Keep one lane-owned fix and one serialized Forgejo gate at a time.

Continue existing dependency chains after those fixes: object write capabilities #1065 before shared grid guards #1031, and bounded server messages #1033 before the GTK consumer #1034. Edit ownership #1029, workspace identity #1054 and stream budgets #1032 retain their acceptance. New features remain selected separately; issue status and lane belong to Project #3.

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
| RV-12 / [#1182](https://github.com/cozyGarage/BookiE/issues/1182) | Restore drops tabs after 32 per connection | UX | Unsaved editor text always restored |
| RV-13 / [#1184](https://github.com/cozyGarage/BookiE/issues/1184) | Copy then paste between BookiE grids changes values | UX | Round trip keeps text and NULL |

The [newest-code follow-up](archive/upstream-next-slices-2026-10-20.md) records the native PostgreSQL and failure-report probes behind RV-14 to RV-16, the latest Apple-side upstream lessons, and a proposed sequence before server notices and PostgreSQL extension work. Its candidate order does not add a release commitment.

## 0.2.x features

| Row | What | Notes |
|---|---|---|
| SNAP-2 to SNAP-4 | Database snapshots: PostgreSQL, SQL Server, then SQLite and DuckDB file copies | ADR 0015 records the accepted design; this is post-0.2.0 implementation work, not a release commitment; limit 5 snapshots per database |
| UI-1b | Edit SSH jump chains in the form | Storage, transport, bundle v2 and per-hop passphrase coverage merged in #490, #492, #494 and #528; GTK editing stays refused until its complete path passes |
| UI-19 | Foreign key value picker, estimated counts | FK navigation, paste TSV and the ENUM and SET pickers (PostgreSQL, MySQL, MariaDB) landed |
| UI-38 | Local filters and sorting for materialized SQL results | Exact-value filtering and local sort are implemented; settings are retained per statement/result set across reruns and pin/unpin. Selection follows the same materialized result; [#609](https://github.com/cozyGarage/BookiE/issues/609) owns remaining acceptance. App-restart persistence is not included |
| UI-39 | Pending grid edit cues that work without color and are announced to assistive technology | Modified, inserted and deleted rows need persistent visible state cues, accessible descriptions, and coverage for revert and widget recycling ([#1126](https://github.com/cozyGarage/BookiE/issues/1126)) |
| UI-20 | Server output (NOTICE, PRINT) and a timing breakdown | with PERF-4 |
| UI-22, UI-23, UI-26 | Multi-cursor editing, typed PostgreSQL activity console, reusable SSH profiles | accepted for later; preview tabs, split panes, SQL code folding and the docked query history panel have landed (#618, #630, #754, #619); PostgreSQL catalog objects are already built (UI-23) |
| PKG-2 | Debian and GNOME desktop pass (UI-D1 to D4) | the packages keep building and passing the distro floor in CI; this is the desktop acceptance |
| PKG-4, PKG-8 | Flatpak Flathub submission and screenshots, and the file-access decision (`--filesystem=home` or portal only) | A Debian 13 guest build/install/launch check is recorded in [platforms](platforms.md#flathub); it does not qualify current source. Not part of 0.2.0; decide PKG-8 before PKG-4 |

## Performance

| Row | What |
|---|---|
| PERF-2, PERF-7, PERF-8 | Progressively load SQL editor results while keeping bounded resource use. Core, PostgreSQL, PolicyGuard and the PostgreSQL editor lifecycle have landed; other engines and comparable memory profiling still need qualification. |
| PERF-3 | MongoDB browse on large collections | Compatible `_id` keyset seek landed in #493; supported server-side sorting landed in #837. Other sorted pages and keyless deep pages still use offset pagination; installed and representative-network acceptance remain |
| PERF-4 | Server time next to elapsed time |
| PERF-5, PERF-6 | Idle memory and binary size, accepted for now |

## Quality and tooling

| Row | What |
|---|---|
| TEST-2 | Maintain the selected-package mutation audit in the [Forgejo nightly workflow](../.forgejo/workflows/nightly.yml) and triage survivors under [#559](https://github.com/cozyGarage/BookiE/issues/559). Expected-value provenance is tracked separately by [TEST-32](oracle-review.md); dated package results remain in [evidence](evidence/test-quality-2026-10-11/). |
| AUD-11 consolidation | Finish the single AST walk for classification, masking and blast-radius planning. Behavioural fixes are closed on the current policy suite; shared analysis landed in #506. Structural consolidation follows 0.2.0. |
| TEST-12 | Verify sample and page-observed type union, plus acceptance evidence, against the bounded 128-document non-snapshot contract in [ADR 0007](decisions/0007-type-and-value-preservation.md) |
| APP-MOD | Keep the app layer thin: finish the staged moves of [ADR 0018](decisions/0018-headless-app-services-crate.md) (completion, workspace and browse/edit models, scoped filter and mapping stores, preference data, quick-switcher ranking and retry decisions are now headless; translated errors and the TabView handshake stay in app adapters; continue the remaining service moves), and replace hard-coded driver-name branches in the app layer with driver capabilities, starting with `browse_tab/value_parse.rs` |
| UI-21, TEST-28 | Fake connection for the GTK tier, native Ubuntu AT-SPI menu reachability |
| TEST-30 | Triage remaining SonarCloud and CodeQL findings; close confirmed false positives with a reason |
| TEST-34 | Import repository-tool Python coverage into SonarCloud without lowering the coverage gate ([#830](https://github.com/cozyGarage/BookiE/issues/830)) |
| TEST-36 | Record duration for each installed GTK scenario and retry so suite growth can be measured before changing timeouts or shard layout ([#1075](https://github.com/cozyGarage/BookiE/issues/1075)); retain current limits until there is measurement evidence |
| AUD-5 | Move nonessential Rust comments into documentation under the repository comment-line rule ([#563](https://github.com/cozyGarage/BookiE/issues/563)) |
| DOC-3, DOC-5 | Orca, keyboard-only and high-contrast acceptance; verify typed values and pending edits remain understandable across display and interaction paths. The [visual matrix](manual-verification-0.2-features.md#visual-audit-matrix) records the proposed acceptance recipe. |
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
