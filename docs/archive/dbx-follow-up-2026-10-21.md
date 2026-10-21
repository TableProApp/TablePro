# dbx architecture and regression follow-up, October 21

Dated source review. This supplements the [October 20 deep review](tablepro-dbx-review-2026-10-20/README.md) and [October 15 architecture review](2026-10-15-dbx-review.md). It does not amend accepted ADRs or select work ahead of the [backlog](../backlog.md).

## Evidence and limits

- BookiE: `20cadf509`, the GitHub `linux` tip fetched for this review.
- dbx: `b9690840adff74d02a59d69a8d053b0427437519`, October 21. The [comparison from the previous pin](https://github.com/t8y2/dbx/compare/d1e88ab4b...b9690840adff74d02a59d69a8d053b0427437519) contains 107 commits. All commit subjects were screened; selected patches and test additions were read. This is not a full audit of all 107 diffs.
- The 40 most recently updated issue/PR feed entries were screened. Selected issue bodies were read. Open reports below are reporter claims, not reproduced defects.
- Upstream source was treated as untrusted data. No upstream script or binary was executed. BookiE source and existing test bodies were inspected; no product tests, database probes or builds were run for this review.

## Architecture worth retaining

At this pin, dbx separates reusable orchestration in `dbx-core` from `dbx-types`, `dbx-sql`, `dbx-drivers`, formats, platform and plugin crates. Its core manifest still includes direct PostgreSQL, MySQL, Redis and MongoDB client dependencies. Extracting crates does not by itself prove every database operation has moved behind a driver boundary. See the [pinned core manifest](https://github.com/t8y2/dbx/blob/b9690840adff74d02a59d69a8d053b0427437519/crates/dbx-core/Cargo.toml).

For BookiE, application orchestration belongs in `tablepro-app-services`; domain contracts remain in `tablepro-core`, and engine access stays in static driver crates. Keep the current GTK-free boundary and PolicyGuard seam. Reusing dbx-core as a dependency would pull in responsibilities and runtime choices that do not match those boundaries.

The [architecture guard](https://github.com/t8y2/dbx/blob/b9690840adff74d02a59d69a8d053b0427437519/scripts/core-architecture.test.mjs) checks Cargo metadata, explicit dependency edges, production use of test-support features, shared transfer orchestration, workspace inputs in Docker dependency caching, and protocol asset agreement. Some checks assert filenames or source text; adopt the invariant when useful, rather than copying those assertions.

BookiE already has `scripts/check-crate-boundaries.py`, which checks direct workspace edges, transitive GUI dependencies and preflight crate inclusion. Treat architecture guards as existing infrastructure to extend, not a missing feature. Further candidates are production test-hook exclusion and packaging/cache completeness when a new workspace member appears. First prove that BookiE's current guards miss the relevant failure. These are proposals, not newly confirmed defects or a request for another CI gate.

## Changes with the strongest PostgreSQL relevance

### One session for a complete SQL file

Merged [#12725](https://github.com/t8y2/dbx/pull/12725), commit [e9639e6919ca](https://github.com/t8y2/dbx/commit/e9639e6919cafd4900072df8de9d6cd2a7732971), adds a pinned session for non-MySQL SQL-file execution. Statements in a file containing BEGIN/COMMIT previously could use different pooled connections. Cleanup closes the session after completion, failure or cancellation. Before constraint restoration on another connection, it releases the pinned session so unfinished transactions cannot hold locks across cleanup.

The valuable regression technique is an independent PostgreSQL observer connection: inspect `pg_stat_activity` and verify another connection can make progress. Inspecting the same workload pool can accidentally select the session being tested and hide the idle-in-transaction state. The added `live_postgres_sql_file_transaction.rs` is an explicitly ignored live-engine target; this source review does not establish that dbx runs it in CI.

BookiE's editor `session_mode.rs` distinguishes pooled, live-session and retired targets and contains bounded cursor cleanup. This does not establish that every script/import path has equivalent ownership. Proposed B4/UX driver or release acceptance: one backend identity across a session-scoped script; temporary objects remain visible; a failed/cancelled script leaves no locks or idle transaction; cleanup failure retires the session. Keep PolicyGuard classification and terminal audit outcomes on every statement. Prefer extending the existing PostgreSQL-first tracker [#590](https://github.com/cozyGarage/BookiE/issues/590) after a concrete path is traced.

### PostgreSQL-compatible does not imply physical row locators

Merged [#12687](https://github.com/t8y2/dbx/pull/12687), commit [72a584568f63](https://github.com/t8y2/dbx/commit/72a584568f63aa5bc96b711ea02881319c1b029e), handles Hologres rejecting `tableoid`, despite reporting a PostgreSQL-style version. A keyless read retries once without the synthetic locator; success remembers the limitation for that connection, and a second failure restores the flag so it does not become a permanent false diagnosis.

BookiE already refuses keyless edits by design, as recorded in the earlier review. Do not add ctid editing just to copy this fallback. The transferable lesson is to scope observed capabilities to the connection and operation, preserve read-only browsing, and preserve the original diagnostic if a fallback also fails. Never apply automatic retries to writes. Candidate tests belong with [#1065](https://github.com/cozyGarage/BookiE/issues/1065), the per-object write-capability audit.

### Serial export must survive a fresh restore

Open [#13058](https://github.com/t8y2/dbx/issues/13058) reports dbx 0.6.50 exporting BIGSERIAL as `bigint DEFAULT nextval(...)` without the referenced sequence. The reporter did not provide a confirmed server/version. This is an upstream report, not a verified BookiE bug.

BookiE already recognizes serial defaults in `crates/drivers/postgres/src/lib.rs` and has sequence-copy coverage under `crates/drivers/postgres/tests/support/identity_copy_contract.rs`. `crates/core/src/export/sql.rs` also pins engine-generated identity values. Those cover different contracts; neither alone proves a schema-plus-data backup restores identifiers and sequence state exactly.

Proposed B3 release fixture: export into a fresh schema, restore without source sequences, compare identity values, then INSERT DEFAULT VALUES and check the next id. Include quoted mixed-case names, serial versus identity, negative increments and an advanced sequence. Respect the recorded SQL-export contract; distinguish row INSERT export from a complete backup before changing expectations. Record an actual failure before filing a defect.

## UX and boundary regression lessons

| Upstream evidence | What changed | BookiE mapping and next check |
|---|---|---|
| [#12024](https://github.com/t8y2/dbx/pull/12024), `b9690840adff` | Quoted completion spans included the quote, so CodeMirror's second matcher hid correctly ranked candidates. The fix also refreshes bypassed results as typing continues. | `completion_proposals.rs` already separates normalized matching from insertion text; GTK `completion_provider/tests.rs` tests activation with quoted names, spaces, Unicode and escaped quotes. Existing coverage, not a newly established gap. Add a rendered-menu progression case only if filtering fails after further typing. UX, gtk-widgets. |
| [#12979](https://github.com/t8y2/dbx/pull/12979), `eeab128d738e` | Restore history into a new editor instead of overwriting active SQL; refuse an ambiguous name fallback for a deleted connection. | `AppMsg::OpenHistoryQuery` already appends an editor tab. Keep a UI regression that preserves the old buffer. Connection/schema ownership still needs separate verification; new-tab behavior alone does not prove the target is correct. UX, GTK. |
| [#12748](https://github.com/t8y2/dbx/pull/12748), `44754e7cc058` | Text-column paste keeps empty strings distinct from NULL; configured NULL sentinels are parsed explicitly. | Existing [#1184](https://github.com/cozyGarage/BookiE/issues/1184) and [#1030](https://github.com/cozyGarage/BookiE/issues/1030) own related clipboard and draft-value contracts. `paste.rs` already tests adjacent empty fields. Add end-to-end copy/paste/save assertions for empty text, NULL, literal sentinel and formula-leading text. Do not copy dbx's coercion of blank non-text input to NULL without B3 contract agreement. |
| [#12824](https://github.com/t8y2/dbx/pull/12824), `a6275be47fb8` | Inline EXPLAIN prefixes no longer absorb following queries under dbx's semicolon-free execution rules. | Preserve BookiE's shared ScriptPlan semantics. Test explicit semicolon boundaries and EXPLAIN options against the same plan used for execution and policy. This does not justify importing dbx's line-based statement heuristic. B3/B4 review. |

## Additional reports and features to consider later

- Open [#13065](https://github.com/t8y2/dbx/issues/13065) reports unsupported identity metadata `i` through an agent. No server or reproduction is provided. Preserve unknown metadata explicitly and refuse unsupported DDL; do not silently reinterpret it. Low-confidence cross-client lead only.
- [#12754](https://github.com/t8y2/dbx/pull/12754) adds previous/next statement and statement-start shortcuts using the existing executable ranges. This is a useful small UX candidate because navigation and execution share boundaries. Check BookiE's existing navigation before proposing another implementation.
- [#12913](https://github.com/t8y2/dbx/pull/12913) preserves manual column widths while invalidating automatic widths on font/density changes. [#12914](https://github.com/t8y2/dbx/pull/12914) reconciles orphan width-cache entries. Check the current ColumnWidthStore lifecycle before promotion.
- The preview-warning suppression feature merged as [#12965](https://github.com/t8y2/dbx/pull/12965) was reverted by [#13012](https://github.com/t8y2/dbx/pull/13012) in this range. Do not describe it as a current capability. Any muted preview warning in BookiE must still leave truncation discoverable before copy/export.

## Suggested order and completion

1. **First:** PostgreSQL session ownership and restore correctness. Extend existing driver/release fixtures after tracing the exact BookiE path. These protect data and locks.
2. **Then:** clipboard value distinctions under the existing issues; preserve the typed value contract through save.
3. **Then:** extend architecture/cache guards only for a demonstrated omission. Keep them in existing preflight and harness checks.
4. **Later:** statement navigation and width-cache refinements, after checking current implementation and open ownership.

Completed in this review: current upstream pin, commit-subject screening, selected fix/test inspection, architecture-guard comparison, open-report qualification and BookiE source mapping. Not completed: reproductions, regression execution, product changes or new defect tickets. No previously completed work is reopened by this document.
