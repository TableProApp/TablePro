# macOS main fixes: Linux applicability review

Reviewed on 2026-10-03. This is a source review and future-work handoff.
The original review changed documentation only. The later
[U1 implementation handoff](upstream-u1-sql-server-2026-10-03.md) records the
bounded SQL Server metadata fix and its native regression evidence separately.

The [older app-release follow-up](upstream-older-releases-review-2026-10-03.md) and [architecture consistency review](architecture-consistency-review-2026-10-03.md) extend this dated source review.

## Evidence and scope

- Upstream: [TableProApp/TablePro main](https://github.com/TableProApp/TablePro/commit/5c2df3b60cd40c25ba86c57e3d1c87499340cb3c),
  pinned at `5c2df3b60cd40c25ba86c57e3d1c87499340cb3c`, October 2.
- Fork: `cozyGarage/BookiE`, branch `linux`, reviewed at
  `7b08dd4786db22ac38bc341f29d0f350412af82d`. The worktree was clean.
- The GitHub API returned 370 reachable commits with committer dates from
  September 14 through the pinned tip. This is a dated window, not a verified
  ancestry range from the old September 14 review pin.
- Screened 257 fix/security/revert subjects. Read the changed-file lists and
  patches for 18 selected commits, then compared the relevant Rust paths.
  The [commit inventory](upstream-main-review-2026-10-03-inventory.md) records
  which commits received that deeper inspection. Subject screening alone is
  not a complete defect audit.
- Paths below are relative to `linux/`. A source gap is not a server or installed
  GTK reproduction. Existing test names describe checked-in coverage, not tests
  executed in this review.

Continue the [0.2 sprint](../bookie-0.2-sprint.md) and
[B4 board](../b4-task-board.md). These packets refine their correctness work;
they do not close B3/B4 or authorize a release. Read `CLAUDE.md` and the
[validation playbook](../validation-playbook.md) before implementation. Recheck
the current branch and task ownership before editing.

## Work packets

| ID | Priority / lane | Source conclusion | Next action |
| --- | --- | --- | --- |
| U1 | High / B3 metadata and writes | Metadata fix and two INSERT consumers have native regression evidence | Finish GTK/other consumer and ledger acceptance in the [handoff](upstream-u1-sql-server-2026-10-03.md) |
| U2 | High / B3 Copy as SQL | Literal INSERT keeps identity values without an engine-specific identity policy | Define safe default copying and explicit identity preservation |
| U3 | Medium / editor correctness | Autocomplete drops schema identity and folds case in cache keys | Preserve resolved connection/schema/table identity |
| U4 | Medium / B4 reconnect | Every reconnect error becomes a string and retries indefinitely | Separate retryable failures from permanent TLS/auth/config failures |
| U5 | Medium / B4 TLS contract | Core supports client cert/key, but saved connection assembly only carries the CA | Decide and implement the supported client-certificate configuration contract |
| U6 | Medium / B3 MongoDB | Sample metadata and fetched-page type merging do not prove collection-wide export coverage | Verify late fields across export boundaries before adding a census |

### U1: SQL Server columns owned by the server

Reference: [#3231](https://github.com/TableProApp/TablePro/commit/ff80b43a9d).
Its SQL Server catalog patch recognizes `timestamp`/rowversion and generated
always period/ledger columns as server-owned, in addition to computed columns.

At the original review baseline, Linux `crates/drivers/mssql/src/lib.rs::fetch_columns` selected `c.is_computed`;
`parse_column_row` mapped only that flag to `ColumnInfo.is_generated`.
The grid and INSERT builders already trust `is_generated`, so incomplete
metadata can offer edits or emit INSERT values the server refuses.

Implement a version-compatible catalog predicate for all supported server-owned
columns. Keep bound schema/table values and joins by object ID; the upstream
OBJECT_ID quoting repair is not needed for this query. Trace grid UPDATE,
inline insert, duplicate row, CSV import, Copy as SQL and SQL file export.
Do not assume one corrected consumer covers every entry point.

Acceptance: native SQL Server fixtures for ordinary, computed, rowversion and
supported temporal columns; assert metadata, refused editing, and generated
SQL. Use dotted/quoted names too. Ordinary writable columns must still work.
Record unsupported server versions or unavailable ledger fixtures explicitly.

### U2: identity values in copied INSERT statements

Reference: [#3231](https://github.com/TableProApp/TablePro/commit/ff80b43a9d).
Upstream separates ordinary copying from explicit identity insertion.

`crates/core/src/sql_literal.rs::build_insert_literal` skips generated columns
but keeps all auto-increment values. Its documentation claims every supported
engine accepts explicit values. SQL Server IDENTITY and PostgreSQL GENERATED
ALWAYS identity need additional SQL or omission. `build_insert_from_draft` in
`sql_dialect.rs` already skips auto-increment columns; preserve that distinction.

Choose an engine-aware default for Copy as SQL and SQL export. Explicit identity
preservation needs an intentional mode and enough metadata to distinguish
ALWAYS from BY DEFAULT; the current boolean does not express that distinction.
Do not change MySQL key preservation incidentally or classify every identity
column as a computed column.

Acceptance: execute produced SQL against SQL Server and PostgreSQL ALWAYS/BY
DEFAULT fixtures, with generated columns and an all-default row. Cover clipboard,
file export and ordinary duplicate/insert consumers. Assert policy/audit routing
for any executable identity-control statements. Keep U1 and U2 as separate fixes.

### U3: qualified autocomplete identity

References: [#3094](https://github.com/TableProApp/TablePro/commit/e031ba6e81)
and [#3070](https://github.com/TableProApp/TablePro/commit/5cff78b343).
The #3094 patch was inspected; #3070 is a subject-screened supporting reference.

Linux already rejects old-generation fetch replies through
`SchemaRequest`, `SchemaIndex::accepts` and `app/schema_index.rs`.
Keep those guards. The remaining source defect is `editor/completion.rs::table_key`:
it discards the schema and lowercases every table name. Cache entries and
`requested_columns` therefore conflate `a.items` with `b.items` and can conflate
case-sensitive quoted PostgreSQL names. `bare_table_names` also offers every
schema's unqualified table name. `split_table_reference` strips quoting before
splitting on a period, which mishandles a period inside a quoted identifier.

Use resolved structured identity and the engine's identifier rules across cache,
deduplication, metadata fetch and candidates. Resolve unqualified names against
the actual database/schema context. Avoid another ad hoc quote stripper.

Acceptance: two schemas with same-name tables and disjoint columns, quoted names
containing periods, quoted case distinctions, a delayed reply across refresh and
connection replacement, and a failed request followed by retry. Assert the actual
consumer sees the right candidates as well as testing key helpers.

### U4: stop futile reconnects without losing recoverable failures

Reference: [#3170](https://github.com/TableProApp/TablePro/commit/4694caf9ba).
The upstream patch introduces a terminal connection failure state.

`app/services/connection_monitor.rs::reconnect_loop` retries every `Err(String)`
with capped backoff. `try_reconnect` calls `connection_service::establish`, so
typed failure information is lost before the retry decision. The same monitor
logs raw errors with `%e`; review that against the repository redaction rule.

Coordinate with B4 F4/F9 and existing fault-notification regressions. Preserve
retry for transient disconnects. Surface terminal certificate, hostname,
credential and configuration failures without repeatedly opening tunnels.
Do not weaken verification, retry an uncertain write, or revive a retired editor
session. Keep diagnostics free of passwords, SQL and connection-string secrets.

Acceptance: a permanent TLS failure stops attempts and exposes a recoverable UI
action; a transient disconnect retries successfully; cancellation stops backoff;
connection replacement reattaches fault notification. Use typed mock failures
and the TLS fixture tier for the verification boundary.

### U5: client certificates and SSH

Reference: [#3198](https://github.com/TableProApp/TablePro/commit/8f8e270c59).
Upstream stopped erasing client certificate/key paths when opening a tunnel.
Its remaining verification downgrade must not be copied into Linux.

Linux `core/src/tls.rs::TlsConfig` has client certificate/key fields. However,
`transport/src/lib.rs::options_from_saved` sets only mode and root CA, with
the client fields defaulting empty; saved connection configuration has no matching
client paths. This is a configuration/integration gap, not evidence that Linux's
tunnel rewrite erases supplied client credentials. Linux already preserves the
service identity separately from the local dial endpoint.

First decide which drivers and saved/UI/daemon paths support mutual TLS. For
supported paths carry both files through configuration, transport and reconnect,
and account for rotated material in `transport/session_material.rs`. Refuse
missing/mismatched material clearly. Avoid advertising support for drivers that
ignore these fields. This packet expands configuration and must be scoped through
the B4 board before implementation.

Acceptance: private-CA server requiring a client certificate, direct and SSH
routes, wrong/missing client material, wrong server hostname and rotated files.
Test GUI and daemon assembly; transport unit preservation alone is insufficient.

### U6: MongoDB late fields and export scope

Continuation at `aeac107a4`: `fetch_columns` now scans the collection and
marks conflicting kinds `mixed`; native driver/app cases cover the named late
Decimal128 fixture. The sample-only description below is the original review
baseline. Whole-export scope, census cost and concurrent writes remain open in
[the B3 board](../type-contract-strategy.md), not a request to add another census.

Reference: [#3213](https://github.com/TableProApp/TablePro/commit/0ff3508258).
Upstream builds its export header from a census of the selected source rather
than a small initial document sample. [#3194](https://github.com/TableProApp/TablePro/commit/3767a03396)
applies the same principle to JSON import; Linux currently imports CSV only.

Linux `drivers/mongodb/src/lib.rs::fetch_columns` samples `SAMPLE_DOCS`.
`fetch_rows` and query handling merge types from their fetched documents, so
the upstream loss is not demonstrated on a loaded page. The existing B3 review
already leaves whole-collection discovery open. Reuse that task instead of
claiming this review discovered confirmed dropped export values.

Acceptance first: fields appearing only after the sample and after a page
boundary, mixed BSON kinds, missing versus NULL, nested/specially named fields,
and a filtered/limited export. Compare native documents with exported rows and
headers. If a broader export is added, keep census scope equal to export scope,
bound time/memory, retain canonical BSON values and refuse writing aggregation
stages through a read-only metadata path.

## Existing protection and reproduction-only candidates

| Upstream reference | Current Linux evidence | Disposition |
| --- | --- | --- |
| [#3184](https://github.com/TableProApp/TablePro/commit/8b6f38d428), state-changing functions | `policy/src/classify.rs` recognizes nextval/setval, advisory locks and pg_terminate_backend; classifier/rule regressions exist | Retain; no duplicate port |
| [#3176](https://github.com/TableProApp/TablePro/commit/7c6154101c), Explain authorization | `classify_explain` preserves executing inner writes and distinguishes ANALYZE false/off/0; bridge uses policy | Retain; trace every new Explain route through PolicyGuard |
| [#3110](https://github.com/TableProApp/TablePro/commit/c429891ac5), semicolon-free T-SQL | Linux parses the whole input and aggregates statements; parse errors fail closed | Verification packet: native `SELECT 1` followed by UPDATE/DROP, bracketed names, Unicode separators, IF/EXEC and GO across GUI/MCP/session; assert no hidden read-only write before adding scanner logic |
| [#3115](https://github.com/TableProApp/TablePro/commit/ea0caa3b66), MERGE terminator | MsSql uses GoBatch; planner retains semicolons in batch text | Add focused server reproduction for MERGE alone, final batch and cursor execution before changing planner ranges |
| [#3223](https://github.com/TableProApp/TablePro/commit/4a961aebc9), ClickHouse cancellation | Driver creates per-operation query IDs and uses run_server_cancellable with request_cancellation | Retain; delayed cancel for run A must not cancel run B, and timeout must stop server work; overlap with B4 Stop/timeout acceptance |
| [#3228](https://github.com/TableProApp/TablePro/commit/32028b7b6b), MCP schemas and typed export | Rust export_data uses core Value/CSV/JSON conversions; server does not publish the same Swift outputSchema | No direct schema port; preserve existing B3 consumer contracts for numbers, binary and NULL |
| [#3199](https://github.com/TableProApp/TablePro/commit/b78af539a9), PostgreSQL 18 VIRTUAL DDL | Metadata uses attgenerated <> '', so virtual columns are recognized; ColumnInfo has only a generated boolean | Verification/design gap for expression and STORED/VIRTUAL preservation in any future DDL reconstruction; do not claim current full table-copy support |
| [#3155](https://github.com/TableProApp/TablePro/commit/b2c74530d7), reuse deleted index names | Rust structure editing uses snapshot diff/materialize_ops, not Swift's operation-history validator | Reproduce drop/recreate same-name index and constraint, check order and one approval; source architecture alone proves neither a defect nor immunity |
| [filter deletion](https://github.com/TableProApp/TablePro/commit/018ed2e076) and [#3196](https://github.com/TableProApp/TablePro/commit/13e6850cf1), DDL settings adoption | Linux persists workspace browse/filter state with its own writer and catalog refresh paths | Verify clear then immediate reopen/restart, and SQL drop/recreate/rename in another tab; inspect only committed successful DDL before migrating settings |
| [#3245](https://github.com/TableProApp/TablePro/commit/5c2df3b60c), Find/Replace matches | No SQL editor Find/Replace controller or SearchContext was found in this tree | Future feature acceptance: update count/highlights after Replace, Replace All and undo; no Swift implementation to port now |

## Exclusions and review limits

SwiftUI/AppKit layout, VoiceOver, macOS 13 support, iCloud/team libraries, iOS,
Sparkle, AppleScript, AI providers and plugin release/ABI repairs have no direct
code port here. GTK accessibility and native desktop acceptance keep their own
requirements. Oracle and engines absent from the static Linux driver registry
are outside this review's implementation scope. JSON/JSONL import, whole-database
restore, Compare & Sync and Rewind fixes are references for future features,
not reasons to add those products in this task.

Some excluded paths still reveal reusable risks, such as committing truncated
display text or logging secrets. Keep the Linux full-value editing regressions
and redaction rules. A subject marked screened in the inventory remains a
possible deeper-review target; it is not asserted fixed or inapplicable.

For each packet, first reproduce on the current tip, add a regression that fails
without the fix, implement Rust/GTK behavior, and record the exact SHA, commands,
reports and remaining acceptance. Use the lowest reproducing tier, then the
affected shared validation layers. Keep local, hosted, real-engine and installed
desktop evidence distinct. Never merge or cherry-pick the Apple source tree.
