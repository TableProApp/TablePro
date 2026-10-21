# Linux documentation and peer review, 2026-10-16

This is a source review and an update plan. It does not qualify a release or report a fresh database, GTK, Wayland or Forgejo pass. No product code, dependencies or existing tests were changed. The accepted sprint and ADRs retain authority over scheduling and behavior.

## Source pins and method

| Repository | Reviewed revision |
| --- | --- |
| BookiE `linux` | `5ebc01d118b8e18447bc5fbd31374cc5a4873811` |
| TablePro `linux` | `45d49a23fa107b5e84636ae9e8e18dabf989f464` |
| TablePro `main`, v0.81.0 release tip | `3a7d96511a4a75153aa783f1c116758575a79737` |
| dbx `main` | `f441d781ec57d85dee1b5d4e3e1aa83a6dc23216` |
| DBeaver `devel` | `b27cd8046fed70146c1bc28c92143fd1294a0dcc` |
| Beekeeper Studio `master` | `19b1372dfa9fd955605777fefaf2a2ee659903b6` |

Fetched BookiE and both TablePro branches without changing the shared checkout. Screened 19 open BookiE PRs, 50 recently updated closed BookiE PRs, 60 TablePro PRs, 45 dbx PRs, 40 open dbx issue-feed records, 35 DBeaver PRs and 30 Beekeeper PRs. Closed does not mean merged: selected candidates were checked for `merged_at` and target branch. These are bounded samples, not exhaustive histories.

Inspected BookiE manifests, guards, streaming, editing, ordering, MongoDB metadata and PostgreSQL cancellation paths. Read selected upstream PR explanations and source patches, the newest TablePro Linux grid and dependency diffs, and pinned dbx architecture, manifests, dependency guard, issue form and query-message buffer. PR-reported test results remain their authors' evidence. The isolated boundary-check probe below was executed locally; no reference-project was built or benchmarked.

