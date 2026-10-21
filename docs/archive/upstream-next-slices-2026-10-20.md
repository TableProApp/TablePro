# Newest code and upstream follow-up, October 20

What this repo does: BookiE is a native Linux database client with typed results, guarded execution and an auditable MCP service. This review assumes one developer using several tabs, connections and windows, including explicit PostgreSQL transactions. It prioritizes correctness and safe everyday workflows before more features.

This is a completed, bounded review. The proposed implementation slices remain open work. It changes no product code or accepted decision. The [backlog](../backlog.md) owns development order; each linked issue owns its acceptance.

## Source boundary

| Source | Inspected revision |
|---|---|
| BookiE `linux` | `d291ee662c83da53011d6d7805deacb7c6edea85` |
| TablePro `main` | `c584da5a763014e154b7386dbe7e3ec9811a53d4` |
| BookiE mirror `main` | `e1b11a1d116c6b789fdf473f2910bffe3bfb7a5b` |
| Previous upstream analysis | `3222542a4f66d24dc03c36478f97bf1ce34dbbf3` |

The pinned upstream has 18 first-parent commits after the previous review and seven after BookiE's mirror. None changes `linux/`. The new product work is in Apple code; other changes concern CI, release and security tooling. Updating the mirror and adopting a behavior into BookiE `linux` are separate operations. This review did not update the mirror.

The [evidence](../evidence/upstream-next-slices-2026-10-20/README.md) records exact pins, the commit inventory, native PostgreSQL results, a focused failure-report reproduction, issue snapshots and measured gate job spans. The main flows read were editor dispatch/session completion, policy transaction bookkeeping, PostgreSQL session execution, workspace persistence, connection URL import, clipboard export/paste, foreign-key navigation and CI diagnostics. Upstream connection compatibility, transaction monitoring and SSH changes were inspected with their relevant tests. This was not a file-by-file audit of either repository.

## What the latest BookiE merges improved

The edit tracker and supporting models now live in `crates/app-services`, with GTK adapters in the app. The headless crate has inherited workspace lints and the crate-boundary checker names its permitted dependencies. The earlier missing-lint-table concern is no longer current. Completion, workspace, browse planning, edits, preferences and reconnect decisions already have headless homes.

The release-version change centralizes 0.2.0 workspace versions and adds release consistency checks. The CSV chooser PR adds focused regression coverage. These are useful foundations, but they do not fix the open execution, TLS, clipboard and restore defects below. Another broad extraction is less urgent than making observable outcomes agree across the driver, guard, audit and UI.

## Must fix

### 1. Savepoint recovery can leave a false rollback in the audit

