# C. TablePro macOS feature surface: UX ideas portable to BookiE GTK

Source pin: TablePro `main` 3222542a4 (apple/TablePro, apple/CHANGELOG.md 0.1.1 to 0.82.0, apple/changelog.d up to #3677). BookiE `linux` 7c4cb3929. Reviewed 2026-10-20. Source and changelog reading only. Neither app was run.

## How to read this

- Upstream column: the changelog version that added the feature, plus the Swift directory under `apple/TablePro/` when it helps. Version numbers come from the `### Added` and `### Fixed` sections.
- BookiE paths: `app/` means `apps/linux/app/src/`. `crates/` is the repo root crates folder.
- Status: **Present**, **Partial**, **Absent**, **OOS** (out of scope by product rule).
- Recommendation: **Have** (nothing to do), **Adopt** (copy the behavior), **Adapt** (same goal, GTK-native shape), **Skip**.
- "Recorded" means an earlier BookiE document already lists it. Those rows get one line and no new design.
- Presence was checked with source greps and UI string scans. A Present row means the feature exists. It does not prove parity in every engine.

Out of scope and not listed row by row: AI chat, inline AI, Agent mode, AI providers, Review with AI, outside MCP servers called from the app, license and team seats, iCloud sync, Sparkle updates, AppleScript, Handoff, iOS features, plugin registry, Oracle, and the REST engines (DynamoDB, Firestore, Bigtable, Spanner, Typesense, Weaviate, Kafka, etcd, Elasticsearch, Beancount, Cloudflare D1/R2).

## 1. Feature inventory

### Connection management

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| Conn | Groups for connections | 0.11.0, nested 0.26.0, Edit Group sheet 0.80.0 | Partial: one flat group per connection. `crates/storage/src/connection_organization.rs`, `app/ui/app/organization.rs` | Skip nesting | UX | M | P3: flat groups plus tags cover the Linux personas |
| Conn | Tags with tag search | 0.53.0 | Present: filter by name, group, tag or driver. `app/ui/welcome_view.rs` | Have | | | |
| Conn | Connection color and window tint | 0.11.0 | Present: `crates/storage/src/connection_color.rs`, `app/ui/app/environment_marker.rs` | Have | | | |
| Conn | Production marker | 0.11.0 | Present: badge, tinted header, `[Production]` title. Recorded in feature comparison | Have | | | |
| Conn | Favorite connections | 0.46.0 | Present: `app/ui/connection_row.rs` "Add to favourites" | Have | | | |
| Conn | Recent connections section, Clear Recent | 0.75.0, 0.76.0 | Absent | Adapt | UX | S | P3: nice, but favorites cover the short list |
| Conn | Multi-select connections, bulk delete, move to group | 0.24.0 | Absent | Skip | UX | M | P3: low frequency |
| Conn | Duplicate connection | early | Present: `app/ui/connection_row.rs` | Have | | | |
| Conn | Import from URL, paste detection | 0.10.0, 0.38.0, 0.39.1 | Present: `crates/storage/src/connection_url.rs`, `app/ui/app/organization.rs`. Socket in URL recorded (#579) | Have | | | |
| Conn | Copy connection as URL (no password) | 0.12.0, 0.36.0 | Absent in app (no copy-URL action) | Adopt | UX | S | P2: cheap, reuses `connection_url.rs` in reverse, useful for sharing with CLI tools |
| Conn | Import from other clients (TablePlus, DBeaver, DataGrip, Beekeeper, Navicat, Sequel Ace) | 0.34.0 to 0.47.0, duplicates 0.49.0, saved queries 0.80.0 | Absent. Saved-query import recorded in feature comparison | Adapt | UX, B4 review | M | P2: DBeaver, DataGrip and Beekeeper run on Linux. This is the main migration path |
| Conn | Encrypted bundle with credentials | 0.25.0 | Present: `crates/storage/src/connection_bundle_crypto.rs` | Have | | | |
| Conn | Saved queries inside bundles | 0.80.0 | Absent. Recorded in feature comparison | Recorded | | | |
| Conn | New connection from a project folder (`.env`, `docker-compose.yml`, `prisma/schema.prisma`, `database.yml`) | 0.61.0, `Views/Connection/ProjectFolder` | Absent | Adapt | UX | M | P3: good developer fit. Must parse only, never execute |
| Conn | Bundled sample database | 0.38.0 | Absent | Adapt | UX | S | P3: a small SQLite file helps onboarding and screenshots |
| Conn | New SQLite or DuckDB file from the form | 0.77.1 | Absent. Recorded in feature comparison | Adopt | UX | S | P2: one `GtkFileDialog.save` call |
| Conn | Open `.sqlite` or `.duckdb` from the file manager | 0.17.0, content sniffing 0.70.0 | Absent: desktop file has `Exec=bookie` and no `MimeType`. No `HANDLES_OPEN` | Adapt | UX | S | P1: basic desktop integration on Linux |
| Conn | Open a connection URL from a terminal (`bookie postgres://...`) | 0.15.0, CLI 0.57.0 | Absent: no command-line handler | Adapt | UX | M | P2: pairs with file open. Show a confirm before connecting (0.26.0 confirms deep links) |
| Conn | Per-connection connect and query timeout | 0.77.0 | Present: `app/ui/connect_dialog/controls.rs` | Have | | | |
| Conn | Startup SQL after connect | 0.16.0, reapply after reconnect 0.73.0, 0.74.0 | Absent | Adapt | B4 | M | P2: needed for `SET search_path`, `SET time_zone`. Must pass PolicyGuard and survive reconnect |
| Conn | Pre-connect shell script | 0.18.0 | Absent | Skip | | | Command execution risk |
| Conn | Password from command, file, env, 1Password, Vault | 0.47.0, 0.56.0 | Absent. Secret Service is the store | Skip | B4 | | Needs an ADR. Command execution and secret routing risk |
| Conn | `~/.pgpass` | 0.18.0 | Partial: used by backup tools only. `crates/dump/src/passfile.rs` | Skip | | | Keyring is the accepted store |
| Conn | Credential profiles shared by connections | 0.75.0 | Absent | Skip | | | P3: small user benefit, new persistence model |
| Conn | Reusable SSH profiles | 0.22.0 | Partial: UI-26 recorded | Recorded | | | |
| Conn | Health check and auto reconnect | 0.3.0, 0.74.0 | Present: `app/services/connection_monitor.rs` | Have | | | |
| Conn | Reason shown next to a disabled Save or Create | 0.73.0, 0.75.0 | Partial: structure tab shows a reason. `app/ui/structure_tab/mod.rs` | Adopt | UX | S | P3: apply the same pattern in the connect dialog |

### SSH, TLS and cloud auth

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| SSH | Password, key, agent | 0.15.0 | Present: `crates/ssh/src/lib.rs` (`SshAuth::Agent`), `app/ui/ssh_section.rs` | Have | | | |
| SSH | Keyboard-interactive and TOTP | 0.18.0, 0.59.0 | Present through system OpenSSH prompts: `crates/ssh/src/openssh/prompt.rs`, `app/ui/ssh_prompt.rs` | Have | | | |
| SSH | Host key verification | 0.18.0 | Present: `crates/ssh/src/known_hosts.rs` | Have | | | |
| SSH | `~/.ssh/config` aliases and ProxyJump | 0.38.0 | Present with system OpenSSH: `crates/ssh/src/openssh/config_route.rs` | Have | | | |
| SSH | Multi-hop editing | 0.15.0 | Partial: UI-1b recorded | Recorded | | | |
| SSH | Forward to a remote Unix socket | 0.57.1 | Present: `forwarded_socket_dir` in `crates/core/src/connection.rs` | Have | | | |
| SSH | Test SSH alone | 0.23.1 | Absent | Adopt | UX, B4 | S | P3: helps split SSH failures from DB failures |
| Net | SOCKS5 proxy | 0.58.0 | Absent | Skip | B4 | M | P3: no persona demand recorded |
| Net | Tunnel command (`kubectl port-forward`, `aws ssm`) | 0.73.0 | Absent | Adapt later | B4 | M | P3: real Linux use, but process supervision and threat review first |
| Net | Transport throughput readout | 0.73.0 | Absent | Skip | | | Low value |
| TLS | TLS modes and client certs | 0.2.0 | Present: `crates/core/src/tls.rs`. U5 recorded | Have | | | |
| Cloud | AWS IAM, Cloud SQL IAM, Entra ID | 0.45.0, 0.66.0, 0.80.0 | Absent. Cloud SQL IAM recorded | Recorded | | | |
| Cloud | Kerberos for SQL Server | 0.58.0 | Present (B4-21) | Have | | | |

### SQL editor

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| Editor | Qualified, alias-aware completion | 0.5.0, 0.49.0 | Present: `app/ui/editor/completion_provider.rs`. U3 recorded | Have | | | |
| Editor | Dialect operators, functions and types in completion | 0.65.0 | Partial: shared keyword list in `app/ui/editor/schema.rs`. Type completion recorded in the 10-18 audit | Recorded | | | |
| Editor | Enum labels offered after `WHERE col =` | 0.65.0 | Absent | Adapt | UX, B3 | S | P3: enum metadata already feeds the grid picker |
| Editor | Keyword case follows typing, or auto uppercase | 0.30.1, 0.75.0 | Absent | Adapt | UX | S | P3: a preference on the completion provider |
| Editor | Format query, selection only, undoable | 0.51.0 | Present: `format_plan::format_script` in `app/ui/editor/mod.rs`. Selection-only behavior not verified | Have | | | Guard: see edge case E30 |
| Editor | Favorites with keyword expansion and `;;` cursor mark | 0.19.0, 0.55.0 | Absent: favorites exist (Ctrl+D) but no expansion | Adapt | UX | S | P2: map to `GtkSourceSnippet`, which supports focus positions |
| Editor | Multi-cursor | n/a | Absent. UI-22 #552 recorded | Recorded | | | |
| Editor | Vim keys | 0.9.0, 0.40.0 | Present: `editor_vim_mode` in `app/services/preferences.rs` | Have | | | |
| Editor | Find and replace | 0.75.0 | Present: `app/ui/editor/find_bar.rs` | Have | | | |
| Editor | Invisible character and smart-quote warnings | 0.74.0 | Present: "SQL warnings" button, `app/ui/editor/diagnostics.rs` | Have | | | |
| Editor | Statement highlight and navigation | 0.67.0 | Present: `app/ui/editor/statement_band.rs`, `statement_cursor.rs` | Have | | | |
| Editor | Per-statement run marks in gutter | 0.67.0 | Partial: ticks and crosses after a run, `app/ui/editor/run_marks.rs`. No click-to-run | Adapt | UX | S | P3: `GtkSourceGutterRendererPixbuf` activate signal |
| Editor | Code folding | 0.67.0 | Present: `app/ui/editor/folding.rs` | Have | | | |
| Editor | Open and save `.sql` files | 0.26.0 | Present: `app/ui/app/editor_files.rs` | Have | | | |
| Editor | Changed-on-disk notice for an open `.sql` file | 0.76.0 | Absent | Adopt | UX | S | P2: `GFileMonitor` plus an `AdwBanner`. Prevents silent overwrite |
| Editor | Per-tab database or schema picker | 0.54.0, 0.81.0 | Absent. Workspace identity #1054 recorded | Recorded | | | |
| Editor | Split editor | n/a | Present (BookiE only): `app/ui/editor/split_view.rs` | Have | | | |
| Editor | Editor zoom (Ctrl+plus, Ctrl+minus) | 0.81.0 fix mentions it | Absent | Adopt | UX | S | P3: CSS font scale on the view |
| Editor | Theme choice, import of VS Code themes | 0.18.0, 0.81.0, 0.82.0 | Partial: fixed light and dark schemes, `apply_editor_scheme` in `app/ui/editor/schema.rs` | Adapt | UX | S | P2: list `StyleSchemeManager` schemes (users drop Omarchy or Catppuccin XML into `~/.local/share/gtksourceview-5/styles`). Skip a theme editor |

### Query execution

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| Exec | Multiple statements, one result each | 0.1.1, 0.27.0 | Present: `app/ui/editor/outcomes.rs` | Have | | | |
| Exec | Result tabs named after their statement; picking one moves the caret | 0.67.0 | Partial: drop-down after five results, no statement label link | Adopt | UX | S | P2: makes multi-statement output readable |
| Exec | Run menu: Run All, Run Without Limit, Clear Results | 0.75.0 | Partial: run whole script and run at cursor | Skip | | | Existing shortcuts cover it |
| Exec | Cancel running query | 0.33.0 | Present: Esc, `app/ui/editor/mod.rs` | Have | | | |
| Exec | Running indicator on the tab | 0.73.0 | Present: `page.set_loading` in `app/ui/app/workspace_tabs.rs` | Have | | | |
| Exec | Named parameters | 0.36.0 | Present: `app/services/query_parameters.rs`, `app/ui/parameters_dialog.rs` | Have | | | |
| Exec | Pin results | 0.27.0, 0.61.0 | Present: `app/ui/editor/pinned.rs` | Have | | | |
| Exec | EXPLAIN tree, diagram, ANALYZE, plan compare | 0.29.0, 0.65.0, 0.68.0, 0.73.0 | Partial: `app/ui/explain_tree.rs`. Recorded in feature comparison | Recorded | | | |
| Exec | Plan opens as a result tab, not a dialog | 0.65.0 | Absent: `app/ui/explain_dialog.rs` is a dialog | Adapt | UX | S | P3: keeps data and plan side by side |
| Exec | Timing breakdown, server messages | 0.72.0, 0.76.0 | Absent. #550 recorded | Recorded | | | |
| Exec | Desktop notification when long work finishes | 0.67.0 | Partial: queries only, `app/ui/editor/finish_notice.rs` | Adapt | UX | S | P3: extend to export, import and backup |
| Exec | Charts over results | 0.67.0 | Absent. Chart facets recorded in 10-20 analysis | Recorded | | | |
| Exec | Dangerous statement confirmation | 0.4.0 | Present: PolicyGuard approval, `app/services/gtk_approval.rs` | Have | | | |
| Exec | Hash-chained local execution log | 0.67.0 | Present: `crates/storage/src/audit_journal.rs` | Have | | | |
| Exec | Query Insights: most run, slowest, getting slower | 0.66.0 | Absent | Adapt | UX | M | P3: computed from local history only. No telemetry |

### Data grid

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| Grid | Inline edit, insert, delete, duplicate row | early | Present: `app/ui/grid/editing.rs`, `app/ui/grid/context_menu.rs` | Have | | | |
| Grid | Pending row marks (new, modified, deleted) | 0.74.0 | Present: `app/ui/grid/column.rs` | Have | | | |
| Grid | Set NULL by key | 0.73.0 | Present: Ctrl+Shift+N | Have | | | |
| Grid | Set Value menu: DEFAULT, `NOW()`, `CURRENT_DATE`, generate UUID or UUIDv7 | 0.40.2, 0.82.0 | Absent | Adapt | B3 then UX | M | P2: common edit. Needs a typed "SQL expression" pending value. 0.82.0 fixed functions saved as quoted text |
| Grid | Fill Column across loaded rows | 0.45.0 | Absent | Adapt | UX | S | P3: stage as one undo step |
| Grid | Paste TSV block | 0.37.0 | Present: `app/ui/browse_tab/paste.rs` | Have | | | |
| Grid | Rectangular cell selection | 0.46.0 | Absent: row selection only | Skip | UX | L | P3: `GtkColumnView` has no cell selection model |
| Grid | Copy as CSV, JSON, Markdown, INSERT, UPDATE, IN clause | 0.18.0, 0.43.1 | Present: `app/ui/grid/context_menu.rs`, `app/ui/app/row_ops.rs` | Have | | | |
| Grid | Copy all values of a column; Select Column | 0.43.1, 0.80.0 | Absent. Select Column recorded | Adopt | UX | S | P3: header menu item |
| Grid | Filters, saved presets, filter by value, raw SQL | 0.27.0, 0.76.0 | Present: `app/ui/filter_strip.rs`, `app/services/named_filter_presets.rs` | Have | | | |
| Grid | Per-rule on/off switch and an all-rules switch | 0.49.0, 0.51.1 | Absent | Adopt | UX | S | P3: `GtkCheckButton` per rule row |
| Grid | Column value filter (pick distinct loaded values) | 0.53.0 | Partial: `app/ui/grid/local_filter.rs` | Skip | | | Filter by value covers it |
| Grid | Multi-column sort (Shift+click) | 0.4.0 | Absent: one sort key, `app/services/browse_query/order.rs`, `app/ui/grid/local_sort.rs` | Adopt | UX, B3 review | M | P2: frequent in browse work |
| Grid | Pagination, page size | 0.45.0 | Present: `app/ui/browse_tab/chrome.rs` | Have | | | |
| Grid | Jump to page number | 0.45.0 | Absent | Adopt | UX | S | P3: click the "Rows x to y" label to open a spin button |
| Grid | Estimated count, Count exactly | 0.62.0 | Absent. #549 recorded | Recorded | | | |
| Grid | Hide, reorder, persist columns | 0.18.0, 0.22.1 | Present: `app/ui/grid/column_visibility.rs`, `column_order.rs` | Have | | | |
| Grid | Size to fit (double-click divider), Size all | 0.27.0, 0.57.0 cap | Absent | Adopt | UX | S | P2: measure with Pango over visible rows, cap at half the viewport |
| Grid | Keyboard column resize | Linux #3566 | Absent. Recorded in 10-20 analysis | Recorded | | | |
| Grid | Row-number gutter, sticky on horizontal scroll | 0.22.1, 0.73.0 | Absent | Adapt | UX | M | P3: helps "row 412" talk; must not join selection |
| Grid | Jump to column | 0.72.0 | Present: `app/ui/grid/column_jump.rs` | Have | | | |
| Grid | Find in loaded rows | 0.67.0 | Present: `app/ui/grid/row_find.rs` | Have | | | |
| Grid | Search all rows on the server | 0.67.0 | Absent | Adapt | UX, B3 | M | P3: needs a guarded, quoted `WHERE` across text columns |
| Grid | Highlight rules (color rows by value) | 0.74.0 | Absent | Skip | | | P3: nice, not core |
| Grid | Display As per column (UUID in `BINARY(16)`, epoch integers, text in binary) | 0.28.0, 0.71.0 | Absent | Adapt | B3 | M | P2: display-only formats. Must keep ADR 0007 exact values and copy rules |
| Grid | JSON tree viewer with filter, links, color swatches | 0.34.0, 0.70.0, 0.80.0 | Partial: pretty text only, `app/ui/grid/value_viewer.rs` | Adapt | UX | M | P2: `GtkTreeListModel` + `GtkTreeExpander`, search entry, copy path or value |
| Grid | Show Row as JSON | 0.70.0 | Present: context menu | Have | | | |
| Grid | Row inspector editing, NULL and DEFAULT menu, Tab between fields, field search | 0.73.0 | Partial: read-only, `app/ui/row_inspector.rs` | Adapt | UX | M | P2: wide tables are painful to edit in the grid |
| Grid | FK navigation | 0.7.0 | Present: `app/ui/app/referenced_row.rs` | Have | | | |
| Grid | FK value picker | 0.2.0, 0.72.0 | Absent. #549 recorded | Recorded | | | |
| Grid | FK preview popover (Space or Ctrl+Return) | 0.27.3, 0.30.0 | Absent | Adopt | UX | S | P2: a `GtkPopover` reusing the referenced-row query, read only |
| Grid | Back and Forward through a tab's browse history | 0.67.0 | Absent | Adopt | UX | M | P2: FK jumps lose the way back today |
| Grid | ENUM and SET pickers | 0.3.0, 0.43.0 | Present: `app/ui/grid/choice_editor.rs` | Have | | | |
| Grid | Date and time picker | 0.2.0, 0.45.0 | Present: `gtk::Calendar` in `app/ui/grid/editing.rs` | Have | | | Guard: E24, E25 |
| Grid | Array element editor (PostgreSQL arrays) | 0.65.0, 0.75.0 | Absent | Adapt | B3 then UX | M | P3: needs array-dimension contract |
| Grid | Geometry as WKT, map view | 0.47.0, 0.74.0, 0.80.0 | Absent. Recorded (map, #902) | Recorded | | | |
| Grid | Image preview for blob cells | 0.73.0 | Absent: hex dump only | Adapt | UX | S | P3: `gdk::Texture::from_bytes` in the viewer, size capped |
| Grid | Hex dump for binary | 0.19.0 | Present: `app/ui/grid/value_viewer.rs` | Have | | | |
| Grid | Large values lazy loaded | 0.24.0 | Present: 8 KiB preview, PERF-10 | Have | | | |
| Grid | Selection statistics | 0.80.0 | Present: `app/ui/browse_tab/selection/stats.rs` | Have | | | |
| Grid | Confirm permanent delete on save | 0.56.0 | Present: `confirm-destructive` preference | Have | | | |
| Grid | New UUID for an empty UUID primary key on Add Row and Paste | 0.82.0 | Absent | Adapt | B3 | S | P3: only when the server has no default |

### Structure and DDL

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| DDL | Columns, indexes, FKs with SQL preview | 0.34.0, 0.4.0 | Present: `app/ui/structure_tab/` | Have | | | |
| DDL | Column comments | 0.54.0 | Present: `app/ui/structure_tab/columns.rs` | Have | | | |
| DDL | Table comments | 0.80.0 | Absent. Recorded | Recorded | | | |
| DDL | Check constraints tab, generated columns | 0.69.0 | Absent | Adapt | B3 then UX | M | P3: read-only listing first |
| DDL | Triggers tab with create, edit, drop | 0.52.0 | Partial: listing in `app/ui/catalog_dialog.rs`. Toggle recorded | Recorded | | | |
| DDL | Show and Copy DDL for tables, views, materialized views | 0.74.0 | Partial: tables only ("Show CREATE TABLE", `app/ui/sidebar_row.rs`) | Adopt | UX, B3 | S | P3 |
| DDL | Read-only source for routines and triggers, Open in Editor | 0.68.0 | Absent | Adapt | UX | S | P3: GtkSourceView read-only buffer |
| DDL | Rename table, schema, database inline | 0.69.0 | Absent in UI | Adopt | UX | S | P3: `sql_ddl` already builds renames |
| DDL | Truncate table from the sidebar | 0.29.0 | Absent (Drop is present) | Adopt | UX | S | P3: same guarded dialog as Drop |
| DDL | Maintenance: VACUUM, ANALYZE, REINDEX, OPTIMIZE | 0.29.0 | Absent | Adapt | UX, B4 policy | M | P3: needs PolicyGuard classes per command |
| DDL | Refresh materialized view (concurrently when allowed) | 0.74.0 | Absent | Adopt | UX | S | P3 |
| DDL | Create view, create schema, create database | 0.2.0, 0.75.0 | Absent | Adapt | UX | M | P3: template into a SQL tab is enough |
| DDL | Types listing (enums, domains) | 0.72.0 | Present: catalog "Types" | Have | | | |
| DDL | Users and roles editing | 0.57.0 | Partial: read-only roles and privileges in catalog | Skip | | | Admin console is a non-goal |
| DDL | Partitions under parent table | 0.75.0 | Absent. Recorded | Recorded | | | |
| DDL | Column reorder through table rebuild | 0.70.0 | Absent | Skip | | | Risky rebuilds, low value |
| ERD | ER diagram with crow's foot, export PNG and SQL | 0.30.0, 0.53.0, 0.65.0 | Absent. Recorded | Recorded | | L | Adapt later with a custom `GtkWidget` snapshot and the plan-diagram zoom code |

### Import and export

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| I/O | CSV import with remembered mapping | 0.49.0, 0.77.0 | Present: `app/ui/import_dialog.rs`, `app/services/csv_import_mappings.rs` | Have | | | |
| I/O | JSON, NDJSON, XLSX, SQL import | 0.48.0, 0.72.0 | Absent. Recorded | Recorded | | | |
| I/O | Import encodings | 0.77.0 | Recorded | Recorded | | | |
| I/O | Import error modes (stop and roll back, stop and commit, skip) and a skipped-rows report | 0.33.0, 0.72.0 | Absent | Adapt | UX, B4 | M | P2: a failed row today ends the import with no partial plan |
| I/O | Export CSV, JSON, Markdown, HTML, XML, SQL, XLSX | 0.22.0, 0.72.0 | Present: `app/ui/export_dialog.rs` | Have | | | |
| I/O | Export remembers options, Reset to Defaults | 0.49.0 | Present: `app/ui/export_dialog.rs` | Have | | | |
| I/O | NDJSON layout | 0.72.0 | Absent | Adopt | B3 | S | P3 |
| I/O | Multi-table export tree, per-table WHERE | 0.72.0 | Absent. Full export refused by ADR 0014 | Skip | | | |
| I/O | Backup and restore with `pg_dump` | 0.41.0 | Present: `app/ui/app/backup.rs`, `crates/dump/` | Have | | | |
| I/O | Backup for MySQL, SQLite, MongoDB | 0.72.0, 0.73.0 | Absent | Adapt later | B4 | M | P3: after snapshot work #547 |
| I/O | Copy To or Transfer between connections | 0.70.0, 0.72.0 | Absent | Skip | | L | P3 |
| I/O | Compare and Sync | 0.68.0 | Absent. Recorded | Recorded | | | |
| I/O | Data Files window | 0.76.0 | Absent. Recorded | Recorded | | | |

### History and favorites

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| Hist | Docked history with search, status, source, time filters, pin, export | 0.65.0 | Present: `app/ui/history_dialog.rs` | Have | | | |
| Hist | Pause history recording | 0.65.0 | Absent | Adopt | UX | S | P3: useful before pasting sensitive SQL; secret filtering already exists |
| Hist | Clear only what the panel shows | 0.65.0 | Partial: delete selected, clear all | Skip | | | |
| Fav | Saved queries, rename, delete | 0.19.0 | Present: `app/ui/saved_queries_dialog.rs` | Have | | | |
| Fav | Folders, global versus per-connection | 0.76.0, 0.80.0 | Absent. Recorded | Recorded | | | |
| Fav | Linked SQL folders, Git status, version history | 0.39.1, 0.76.0 | Absent. Recorded | Recorded | | | |
| Nav | Recent tables per connection | 0.56.0 | Absent | Adopt | UX | S | P2: fast return to work after restart |
| Nav | Star a table as favorite | 0.47.0 | Absent | Adopt | UX | S | P2: same store as recent tables |

### Sidebar, navigation and quick switch

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| Side | Search, schema groups, collapse | 0.40.0, 0.66.0 | Present: `app/services/sidebar_tree.rs` | Have | | | |
| Side | Schema filter | 0.80.0 | Present. Recorded | Have | | | |
| Side | Reveal table in sidebar | n/a | Present: Ctrl+Shift+L | Have | | | |
| Side | Remember expanded nodes per connection | 0.58.0 | Not verified: collapse logic in `sidebar_tree.rs`, persistence not found | Check | UX | S | P3 |
| Side | Multi-select tables for bulk drop or export | 0.65.0 | Absent | Skip | | | P3 |
| Side | Routines and triggers as sidebar sections | 0.68.0 | Partial: catalog dialog only | Adapt | UX | M | P3 |
| Quick | Open Quickly: commands, favorites, tabs, connections, tables | 0.51.0, 0.65.0 | Present: `app/services/quick_switcher.rs`, `app/ui/quick_switcher_dialog.rs` | Have | | | |
| Quick | Recent queries in Open Quickly; Alt+Return opens in a new tab | 0.51.0 | Absent | Adopt | UX | S | P3 |
| Quick | Database switcher | 0.14.1 | Present: `app/ui/app/database_switcher.rs` | Have | | | |

### Tabs and windows

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| Tabs | Preview tabs, Keep Tab, reuse setting | 0.17.0, 0.67.0 | Present: `app/services/workspace_state/preview_tabs.rs`, `app/ui/app/workspace_tabs.rs` | Have | | | |
| Tabs | Close others, close to the right | 0.61.0 | Present: `app/ui/app/workspace_tabs/bulk_close.rs` | Have | | | |
| Tabs | Reopen closed tab | 0.57.0 | Present: Ctrl+Shift+T | Have | | | |
| Tabs | MRU Ctrl+Tab | 0.76.0 | Present (user guide) | Have | | | |
| Tabs | Drag reorder, middle-click close | 0.67.0, 0.71.0 | Present by `AdwTabBar` default | Have | | | |
| Tabs | Unsaved dot | 0.67.0 | Present: `set_needs_attention`, `app/ui/app/workspace_preview.rs` | Have | | | |
| Tabs | Move tab to a new window, drag out | 0.70.0 | Absent: no `create-window` handler | Adapt | UX | M | P3: only within the same connection, carrying pending edits |
| Tabs | Restore per-tab caret, scroll, page, sort | 0.51.0, 0.67.0 | Partial: tabs and editor text restored, `app/services/workspace_state.rs`. No caret, page or sort | Adopt | UX | S | P2: restart should land where you were |
| Win | Ask about unsaved work in every tab on close and quit | 0.57.0, 0.61.0 | Present: `app/ui/app/init_window.rs`, `workspace_close.rs` | Have | | | |
| Win | Multiple windows | 0.10.0 | Present: New Window | Have | | | |

### Safety, MCP, keyboard, settings, accessibility, performance

| Area | Feature | Upstream | BookiE status + path | Rec | Lane | Effort | Priority |
|---|---|---|---|---|---|---|---|
| Safe | Safe Mode levels, read-only | 0.17.0 | Present as PolicyGuard, environments, read-only | Have | | | |
| Safe | Minimum level from managed config | 0.67.0 | Present: policy file | Have | | | |
| Safe | Restore Previous Values after commit (Data Rewind) | 0.69.0 | Absent | Skip | B4 | L | P3: needs before-images; overlaps snapshots #547 |
| MCP | Server, tokens, scopes, connection allowlist | 0.36.0, 0.37.0 | Present: `crates/mcp/`, `app/ui/mcp_preferences.rs` | Have | | | |
| MCP | Client setup snippets (Claude Code, Cursor, Zed) | 0.36.0, 0.40.0 | Absent: endpoint shown, no config snippet | Adopt | UX | S | P2: lowers setup errors. Show token once, never write it to a file silently |
| MCP | Activity window: clients, calls, filter, export | 0.38.0 | Absent: audit journal has no GUI viewer | Adapt | UX, B4 | M | P1: governed MCP is the product bet. Users must see what agents ran |
| MCP | In-client destructive confirmation | 0.35.0, 0.67.0 | Present: `app/services/approval_router.rs` | Have | | | |
| MCP | Prompt templates, argument completion, subscriptions | 0.67.0 | Not compared in this slice | | B4 | | |
| Keys | Shortcuts window | n/a | Present: `app/ui/app/shortcuts.rs` | Have | | | |
| Keys | Rebindable shortcuts | 0.5.0 | Absent | Skip | | | P3: GNOME apps rarely do this |
| Keys | Focus Object List, Editor, Results | 0.75.0 | Absent | Adopt | UX | S | P2: F6 cycles panes (GNOME convention) plus direct accels |
| Set | Preferences pages | n/a | Present: `app/ui/preferences.rs` | Have | | | |
| Set | Saved Customizations list with reset | 0.58.0 | Absent | Adopt | UX | S | P3: lists per-table layouts and filters |
| A11y | Header sort state and cell position for screen readers | 0.37.0 | Partial: DOC-3 recorded | Recorded | | | |
| A11y | Destructive alerts default to Cancel | 0.65.0 | Present: Drop and Delete use `set_default_response("cancel")`, `app/ui/app/structure.rs`, `app/ui/browse_tab/row_ops.rs` | Have | | | |
| Perf | Only build columns near the viewport for very wide results | 0.67.0 | Not measured: `GtkColumnView` recycles rows, not columns | Check | UX | S | P2: measure a 300-column result first |
| Perf | Lazy load of restored tabs (front tab only) | 0.55.0 | Not verified | Check | UX | S | P2: see E17 |
| Perf | Server activity with kill | 0.31.0 | Present: `app/ui/activity_dialog.rs` | Have | | | |

## 2. GTK adaptation notes for selected gaps

Each note names the widget pattern and one acceptance idea.

1. **Open files and URLs from the desktop and CLI.** Add `HANDLES_OPEN | HANDLES_COMMAND_LINE` to the `adw::Application`. Add `MimeType=application/vnd.sqlite3;application/x-sqlite3;` to the desktop file. Sniff the SQLite header and DuckDB magic, not the extension (0.70.0). A URL argument opens the connect dialog prefilled and never connects without a click. Acceptance: `bookie file.db` and a file-manager double-click each open one window; a second launch reuses `single_instance.rs`.
2. **MCP and audit activity window.** An `AdwWindow` with a `GtkColumnView` over the audit journal: time, consumer (GUI, MCP token name, agentd), connection, statement digest, outcome. A `GtkSearchEntry` and a consumer `GtkDropDown` filter it. Read only, with Export CSV. Acceptance: an MCP call shows within one refresh and refused calls show their refusal reason.
3. **Back and Forward per tab.** Keep a bounded stack of (table, filter, sort, page) per browse tab. Bind Alt+Left and Alt+Right and add two `GtkButton`s in the tab chrome. Keep FK jump filters and pending edits with the entry they belong to (0.63.0, 0.40.0). Acceptance: FK jump then Alt+Left restores the earlier filter and scroll row.
4. **FK preview popover.** A `GtkPopover` anchored to the cell, filled from the existing referenced-row query, with Open and Open in New Tab buttons. Space toggles it when the grid has focus and no editor is open. Acceptance: Esc closes it and focus returns to the same cell.
5. **Editable row inspector.** `AdwPreferencesGroup` with one `AdwEntryRow` per column, type in the subtitle, and a suffix `GtkMenuButton` for NULL and DEFAULT. Tab and Shift+Tab move between rows. A `GtkSearchEntry` filters fields. Edits stage into the same change tracker as grid edits. Acceptance: one inspector edit equals one undo step (0.75.0 fixed one step per character).
6. **JSON tree viewer.** A `GtkStack` with Text and Tree pages. Tree uses `GtkTreeListModel` with `GtkTreeExpander` rows. Filter with plain text or `/regex/`; matches reveal ancestors (0.67.0). Copy value and Copy path in the row menu. Acceptance: exact number spelling kept (ADR 0007), and a 1 MiB value stays responsive.
7. **Set Value submenu.** In the cell `GMenu`: DEFAULT, NULL, and dialect functions filtered by column type, plus Generate UUID. B3 must define a pending "SQL expression" value so `NOW()` is never stored as text (0.82.0). Acceptance: duplicating a row with stored text `CURRENT_DATE` keeps the text (0.82.0).
8. **Multi-column sort.** Shift+click adds a key. Show priority as "1 ▲" in the header label. Browse sorts send a multi-key `ORDER BY` through `order.rs`; result grids sort locally with stable compare. Acceptance: sort keys survive hide or show of a column (0.67.0) and a reused tab (0.73.0).
9. **Recent and starred tables.** A "Recent" and "Starred" `GtkListBox` section at the top of the sidebar, keyed by connection, database, schema and table. A star toggle in `sidebar_row.rs`. Drop the entry on DROP or rename (0.77.0). Acceptance: restart keeps both lists; a dropped table leaves both.
10. **Favorite snippets.** Register each favorite with a keyword as a `GtkSourceSnippet`. Translate `;;` to a focus position. Acceptance: keyword then Tab inserts the body and places the caret at the mark.
11. **Statement-labelled results.** Replace the result drop-down labels with a first-line snippet of the statement. Selecting a result moves the editor caret to that statement and flashes the statement band. Acceptance: labels stay correct after a pin and rerun.
12. **Pane focus.** `win.focus-sidebar`, `win.focus-editor`, `win.focus-results` actions with accels, and F6 to cycle. Acceptance: Orca announces the focused pane name.
13. **Per-tab restore detail.** Add caret offset, scroll row, page index and sort keys to `WorkspaceTabRecord`. Restore only the front tab eagerly (0.55.0). Acceptance: restart shows the same page and caret in the front tab; other tabs load on first view.
14. **Import from other Linux clients.** Read DBeaver `data-sources.json`, DataGrip `dataSources.xml`, Beekeeper's SQLite store. Preview in an `AdwDialog` list with Replace, Add Copy, Skip per row (0.49.0). Passwords are not imported unless the source keeps them in a readable form, and then only into Secret Service after an explicit tick. Acceptance: an import never overwrites without a choice, and SSH settings carry over.
15. **Copy URL and MCP client snippet.** A connection menu item "Copy Connection URL" that omits the password. In MCP preferences, a `GtkDropDown` of clients and a Copy button that renders the JSON with the endpoint and a token placeholder. Acceptance: no secret enters the clipboard unless the user clicks Copy Token.
16. **New SQLite or DuckDB file.** A "New…" button beside Browse that opens `GtkFileDialog.save`. Acceptance: Test on a new path creates nothing until Connect.
17. **Display As.** A header menu radio group (Default, Text, Hex, UUID, Unix seconds, Unix milliseconds). Display only, keyed per connection, database, schema, table (0.58.0). Copy follows the display choice only for single-cell copy. Acceptance: exports keep the raw typed value.
18. **Import error modes.** Three `AdwComboRow` choices in the import dialog. A skipped-rows report saved as CSV with line and error. Acceptance: Stop and Roll Back leaves the table unchanged; cancel is not recorded as a failure (0.65.0).
19. **Startup SQL.** A multi-line field in the connect dialog. Each statement passes PolicyGuard. Re-run after every reconnect, before any queued query (0.73.0, 0.74.0). Acceptance: `SET search_path` survives a forced reconnect.
20. **Size to fit.** Header menu "Size to Fit" and "Size All to Fit". Measure header and visible rows with Pango, cap at half the viewport (0.57.0). Persist through the existing width store. Acceptance: hidden columns stay hidden after a resize (0.56.0).

## 3. UX edge cases to guard in the GTK app

These are upstream regressions. They are test prompts, not BookiE defects. "BookiE evidence" says what the source shows today.

| ID | Edge case | Upstream fix | BookiE evidence | Lane | Test idea |
|---|---|---|---|---|---|
| E1 | Switching database leaves the previous database's tab on screen; same-named table in another database shows as open in the switcher | 0.81.0 (#3436), 0.75.0 | Recorded under #1054. Quick switcher keys relations by schema and name only | UX | Open `a.users`, switch to db `b`, open Open Quickly: `users` must not show as open |
| E2 | Table info or row counts from a same-named table in another schema or database | 0.81.0 | Not checked | UX | Two schemas with `users`; inspector and counts must differ |
| E3 | Unsaved grid edits not kept with their tab after jumping from another window | 0.78.0 | Change tracker is per tab | UX | Edit, switch window, return: dot and values intact |
| E4 | Undo in one tab replays another tab's changes | 0.77.0 | Not checked | UX | Edit in two tabs, Ctrl+Z in tab 2 only reverts tab 2 |
| E5 | Closing a background tab with unsaved work leaves you on its neighbor | 0.76.0 | Not checked | UX | Close a non-selected dirty tab via its menu; selection stays on the current tab |
| E6 | Bulk close asks about another database's work, or saves the wrong tab | 0.68.0 | `bulk_close.rs` exists | UX | Close Others with two dirty tabs; one prompt per tab, correct names |
| E7 | Cancel on a discard prompt still applies the filter, or leaves a sort arrow | 0.73.0, 0.74.0, 0.76.0 | Not checked | UX | Pending edit, apply filter, Cancel: filter strip and header unchanged |
| E8 | Hiding or showing a column silently drops unsaved edits | 0.73.0 | Not checked | UX | Edit cell, hide another column: edit stays pending |
| E9 | Staged drop runs against the database in front at save time | 0.69.0 | Structure save path not checked for this | UX, B4 | Stage drop in db A, switch to B, save: refused or runs in A |
| E10 | Edits saved against wrong rows after a tab reused a previous table's key | 0.78.0 | Row identity in `change_tracker_row_identity.rs` | UX, B3 | Reuse preview tab across two tables with different PKs, edit, save |
| E11 | After a structure change, tabs show old columns and edits use the old PK | 0.76.0 | Not checked | UX | Add column in Structure; open data tab shows it and saves with new metadata |
| E12 | Inline editor or popover editor stays open over a different row after refresh, sort or filter | 0.66.0, 0.75.0 | `close_edits.rs` finishes edits and refuses while preedit is active | UX | Open date popover, press F5: popover closes or refresh waits |
| E13 | Grid jumps to top after a failed page change | 0.75.0 | Not checked | UX | Kill connection, press Next: stays on current rows with an error |
| E14 | Scroll position lost when switching tabs | 0.68.1 | `AdwTabView` keeps child widgets | UX | Scroll, switch away and back: same row |
| E15 | Selection lost on tab switch or result view change | 0.73.0 | Known limitation: selection follows row identity within a result | UX | Select rows, switch tab and back: same selection |
| E16 | Stop interrupts a save or schema change | 0.64.0 | Policy cancel paths exist; save cancel not checked | B4 | Press Esc during save: save completes or reports unknown, never half |
| E17 | Restored tabs all load at launch and flood errors; restored tab on a reconnecting link shows "Not connected" | 0.52.0, 0.55.0 | Not verified | UX | Restore 10 tabs over a slow SSH link: one load, no error dialogs |
| E18 | Quit erases saved tabs when a window had not loaded its tabs yet | 0.62.0 | Workspace persistence in `workspace_persist.rs` | UX | Quit while a window is still connecting: tabs survive next start |
| E19 | Cancelled connect overwrites a later successful one; cancel leaves the SSH tunnel open | 0.43.2, 0.57.1 | "Connection cancelled." path in `app/ui/app/connection.rs` | B4 | Cancel, connect again quickly: second wins; no listening port left |
| E20 | Session state lost after automatic reconnect (timeout, database, startup SQL) | 0.73.0, 0.74.0 | Monitor swaps connections | B4 | Set query timeout, force reconnect, run a slow query: timeout still applies |
| E21 | Stopping a MySQL query cancels the next one | 0.63.0, 0.76.0 | Not checked | B4 | Stop, then run a new query at once: it succeeds |
| E22 | Stop shows a red error and records a failure in history | 0.63.0 | History has a cancelled status | UX | Cancel: history shows Cancelled, no error banner |
| E23 | Escape on autocomplete moves focus out of the editor | 0.56.2 | Not checked | UX | Type, open completion, Esc: caret still in editor |
| E24 | Date picker confirmed without change rewrites the cell | 0.69.0 | Not checked | UX, B3 | Open picker, close with OK: no pending change |
| E25 | Timestamp in a DST gap, or offset values shown one day in grid and another in picker | 0.69.0, 0.74.0 | B3 temporal contract exists | B3 | Fixture with a DST-gap value; grid and picker agree |
| E26 | New query tab loses focus after the first characters, or sidebar filter keeps focus | 0.53.0, 0.58.0 | Not checked | UX | Ctrl+T then type 20 chars: all land in the editor |
| E27 | Opening a table by keyboard does not move focus into the grid | 0.47.0 | Not checked | UX | Sidebar Enter: arrow keys move grid cells |
| E28 | Esc in a search popover closes it before clearing the text | 0.47.0 | Not checked | UX | Open Quickly with text: first Esc clears, second closes |
| E29 | Right-click outside the selection acts on the old selection, including Delete | 0.65.0 | Not checked | UX | Select rows 1-2, right-click row 5, Delete: only row 5 |
| E30 | Format Query not undoable, or formats everything when text is selected | 0.51.0 | Formatter present | UX | Select one statement, format, Ctrl+Z: one step back |
| E31 | Pasting a very large script stalls or drops highlighting | 0.24.0, 0.66.0 | Not checked | UX | Paste 5 MB SQL: app stays responsive |
| E32 | Saving over a `.sql` file changed on disk | 0.76.0 | No file monitor found | UX | Edit file outside, Ctrl+S in app: prompt before overwrite |
| E33 | Rows-per-page change on a later page leaves a wrong page label | 0.67.0 | Not checked | UX | Page 3, change page size: back to page 1 with correct label |
| E34 | History panel drops loaded pages and selection after switching connection | 0.78.0 | Not checked | UX | Scroll history, switch connection and back |
| E35 | Saved filters, layouts and favorites kept for a dropped or renamed table | 0.77.0 | Not checked | UX | Drop table with a saved filter; recreate: no stale filter |
| E36 | Display formats and layouts shared by same-named tables in different schemas | 0.56.0, 0.58.0 | Not checked: key shape in `persistence_stores.rs` | UX | Hide a column in `a.t`; `b.t` keeps all columns |
| E37 | Theme or dark-mode change not repainting an open editor or grid | 0.66.0, 0.81.0 | `apply_editor_scheme` reads `StyleManager` | UX | Toggle dark mode with an editor open: scheme follows at once |
| E38 | Save message counts statements as rows | 0.69.0 | Not checked | UX | Save 3 edits touching 5 rows: message says 5 rows |
| E39 | An alert attaches to a transient popover and closes with it | 0.65.0 | Not checked | UX | Trigger an error from Open Quickly: alert is modal on the main window |
| E40 | Health monitor keeps waking after it gave up | 0.69.0 | `connection_monitor.rs` has backoff | B4 | Leave a dead connection 10 minutes: no periodic CPU wakeups after giving up |

## 4. Top 20 for the roadmap

Ranked by user value for the developer and Omarchy personas, fit with the governed-MCP bet, and cost.

| Rank | Feature | Lane | Effort | Why now |
|---|---|---|---|---|
| 1 | MCP and audit activity window | UX, B4 | M | The product bet is governed MCP. Users cannot see agent activity in the GUI today |
| 2 | Open `.sqlite`/`.duckdb` and URLs from file manager and CLI | UX | S-M | Basic Linux desktop integration; small diff |
| 3 | Back and Forward per browse tab | UX | M | FK navigation exists but has no way back |
| 4 | FK preview popover | UX | S | Reuses the referenced-row query; daily use |
| 5 | Editable row inspector | UX | M | Wide tables are hard to edit in a grid |
| 6 | JSON tree viewer with filter | UX | M | JSON columns are common in PostgreSQL work |
| 7 | Set Value menu with DEFAULT, functions and UUID | B3, UX | M | Common edit; needs a typed expression value first |
| 8 | Multi-column sort | UX, B3 review | M | Frequent browse need |
| 9 | Recent and starred tables in the sidebar | UX | S | Fast return after restart; large catalogs |
| 10 | Restore per-tab caret, page, scroll and sort | UX | S | Restart lands where you left off |
| 11 | Statement-labelled result tabs that move the caret | UX | S | Makes multi-statement output usable |
| 12 | Pane focus shortcuts and F6 cycling | UX | S | Keyboard and accessibility gain (DOC-3) |
| 13 | Favorite keyword snippets via `GtkSourceSnippet` | UX | S | Native API does the work |
| 14 | Import connections from DBeaver, DataGrip, Beekeeper | UX, B4 | M | Main migration path for Linux users |
| 15 | Copy connection URL and MCP client config snippet | UX | S | Cheap; fewer MCP setup errors |
| 16 | Changed-on-disk notice for `.sql` files | UX | S | Prevents silent overwrite |
| 17 | New SQLite or DuckDB file from the form | UX | S | Removes a dead end for file engines |
| 18 | Display As per column | B3 | M | Binary UUIDs and epoch integers are unreadable today |
| 19 | Import error modes and skipped-rows report | UX, B4 | M | Safer imports with a clear outcome |
| 20 | Size to Fit columns and a style scheme picker | UX | S | Two small polish items that users notice daily |

Next after these: startup SQL (B4), Open Quickly recent queries, rename and truncate from the sidebar, refresh materialized view, history pause, project-folder connection setup, Query Insights from local history.

## 5. Limits

- Presence checks are greps and UI string scans at 7c4cb3929. A Present row does not prove every engine works.
- Upstream items come from changelog text and directory names. Implementation was not read row by row.
- Edge cases marked "Not checked" need a reproduction before anyone files a defect.
