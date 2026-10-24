# Feature comparison research snapshots

Historical release notes and source scans, preserved from the active comparison page on 2026-10-23. These dated records describe only the sources and BookiE revisions named in each section. They are not current product status, issue status or a delivery queue. Use the [active parity candidates](../0.2-feature-comparison.md), [backlog](../backlog.md) and Project #3 for current planning.

## October 17 release snapshots (historical)

| Product | What moved | Relative to BookiE |
|---|---|---|
| BookiE | ENUM/SET pickers on PostgreSQL, MySQL and MariaDB; FK navigation and paste-TSV already landed; EXPLAIN tree for PostgreSQL and SQLite; MySQL `TINYINT(1)` values outside 0 and 1 remain integers (#1006); full-table export refusal (ADR 0014); PolicyGuard (ADR 0016); open work moved to Project #3 | Closed part of UI-19. PostgreSQL editor streaming and full-value editing have landed. Jump-chain editing, other-engine streaming, NOTICE/timing and Wayland acceptance remain open; a consistent full-table export path is an unselected future candidate |
| DBeaver | Community 26.2.2 (latest GitHub release checked 2026-10-17); current `devel` source `61c952984`. Recent merged fixes include SQLite metadata shadowing ([#42376](https://github.com/dbeaver/dbeaver/pull/42376)) and SQL comment scanning across line endings. The same shadowing class reproduced in Bookie's metadata path and was fixed by [PR #1057](https://github.com/cozyGarage/BookiE/pull/1057), with regression coverage that preserves catalog visibility | Broader driver and AI surfaces. MCP is no longer unique to BookiE; Bookie keeps governed MCP + PolicyGuard and has no in-app assistant by product choice |
| TablePlus | macOS 27.0.2 (2026-10-08): MCP setup, JSON/Tree views, Notification Center, import/export and driver updates. Windows: Elasticsearch and Entra ID. Linux 1.7.0 (2026-08-22) | Recent macOS work adds MCP and editor polish; the Linux release cadence remains slower than macOS/Windows |
| TablePro | macOS main `bdbcb7de9`; separate Linux branch `7cd300f82`. macOS release v0.81.0 (2026-10-16) adds per-database tabs and an Oracle query-tab schema picker; it also fixes database-switch identity leaks across tabs, quick switch, table info and `open_table_tab` (#3436). Recent Linux fixes cover SQLite rebuild references, SSH host-key replacement under strict policy, ClickHouse mutation resolution and active-edit close | Separate from TablePlus. [Source-based port assessment](linux-peer-review-2026-10-16.md#tablepro-port-assessment) adapts relevant behavior to BookiE rather than merging its architecture |
| dbx | 0.6.46 (latest GitHub release checked 2026-10-17), source `ab9212975`. Since the prior pin, it adds Mycat proxy database/table listing. Earlier fixes include PostgreSQL I/O error sources in diagnostics and guarded trigger toggles with dialect-specific SQL and quoting tests. Its merged SSH ProxyCommand work uses a helper process and executable allowlist; Bookie should retain its explicit SSH paths unless a separate threat-reviewed feature is selected. | The reviewed release includes additional engine and integration features. PostgreSQL NOTICE/WARNING display and nested-CTE completion are already present; Bookie UI-20 remains open. Bookie keeps ADR 0007 typed values and fail-closed masking as differentiators. The dbx debug-log performance report was later corrected as a root-cause attribution, a reminder to verify the suspected path in the reproducer. Trigger toggles remain an unselected feature candidate |
| Beekeeper Studio | Latest GitHub release checked: 6.1.6; source `f7ff968f3`. Recent merged work includes Home/End keyboard navigation fixes and moving non-database integration specs to Vitest | Re-check the GTK navigation equivalent only if BookiE reports the same user-facing issue; test-management lesson is to separate database-backed integration specs from fast host-only tests |

The October 17 dbx issue/merge-feed check adds useful regression cases: [#12484](https://github.com/t8y2/dbx/issues/12484) reports an empty second page when MySQL returns exactly 100 rows; [#12504](https://github.com/t8y2/dbx/issues/12504) reports writes truncating MySQL LONGTEXT at 4096 characters; and [#12478](https://github.com/t8y2/dbx/issues/12478) reports query-tab renaming changing an object-tab label. Proposed fix [#12509](https://github.com/t8y2/dbx/pull/12509) closed without merge, so the tab-identity issue remains open. Merged [#12434](https://github.com/t8y2/dbx/pull/12434), [#12435](https://github.com/t8y2/dbx/pull/12435) and [#12468](https://github.com/t8y2/dbx/pull/12468) are useful for exact page-boundary checks, bounded metadata loads and tests that prove scan budgets actually affect execution. These are reported dbx cases, not confirmed Bookie defects; validate Bookie's matching paths before filing work.

The refreshed dbx main head adds four portable review prompts: [#12505](https://github.com/t8y2/dbx/pull/12505) supports foreign-key navigation across databases; [#12508](https://github.com/t8y2/dbx/pull/12508) searches the full cell value beyond a display truncation boundary; [#12503](https://github.com/t8y2/dbx/pull/12503) follows SQL Server TDS routing redirects; and [#12513](https://github.com/t8y2/dbx/pull/12513) avoids an `information_schema.columns` join for PostgreSQL nullability after issue [#12393](https://github.com/t8y2/dbx/issues/12393) reported a 40-second column load. Bookie's table-structure query already uses `pg_catalog.pg_attribute`, so that exact join fix does not apply; #580 still needs separate sidebar/catalog profiling under restricted roles and many schemas. Check full-value search against Bookie's truncated-cell model. These upstream fixes are not evidence of matching Bookie defects.

The reviewed projects include AI features, additional database drivers and MCP setup features outside the current BookiE scope.
BookiE's distinguishing contracts remain exact type/value preservation (ADR
0007), guarded database access and audited, scoped MCP consumers without an
in-app chat product. Do not infer parity from a name alone.

| Area | BookiE today | DBeaver | TablePlus | dbx |
|---|---|---|---|---|
| Drivers | 8 driver crates: PostgreSQL, MySQL/MariaDB, SQLite, SQL Server, ClickHouse, MongoDB, Redis and DuckDB (optional app feature). Oracle is out of scope (PKG-7) | 100+ via JDBC; still expanding (Fabric, Valkey, Doris, etcd, …) | about 15+, plus Elasticsearch on macOS/Windows; Oracle and Cassandra included | many, with JDBC sidecars; 100+ claimed |
| SSH and TLS | Built-in and system OpenSSH, multi-hop, host-key prompts, TLS modes and SQL Server Kerberos. Jump-chain editing remains incomplete (UI-1b) | yes | yes | yes |
| Editor | Completion, formatter, statement navigation, multiple results and pinning, named parameters, EXPLAIN tree for PostgreSQL and SQLite, find and replace, optional Vim keys | yes; redesigned plan graph in 26.1 | yes; folding and theme work on macOS | yes; nested-CTE autocomplete in 0.6.40 |
| Grid | Inline edit, filters, hidden/reordered columns, find, value viewer, row inspector, long-value preview, ENUM/SET pickers (PostgreSQL, MySQL, MariaDB), FK navigation, paste TSV, selection sum/average tooltip | yes | yes | preview and fetch on demand |
| Schema editing | Structure editor for columns, indexes, foreign keys and column comments; triggers can be browsed but not enabled/disabled from the UI | full | yes | yes; #12512 adds scoped trigger toggles for supported dialects |
| Import and export | CSV import; CSV, JSON, Markdown, HTML, XML, SQL and Excel result exports. Full-table export is refused unless a verified snapshot path exists | many formats | CSV, JSON, SQL | yes; XLSX header/comment modes in 0.6.40 |
| Safety | Policy guard, approval, read-only connections, audit journal, masking and scoped MCP server | read-only connections, confirmations; Team/Enterprise audit logging | safe mode | SQL guard and write-unlock toggle |
| AI / agents | Governed MCP server and `bookie-agentd`; no built-in chat by product choice | assistant + MCP client/host + model configs | MCP one-click into agents; assistant on some builds | built-in assistant + native MCP server/CLI |
| History and saved queries | Query history, favorites, saved queries and Open Quickly | yes | yes; faster history search on macOS 27 | yes |
| Packaging | Linux: Arch, Debian and Flatpak manifest; Flathub and desktop acceptance remain open | Windows, macOS, Linux | macOS, Windows and Linux | cross-platform desktop, Docker, CLI |

The matrix above covers TablePlus separately from TablePro. TablePro implementation details and regression candidates are in the linked source review; they are not inferred from TablePlus release numbers.

## 2026-10-20 release refresh

Checked against the public GitHub release feeds on 2026-10-20: DBeaver 26.2.3 (2026-10-18), dbx v0.6.50 (2026-10-20, source `b993e7a6f`), TablePro v0.82.0 (2026-10-19) and v0.83.0-beta.1 (2026-10-20), and Beekeeper Studio v6.1.6 (unchanged since 2026-10-07). These versions supersede the pins in the snapshot table above. This is a release-note read, not a runtime audit; BookiE status comes from a source search of `apps/linux` and `crates/core`. Nothing here is selected work and no issue is implied.

| Upstream change | Source | BookiE today | Disposition |
|---|---|---|---|
| Copy selected rows as SQL DELETE and INSERT, for rollback scripts | dbx 0.6.47 | **INSERT Statement** copy exists in the cell menu; DELETE copy does not | Candidate. Small. The DELETE form must use the primary key and refuse keyless tables, like grid deletes |
| Typed value suggestions and operator completion in the hand-written WHERE box | dbx 0.6.50 | Filter strip with named presets and Filter by This Value; no typed value or operator completion | Candidate. UX lane, after the filter acceptance work |
| Generate UUID and UUIDv7 in Set Value, Fill Column, and Add/Duplicate/Paste on UUID primary keys with no default | TablePro 0.82.0 | No generator; the user types the value | Candidate. UX lane. Needs a decision on which engines own UUID defaults |
| SQL completion that matches table and column comments | dbx 0.6.49 | Completion uses names and scope, not comments | Candidate. Depends on B3 catalog metadata carrying comments |
| Result tabs and borders take the source connection's colour | dbx 0.6.49 | Production badge and tinted header bar only | Candidate. Extends the existing Production marker; check colour-only meaning against #1126 first |
| Run a SQL script file without opening it in the editor | DBeaver 26.2.3 | Not present; files open as editor tabs | Candidate. Must go through PolicyGuard like any editor run |
| Refresh sidebar metadata after successful DDL | DBeaver 26.2.3 | Present: `CatalogChanges` (`services/catalog.rs`) refreshes the sidebar after DDL from the editor, waits for COMMIT inside a transaction and skips the refresh on rollback; it refreshes without a prompt | Parity already present |
| Export file name taken from the result or tab title | dbx 0.6.47 | Not verified | Low value. No work unless asked |
| Advanced copy formats (DbUnit XML, PHP array, HTML) | dbx 0.6.50 | CSV, TSV, JSON, Markdown, HTML, XML, SQL IN clause | Not selected. Existing formats cover the common cases |
| Per-SQL-file column width memory; F5 sidebar refresh; statement navigation shortcuts | dbx 0.6.49, 0.6.50 | Column widths are stored per table and F5 refreshes; statement navigation exists | Parity already present |
| Facet charts over results, theme editor with VS Code import, iCloud theme sync | TablePro 0.82.0, 0.83.0-beta.1 | None | Out of scope: charts and theme sync are not in the product goals |
| AI chat attachments, assistant execution actions | DBeaver 26.2.3, dbx 0.6.48 | None, by product choice | Out of scope; governed MCP is the agent interface |

Open BookiE defects found through upstream fixes stay in the [backlog](../backlog.md#upstream-client-review-defects). RV-12 (restore dropped editors past 32 tabs) and RV-13 (paste changed copied values) are fixed in [#1206](https://github.com/cozyGarage/BookiE/pull/1206) and leave the ledger when it merges.

## 2026-10-21 deep scan of DBeaver, Beekeeper Studio and post-pin TablePro and dbx

Three read-only scans: DBeaver 25.0.0 to 26.2.3 release notes, Beekeeper Studio v5.x to v6.1.6 release notes and PR titles, and TablePro and dbx commits after the [October 20 review](tablepro-dbx-review-2026-10-20/README.md) pins (`3222542a4`, `d1e88ab4b`). Upstream evidence is release notes and PR titles, not diffs. BookiE status comes from grep and spot reads of `linux`, not from running the app. "Unverified" means no match was found, not that the feature is absent. Each row needs a reproduction or a failing test before it becomes an issue.

### Defects and test gaps to confirm first

| Class | Upstream | BookiE |
|---|---|---|
| A script's own `BEGIN`/`COMMIT` ran on different pooled connections | dbx #12725 | Unverified: no session pinning found in the script path. Needs a test with a multi-statement script that opens a transaction |
| Pasted empty string stored as NULL | dbx #12748 | Likely applies: blank paste input is NULL by design (`browse_tab/value_parse.rs`). Decide whether paste can carry an explicit empty string |
| Statement classifier edge cases: MySQL `/*! */` comments, `WHERE` only in a comment, CTE-led `DELETE` | dbx fixes | Classifier is AST-based (`crates/policy/src/classify.rs`) and handles CTEs; the MySQL executable-comment case is unverified. Add classifier tests |
| CSV export prefixes `'` to numeric-looking text such as `-5` | TablePro #3707 | Applies to text values only. Re-import into typed columns can reject the value; decide whether plain numbers should skip the guard |
| JSONB double encoding, export column order, `bit(1)`, MySQL ALTER charset, MSSQL dotted names, swallowed driver errors | Beekeeper release notes | Unverified fix classes; each needs a regression test, not a feature |
| SSH: agent errors, encrypted default keys, stale credentials after changing auth mode; honouring `~/.ssh/config` | Beekeeper | Unverified. System OpenSSH runs with a private `-F` file (`crates/ssh/src/openssh/argv.rs`), so `Host` aliases and `Include` may be ignored |
| Command execution when fetching a password through a shell command (CWE-78) | DBeaver 26.2.3 | Not applicable: BookiE has no ProxyCommand or password-command setting; askpass only prompts the user |

### Feature gaps, ranked by user value

| # | Feature | Upstream | BookiE today | Effort |
|---|---|---|---|---|
| 1 | Edit rows directly in SQL editor results | Beekeeper v5.7 | Editing exists only in table browse tabs; editor results are read-only | L |
| 2 | Per-connection Safe Mode levels and cascade-delete preview | TablePro #3706, #3703 | Boolean read-only plus PolicyGuard; no cascade preview | M, L |
| 3 | Table actions in the sidebar menu: Duplicate (Rename and Truncate exist, `ui/sidebar_row.rs`) | DBeaver | Menu has Rename Table and Truncate Table; no Duplicate | S |
| 4 | CSV import options: more delimiters | DBeaver CSV fixes | Quote, backslash-escape and encoding options exist (`ui/import_dialog.rs`); the delimiter choice was not rechecked here | S |
| 5 | Source table in grid header tooltips | DBeaver | The column comment shows under the header name (`ui/grid/column.rs`); the source table does not | S |
| 6 | Spreadsheet-style grid input: type to edit, fill handle, paste as new rows | Beekeeper | Paste into existing rows only | M |
| 7 | Generate UPDATE, DELETE and SELECT from selected rows; Markdown and default copy format | DBeaver, dbx, TablePro | INSERT, IN clause, TSV, CSV, JSON copy exist | S |
| 8 | Row grouping panel and striping by column value | DBeaver | None | M |
| 9 | Separate toggles for schema and keyword completion; MySQL cleartext-auth option | Beekeeper | Single completion setting | S |
| 10 | Excel import | TablePro, DBeaver | Present: `.xlsx` import reads the first worksheet with data (`crates/core/src/import/xlsx_import.rs`) | Done |

Rows already recorded elsewhere and not repeated: ER diagram, table and data compare and transfer, connection and saved-query import, JSON and SQL import, BLOB save and load, saved-query folders. Not applicable: JDBC, Hive, Oracle, Cassandra, Trino, Redshift, cloud workspaces, licensing, plugins and the AI assistants.