The [October 15 dbx review](2026-10-15-dbx-review.md), [PostgreSQL research](2026-10-15-postgresql-client-research/review.md), [upstream intake](../upstream-sync.md) and [#983](https://github.com/cozyGarage/BookiE/issues/983) already own substantial overlap. Keep their dated findings intact and update current owners instead of rewriting historical evidence.

## Findings in current BookiE

### 1. Current documentation contradicts landed code

Confirmed against the reviewed source:

- `ARCHITECTURE.md`, its SQL editor row, and ADR 0011's implementation status say the editor does not use cursors. PR #908 is merged. PostgreSQL editor streaming retains four pages, with a 5,000-row fetch size. Other engines retain the materialized path.
- `docs/0.2-feature-comparison.md` says credential-bearing history is still saved (#967). PR #988 is merged and #967 is closed. It also calls streaming wholly open.
- That comparison combines **TablePlus and TablePro**, attributing TablePlus release numbers and features to one row. These are separate products. TablePro's inspected main tip is v0.81.0. Split their identities and sources before using the page to choose parity work.
- `docs/backlog.md` calls full-value editing an active #610 PR. #610 is a closed issue; its implementation landed through #939. The user guide already describes it.
- `ARCHITECTURE.md` omits `tablepro-dump`, although the workspace, boundary allowlist and preflight list include it. ADR 0019 is accepted. Vendor-tool foundations (#999), SSH endpoint assembly (#1005), and administrative guard operations (#1008) are merged; the user-facing PostgreSQL backup/restore PR #1017 remains open. Neither foundations nor an open PR prove the UI shipped.
- `docs/user-guide.md` does not explain PostgreSQL streaming, retained-page eviction or completion/truncation limits. `docs/known-limitations.md` already records much of this accurately and should supply the shared scope.
- The active ledger still lists UI-39/#610 even though the issue is closed. The index validator checks format, not live issue status.

### 2. The architecture guard has a test-dependency blind spot

Confirmed with the real checker and synthetic Cargo metadata built by its existing test helper. `check-crate-boundaries.py` rejects normal and build GTK edges from app-services, but traverses no dev edges:

```text
app-services -> gtk4, normal: rejected
app-services -> gtk4, build: rejected
app-services -> gtk4, dev: []
```

Its module documentation says GUI dependencies are forbidden in development dependencies too. `test_an_external_crate_cannot_hide_a_forbidden_edge_behind_a_dev_dependency` currently expects an empty error list for core -> gtk4. That test pins the exemption rather than the documented prohibition. This is a guard defect, not evidence that a shipped headless crate currently imports GTK.

Follow-up: UX tooling fix, coordinated with [#891](https://github.com/cozyGarage/BookiE/issues/891). Keep permitted workspace test edges, such as driver -> policy, distinct from forbidden GUI edges. Add failing regressions for direct and transitive GUI dev dependencies before fixing traversal. Explain the changed expectation; do not delete the existing test. Include build dependencies and enabled optional features in the matrix.

### 3. Blank input conflates NULL and default intent

`browse_tab/value_parse.rs::parse_input_for_column` returns `Value::Null` for empty input if a column is nullable **or has a default**. `parse_input_for_grid_cell` reaches that behavior for ordinary persisted cells. The existing `empty_on_not_null_with_default_yields_null` test explicitly pins it. A declared default does not make an existing NOT NULL column nullable.

This is a confirmed parser outcome and a contract question requiring native reproduction, not a claim of demonstrated stored-data corruption. TablePro [#3428](https://github.com/TableProApp/TablePro/pull/3428) shows why this boundary matters: its fix distinguishes typed clearing, empty text/binary and NULL, and refuses NULL where the server could substitute a timestamp.

Follow-up: B3 and UX handoff. Separate persisted-cell clearing from a new draft's omitted/default value. Preserve BookiE's documented empty-input behavior until the contract is explicitly resolved. Test nullable/non-nullable columns with and without defaults, text/SET empty members, JSON `null`, timestamp modes, inline edits, TSV paste and the full-value dialog. Verify stored native values and unchanged rows on refusal. Keep existing tests and amend intentional semantics with a reason in the fix.

### 4. Streaming is implemented but does not prove a small memory footprint

The four-page cache is real (`editor/stream_pages.rs`). PostgreSQL applies `QueryResultBudget` during decoding; a truncated page ends the cursor. This is stronger than an unlimited row-only implementation. However, the UI cache admits by page count, not one aggregate byte/cell budget, and decoding an individual large value precedes the result-budget admission check. Arc-backed snapshots and pins also need whole-lifecycle measurement.

Keep [#554](https://github.com/cozyGarage/BookiE/issues/554) open. Measure retained pages, old result snapshots, pins, oversized cells, cancelled/exporting runs and database buffers separately. Do not describe retained pages as the complete process-memory ceiling. PRs #1002 and #1012 already address stream status/pins and session/export ownership; review their final merged behavior before adding another fix.

## Work already done: reuse it

| Earlier recommendation | Current evidence and remaining work |
| --- | --- |
| Flatten the repository | Root workspace, `crates/`, `apps/linux/`, `tests/`, `scripts/`, `docs/` already exist. No new move needed. |
| Shared headless orchestration | `tablepro-app-services` and ADR 0018 exist. Continue their staged extraction, not a second application core. |
| Executable boundaries | Guard and synthetic graph tests exist; #887 closed. Fix the dev-GUI blind spot above. |
| Faster Rust test execution | #892 closed; #1010 runs unit and sandbox tiers under pinned nextest. Measure actual feedback time; retain every other tier. |
| Stream Mongo metadata rather than collecting samples | #926 merged; `observe_sample` consumes one document at a time. #894 is still open: distinguish completed retention repair from schema-cardinality, driver buffering and representative memory acceptance. |
| Structured MCP outcomes | #927 merged; #896 closed. Preserve this contract. |
| MCP tool annotations | #925 merged; #897 closed. Backlog PEER-1 needs reconciliation. |
| Lossless MCP numbers | #895 open and PR #956 open. Coordinate with its owner; do not create a parallel serializer. |
| Session-aware SQL lexing | #893 remains open. #1019/#1022 address specific lexical cases, not the full session-mode problem. |
| PostgreSQL duplicate-execution recovery | #921 merged. The older research is a historical defect record, not proof the retry bug remains. |
| History credential exclusion / SQLite FK creation | #988/#991 merged; #967/#972 closed. Remove current missing-feature claims. |
| SQL Server defaults, table rename, float display, concurrent saves | Open PRs #994, #996, #1003, #1013. Avoid competing edits. |

## What to learn from peers

### dbx: adopt contracts and regression sequences

At the pinned [architecture](https://github.com/t8y2/dbx/blob/f441d781ec57d85dee1b5d4e3e1aa83a6dc23216/crates/ARCHITECTURE.md), `dbx-core` orchestrates application workflows; `dbx-types` holds domain/DTO data. **BookiE core corresponds more closely to dbx-types**, while app-services is the appropriate home for headless orchestration. Do not reverse BookiE's dependency direction to match an external crate name.

- **Dependency boundaries and feature forwarding:** their metadata guard checks allowed edges, feature propagation, source ownership and build inputs. Keep BookiE's graph guard; add focused checks that optional DuckDB and any future vendor-client support reach the intended composition roots without pulling GUI dependencies into agentd. Compile selected configurations too; source-text checks alone are insufficient.
- **Shared consumers:** share pure planning and workflow outcomes across GTK and headless consumers, while every execution keeps PolicyGuard. Do not make shared code expose raw driver handles.
- **Resource ownership:** request identity must own cursor, cancellation, session, export and terminal audit. Test late completion after replacement and teardown. A retained Arc or a dropped future is not proof of server completion.
- **Bounded output:** their query-message buffer limits both message count and bytes, with cumulative counters. Reuse this pattern in existing NOTICE/PRINT work [#550](https://github.com/cozyGarage/BookiE/issues/550), including GTK queue pressure and notices arriving before the first result.
- **Templates:** their issue form requests database/version, steps and copied support information. BookiE's form already asks for most of this. A small sanitized Copy support information action would improve reports; do not copy a whole template merely to add fields already present in BookiE.

Newly inspected merged fixes provide useful cases:

| Peer source | BookiE disposition and acceptance |
| --- | --- |
| [dbx #12309](https://github.com/t8y2/dbx/pull/12309), PK tie-breakers | Already covered in browse ordering by `resolved_order_by` and composite-key tests. SQL-result header sort is local and never re-executes DML. Preserve both contracts; test tied sort values and page/export agreement where applicable. |
| [dbx #12325](https://github.com/t8y2/dbx/pull/12325), load-all after jumping pages | Transfer the invariant: a retained window is not a contiguous prefix. BookiE's forward cursor and refused full-table export differ. Check page eviction, visible row offsets and completeness claims in #554; do not add dbx's load-all mechanism. |
| [dbx #12380](https://github.com/t8y2/dbx/pull/12380), keyless PG physical identity | Later design candidate only. `tableoid:ctid:xmin` needs invalidation, inheritance/partition and concurrent-write tests. Existing `ctid` ordering is not permission to write a keyless row. Preserve current safe refusals. |
| [dbx #12394](https://github.com/t8y2/dbx/pull/12394), BSON constructors | Candidate for a deliberately limited Mongo parser, not JavaScript evaluation. Preserve Int32/Int64/Double/Decimal128 and reject ranges/identifier-prefix matches. Native `$type` is the oracle. |
| [dbx #12400](https://github.com/t8y2/dbx/pull/12400), adjacent CASE expressions | Oracle is outside scope, but punctuation-sensitive nesting is a useful lexer regression for supported procedural dialects. Route through #893/#983. |
| [dbx #12354](https://github.com/t8y2/dbx/pull/12354), settings close bypass | Exercise every close route for drafts: button, shortcut, inactive tab, parent close and disconnect. Keep confirmation and completion as distinct state transitions. |
| [dbx #12330](https://github.com/t8y2/dbx/pull/12330), export DEFINER | Future MySQL dump design input under ADR 0019. Rewriting DEFINER changes security identity; make portability policy explicit rather than stripping it from every export silently. |

### DBeaver and Beekeeper: protect every consumer

- [DBeaver #42333](https://github.com/dbeaver/dbeaver/pull/42333) checks INSERT, UPDATE and DELETE independently at command entry points. Adopt its matrix: toolbar, shortcut, context menu, mixed selection, pending insert discard, keyless/readonly objects. A disabled widget alone is not an operation guard.
- [DBeaver #42362](https://github.com/dbeaver/dbeaver/pull/42362) fixes SQL Server datetimeoffset quoting in multi-cell Copy as SQL. Reuse one typed literal serializer across single-cell, row and export paths; execute exported SQL and compare native values. This case already belongs to #983.
- [DBeaver #42369](https://github.com/dbeaver/dbeaver/pull/42369) preserves PostgreSQL `@?` as an operator when formatting. Add to the shared dialect corpus; assert semantic token preservation, not formatter whitespace.
- [DBeaver #42313](https://github.com/dbeaver/dbeaver/pull/42313) sanitizes diagnostics and removes incomplete archives after cancellation. Useful for a future support bundle; never include SQL values, secrets or private endpoints by default.
- Reject the permissive direction of [DBeaver #42374](https://github.com/dbeaver/dbeaver/pull/42374): classification failure is not evidence of a safe read. BookiE retains its governed approval/refusal behavior.
- [Beekeeper #4691](https://github.com/beekeeper-studio/beekeeper-studio/pull/4691) bounds binary encoding before allocating the display string and treats binary as a leaf. BookiE already previews long values and summarizes binary. Extend measurement to JSON serialization, full-value dialogs, selection summaries and copy/export, where truncating after conversion can still allocate a large intermediate. Their reported speedup is not a BookiE benchmark.
- [Beekeeper #4838](https://github.com/beekeeper-studio/beekeeper-studio/pull/4838) confuses DuckDB type aliases with column names. Add a metadata regression candidate preserving label, declared type and origin independently.

No driver crate addition is justified by this review. Keep the official Rust driver stack. DBeaver's JDBC implementation is not a Rust drop-in; dbx's internal crates carry different contracts. ADR 0019 already selects vendor tools for logical dumps and DuckDB for approved conversion work.

## TablePro: port assessment

BookiE and upstream Linux are substantially diverged. A whole-branch merge would import an incompatible session/driver architecture and unrelated product choices. No reviewed commit is recommended for direct cherry-pick. Linux Rust changes can still be adapted selectively with attribution and regression tests. Main's Swift behavior requires implementation against BookiE contracts.

Only three commits touching `linux/` follow yesterday's reviewed Linux pin `20ed72497`:

| Branch / commit | Disposition |
| --- | --- |
| Linux [#3438](https://github.com/TableProApp/TablePro/pull/3438), `2d7089204` | Highest-value new probe: active cell edit + focus move + close/quit/disconnect. Upstream removed its field during focus changes. BookiE keeps its text editor parented in a Stack, so the same unparenting cause is absent. Its pending edit is delivered through messages, so close ordering still needs installed GTK proof. Adapt tests first; do not copy their replacement GridCell. |
| Linux [#3437](https://github.com/TableProApp/TablePro/pull/3437), `0dc391484` | PPA/COPR distribution is a future packaging option. BookiE 0.2.0 still targets Arch/Hyprland. No release-channel expansion or distro-floor change from this review. |
| Linux [#3440](https://github.com/TableProApp/TablePro/pull/3440), `45d49a23f` | Review supply-chain policy separately. Upstream scopes a yanked zip exception; BookiE currently warns for all yanked crates and locks zip 8.6.0 plus 6.0.0. Inspect actual production/test/build use and current advisories before tightening policy or copying an exception. This review did not run a fresh advisory audit. |
| Earlier Linux [#3423](https://github.com/TableProApp/TablePro/pull/3423), `c423710ba` | Different cancellation implementation: BookiE uses `pg_cancel_backend`, not tokio-postgres cancel-query dispatch. Keep #983's stop-then-immediately-query regression; no transport patch inferred. |
| Earlier Linux [#3398](https://github.com/TableProApp/TablePro/pull/3398), `1155d3eb1` | Upstream's shared cancellation token/drop guard bug uses machinery BookiE does not have. Test cancellation ownership; do not port OwnedCalls. |
| Main [#3428](https://github.com/TableProApp/TablePro/pull/3428) | Investigate blank/NULL/default handling above. A typed clipboard flavor could preserve NULL, empty and embedded separators while retaining interoperable text. A public conversion-policy change needs B3 agreement. |
| Main [#3427](https://github.com/TableProApp/TablePro/pull/3427) | Zero dates, AUTO_INCREMENT 0, timezone and session restoration form a useful native dump/import matrix. BookiE already refuses implicit MySQL commits in guarded transactions (#986) and reports partially applied nontransactional batches (#990). Extend existing owners; do not claim general dump parity. |
| Main [#3436](https://github.com/TableProApp/TablePro/pull/3436) | Per-database workspace identity is a later UX candidate. Specify identity as connection + effective database, with session settings, temporary objects and draft ownership preserved; PostgreSQL schema is not a database. |
| Main [#3405](https://github.com/TableProApp/TablePro/pull/3405) | Check that Show/Copy DDL on supported views returns the actual view definition or a clear refusal, never synthesized CREATE TABLE. Include encrypted/restricted MSSQL definitions. Existing failures become one engine-specific issue after reproduction. |
| Main [#3387](https://github.com/TableProApp/TablePro/pull/3387) | Import/transfer must use the normal execution gate. BookiE already commits imports through PolicyGuard. Preserve denied/approved/audit tests for every import variant; no second gate. |

## 2026-10-16 follow-up source scan

This update checks current public branch/release metadata and selected merged PRs after the source pins above. It does not replace the pinned October 16 review or claim a complete branch diff. Current source heads checked: TablePro Linux `7cd300f82eaa4743d18ab049bf40a374d3ecf927`, TablePro main `bdbcb7de95a267aab261e258fc6d5c745261848f`, dbx main `cbdf5c9cdcb65eea14426534f13c741d239f45d4`, DBeaver devel `61c9529849c9fa500c303d1a385897a4088d6656`, Beekeeper master `f7ff968f39699c22d4f9a4674f38a5ecfbfbe586`, and BookiE linux `f2f9200b07d1e40aa6d1345135f589df73a9089c`. dbx's latest GitHub release was v0.6.46; DBeaver Community 26.2.2 and Beekeeper Studio 6.1.6 were their latest GitHub releases at check time.

### TablePro Linux and macOS main

- [Linux #3455](https://github.com/TableProApp/TablePro/pull/3455) replaces token-name guessing during SQLite column drops with a rebuild that restores dependent objects and lets SQLite validate the result. The lesson is to test both false matches and real dependency use, including a trigger that fails only when executed. BookiE's SQLite catalog uses SQLite's `sqlite_master` and table-valued PRAGMA queries; the specific `pragma_table_list` shadowing defect reviewed in DBeaver is not present in the same form. No BookiE defect is inferred without exercising its structure-save path.
- [Linux #3451](https://github.com/TableProApp/TablePro/pull/3451) hides host-key replacement when effective OpenSSH policy forbids replacing the key. BookiE already forces `StrictHostKeyChecking=ask` for its destination and has host-key outcomes in transport; verify prompt availability against user `ssh_config` before changing behavior. Do not infer equivalence from a config option name alone.
- [Linux #3449](https://github.com/TableProApp/TablePro/pull/3449) fixes a time-of-check gap between ClickHouse active-query and query-log observations. Bookie's ClickHouse cancellation tests exercise `system.processes`, but the reviewed code does not establish the same mutation-outcome resolver or server ordering guarantee. Carry the observation-order test pattern into a focused B4 review only if that resolver exists; no issue opened here.
- [Linux #3448](https://github.com/TableProApp/TablePro/pull/3448) connects an existing preference to the actual deletion action and covers a late asynchronous completion after a dialog closes. General lesson: test a preference by toggling it and invoking the described action, and cover completion after owner teardown. Bookie already tracks lifecycle and operation-path tests in #1029 and #1031.
- [Linux #3438](https://github.com/TableProApp/TablePro/pull/3438) identifies a GTK 4.22 focus traversal hang when an active cell editor is unparented, alongside loss of pending edits on close. Bookie uses a different widget structure, so the relevant transfer is the GTK installed scenario matrix, not the upstream widget fix. #1029 and active PR #1047 own Bookie's close/quit/disconnect tests.
- [main #3428](https://github.com/TableProApp/TablePro/pull/3428) preserves the distinction between empty text/binary and typed NULL across edit surfaces. Bookie has not adopted that rule; #1030 owns the blank-input contract and must verify stored values for nullable and non-nullable/defaulted columns before changing it.
- [main #3436](https://github.com/TableProApp/TablePro/pull/3436) gives each selected database its own tab workspace. Bookie's confirmed connection-only workspace key is tracked in #1054; this is a distinct identity question, and PostgreSQL schema must not be substituted for database identity.
- [main #3456](https://github.com/TableProApp/TablePro/pull/3456) fixes a theme list that could not scroll or receive keyboard focus in a grouped SwiftUI form. This is a usability test prompt only; reproduce the issue in GTK before adapting it.

### dbx, DBeaver and Beekeeper

| Merged source | Transferable lesson | Bookie disposition |
|---|---|---|
| [dbx #12435](https://github.com/t8y2/dbx/pull/12435), Redis visible-database metadata timeout | A connected socket does not mean every metadata command will return; put a deadline around each blocking database probe, not only connection setup. | Bookie's Redis connection currently uses a fixed database count and does not issue this picker probe. No port needed. Apply this rule if remote database discovery is added. |
| [dbx #12468](https://github.com/t8y2/dbx/pull/12468), Redis fuzzy-scan budget continuation | Carry one cumulative work budget across automatic and manual continuation; recomputing a per-page lower bound can defeat the intended total cap. | Bookie's SCAN path is offset-based browse pagination, not dbx's fuzzy key search. Do not treat this as a confirmed defect; consider aggregate scan work and cancellation if search is introduced. |
| [dbx #12434](https://github.com/t8y2/dbx/pull/12434), load-all after a page jump | State-machine tests must start from a noninitial page with unknown totals and prove continuation rearms after a reload. | Bookie streams only a forward PostgreSQL cursor and explicitly limits full result retention. Keep the scenario for any future load-all feature; do not add that feature by analogy. |
| [dbx #12420](https://github.com/t8y2/dbx/pull/12420), MySQL BLOB clipboard | Display decoding and clipboard conversion must share type-aware semantics across cell, row and bulk copy paths. | Bookie's value contract already centralizes native values; use #983 to verify decoded text-like blobs versus binary bytes across all copy/export consumers before changing behavior. |
| [dbx #12394](https://github.com/t8y2/dbx/pull/12394), mongosh numeric constructors | Accept only documented constructors and preserve BSON width; never evaluate shell text to parse a value. | Existing MongoDB parser and B3 integer-width tests own this area. Extend only for a reproduced constructor gap, retaining native BSON type checks. |
| [DBeaver #42376](https://github.com/dbeaver/dbeaver/pull/42376), SQLite PRAGMA shadowing | A temporary user object can shadow an unqualified metadata table-valued function. | Bookie's SQLite metadata uses `sqlite_master` and PRAGMAs; check any new table-valued PRAGMA query for schema qualification. The exact upstream query is not used here. |
| [DBeaver #42356](https://github.com/dbeaver/dbeaver/pull/42356), SQL line-comment scan | Test CRLF and bare-CR inputs explicitly, and keep lexing linear on long comments. | Bookie's lexer already uses one byte search for LF rather than repeatedly copying the remaining script. Add line-ending tests only for semantics supported by BookiE's dialects; no evidence justifies importing DBeaver's implementation. |
| [Beekeeper #4859](https://github.com/beekeeper-studio/beekeeper-studio/pull/4859), Home/End grid navigation | Keyboard navigation and viewport scrolling can disagree at boundaries. | GTK grid behavior needs an observable regression before adopting; this repository change alone does not establish the same problem. |

No dependency or driver addition follows from this scan. DBeaver JDBC and dbx internal crates do not satisfy Bookie's Rust traits, policy flow, or native GTK composition. Keep the existing official Rust driver stack; evaluate reusable crates individually for license, maintenance, runtime behavior and ADR 0007 value fidelity.

## Documentation update plan

Keep code docs on `linux` with the implementation they describe. Separate docs branches would weaken this coupling and make agent context less reliable. Use `docs/README.md` as the short entry point and dated archives for research.

| Order | Scope | Deliverable and check |
| --- | --- | --- |
| D1 | `ARCHITECTURE.md`, ADR 0011 implementation status, user guide, feature comparison | Correct streaming scope and four-page behavior, split TablePro from TablePlus, remove the #967 missing-feature claim. Update ADR status only; do not silently change its decision. Cross-check source selectors and #554. |
| D2 | Architecture diagram/ownership table, documentation map | Add the dump crate and link ADR 0019. State foundations merged, UI #1017 pending. Keep logical dumps, native snapshots and full-table result export distinct. |
| D3 | Backlog, known-issues index, Project #3 | Remove closed UI-39/#610 from open work; reconcile PEER-1 and earlier research outcomes. Review #894's remaining acceptance without closing it from a source-only fix. Preserve genuinely open release/installed gates. |
| D4 | `upstream-sync.md`, comparison, #983 | Link this dated review and maintain a small candidate table: existing coverage, open PR, needs reproduction, later or rejected. Attach the new close/NULL/view cases to existing owners before filing new work. |
| D5 | Validation playbook and `.github` follow-up | Preserve existing tiers. Consider a concise PR form requiring trigger, failing-before proof, exact head and unrun gates; add API-backed ledger-status reporting as a separate explicit network check, not to the offline format checker. Record baseline/head runtime versions for UI bugs. |

For each documentation slice: read latest merged source and issue state, edit only current owners, run `check-doc-links.py`, `check-known-issues.py`, and `inventory-ignored-tests.py --check`, and inspect the diff. Historical evidence remains unchanged. No feature/release claim should be promoted solely because a PR is open or one test passed.

## Recommended development sequence

1. Reconcile D1-D3 so another agent does not implement completed work. This does not alter the 0.2.0 blocker list.
2. Finish existing correctness PRs and #1016's session-recovery investigation before introducing competing stream/session changes. Maintainer handles Forgejo and merge per the current handoff.
3. Fix the guard blind spot in a small UX tooling PR with failing-first graph tests. Keep accepted workspace test exceptions explicit.
4. Run the active-edit close and NULL/default native reproductions. Coordinate B3/UX before modifying conversion behavior. Follow #893 for session lexical settings.
5. Profile stream retention and conversion allocations under #554. Only measured bottlenecks justify new budgets or architectural extraction.
6. Implement bounded NOTICE/PRINT under #550 when selected, then other UX candidates. Keep keyless editing, broad engine additions and packaging expansion outside this review's authorization.

All runtime checks above are proposed acceptance, not completed results. No new GitHub issues were opened, existing issue states were not changed, and no competing branch was modified during this review.
