# TablePro adoption and collaboration review, October 21

Completed source review; implementation proposals are not completed work. This extends the [October 20 analysis](upstream-main-analysis-2026-10-20.md), its [follow-up](upstream-next-slices-2026-10-20.md) and the [deep feature review](tablepro-dbx-review-2026-10-20/README.md). Current order belongs to the [backlog](../backlog.md).

## Scope and recommendation

External implementations are evaluated against BookiE's product goals, accepted decisions and demonstrated user needs. Upstream compatibility is not an acceptance criterion by itself. Select Rust/Linux changes only when they improve an identified behavior, and record provenance for reused code or fixtures. Maintain separate application composition, policy enforcement and durable identities. A whole-tree merge would cross incompatible crate paths, runtime ownership, driver contracts and product decisions.

Pinned upstream: [`9541927e2d8336ef425c7005ba2254982e423b8f`](https://github.com/TableProApp/TablePro/tree/9541927e2d8336ef425c7005ba2254982e423b8f), October 21. BookiE: `be3ce4099`. The comparison starts at the previous review's `c584da5a763014e154b7386dbe7e3ec9811a53d4`. It has 45 commits, eight touching Linux. All subjects were screened; selected source, tests and PR bodies were inspected. The [evidence inventory](../evidence/tablepro-collaboration-2026-10-21/README.md) preserves each commit and the reviewed paths.

No upstream build scripts were executed. No builds, database experiments or GTK acceptance runs back this review. Performance numbers and upstream test results below are attributed reports. Candidate defects need a failing BookiE regression before implementation. Open PRs are not shipped main-branch behavior.

## Implementation follow-up, October 21

The source review above remains pinned to its recorded commits. Subsequent BookiE work:

- Fixed column sizing is complete in [PR #1267](https://github.com/cozyGarage/BookiE/pull/1267), merged as `fc66c589e59aa0f944b604455683b03cd7f1e3b6`. [Issue #1266](https://github.com/cozyGarage/BookiE/issues/1266) is closed. Three rendered-width regressions failed against the original implementation and passed with the fix. Local checks, all 81 isolated GTK widget cases, GitHub checks and Forgejo run #835 passed. The [implementation evidence](../evidence/grid-fixed-width-2026-10-21/README.md) records scope and limitations.
- Large-catalog work remains open under [#580](https://github.com/cozyGarage/BookiE/issues/580). Source verification found an existing schema filter and persisted hidden-schema settings; the remaining proposal concerns measured responsiveness and driver scoping. The [issue follow-up](https://github.com/cozyGarage/BookiE/issues/580#issuecomment-6315099855) records that distinction. No latency or allocation baseline has been established. Coordinate completion changes with open PR #1236.
- Copy/paste fidelity is already owned by PR #1206. A [parser review](../evidence/clipboard-marker-review-2026-10-21/README.md) reproduced two external-text regressions in its proposed marker decoding. Both cases pass on current linux. Clipboard provenance and actual copy/paste regression coverage are required before that fix can establish value preservation.
- SQL-export source review found an intentional boundary: `sql_export_uses_engine_generated_identity_values` pins fresh PostgreSQL/SQL Server identity values rather than exact key restoration. The writer does not restore sequence state or remap related foreign keys. This is not a newly reproduced defect in PR #1239. The user guide now distinguishes row export from database backup and corrects stale CSV mapping guidance against the current import adapter. Native restore fidelity still needs its own regression evidence.
- PostgreSQL round-trip fixtures, SSH authentication scenarios and Vietnamese translation adoption remain proposals. Existing export/import PRs retain ownership of their overlapping changes. No upstream contribution has been submitted.

## Architecture comparison and adaptation costs

| Concern | Upstream at the pin | BookiE | Consequence |
|---|---|---|---|
| Native Linux UI | GTK4, libadwaita, GtkSourceView and Relm4 | Same stack | Reuse GTK techniques and focused tests; adapt component ownership. |
| Domain and static drivers | `linux/crates/core`; registered driver crates | Root `crates/core`, eight drivers | Related design; types and APIs have diverged. Match behavior before adapting code. |
| Runtime and connection orchestration | `session` owns connect, runtime, liveness and operation runner; `net` owns transport/TLS | `app-services`, `transport`, `policy`, `ssh` | Translate responsibilities instead of recreating their crate layout. |
| PostgreSQL | tokio-postgres/deadpool, separate wire codecs; unnamed execution described for pooler compatibility | Patched SQLx; explicit sessions and native values | Share SQL oracles, fixture inputs and lifecycle cases. Driver implementation is not a direct replacement. |
| Safety | Linux Safe Mode plus read-only connection behavior | Shared PolicyGuard for GUI, MCP and agentd | Adapt confirmation UX into the existing policy seam. Do not add an independent editor permission engine. |
| UI scheduling | Sidebar and completion work runs off GTK; lazy GListModel adapters | GTK-free logic exists, but sidebar uses ListBox and completion eagerly creates proposals | A targeted performance adoption is valuable. Broad service extraction is not the first prerequisite. |
| Apple clients | Separate Swift packages and driver plugins | Linux-only source and static Rust drivers | Translate test scenarios and behavior. Keep Apple implementation outside the product tree. |

Sources: pinned [Linux architecture](https://github.com/TableProApp/TablePro/blob/9541927e2d8336ef425c7005ba2254982e423b8f/linux/ARCHITECTURE.md), [PostgreSQL driver](https://github.com/TableProApp/TablePro/blob/9541927e2d8336ef425c7005ba2254982e423b8f/linux/crates/drivers/postgres/src/lib.rs), and BookiE [architecture](../../ARCHITECTURE.md).

## Ranked adoption candidates

### 1. PostgreSQL export/import regression cases, before more export features

Priority P1 for data fidelity; B3 with UX/B4 review where import and audit are involved. Confidence high that the test model is useful; no newly reproduced BookiE failure.

Merged Apple [#3707](https://github.com/TableProApp/TablePro/pull/3707) exercises actual exporters and importers, including compressed SQL and multipart restore. Merged [#3710](https://github.com/TableProApp/TablePro/pull/3710) has a machine-readable corpus per engine and checks that every advertised column type has a scenario. Its runner reads through browse and export paths, edits, reads again and replays SQL export. A test that only compares generated SQL text cannot establish those outcomes.

Open Linux [#3714](https://github.com/TableProApp/TablePro/pull/3714) is the best immediate collaboration target. Its proposed shared suite compares CSV writer/reader settings and SQL INSERT restore. The author reports fixes for PostgreSQL BC/far dates, SQL Server high-scale decimal parameters, SQLite temporal forms and ClickHouse compound literals. These are branch claims until merged and independently checked. The PR explicitly excludes some format/default combinations from lossless claims.

BookiE already has `tests/data/value-contract.json`, PostgreSQL wire/date/array/identity fixtures and export tests. Extend those owners instead of introducing another whole corpus framework. Add a matrix that carries each PostgreSQL value through browse, edited save, CSV import and SQL restore. Compare typed value and stored state, not only display strings. Distinguish exact restore from spreadsheet-safe export, and keep literal NULL-marker text separate from SQL NULL. Do not copy a transformed expected result and call it exact preservation.

Acceptance: existing PostgreSQL driver tier for storage/binding behavior; existing release tier for complete export/import composition; GTK only for the UI paths the lower layers cannot prove. Reuse [#1184](https://github.com/cozyGarage/BookiE/issues/1184), [#1030](https://github.com/cozyGarage/BookiE/issues/1030) and existing B3 value work where they cover the case. Open BookiE #1239 and #1215/#1216 already touch export/import behavior; coordinate landing order before editing them.

### 2. Large-catalog responsiveness with lazy sidebar and completion rows

Priority P2, UX; high-confidence source gap, unmeasured local impact. Existing owners: [#580](https://github.com/cozyGarage/BookiE/issues/580) and [ADR 0012](../decisions/README.md).

Merged [#3729](https://github.com/TableProApp/TablePro/pull/3729), followed by [#3747](https://github.com/TableProApp/TablePro/pull/3747), changes both data preparation and GTK object creation. The sidebar builds collation/search keys off the main thread, filters an index, and creates row objects only when requested by a custom GListModel/SectionModel. Completion ranks candidates off GTK and creates proposals lazily. A generation check rejects a ranking or search result overtaken by a later request.

A subtle GTK lesson: replacing a selected model's contents in one remove-and-add notification can make GTK scan every newly inserted row to recover its tracked objects. Upstream deselects and sends removal then insertion. This preserves lazy allocation at replacement, not just at initial loading. Its tests assert the number of row objects constructed, which gives deterministic evidence beyond timing.

BookiE `sidebar_row.rs` still uses ListBox. `completion_provider.rs::model` reads the buffer, computes candidates and builds a Proposal object for every match on the GTK path; `populate_future` computes that model before returning its ready future. An async signature alone does not move this work off the main loop. Current generation checks protect correctness and must survive a performance change.

Recommended slice: first a synthetic large-catalog fixture that measures event-loop stall and counts constructed proposals; then off-thread headless candidate work with request identity; then lazy GTK proposals. Treat sidebar migration separately. Upstream uses flat schema sections; BookiE's accepted tree-model ADR requires a design reconciliation before copying that model literally. Measure BookiE's scope rather than claiming its architectural target is already implemented.

The upstream fixture uses PostgreSQL with 100 schemas of 500 tables and MySQL with 50,000 tables. It separately bounds total step latency, longest main-loop stall and resident-memory growth. The PR reports up to 53 ms stalls after its change, but MySQL completion can still take seconds off GTK. Responsiveness and total latency are separate acceptance criteria. Reuse existing tiers and calibrate budgets on BookiE's runner hardware; no extra parallel gate is proposed.

### 3. Fixed column widths that stay fixed

Priority P2, UX; high source confidence, rendered failure not reproduced.

Merged [#3702](https://github.com/TableProApp/TablePro/pull/3702) sets `expand(false)` when a saved width exists and after a user resize; clearing fixed width restores expansion and forgets the saved override. In BookiE `apps/linux/app/src/ui/grid/column.rs`, the builder always enables expansion, restoring a width does not disable it, and the notify handler persists positive widths without changing expansion.

Candidate regression: show two columns, resize one, enlarge the window and reload the table. Its allocated width should follow the intended manual-width contract; clearing the override should return it to automatic sizing. Assert rendered width after layout rather than only the fixed-width property. Keep minimum widths for unsized columns separate. This is a focused source adaptation candidate, subject to a failing gtk-widgets regression and the current width-store API.

### 4. SSH agent/key-file matrix and safer error messages

Priority P2, B4; compatibility lead, no confirmed BookiE defect.

Merged [#3720](https://github.com/TableProApp/TablePro/pull/3720) supersedes upstream ADR 0019 with 0020. Always forcing IdentitiesOnly for a selected key file broke agent-held certificates and encrypted PEM keys lacking a readable public half. The revised implementation fingerprints the file, asks the configured agent and pins only where needed, with bounded helper subprocesses. Tests include decoy keys beyond MaxAuthTries, certificate-only server trust, encrypted keys and key-exchange failures.

BookiE's system OpenSSH `argv.rs` currently adds `-i` for a key path and does not force IdentitiesOnly. Therefore importing the conditional pinning logic without the original need can introduce unnecessary subprocesses and failure modes. First adapt the test scenarios to BookiE's applicable system/OpenSSH and built-in routes, then change only a demonstrated failing route. Preserve per-hop authentication: options for the destination are not automatically the right options for every jump host.

The same upstream range adds typed SSH algorithm/runtime-directory failures and distinct TLS remedies. BookiE [#1174](https://github.com/cozyGarage/BookiE/issues/1174) and open PR #1226 already own the broad TLS downgrade advice; do not duplicate them. Check error redaction before reusing library diagnostic text.

### 5. Vietnamese catalogue and translation packaging tests

Priority P3, UX; direct source adaptation opportunity with review.

Merged [#3727](https://github.com/TableProApp/TablePro/pull/3727) ships `linux/po/vi.po`, publishes a template artifact and checks catalogue placeholders and package installation. BookiE currently has a template and LINGUAS but no locale catalogue in `apps/linux/po` at this pin.

Reuse matching translated msgids with attribution, merge against BookiE's own POT and review branding, policy terminology and placeholders. BookiE uses `tr!` extraction; the referenced implementation extracts gettext wrapper calls. Do not replace BookiE's extraction pipeline just to import one language. Package smoke acceptance should exercise an actual generated locale; C/C.UTF-8 is insufficient to establish translated output. Translation corrections can be contributed to each application's catalogue where the source strings and terminology match.

## PostgreSQL ideas from Apple, adapted as behavior

| Idea and source | What to learn | BookiE adoption boundary |
|---|---|---|
| [CTE/ORDER BY completion, #3713](https://github.com/TableProApp/TablePro/pull/3713) | MATERIALIZED/NOT MATERIALIZED, data-modifying CTE RETURNING, VALUES/TABLE bodies, explicit column-list renaming, nested WITH scope, LATERAL and target-table inference | Feed a neutral SQL/catalog/expected-proposals matrix into existing app-services completion tests. Parse with the current session's lexical settings. Open #1236 already touches that boundary. Do not port Swift parser implementation. |
| [pgvector display, #3725](https://github.com/TableProApp/TablePro/pull/3725) | Discover dynamic OIDs, arrays and dimensions; keep vector, halfvec and sparsevec distinct | Existing [#902](https://github.com/cozyGarage/BookiE/issues/902) and `vector_contract.rs` own extension qualification. The upstream probe checks base type and name; that alone does not prove extension ownership. Do not treat an arbitrary user base type named vector as pgvector. Preserve raw/native values through rich display. |
| [Temporary tables, #3746](https://github.com/TableProApp/TablePro/pull/3746) | Objects created by an editor session need discovery through that owning session | A global pool cannot discover another backend's temp schema reliably. Key any UI model by session identity and generation; never display stale objects after reconnect. Candidate feature, not a claim that BookiE supports it. |
| [PostgreSQL socket connection, #3721](https://github.com/TableProApp/TablePro/pull/3721) | Local-socket workflow and transport-specific validation | BookiE's PostgreSQL driver already supports socket directories. URL import work is in open #1231. Test user entry and import routes before claiming a driver gap. |
| [Policy matrix, #3704](https://github.com/TableProApp/TablePro/pull/3704) | Every write/query-capable tool has a row; denied outcomes assert zero driver calls; prompt refusal is tested | Adapt registry-completeness assertions into current MCP/policy tests. Linux Safe Mode and Apple's six-level policy matrix are different source surfaces. Retain BookiE's scopes, allowlists, audit and masking contracts. |
| [Sequences, open #3722](https://github.com/TableProApp/TablePro/pull/3722); [types, open #3736](https://github.com/TableProApp/TablePro/pull/3736) | Review their future metadata and mutation tests after merge | Later PostgreSQL-first feature candidates. Generated DDL must use PolicyGuard; preview, unsupported metadata and cancellation outcomes need explicit acceptance. |

## Existing coverage and deliberate differences

- The TLS dependency update in [#3724](https://github.com/TableProApp/TablePro/pull/3724) names rustls-webpki 0.103.16 and webpki-roots 1.0.10. BookiE already has those exact locked versions via #1204. No duplicate dependency bump is needed; this is not a full advisory scan.
- BookiE already has Unix-socket connection handling, headless services, architecture checks, driver conformance cases, query cancellation, export tests and typed values. Add missing cases to these systems.
- Do not import Linux Safe Mode's second statement classifier into core as a replacement for `tablepro-policy`. Shared lexical facts can inform the existing classifier, but one authorization path must remain authoritative.
- Do not copy paid Starter/Team feature gates, Apple Intelligence, Swift plugin ABI or platform UI into the Linux product. Upstream main contains multiple product directions; a newer commit is not automatically useful scope.
- The upstream PostgreSQL client-library choice does not justify removing BookiE's SQLx patches. The [patch removal rule](../proposals/upstream-patches.md) requires a released replacement and equivalent contract evidence.
- The fetched BookiE `origin/main` mirror is `a420dda83ab9890a3f1404d7b79eb126aae3084a` at this review, behind the pinned upstream. Updating that mirror and adapting code to `linux` are distinct actions. This review changes neither mirror history nor product code.

## Concrete collaboration plan

Start with one bounded test contribution and its equivalent BookiE fixture. Upstream [contributor instructions](https://github.com/TableProApp/TablePro/blob/9541927e2d8336ef425c7005ba2254982e423b8f/CONTRIBUTING.md) target main; Linux build/test commands live under linux and use Meson's environment. A BookiE branch is not an upstream-ready PR.

| Proposed contribution | What BookiE can supply | Where it should land | Condition before sending |
|---|---|---|---|
| PostgreSQL export/import edge fixtures | Exact SQL inputs for quoted NULL arrays, BC/far dates, negative zero, identity and sequence state; typed assertions | Collaborate with open #3714 or follow after it merges; adapt a narrow equivalent into BookiE's current driver/release tier | Compare the current upstream corpus first; contribute a missing failing case, not duplicate coverage or an entire harness. |
| Pooler/cancel/session scenario | Existing PostgreSQL qualification inputs and observer assertions from completed UP-2/UP-4 | Upstream PostgreSQL/session conformance suite | Trace the same failure in the target client implementation; preserve cancellation versus unknown-write outcomes. |
| Boundary guard | Small negative test proving a forbidden crate edge/test hook is rejected | Upstream Linux CI harness | Architecture docs say edges are review-enforced; check current main and open work before implementing a mechanical guard. Keep their allowed net/driver edges. |
| GTK lifecycle or stale-result regression | Deterministic out-of-order completion/search case; close while operation is in flight | Upstream existing GTK tests and BookiE gtk-widgets | Verify it adds coverage beyond the existing generation and lazy-allocation tests. No wall-clock-only flaky repro. |
| Vietnamese terminology and placeholders | Language review and shared correction where msgids match | Separate small locale PR per app | Review the rendered UI and translator placeholders. Preserve project-owned branding. |

Suggested contribution sequence:

1. Refresh upstream and the existing PR before each packet. Record exact source commit, local mapping, owner and acceptance in the BookiE issue. Reuse #1149's completed work as evidence; do not reopen its nine closed packets.
2. Implement the minimal regression in the repository that owns the bug. If the behavior differs intentionally, share the scenario rather than changing the other project's rule.
3. For reused Rust code, preserve relevant author notices and record source commit/path and adaptation. For fixtures, record provenance and differences in expected outcomes. Both repositories carry AGPLv3 licenses and upstream explicitly licenses contributions under AGPLv3; check notices for each copied file/dependency under BookiE's existing policy.
4. Submit upstream PRs from a clean branch based on upstream main, changing linux paths. Keep BookiE's branding, private lab configuration and BookiE-only policy code out of that diff. Cross-link the corresponding BookiE work after there is a concrete reviewable contribution.
5. Validate each repository with its own existing workflow. BookiE code still uses the serialized Forgejo gate. A green upstream run is evidence for its tree, not acceptance of BookiE's adaptation.

No upstream PR or message was sent in this review. The next implementation recommendation is one missing PostgreSQL round-trip fixture, then the narrow column-width behavior, then measured large-catalog work. Security and existing failing gates retain priority over these feature candidates.