- **What this is:** PostgreSQL lets a transaction recover from an error with `ROLLBACK TO SAVEPOINT` and subsequently commit.
- **Problem:** `PolicySession::note_statement` sets `OpenBatch.aborted` on an error, but successful recovery does not clear it. `finish_outcome` therefore labels the later successful commit RolledBack. The native oracle commits IDs `{2,3}` after recovery; the policy consequence is established by source tracing, not a guarded real-driver run.
- **Fix:** [#1186](https://github.com/cozyGarage/BookiE/issues/1186), B4, P1. Start with an error/recovery/commit regression, then carry sound recovery evidence through existing transaction analysis. Keep failed recovery and unknown outcomes distinct.
- **Impact:** The journal can say data was rolled back when it was committed. Confidence: high from source plus native server evidence.

Relevant source: `crates/policy/src/guard/session.rs`, `note_statement`, `finish` and `finish_outcome`; `crates/policy/src/transaction_control.rs`. Existing savepoint tests cover staying inside the transaction, and an aborted-commit test covers rollback, but neither combines recovery and commit.

### 2. The editor calls a rolled-back PostgreSQL session committed

- **What this is:** PostgreSQL can successfully process COMMIT in an aborted transaction and answer with ROLLBACK.
- **Problem:** `commit_session` discards the query result and returns unit success; `on_session_commit_finished` then displays “Session committed.” The native oracle stores zero rows. The policy already knows the aborted outcome in its existing regression, but that distinction does not reach this UI handler.
- **Fix:** [#1187](https://github.com/cozyGarage/BookiE/issues/1187), UX, P1, coordinated with B4. Preserve an explicit committed/rolled-back/unknown outcome through the service boundary and test the rendered result against real stored rows.
- **Impact:** Users can believe earlier writes were saved after PostgreSQL discarded them. Confidence: high from source and native server behavior; the installed GTK workflow was not executed.

Relevant source: `apps/linux/app/src/ui/editor/session_mode.rs`, `commit_session` and `on_session_commit_finished`. Do not solve this by replacing every outcome with an uninformative generic success.

### 3. Imported PostgreSQL TLS requirements are discarded

- **What this is:** A PostgreSQL connection URL can carry a required TLS mode.
- **Problem:** `connection_url.rs` strips the query string and creates a connection with TLS Disabled, including for `sslmode=require`. Separately, `error_text.rs` advises Disabled for the broad TLS error class, including verification failures.
- **Fix:** Existing [#1172](https://github.com/cozyGarage/BookiE/issues/1172) and [#1174](https://github.com/cozyGarage/BookiE/issues/1174), B4, P1 recommendation. Preserve recognized requirements or refuse unsupported modes; then distinguish certificate/authentication problems from a server that offers no TLS.
- **Impact:** URL import can silently weaken the requested connection, and recovery advice can encourage another downgrade. Confidence: high source confirmation; no TLS fixture was rerun here.

Keep these as separate behavior changes with shared connection-path acceptance. Do not silently replace VerifyFull with a weaker mode to make a test connect.

### 4. Keyboard Run still bypasses the running-query guard

- **What this is:** Ctrl+Return and the Run button should obey one execution rule.
- **Problem:** The shortcut emits Run even when the button is disabled. `begin_run` checks teardown, while `execute_sql` starts a new generation and cancels the previous token. A repeated shortcut can replace the current operation while the previous database operation has not necessarily stopped.
- **Fix:** Existing [#1171](https://github.com/cozyGarage/BookiE/issues/1171), UX, P1 recommendation. Put the shared operation guard before dispatch and cover keyboard, toolbar and parameter-dialog callbacks under [#1031](https://github.com/cozyGarage/BookiE/issues/1031).
- **Impact:** A write can have an uncertain outcome while the UI starts another run. Confidence: high source confirmation; a fresh GTK reproduction remains acceptance work.

Relevant source: `editor/split_view.rs`, `editor/mod.rs` and `editor/run_lifecycle.rs`. Keep cancellation distinct from confirmation that the server stopped.

### 5. Workspace limits can discard unsaved editors

- **What this is:** Workspace persistence is the recovery path for unsaved SQL.
- **Problem:** `clamp_connection` truncates the combined tab list to 32 on both save and load. An unsaved editor after the first 32 tabs can disappear from the recoverable workspace. This is distinct from the existing database-scoped identity work in #1054.
- **Fix:** Existing [#1182](https://github.com/cozyGarage/BookiE/issues/1182), UX, P1 recommendation. Bound admission or preserve drafts separately with an explicit recovery path; test 33 or more tabs and the active editor beyond the limit.
- **Impact:** A resource limit becomes silent loss of user-authored SQL. Confidence: high source confirmation; process-death and desktop acceptance were not rerun.

Relevant source: `crates/app-services/src/workspace_state.rs`, `save_locked`, `load_locked` and `clamp_connection`. Keep atomic file writes and existing failed-save preservation.

### 6. Internal grid copy/paste is not an exact-value round trip

- **What this is:** Copying from one BookiE grid to another should preserve the selected values.
- **Problem:** `render_tsv` inherits spreadsheet formula sanitization and emits a text NULL marker; paste operates on text cells without the original value tags. A formula-like string or SQL NULL can therefore change meaning. Spreadsheet safety and an internal transfer have different requirements.
- **Fix:** Existing [#1184](https://github.com/cozyGarage/BookiE/issues/1184), UX, P1 recommendation. Test the actual copy-to-paste composition using NULL, literal marker text, empty text, quotes, tabs, line breaks and formula prefixes. Preserve safe spreadsheet export behavior.
- **Impact:** A routine transfer can stage different data without the user editing it. Confidence: high source confirmation; no new clipboard/display run was made.

Relevant source: `crates/core/src/export/csv.rs`, grid/context-menu export and `browse_tab/paste.rs`. ADR 0007 governs the value boundary.

## Should fix

### 7. CI can hide the assertion behind a red GTK scenario

- **What this is:** The distro-floor script captures GTK output and prints a summary when it finishes.
- **Problem:** The failure reporter keeps only the last 30 matching lines, including successful scenarios, then the last 20 raw lines. A focused reproduction with one early failure and 40 later passes loses both FAILED and AssertionError while preserving only the final scenario name.
- **Fix:** [#1188](https://github.com/cozyGarage/BookiE/issues/1188), UX, P2. Extend the existing harness with that early-failure case and prioritize bounded failure/retry diagnostics over pass summaries. Use the existing gate.
- **Impact:** Each red run can require another expensive run merely to recover the reason it failed. Confidence: confirmed by executing the helper.

An important correction to earlier runtime guesses: silence after `debconf` does not prove apt is stuck. `test-distro-floor.sh` redirects the whole GTK suite to a file, so successful test execution can also be invisible until completion. Add phase/progress reporting before changing timeouts, runner counts or gate coverage.

Measured first-to-last log spans for the green run #800 were unit 179 seconds, sandbox 195 seconds, widgets 215 seconds, PostgreSQL driver 341 seconds, GTK shard 1 378 seconds, Debian floor 871 seconds and Ubuntu floor 935 seconds. These exclude queue time and do not isolate apt, image build, smoke or upgrade phases. One run cannot establish a performance regression or justify deleting coverage.

## Latest upstream ideas worth adapting

| Upstream change | Useful lesson | BookiE action |
|---|---|---|
| [#3688 transaction monitoring](https://github.com/TableProApp/TablePro/pull/3688) | Distinguish open, aborted and unknown state; pin confirmations to driver identity and work generation; avoid a health SELECT that changes a transaction or interferes with a stream | Fix #1186/#1187 first. Later add a truthful transaction indicator. BookiE editors own separate sessions, so a connection-wide Commit control copied literally could target the wrong editor. |
| [#3685 connection compatibility](https://github.com/TableProApp/TablePro/pull/3685) | Encode an older format only if decoding it reconstructs the same semantic bundle; preserve the newer format when nested groups or saved queries require it | Reuse the old-reader/round-trip test model when changing BookiE bundles. Current v2 output is not itself a defect without an older-reader compatibility promise. Do not assume Apple and BookiE formats interoperate. |
| [#3682 foreign-key navigation](https://github.com/TableProApp/TablePro/pull/3682) | Composite keys, schemas, ambiguous names, empty values and placeholder values need explicit cases; shared literal construction avoids inconsistent lookups | BookiE already has typed reference targets, composite-key tests and shared equality filters. Add missing real PostgreSQL consumer cases to existing coverage rather than implement another navigator. |
| [#3687 real OpenSSH matrix](https://github.com/TableProApp/TablePro/pull/3687) | Test actual server authentication combinations and negotiation stages; report unsupported authentication precisely | Reuse case definitions under #566/#548 after core fixes. Test current supported/refused behavior first. The libssh2 partial-success and channel-pump workarounds do not directly apply to BookiE's russh implementation. |
| [#3684 saved queries](https://github.com/TableProApp/TablePro/pull/3684) and [#3690 completion](https://github.com/TableProApp/TablePro/pull/3690) | Keep portable query models and deterministic, testable search/completion rules separate from platform UI | BookiE already has headless completion and favorites. Reuse focused regression cases when a gap is demonstrated. Mobile/iCloud work is outside the accepted Linux product. |

Upstream's new scanner image, hosted-runner move and release attestation changes are deployment-specific. They do not establish a need for another BookiE gate or a replacement of the current lab. Preserve existing dependency/security review and only adopt a tool for a concrete uncovered risk.

## Proposed next slices

These are recommendations, not a new release commitment. Each row should be delivered as focused changes through the owning issues and existing test tiers.

| Order | Slice | Acceptance |
|---|---|---|
| Independent small CI fix | #1188 diagnostic preservation | Existing Python/shell harness; early failure plus later passes; unchanged exit status. No added gate. |
| 1 | #1186 transaction recovery truth, then #1187 editor outcome | Policy regression, real PostgreSQL rows/audit comparison, then GTK commit-end workflow. |
| 2 | #1172 URL TLS preservation, then #1174 precise recovery advice | Import/unit and transport/TLS cases, including verification failures; no downgrade. |
| 3 | #1171 shared Run guard | Observable dispatch count across action entry points and slow/write cancellation cases. |
| 4 | #1182 draft recovery, then #1184 internal clipboard round trip | Persistence boundary/restart proof and exact-value composition tests. Keep these separate PRs. |
| 5 | Bounded PostgreSQL NOTICE output, #1033 then #1034 | Native RAISE NOTICE plus cumulative count/byte limits; results still complete; no stale append after Stop, close or reconnect. This is the strongest next visible PostgreSQL feature. |
| 6 | PostgreSQL extension qualification, #902 with #594 | Start with pgvector's exact select/edit/export path, then PostGIS as its own slice. Use native values and guarded consumer tests before richer vector/map viewers. |

The notices work improves a common PostgreSQL debugging workflow with a bounded scope. Extension work fits the PostgreSQL-first product, but an exact value path is more valuable now than a new viewer. Keep stream-retention evidence in #1032 and reconnect/lost-ack evidence in #593/#590 ahead of large new result features. Architecture/ADR follow-up remains #891; fixing these cases does not require replacing Relm4 or importing a second session framework.

## Verdict and limits

Verdict: the recent architecture and release work provide a usable base. Finish truthful PostgreSQL outcomes and the already-open safety defects, improve failure diagnostics, then deliver bounded server notices and one extension path.

Native PostgreSQL semantics and the diagnostic-loss case were independently executed. No BookiE application build, installed GTK run, guarded real-driver regression, complete suite, upstream Apple build or new Forgejo gate was run for this review. Existing green gates prove their recorded revisions and tiers, not these newly identified cases. Project #3 item insertion was unavailable because the current token lacks `read:project`; the new issues have lane labels and ledger entries.
