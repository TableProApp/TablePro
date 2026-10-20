# D. dbx feature and architecture review against BookiE

Source pin: BookiE `linux` 7c4cb3929 (2026-10-20). dbx `main` d1e88ab4b5b196d8b920b56ee8bc1735dcdc6269 (2026-10-19). Source read only. No dbx script, build or test was run. No BookiE code was changed. dbx paths are relative to the dbx repo root. BookiE paths are relative to the repository root.

Already recorded, not repeated here: dependency guard (#887/#891), nextest (#892), lexical settings (#893), Mongo metadata budget (#894), MCP wide integers (#895), MCP outcomes (#896), MCP annotations (#897), bounded NOTICE buffer (#550), trigger toggle candidate, PEER-2 dialect lexer profile, PEER-3 Redis command table, ProxyCommand boundary (#970 note), dialect type completion, ER diagram and compare as unselected candidates. See `docs/archive/2026-10-15-dbx-review.md`, `linux-peer-review-2026-10-16.md`, `-10-17.md`, `code-and-ui-audit-2026-10-18.md` and `docs/0.2-feature-comparison.md`.

Key: Have = BookiE already has it. Adopt = take the idea close to as is. Adapt = take the idea, change the shape. Skip = out of scope or not worth it. Effort S < 3 days, M 1 to 2 weeks, L more.

## 1. Feature table

### Connections

| Area | dbx feature + source path | BookiE status + path | Decision | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| URL import | About 40 schemes incl. `mongodb+srv`, `rediss`, `jdbc:` forms. `apps/desktop/src/lib/connection/connectionUrl.ts`, redaction in `connectionStringRedaction.ts` | Partial. 9 schemes, no `mongodb+srv`, `rediss`, socket or `duckdb`/`sqlite` file URLs. `crates/storage/src/connection_url.rs:20` | Adapt | UX | S | P2. `mongodb+srv` and `rediss` are common paste inputs. Socket form already tracked in #579 |
| Import from other clients | Navicat, DBeaver (decrypts `credentials-config`), DataGrip. `apps/desktop/src/lib/imports/` | Absent. Bundles import only BookiE bundles. `crates/storage/src/connection_bundle.rs` | Adapt (DBeaver, DataGrip XML only, no secret decryption) | UX | M | P2. Biggest onboarding friction for switchers. Skip decrypting other apps' secrets |
| Groups, tags, colors | Nested sidebar groups, color, note. `types/database.ts` `SidebarLayout` | Have. Group, tags, color, favorite. `crates/storage/src/connection_organization.rs:22` | Have | - | - | - |
| PROD marking | Per connection, per database list, badge scope connection/database/table, watermark. `lib/database/productionSafety.ts`, `components/common/ProductionWatermark.vue` | Have at connection scope. `apps/linux/app/src/ui/app/environment_marker.rs` | Adapt (per database marks) | UX + B4 | M | P3. Per-database marks matter on shared servers. Needs PolicyGuard input, not only display |
| Write unlock | Per-connection read-only, timed unlock 60s or 300s, backend `Instant` gate. `stores/readOnlyUnlockStore.ts`, `ReadOnlySessionControl.vue` | Partial. Read-only connections and PolicyGuard approval exist. No timed unlock. Already noted as needing an ADR against ADR 0016 | Adapt only via ADR | B4 | M | P3. Approval flow covers the need. Recorded |
| Secrets | AES-GCM envelope keyed from OS store, file key fallback | Have, stronger. Secret Service only, absent vs failure distinguished. `crates/storage/src/secrets.rs` | Have | - | - | - |
| Config export | Plaintext scrubbed or passphrase encrypted, tunnel profiles follow | Have. Encrypted bundles v2 with SSH hops. `crates/storage/src/connection_bundle_crypto.rs` | Have | - | - | - |
| Cloud sync | WebDAV, snippet sync to GitHub/GitLab | Absent | Skip | - | - | - Local-first product. Users can sync files themselves |
| Deep links | `connectionDeepLink.ts` | Absent | Skip | - | - | - Pairing deep links are excluded |

### SSH and proxies

| Area | dbx feature + source path | BookiE status + path | Decision | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Transport chain | Ordered `transport_layers[]` of ssh, proxy, http_tunnel. `crates/dbx-drivers/src/db/transport_layer_tunnel.rs` | Partial. Multi-hop SSH works, chain editing refused (UI-1b #548). `crates/transport/src/route.rs` | Have (tracked) | B4/UX | - | - Recorded |
| Shared tunnel profiles | `profile_id` per layer, `TunnelProfileManager.vue` | Absent. UI-26 reusable profiles accepted for later | Have (tracked) | UX | - | - Recorded |
| SOCKS5/HTTP proxy | Proxy layer with auth and test target. `crates/dbx-driver-support/src/http_tunnel.rs` | Absent. Effective ProxyCommand rejected by test `crates/ssh/src/openssh/config_route.rs:151` | Adapt (SOCKS5 only, no HTTP tunnel PHP) | B4 | M | P3. Corporate egress case. Needs threat review and DNS-leak rule |
| ProxyCommand | Allowlisted executables, no shell | Deliberately refused | Skip (recorded) | - | - | - |
| HTTP tunnel | `deploy/dbx_tunnel.php` | Absent | Skip | - | - | - Remote PHP shim is a large attack surface |
| SSH config host import | `lib/connection/sshConfigHosts.ts` | Partial. System OpenSSH path honors `~/.ssh/config` routes. `crates/ssh/src/openssh/config.rs` | Adapt (prefill picker from `Host` entries) | UX | S | P3. Small quality-of-life gain |

### Drivers (BookiE engines only)

| Engine | dbx | BookiE | Note |
|---|---|---|---|
| PostgreSQL | Native tokio-postgres fork + deadpool | Native, streaming cursors, best coverage | BookiE ahead on streaming and cancel confirmation |
| MySQL/MariaDB | Native patched mysql_async, many forks | Native | dbx carries TiDB, Doris, StarRocks, OceanBase variants. Skip |
| SQLite | rusqlite, SQLCipher, remote over SSH worker `crates/dbx-sqlite-worker` | Native, local only | SQLCipher is an Adapt candidate (P3, B3, M). Remote worker Skip (recorded) |
| SQL Server | Vendored tiberius, GO batches | Native tiberius, Kerberos | Comparable. BookiE has Kerberos |
| ClickHouse | Native HTTP | Native | Comparable |
| MongoDB | Native `mongodb` 3.x with OIDC, plus legacy agent sidecar | Native | OIDC auth is a P3 B4 candidate |
| Redis | `redis` crate with cluster, sentinel, TLS | Native | Cluster and sentinel: verify BookiE support before claiming gap. P3 B3 |
| DuckDB | Managed sidecar worker process | Static crate, optional feature | BookiE model is simpler and matches ADR 0001 |

Others in dbx, out of BookiE scope: Oracle, Dameng, Kingbase, DB2, Snowflake, Trino, Hive, HANA, Teradata, Vertica, Firebird, H2, Informix, Neo4j, Cassandra, BigQuery, Spanner (JDBC/Go sidecars), Elasticsearch, Meilisearch, Solr, CouchDB, HBase, Qdrant, Chroma, Milvus, Weaviate, DynamoDB, InfluxDB, VictoriaMetrics, Salesforce, MQ and MQTT consoles, Nacos, Consul, etcd, ZooKeeper.

### Editor

| Area | dbx feature + source path | BookiE status + path | Decision | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Alias completion | `lib/sql/semantic/references.ts` | Have. `apps/linux/app/src/ui/editor/completion.rs:328` `resolve_qualifier` | Have | - | - | - |
| CTE completion | CTE names and columns as sources, nested. `lib/sql/semantic/cteNavigation.ts`, `sqlCompletion.ts` `ScannedCteDefinition` | Absent. `table_references` only sees real tables; `with` is just a keyword. `completion.rs:174`, `:285` | Adopt | UX | M | P1. Common in daily SQL. Pure function, easy to unit test |
| Function signature help | PG, DuckDB, others. `lib/sql/functionSignatures/` | Absent | Adapt (PG, DuckDB, ClickHouse static tables) | UX | M | P2. Static data, no network |
| Formatter | `sql-formatter` npm + custom layout printer, format on save | Have. `sqlformat` 0.5. `crates/core/src/sql_format/mod.rs:17` | Have | - | - | - Format on save is a trivial preference if asked |
| Snippets | Built-in templates (select, insert, CTE, join, create table). `lib/sql/sqlSnippetTemplates.ts` | Absent | Adopt (GtkSourceView snippets, static) | UX | S | P2. GtkSourceView 5 has a snippet manager. Low code |
| Folding | Block folding | Have. `apps/linux/app/src/ui/editor/folding.rs` | Have | - | - | - |
| Multi-cursor | Rectangular select, add next occurrence | Absent. UI-22 deferred | Have (tracked) | UX | - | - Recorded |
| Visual EXPLAIN | 7 engines, SVG export. `components/explain/` | Partial. PG and SQLite tree. `apps/linux/app/src/ui/explain_tree.rs` | Adapt (MySQL, SQL Server JSON plans) | B3/UX | M | P3. Recorded as partial |
| Parameters | `?`, `:name`, `${}`, `#{}`, `@name`, value history. `lib/sql/sqlVariableSyntax.ts` | Have named params. `crates/core/src/params.rs`, `ui/parameters_dialog.rs` | Adapt (value history) | UX | S | P3. Small comfort gain |
| Error position | Offset to line/col within statement. `lib/sql/errorPosition.ts` | Have. `ui/editor/error_location.rs` | Have | - | - | - |
| Statement diagnostics | Routine syntax checks. `lib/sql/sqlDiagnostics.ts` | Have. `ui/editor/diagnostics.rs` | Have | - | - | - |
| Run on many DBs | `MultiDbExecuteDialog.vue` with typed confirm code | Absent | Skip for now | - | - | - Large blast radius. Revisit only with PolicyGuard batch design |
| Saved queries | Folders, directory import | Have saved queries and favorites. `crates/storage/src/favorites.rs` | Have (folders recorded) | - | - | - |
| History | SQLite table, cursor paging 100, retention | Have, credential-bearing statements excluded. `crates/storage/src/query_history.rs` | Have | - | - | - |
| Shortcut registry | 99 rebindable shortcuts with recorder. `lib/editor/shortcutRegistry.ts` | Partial. `WINDOW_SHORTCUTS` fixed. Recorded | Have (tracked) | UX | - | - |
| Expand `SELECT *` | Editor action | Absent | Adopt | UX | S | P3. Uses existing column cache in `completion.rs` |

### Results grid and data editing

| Area | dbx feature + source path | BookiE status + path | Decision | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Copy formats | 18 formats incl. SQL UPDATE, DELETE+INSERT, WHERE clause, JSON lines, XML, HTML. `lib/dataGrid/dataGridCopyExtractor.ts` | Partial. Rows, headers, JSON, CSV, Markdown, IN clause, INSERT. `apps/linux/app/src/ui/grid/context_menu.rs:498` | Adapt (add UPDATE, WHERE clause, JSON lines) | B3/UX | S | P2. Reuse `crates/core/src/sql_literal.rs` typed literals so copy and export agree |
| Value viewer | JSON tree, hex, image, geometry map | Partial. Value viewer, full-value editor. `ui/grid/value_viewer.rs` | Adapt (hex and image preview) | UX | S | P3. Map view recorded as candidate |
| Transpose / record view | `lib/dataGrid/dataGridTranspose.ts` | Have. Row inspector `ui/row_inspector.rs` | Have | - | - | - |
| Charts | echarts bar, line, pie | Absent | Skip | - | - | - Not core to governed client |
| Grid snapshot image | `GridSnapshotDialog.vue` | Absent | Skip | - | - | - |
| Distinct-value filter popover | `DataGridFilterBuilder.vue` | Partial. Filter strip, filter from cell. `ui/filter_strip.rs` | Adapt (distinct values of loaded rows) | UX | S | P3 |
| FK display / picker | FK navigation and display, no picker | Have navigation; picker tracked UI-19 | Have (tracked) | - | - | - |
| Keyless edits | Physical locator (ctid, rowid) or all-column match | Refused by design (TEST-14). Recorded | Skip | - | - | - |
| Save preview | SQL preview before commit, optional transaction | Have change tracker and approval. `services/change_tracker.rs` | Have | - | - | - |
| Test data generator | 45 generator types. `components/generate/DataGenerateDialog.vue` | Absent | Adapt (later) | UX | M | P3. Useful for dev DBs. Must go through PolicyGuard bulk insert |

### Structure, DDL, ER, compare, transfer

| Area | dbx feature + source path | BookiE status + path | Decision | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Table designer | Columns, indexes, PK, charset, comments, partitions | Have columns, indexes, FKs, column comments. `ui/structure_tab/`, `crates/core/src/sql_ddl/diff.rs` | Have | - | - | - Table comment and partitions recorded |
| DDL profile as data | `DdlDialectProfile` with QuoteStyle, AutoIncSyntax, comment style, rename syntax. `crates/dbx-sql-dialect/src/sql_dialect/ddl_profile.rs:100` | Partial. Per-engine branches in `crates/core/src/sql_ddl/*` and `sql_dialect.rs` (string `driver_id` match) | Adapt | B3 | M | P1. Prerequisite for compare, ER sync and create-table-from-diagram. See architecture table |
| Trigger toggle | `table_structure_sql/triggers.rs` | Absent. Recorded candidate | - | - | - | - |
| Show DDL | `DdlViewDialog.vue` | Have for tables via structure tab. Verify view DDL (recorded #3405 prompt) | Have | - | - | - |
| ER diagram | Vue Flow + elkjs, inference, layers, drafts, export PNG/SVG/Mermaid/DBML. `apps/desktop/src/components/diagram/`, `lib/diagram/` | Absent. No `diagram` symbol in `apps/` or `crates/` | Adapt (read-only first, see section 4) | UX + B3 | L | P2. Most visible gap. Metadata already exists |
| Schema diff | Columns, indexes, FKs, triggers, routines, rename detection, rollback plan with completeness. `crates/dbx-sql-schema/src/schema_diff.rs` (16k lines) | Absent. `sql_ddl/diff.rs` diffs one table snapshot against edits only | Adapt (same-engine, tables only, read-only report first) | B3 | L | P2. Reuse `diff_to_ops`; output is a script for the editor, run through PolicyGuard |
| Data compare | Key-column compare and sync SQL. `crates/dbx-core/src/data/data_compare.rs` | Absent | Skip for now | - | - | P3. Needs bounded scans and snapshot semantics (ADR 0014) |
| Data transfer | Cross-connection append, overwrite, upsert, rebuild. `crates/dbx-core/src/data/transfer.rs` (about 1 MB) | Absent | Skip for now | - | - | P3. Huge surface, type mapping risk against ADR 0007 |
| Scheduled backups | systemd --user timers, gzip, retention. `src-tauri/src/background_backup.rs` | Partial. Manual pg_dump/pg_restore via `crates/dump`, `ui/app/backup.rs`. Snapshots SNAP-2..4 tracked | Adapt (systemd user timer calling `bookie-agentd` or `pg_dump`) | B4 | M | P3. Linux-native fit, but after SNAP work |
| Database search | Object search across schemas | Have Open Quickly. `ui/quick_switcher_dialog.rs` | Have | - | - | - |
| Process list | `ProcessListPanel.vue` | Have PG activity dialog. `ui/activity_dialog.rs` | Have | - | - | - |

### Import and export

| Area | dbx feature + source path | BookiE status + path | Decision | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| Export formats | CSV quote modes, XLSX streaming with header modes and row split, JSON, Markdown, SQL batch/single, `\N` NULL. `crates/dbx-formats/` | Have CSV, JSON, Markdown, HTML, XML, SQL, XLSX. `crates/core/src/export/` | Have | - | - | - Full-table export refused (ADR 0014) |
| CSV formula-injection guard | Prefix guard in `crates/dbx-formats` CSV encoder | Have. `sanitize_formulas`, text values only. `crates/core/src/export/csv.rs:78`, `:247` | Have | - | - | - |
| XLSX row limit | Split sheets at max rows | Have the limit check. `crates/core/src/export/xlsx.rs:11` | Have (splitting into more sheets is optional) | B3 | S | P3 |
| Import formats | CSV, TSV, delimited, JSON, XLSX, SQL, Parquet (via DuckDB) | Partial. CSV only. `crates/core/src/import/csv_import.rs` | Adapt (JSON objects/arrays, then XLSX via calamine) | B3/UX | M | P2. JSON/SQL import recorded as candidate; Parquet through DuckDB driver is cheap once DuckDB feature is on |
| Import options | Encoding (UTF-8, GBK, UTF-16), title row, data start/last row, empty-as-NULL, null literal | Partial. Mapping memory exists. `services/csv_import_mappings.rs` | Adapt (null literal, start row, UTF-16) | B3 | S | P3. Encoding breadth recorded |
| Data dictionary PDF | `lib/docs/dataDictionaryPdf.ts` | Absent | Skip | - | - | - Markdown/HTML export of catalog would cover it |

### Safety, MCP, CLI, web, i18n

| Area | dbx feature + source path | BookiE status + path | Decision | Lane | Effort | Priority |
|---|---|---|---|---|---|---|
| SQL guard | Desktop: leading-keyword regex confirm, can be disabled (`composables/useSqlExecution.ts:40`). Core: AST risk classes plus dangerous rules, fail closed (`crates/dbx-sql-core/src/sql_risk.rs`) | Have, stronger. PolicyGuard classify, approval, blast radius, masking, audit. `crates/policy/src/` | Have | - | - | - |
| Shared safety corpus | One JSON corpus run by Rust and TS. `tests/fixtures/production-safety-corpus.json` | Partial. Policy tests are Rust-only, spread over `guard_tests_*.rs` | Adopt (one data corpus for classify, effects, MCP) | B4 | S | P1. Lets MCP, GUI and agentd assert the same verdicts from one file |
| MCP tools | 28 tools incl. sessions/transactions, batch, routines, schema context, open in UI. `crates/dbx-mcp/src/server.rs` | 11 tools. `crates/mcp/src/tools.rs:4` | Adapt (add `list_routines`, `get_routine_source`, `get_schema_context`) | B4 | M | P2. Read-only discovery tools raise agent quality without new write paths. Skip connection add/remove and plugin tools |
| MCP scoping | Global, per group, per connection, per database read-only and dangerous-SQL flags, tool allowlist | Have token scopes, connection allowlist, rate limit, PolicyGuard. `crates/mcp/src/tokens.rs`, `rate_limit.rs` | Adapt (per-token tool allowlist) | B4 | S | P2. Least privilege per agent |
| MCP HTTP | Streamable HTTP with bearer, Host/Origin allowlist | Absent by design. stdio only; agentd rejects `--http`, `--bind`, `--port` flags (test at `crates/agentd/src/main.rs:473`) | Skip. If HTTP is ever added, copy the Host/Origin allowlist | B4 | - | - |
| MCP approval binding | Approval bound to connection, database and exact SQL, policy re-checked after dialog | Have approval router. `services/approval_router.rs` | Verify | B4 | S | P2. Add a test that policy is re-evaluated after approval returns |
| CLI | `dbx query`, `schema describe`, `doctor`, output table/JSON/CSV. `crates/dbx-cli/src/main.rs` | Partial. `bookie-agentd` serves MCP and issues tokens only. `crates/agentd/src/main.rs` | Adapt (`bookie-agentd query`/`doctor` through PolicyGuard) | B4 | M | P3. Scripting value; must reuse the governed path |
| Docker/web mode | axum server, password login. `crates/dbx-web/` | Out of scope (PRODUCT non-goal) | Skip | - | - | - |
| AI chat | Many providers. `crates/dbx-ai-provider/` | Out of scope by product rule | Skip | - | - | - |
| Plugins | Signed marketplace. `crates/dbx-plugin-runtime/` | Out of scope (ADR 0001) | Skip | - | - | - |
| i18n | 14 locales, lazy load, placeholder parity spec. `apps/desktop/src/i18n/` | Partial. gettext infra, `tablepro.pot`, zero locales in `apps/linux/po/LINGUAS` | Adapt (placeholder parity check for `.po`) | UX | S | P3. Add when first locale lands |

## 2. Architecture ideas

| dbx idea | Where | What BookiE should do | BookiE crate | BookiE already better |
|---|---|---|---|---|
| `SqlDialectProfile` (all-bool lexer flags: hash comments, `-- ` rule, nested block comments, backtick, backslash escapes, `E''`, dollar quotes, GO, DELIMITER, psql `\` commands) | `crates/dbx-sql-core/src/sql.rs:172` | Replace `LexicalSettings { backslash_escapes }` with a small `DialectProfile` const per `SqlGrammar`. Feed splitter, classifier, completion and export quoting. Keep session override from #893. Note: dbx only uses it in the splitter, which is why its formatter and export can disagree | `crates/core/src/sql_syntax/script/lexical_settings.rs` | BookiE already shares one lexer between splitter and policy |
| `DdlDialectProfile` + `type_rewrite`, rule "call sites must not branch on databases" | `crates/dbx-sql-dialect/src/sql_dialect/ddl_profile.rs` | Move quoting, auto-increment, comment style, rename syntax and FK placement into one `const` struct per driver. Replace `match driver_id` strings in `sql_dialect.rs` | `crates/core/src/sql_ddl/` | BookiE DDL has per-engine comment, default and collation tests |
| Capability descriptor + manifest | `crates/dbx-types/src/database_manifest.rs`, `plugins/connection-types/*.yaml` | Do not use YAML. Add a static `DriverCapabilities` struct returned once by `DatabaseDriver`, replacing ten `supports_*` methods. Feeds APP-MOD | `crates/core/src/driver.rs:74` | Compile-time checked, no runtime YAML or hot reload |
| Split SQL crates (`sql-core`, `sql-dialect`, `sql-data`, `sql-schema`) | `crates/dbx-sql*` | Only extract `sql_ddl` + future schema diff into `crates/sql-schema` when compare lands. Not before | new `crates/sql-schema` | `core` stays small and GTK-free |
| `dbx-driver-support` (query message buffer, operation budget, connect timeout, TCP probe, WKB) | `crates/dbx-driver-support/src/` | Put shared driver helpers in `crates/drivers/shared` as a real crate when two drivers need them. Message buffer recorded under #550 | `crates/drivers/shared` | Cancel requires server confirmation |
| `dbx-types` JSON-as-cell model | `crates/dbx-types/src/types.rs` | Do not adopt. Keep ADR 0007 typed `Value`. Borrow `json.rs` safe-int idea only at the MCP edge (#895) | `crates/mcp` | Decimals, binary, time zones keep native type; dbx stores decimals and datetimes as strings |
| `dbx-formats` leaf crate | `crates/dbx-formats/` | Keep export in `core/export`. Formula guard and XLSX row limit already exist. Nothing to copy | `crates/core/src/export/` | `rust_xlsxwriter`, duplicate-label-safe JSON, formula guard limited to text values |
| Shared safety corpus JSON | `tests/fixtures/production-safety-corpus.json` | Add `tests/fixtures/policy-corpus.json` read by `crates/policy` and `crates/mcp` tests | `crates/policy` | PolicyGuard is the only path; dbx desktop uses a separate regex |
| Insta snapshots for dialect descriptors and type maps | `crates/dbx-sql-dialect/src/sql_dialect/snapshots/` | Snapshot the DDL profile and type maps once they are data | `crates/core` | Mutation testing and real-engine tiers |
| Architecture guard checks feature forwarding and lockfile | `scripts/core-architecture.test.mjs` | Recorded (#891). Only add feature-forwarding check for optional DuckDB | `scripts/check-crate-boundaries.py` | Python guard already in preflight |
| Testing: 1,567 vitest specs, 294 `packages/app-tests`, about 60 `#[ignore]` live tests against remote DBs, no fuzzing, no Playwright | `vitest.config.ts`, `crates/dbx-core/tests/live_*` | Nothing to copy at scale. Copy the idea of logic-level "app tests" that drive services without UI, which ADR 0018 enables | `crates/app-services` | Docker real-engine tiers, installed GTK suite, mutation runs, Forgejo gate |
| MCP: rmcp, stdio + HTTP, 28 tools, annotations, per-group policy, approval bound to exact SQL, audit via history with Drop guard | `crates/dbx-mcp/src/server.rs` | Adopt read-only discovery tools and a per-token tool allowlist. Keep PolicyGuard path | `crates/mcp` | Tokens with scopes, rate limits, terminal audit states in journal, masking. dbx MCP has no rate limit and its audit is history rows |
| Schema diff deploy result `committed/rolled_back/mixed` with rollback completeness | `crates/dbx-core/src/query.rs` `execute_schema_diff_deploy`, `handoff.md` | When compare lands, report per-statement outcome and mark non-transactional DDL engines (MySQL) as possibly mixed. Never probe by re-commit | `crates/policy`, `crates/core` | `OperationOutcomeUnknown` and structured MCP outcomes already exist |

## 3. Where BookiE is ahead

- Typed values (ADR 0007). dbx cells are `serde_json::Value`; decimals and datetimes are driver-formatted strings.
- One governed path. dbx desktop confirms by leading-keyword regex that users can disable; its AST classifier guards MCP. BookiE runs GUI, MCP and agentd through PolicyGuard.
- Audit. Terminal audit states for denied, failed, cancelled and timed-out work, in a journal. dbx records MCP calls as history rows.
- MCP rate limiting and scoped tokens. dbx MCP has no rate limit.
- Masking of returned results. Not found in dbx.
- Cancellation needs server confirmation; unknown outcomes are explicit.
- Secrets in Secret Service only. dbx falls back to a key file on some builds.
- Static drivers. dbx needs Java and sidecar processes for DuckDB and legacy MongoDB.
- PostgreSQL streaming with bounded pages. dbx caps at 100,000 rows.
- Test tiers: real engines in Docker, installed GTK suite, mutation testing. dbx live tests are opt-in against remote servers.
- Credential-bearing statements kept out of history.
- Kerberos for SQL Server.

## 4. ER diagram design for GTK

What dbx built (`apps/desktop/src/lib/diagram/`, `components/diagram/`, design doc `dbx-er-diagram-architecture.html`, v4):

- Model. `DiagramTable { name, schema, comment, columns, foreignKeys, indexes, origin: live|draft, pending/dropped columns }` in `erDiagram.ts`. Edges carry cardinality pairs `1/N` (`cardinality.ts`), default N:1 for FKs.
- Relationship sources in layers. P0 physical FKs. P1 naming (`user_id`, `UserId` to `users.id`, snake and camel). P2 type compatibility table (`match-strategies.ts`). P3 user regex. Inferred edges are dashed; pending ones dotted grey. Users confirm or ignore; choices persist per connection, database, schema key.
- Layout. elkjs `layered` (Sugiyama), `ORTHOGONAL` routing, `BRANDES_KOEPF`, `LAYER_SWEEP`, `NETWORK_SIMPLEX`, `separateConnectedComponents`, direction LR/TB. Plus a simple left-to-right grid ordered by connectivity (`ltr-auto-layout.ts`) and an obstacle-avoiding orthogonal router (`edge-obstacle-router.ts`).
- Layers (group boxes) with auto or free layout (`layer-store.ts`, `size-layer.ts`).
- Undo/redo via snapshot stack capped at 50; only layout and relationship edits are recorded, not zoom or selection (`graph-store.ts`).
- Drafts. Design tables on canvas, generate CREATE/ALTER, sync to DB (`draft-table.ts`, `DiagramSyncDialog.vue`).
- Export PNG, SVG, Mermaid, DBML, JSON (`lib/export/diagramFormats.ts`).
- Backend tweak. One bulk "all columns in schema" call instead of per-table calls.
- Lesson from their history. The first version was one 1,150-line component; the rewrite split model, layout, routing, inference and storage into testable modules. The main dialog is still 2,412 lines.

Transferable plan for BookiE:

1. Pure model and logic in a GTK-free place (`crates/app-services` or a `diagram` module in `crates/core`): graph from catalog, FK edges, name inference with the P1/P2 rules, layout, export to Mermaid and DBML text. Unit tests mirror dbx TC-M1..M5 (naming, type mismatch, conflict, FK dedupe, camelCase) and TC-S1..S4 (undo).
2. Metadata. Add one bulk `columns_and_fks_for_schema` driver call so the diagram is one round trip through PolicyGuard. Bound table count (for example 300) and refuse above it with a filter prompt, in line with #580.
3. Layout without JavaScript. Options: `layout-rs` or a small own Sugiyama (longest-path layering, barycenter crossing reduction, simple orthogonal routes). Start with the connectivity-ordered grid (dbx `ltr-auto-layout.ts` is about 350 lines and is the default fallback). Do not ship elkjs or a webview.
4. Rendering. One `gtk::DrawingArea` (or a custom widget with `snapshot`) drawing cards with Pango, plus `GestureDrag`, `GestureZoom`, `EventControllerScroll`. No zoom clamp at 0.6..1.5 like dbx v1. Cull off-screen cards for large schemas. Accessibility: also expose a list view of tables and relationships, since a canvas is not readable by Orca.
5. Persistence. Positions, confirmed and ignored inferred edges, keyed by connection id + database + schema, in `crates/storage` JSON next to favorites. Not in the DB.
6. Read-only first. Draft tables and sync come later and must emit SQL into an editor tab so PolicyGuard and audit apply. No direct DDL from the canvas.
7. Export SVG/PNG via Cairo, Mermaid/DBML as text. These are cheap and loved.

Skip: engineering (Chen notation) view, layers, field lineage, explain plan in the same canvas.

## 5. Top 20 to adopt, ranked

1. CTE-aware completion. UX, M, P1. `apps/linux/app/src/ui/editor/completion.rs`.
2. Static dialect profile replacing `LexicalSettings`, consumed by splitter, classifier, completion and export. B3 with B4 review, M, P1. Extends PEER-2/#893.
3. DDL profile as data per driver, ending `driver_id` string matches in `sql_dialect.rs` and `sql_ddl`. B3, M, P1.
4. Shared policy verdict corpus as one JSON fixture used by policy and MCP tests. B4, S, P1.
5. Read-only ER diagram: model, FK edges, grid layout, Cairo render, SVG/PNG/Mermaid/DBML export. UX + B3, L, P2.
6. Inferred relationships with confirm/ignore in the diagram. UX, M, P2.
7. Same-engine schema compare report that emits a reviewed script into the editor. B3, L, P2.
8. MCP read-only discovery tools: routines, routine source, schema context. B4, M, P2.
9. Per-token MCP tool allowlist. B4, S, P2.
10. Copy as UPDATE, WHERE clause and JSON lines from the grid, using `sql_literal.rs`. B3/UX, S, P2.
11. JSON import (objects and arrays), then XLSX via `calamine`. B3/UX, M, P2.
12. URL import for `mongodb+srv`, `rediss` and file URLs. UX, S, P2.
13. GtkSourceView SQL snippets (select, insert, CTE, join, create table). UX, S, P2.
14. Function signature help for PostgreSQL, DuckDB and ClickHouse. UX, M, P2.
15. Connection import from DBeaver and DataGrip, without secrets. UX, M, P2.
16. Static `DriverCapabilities` struct replacing scattered `supports_*` methods. B3, S, P2. Feeds APP-MOD.
17. Expand `SELECT *` into the column list from the completion cache. UX, S, P3.
18. Test that approval re-evaluates policy after the dialog returns, bound to exact SQL and database. B4, S, P2.
19. SOCKS5 proxy transport layer, after a threat review covering DNS resolution. B4, M, P3.
20. Parameter value history in the parameters dialog. UX, S, P3.

Not ranked but noted: per-database PROD marks (P3), systemd user timer backups after SNAP (P3), test data generator (P3), `bookie-agentd query` CLI (P3), `.po` placeholder parity check (P3).
