# Upstream adoption through macOS 0.72

Historical matrix below. For later main-branch decisions and implemented fixes,
see the [September 14 Linux sprint](sprint-2026-09-14.md).
For the October 2 macOS main tip, see the
[October 3 applicability review](upstream-main-review-2026-10-03.md).

Reviewed: 2026-09-07. Linux baseline: `7d8288132` plus the stabilization changes described in the [historical sprint audit](stabilization-2026-09.md).

Reference is pinned to [v0.72.0](https://github.com/TableProApp/TablePro/releases/tag/v0.72.0), commit `6e6396c590bc1cc37f5e71e6d98d563dfcf8a2d6`. The [pinned README](https://github.com/TableProApp/TablePro/blob/6e6396c590bc1cc37f5e71e6d98d563dfcf8a2d6/README.md), release notes, and the prior 0.62–0.71 review form the whole-product inventory. This is a source/behavior review, not a macOS runtime test. Later `main` changes are excluded. This file records parity findings as of its review date; the active sprint owns current sequencing.

## Rules and status

Reimplement relevant behavior in Rust/GTK. Never merge Apple source trees. All database access keeps policy, approval, audit, bounded operations, and owning-connection identity. Drivers remain static; every shipped feature is free without entitlements. Database metadata is untrusted input. Unsupported capabilities and failed reads must be distinguishable.

**Implemented** means the Linux path exists; **partial** means only part exists; **missing** means no integrated path was found; **unverified** means evidence is insufficient; **intentionally excluded** is a product decision. None means release-approved. Evidence links below identify concrete Linux implementation boundaries.

## Whole-app matrix

| Capability | Linux status and evidence | Next action / acceptance |
|---|---|---|
| Connections, TLS, SSH | Implemented: [transport](../../crates/transport/src/lib.rs), [connection form](../../crates/app/src/ui/connect_dialog/mod.rs) | Keep TLS/SSH fixtures; client certificates and editable reusable SSH profiles remain partial |
| Multiple connections/windows | Implemented: [database service](../../crates/app/src/services/database_service.rs), GTK ownership scenarios | Preserve isolation when switching, reconnecting, exporting and approving |
| Groups, tags, favorites, search, URL import | Implemented: [organization](../../crates/storage/src/connection_organization.rs), [URL parsing](../../crates/storage/src/connection_url.rs) | Do not recreate old Phase 10.2 tasks; add corruption/save-failure coverage before expanding hierarchy |
| Workspace restore | Partial: [workspace state](../../crates/app/src/services/workspace_state.rs) | Last connection and per-connection tabs restore; prove restart with all referenced connections before marking complete |
| SQL authoring, completion, parameters | Implemented: [editor](../../crates/app/src/ui/editor/mod.rs), [completion](../../crates/app/src/ui/editor/completion.rs) | Preserve dialect-aware boundaries and bound parameters; extend PostgreSQL operators/functions after schema metadata |
| Multiple statement results | Implemented execution, partial UX: [outcomes](../../crates/app/src/ui/editor/outcomes.rs) | The run path already splits batches; do not reimplement Execute All as a new engine. Add explicit navigation/gutter actions and GTK multi-result proof |
| Folding, Vim, multi-cursor, split panes | Missing integrated workflows: editor and workspace UI | Separate GTK feasibility slices; do not assume toolkit support is an implemented feature |
| Grid editing, undo, sort, filter | Implemented: [browse](../../crates/app/src/ui/browse_tab/mod.rs), [change tracker](../../crates/app/src/services/change_tracker.rs) | Maintain stable row identity, exact numerics, generated-column refusal and no-PK write refusal |
| Deep pagination | Implemented: [browse query builder](../../crates/app/src/services/browse_query.rs) | Keep PK tie-breakers, keyset/offset equivalence and parameter ordering tests |
| Grid find, Jump to Column, browse history | Missing integrated workflows: browse UI | First ship column search over existing metadata; map to stable ordinal after hide/show; keyboard and wide-grid GTK tests |
| FK value selection | Partial: [FK header metadata](../../crates/app/src/ui/app/browse.rs) | Next: bounded, paginated reference lookup using owning connection; composite keys/nulls/read-only denial and cancelled requests need tests |
| Binary UTF-8 display | Implemented: [grid rendering](../../crates/app/src/ui/grid/column.rs) | Display only; preserve bytes in export and SQL literals |
| Structure columns/indexes/FKs | Implemented: [DDL helpers](../../crates/core/src/sql_ddl/), [structure tests](../../crates/release-tests/tests/structure_ddl.rs) | Keep separate transaction ownership; add check constraints and generated-expression metadata next |
| Views and schema object review | Partial: PostgreSQL views in sidebar and [controlled metadata](../../crates/core/src/connection.rs) | Add materialized views, routines, triggers, sequences, extensions, roles/grants as capability-declared reads before new object mutations |
| PostgreSQL user types | Missing: current [ColumnInfo](../../crates/core/src/query.rs) and connection traits have no type catalog | Add typed enum/composite/domain/range metadata; use same source for sidebar, structure choices and governed MCP `list_types`. Enum edits follow separately |
| Activity/locks | Partial: [activity dialog](../../crates/app/src/ui/activity_dialog.rs), [activity SQL](../../crates/core/src/activity.rs) | Existing dialog is not the planned typed operational console; add explicit capabilities and validated session actions |
| EXPLAIN and insights | Partial: [EXPLAIN dialog](../../crates/app/src/ui/explain_dialog.rs); no insights aggregation | First make a pinnable plan tree; later local history aggregation. Defer diagram and charts |
| Timing breakdown | Missing: [statement outcomes](../../crates/app/src/ui/editor/outcomes.rs) record elapsed time only | Add optional metrics with documented driver semantics. Never label elapsed time as server time or unavailable as zero |
| Query history | Implemented: [SQLite FTS store](../../crates/storage/src/query_history.rs) | Add retention, failure, and privacy tests; keep MCP history isolated |
| Export/import | Partial: [core CSV](../../crates/core/src/export/mod.rs), current-page GUI CSV/JSON | Build streaming, progress, cancellation and snapshot contract first; no full SQL dump is currently available |
| Advanced export options/formats | Missing integrated workflows | After foundation: object selection, per-table selection, conflict modes, file parts, NDJSON, bookmarks, import error report, then other formats/XLSX. Fixtures must prove quoting, ordering and partial outcomes |
| Cross-connection transfer | Missing | After object administration/export foundation; separate source/destination guards, bounded batches, destination approval, auditable partial completion |
| Engine-native backup/restore | Missing | Per-engine subprocess adapter with checked availability, safe argv, cancellation, output draining and destructive restore confirmation |
| Restore Previous Values | Missing | Local snapshot design first; every rewind remains a governed write; no paid gate |
| MCP and headless access | Implemented: [MCP](../../crates/mcp/src/tools.rs), [daemon](../../crates/agentd/src/lib.rs) | Extend domain metadata and GUI together; do not add agent-only bypasses |
| DuckDB local files | Implemented, optional: [driver](../../crates/drivers/duckdb/src/lib.rs) | CSV/TSV/JSON/Parquet paths now have tests and bundled extensions; optional CI covers the app build |
| Redis Sentinel/Cluster | Missing; current driver experimental | Keep separate from default-driver stabilization; topology and failover fixtures required |
| MongoDB depth | Partial: [driver](../../crates/drivers/mongodb/src/lib.rs) | Collection drop fixed; nested filters, binary UUID and MQL authoring remain separate driver slices |
| Entra authentication and Kerberos | Partial: Kerberos configuration exists; Entra missing | SQL Server auth fixtures before maturity upgrades; real KDC/SPN negotiation remains unverified |
| Additional engines | Missing or unverified beyond current static crates | Redshift/Cockroach compatibility must be tested, not inferred from PostgreSQL. Trino/Snowflake/BigQuery and other upstream engines wait for existing-driver release work. |
| Desktop automation | Partial: MCP and connection URL import | OS URL registration is distinct from importing a URL; specify Linux desktop behavior before adding it |
| AppleScript, iCloud, Apple UI/iOS | Intentionally excluded | Use Linux desktop integration; no Apple service imitation |
| Runtime plugins, built-in AI, entitlements | Intentionally excluded | Static driver crates, external governed agents, no license/account gates |

## 0.72 correctness review

The release's filter/type, stale catalog and transaction fixes have direct Linux analogues. This sprint adds PostgreSQL non-text pattern conversion, rejects invalid count filters, forwards daemon view metadata, rejects retired-connection sidebar results, and tests editor/structure transaction separation. DuckDB's bundled extensions remove a reproduced offline dependency.

Export-specific quoting, dependency cycles, duplicate FK declarations, destructive restore and partial-import reports are **not applicable to a nonexistent Linux bulk dump/restore path yet**. Carry them as acceptance tests for that future foundation. Existing Copy Row as INSERT remains a different workflow; do not remove identity values from it merely to imitate dump options.

The previous review already closed MongoDB collection drop, generated/identity edits and UTF-8 display. The SSH fixed-port race has no equivalent because Linux allocates fresh ephemeral ports. MongoDB method-named collections use native collection APIs; shell-filter count behavior still needs a dedicated driver fixture. Apple sync conflict/group-cycle fixes do not automatically apply to local sidecar storage, whose malformed-file behavior needs its own tests.

## Ordered implementation slices

1. Close stabilization findings and reconcile evidence. Then finish restart/session restoration and typed activity (Phase 10).
2. Small grid capabilities: Jump to Column, then FK selection. Each gets owning-tab tests and an installed GTK scenario.
3. Extend read-only schema catalog, including PostgreSQL types. Add driver trait capability, policy forwarding, GUI and MCP read contract in the same slice. Cache by connection identity and refresh after DDL.
4. Add optional query timing, then plan-tree/insights work; validate units and missing metrics per driver.
5. Complete object administration, then streaming export/import and snapshot semantics. Validate engine quoting, cyclic dependencies, progress and partial failure before advanced format options.
6. Cross-connection transfer and engine-native backup/restore become independent projects. New drivers follow existing-driver release evidence.

No feature in this list bypasses the safety layers. [Upstream sync](../upstream-sync.md) records actual behavioral ports; this matrix records gaps without implying they have shipped.
