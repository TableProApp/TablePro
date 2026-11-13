# Roadmap

The work that makes the Linux and Windows apps complete daily-use clients, the core work under them, and the sync service and features every platform still lacks. The bar is the macOS app plus what the market expects from a daily-use client.

Written 2026-11-11 against main `8581bd6c7`, from code inventories of the macOS, Linux and Windows apps and the Rust core, and a survey of 20 other clients ([Sources](#sources)). The maintainer's answers of 2026-11-13 are under [Decisions](#decisions). What the Linux app does today is in [linux/docs/features.md](linux/docs/features.md).

## How to track

- Tick a box when its PR merges and write the PR after it: `- [x] Windows: #4321`.
- A partial PR leaves the box open and adds `partly #4321: <what is left>`.
- IDs never change. A new item goes at the end of its section with the next free number.
- Tier, from the survey: **CORE** every daily user expects it, **STD** most serious clients have it, **ADV** a pro-tier differentiator.
- `macOS: yes` means the macOS app has it; its code and docs are the reference. `paid` means it is a paid feature there.
- `needs C-07` names a core item that lands first.
- A `server` box is work in tablepro-cloud, outside this repository.
- Recount the progress table:

```sh
awk '/^## /{p=$0} /^ *- \[[ x]\]/{t[p]++} /^ *- \[x\]/{d[p]++} END{for(k in t) print d[k]+0"/"t[k]"  "k}' ROADMAP.md
```

## Order

1. Linux 0.1.0: the Linux items of Phase 0.
2. Phase 1, then Windows: the Windows items of Phase 0 and every CORE item of Phase 2, then the first public Windows release (D-04).
3. Phases 3 to 8, by tier and demand.

## Progress

| Section | Boxes | Done |
|---|---|---|
| Phase 0: Release blockers | 16 | 0 |
| Phase 1: Core enablers | 23 | 0 |
| Phase 2: Windows daily use | 62 | 0 |
| Phase 3: Standard features both apps lack | 116 | 0 |
| Phase 4: Advanced tier | 60 | 0 |
| Phase 5: Engines | 27 | 0 |
| Phase 6: Quality bars | 8 | 0 |
| Phase 7: Sync and teams | 15 | 0 |
| Phase 8: Beyond the market | 40 | 0 |
| Total | 367 | 0 |

## Where each app stands

**macOS**, the reference: 48 engine types (5 bundled driver plugins, 31 in the registry), and every survey tier up to ADV. Compare & Sync, Server Dashboard, Table Health, Query Insights, Data Rewind, EXPLAIN diagrams, charts, map mode, routine debugger, users and roles, backup and restore, an agent-mode AI with 15 providers, an MCP server with 47 tools, iCloud sync and Team features.

**Linux**, 0.1.0-beta.3: 9 engines from the core. Covers most of the CORE tier: connections with SSH, TLS and sockets, filters, editing with undo, completion, formatter, snippets, Vim, history, saved queries, structure editing, ER diagram, 7 export formats, dump and SQL import, AI chat, MCP with 11 tools, a CLI. Missing: all of admin and monitoring, query parameters, drawn plans, charts, schema compare, data transfer, backup through native tools, SOCKS, cloud IAM, users and roles, view and routine editing, the 10 paid features. 0.1.0 waits on [release criteria](linux/docs/releasing.md#release-criteria) 8 and 10.

**Windows**, unreleased: 9 engines through the FFI. Has the connection library (groups, tags, favourites), in-process SSH, TLS with remedies, paging and sort, table-row editing with SQL review, a Direct2D editor with highlighting and multiple cursors, run statement, selection or script with transactions, Safe Mode (3 levels), tab tear-out, session restore, an MSIX build. Missing most of the CORE tier past that: filters, value viewers, row details, FK navigation, copy formats, completion, formatter, history, saved queries, .sql files, export, import, structure, sidebar actions, undo of edits.

**Core**: the logic mostly exists, the FFI does not. `ddl`, `export`, `import`, `dump`, `filter`, history, saved queries, `ai`, `mcp`, `cli`, `account` and `foreign-import` are core code the FFI does not expose. The formatter, completion scope, script runner, key-based change tracker, copy renderer, highlight rules, Open Quickly and ER layout sit in `linux/crates/app`, GTK-free. Phase 1 moves both down so Windows builds on the code Linux already runs.

## What the market expects

- Top reasons users pick or leave a client: startup speed and memory, price model, engine breadth, native feel and dark mode, stability on big tables, OS availability, editor smarts, abandoned tools, trust (no forced AI, no required login), guards against production mistakes.
- Native on all three OSes is rare: most cross-platform clients are JVM (DataGrip, DBeaver, DbVisualizer) or Electron (Beekeeper, DbGate, Antares).
- Safe Mode is a stated reason to pick TablePlus. TablePro has it on every platform.
- Moving into STD during 2025-2026: an MCP server, AI with per-action consent, cloud IAM sign-in, a command palette, visual EXPLAIN, schema compare.
- Azure Data Studio retired on 2026-02-28. SQL notebooks now live only in the VS Code mssql extension.

## Principles

- Core first: logic both apps need lands in a core crate and the FFI before a Windows UI uses it. A Linux move keeps Linux's behavior and switches Linux to the core version in the same PR.
- Native UI per platform (`AGENTS.md`), no shared UI layer.
- Linux and Windows link their drivers at compile time for good ([core ADR 0025](core/docs/decisions/0025-linux-and-windows-link-their-drivers.md)). Oracle is blocked on a client library.
- One license and one feature gate on every platform: what is paid on macOS is paid on Linux and Windows (D-02).
- A new question that would reverse a decision goes under [Decisions](#decisions) as the next D item, and waits for the maintainer.

## Phase 0: Release blockers

### Windows first public release

- [ ] **R-01** RUSTSEC-2026-0459 (bundled SQLite before 3.54.0): `deny.toml` blocks a Windows release until sqlx allows libsqlite3-sys 0.39 and the pin is raised
- [ ] **R-02** Maintainer setup, `windows/RELEASING.md` steps 1-6: tag rulesets, Artifact Signing with a Public Trust profile, the OIDC app registration, the `windows-release` secrets, `WINDOWS_SIGNING_*` and `WINDOWS_PUBLISHER` (permanent after the first release), the `windows-winget` environment
- [ ] **R-03** Dry run of `release-windows.yml` from main: the x64 package, the bundle, install-and-start tests and winget validation, all unverified (ADR 0005)
- [ ] **R-04** Real hardware: Windows 10 build 17763, Native AOT, Mica on a GPU, TabView in the title bar on Windows 10, loading from a signed MSIX (ADR 0001, 0004)
- [ ] **R-05** Drop the Windows App SDK metapackage once Community Toolkit 8.3 is stable (41.8 MB of unused ONNX and DirectML per architecture)
- [ ] **R-06** Updates: an App Installer file or the Store, an in-app update check, stable and beta channels
- [ ] **R-07** Live-server Windows tests for the 7 engines no Windows suite connects to: MySQL, SQL Server, DuckDB, ClickHouse, Cassandra, MongoDB, Redis
- [ ] **R-08** Windows user guide on docs.tablepro.app and the download page
- [ ] **R-09** First `windows-v0.1.0` tag, once the rest of Phase 0 and every CORE item in Phase 2 are done; no public build before it (D-04)

### Linux 0.1.0

- [ ] **R-10** [Release criterion](linux/docs/releasing.md#release-criteria) 8: the manual pass with Orca, the keyboard alone, High Contrast, 1.5x text and a right-to-left locale
- [ ] **R-11** Release criterion 10: a dated week of daily use
- [ ] **R-12** Bring [linux/docs/features.md](linux/docs/features.md) up to date: about 40 features from #4108 to #4159, #4145 and #4147 are missing, and the Saved queries, Sidebar, Preferences, Connections import, MCP Tools and Copy rows are stale
- [ ] **R-13** The display-scale pass on a real GPU and a HiDPI screen, and a hand install on Ubuntu 26.04
- [ ] **R-14** #4099 (KDE Wallet prompt opens behind the window) and #4101 (`flatpak list` shows "Usage data")
- [ ] **R-15** After 0.1.0: the Flathub manifest and exception request, by the maintainer, under [Flathub's requirements](linux/docs/decisions/0041-beta-repositories-and-release-packages.md#context)
- [ ] **R-16** After 0.1.0: an AUR PKGBUILD, kept by the community

## Phase 1: Core enablers

Each item ends in an FFI surface Windows needs. Linux paths are under `linux/crates/app/src/`.

- [ ] **C-01** Filters through the FFI: `table_query` takes a `FilterSet` (always `FilterSet::default()` in `core/crates/ffi/src/session.rs` today) and `operators_for`
- [ ] **C-02** Export through the FFI: `core::export` encoders (CSV, TSV, JSON, JSON Lines, HTML, Markdown, SQL INSERT, XML, XLSX) as a streaming job with progress and Stop; the sinks and ledger in `ui/export/` move down
- [ ] **C-03** CSV import and pasted rows through the FFI: `core::import::{csv_import, plan_import, PastedRows}`
- [ ] **C-04** SQL dump and SQL file import through the FFI: `core::dump`, `SqlFileReader`, with the orchestration in `ui/export/dump_job.rs` and `services/import_file.rs` moved down
- [ ] **C-05** Structure through the FFI: the table definition (columns, indexes, keys, comments), CREATE statements, `core::ddl` drafts, `diff_table`, plans and catalog operations (core ADR 0013); the logic in `services/pending_structure.rs` moves down
- [ ] **C-06** Storage through the FFI: `QueryHistory` (FTS5, retention, export), `SavedQueries` with folders and keywords, `Favourites`, `DraftStore` (deferred by core ADR 0017)
- [ ] **C-07** SQL formatter into core: `ui/editor/format_plan.rs` and `significant_tokens.rs`
- [ ] **C-08** Completion context into core: `completion/completion_scope.rs`, `catalog_read.rs` and the fuzzy ranking; proposal objects stay per app
- [ ] **C-09** Script runner into core: `script_runner.rs` and `run_log.rs` with `BatchErrorPolicy` (the FFI's `QueryEditor::run` takes one statement or one `GO` batch)
- [ ] **C-10** Pending row edits keyed by primary key into core: `services/change_tracker.rs` and `undo_op.rs`, so edits survive sort, filter and paging and undo is shared; replaces the position-keyed FFI `TableEditor` and Windows `UndoHistory.cs`
- [ ] **C-11** Copy and display text into core: `ui/clipboard/copy_renderer.rs`, `services/grid/display_text.rs`, `date_display.rs`, `hex_dump.rs`, `ui/format/thousands.rs`
- [ ] **C-12** Grid helpers into core: highlight rules (`services/grid/highlight.rs` and `persistence/highlight_rules_store.rs`) and find in grid (`find_matches.rs`)
- [ ] **C-13** Open Quickly matching and index into core: `ui/quick_open/{matching,search_index}.rs`
- [ ] **C-14** ER diagram model, layout and scene into core: `ui/diagram/{layout,model,scene}.rs`; drawing and export stay per app
- [ ] **C-15** Snippets in a neutral format: `builtin_snippets` is written in GtkSourceView syntax today; core keeps a neutral form and each app converts
- [ ] **C-16** Foreign import through the FFI: a Windows `ForeignHost` and `ForeignAppDirs`, passwords into Credential Manager, DPAPI-held passwords read (core ADR 0008)
- [ ] **C-17** AI through the FFI: providers, prompts, schema context, streamed replies
- [ ] **C-18** MCP server through the FFI, with a Windows host
- [ ] **C-19** Account through the FFI: the Windows `AppClient` once registered with tablepro-cloud, and the entitlement gate that every paid feature on Windows needs (core ADR 0016, D-02)
- [ ] **C-20** CLI on Windows: a `Host`, MCP dispatch, peer verification on the pipe, PowerShell completion (core ADR 0018)
- [ ] **C-21** Query-result editing through the FFI (core ADR 0015, after ADR 0019)
- [ ] **C-22** Connection library through the FFI: export to JSON, duplicate with secrets
- [ ] **C-23** uniffi 0.32 once uniffi-bindgen-cs supports it (issue #183, core ADR 0002)

## Phase 2: Windows daily use

The first public Windows release waits for every CORE item here and the Windows items of Phase 0 (D-04).

### Connections

- [ ] **W-01** Duplicate a connection with its secrets · CORE · needs C-22
- [ ] **W-02** Export the connections file (no secrets); import of TablePro's file exists · STD · needs C-22
- [ ] **W-03** Paste a URL on the Connections page to start a connection (today only in the engine chooser) · STD
- [ ] **W-04** Jump hosts in the SSH section; the core and the FFI record carry them · STD
- [ ] **W-05** Connect timeout field · STD
- [ ] **W-06** Group colour (the record has `Color`) · STD
- [ ] **W-07** Import from TablePlus, DBeaver, DataGrip, Beekeeper, Navicat and DBX · STD · needs C-16
- [ ] **W-08** Production cue: the connection colour on the tab strip, title bar and toolbar, and an environment label · CORE

### Sidebar

- [ ] **W-09** Object context menu: Open, Open in New Tab, Copy Name, Show CREATE, Truncate, Drop, through Safe Mode · CORE · needs C-05
- [ ] **W-10** Create and drop databases and schemas · CORE · needs C-05
- [ ] **W-11** Database switcher per connection and per query tab · CORE
- [ ] **W-12** Open a routine, trigger or sequence: its definition read-only, with Copy and Open in Editor · STD
- [ ] **W-13** Columns, indexes and keys under a table node · STD · needs C-05
- [ ] **W-14** Table info: rows, size, comment · STD

### Grid

- [ ] **W-15** Filters: per-column operators, raw WHERE, match any or all, kept per table · CORE · needs C-01
- [ ] **W-16** Filter by a cell's value, or exclude it · CORE · needs C-01
- [ ] **W-17** Value viewers for long text, JSON, binary (hex) and images; a tooltip on a cut cell · CORE
- [ ] **W-18** Row details pane with editing · STD
- [ ] **W-19** Follow a foreign key to the referenced row, and show referencing rows · CORE
- [ ] **W-20** Copy as CSV or TSV with headers, JSON, Markdown, INSERT, IN clause · CORE · needs C-11
- [ ] **W-21** Reorder, hide and freeze columns, kept per table (the control has frozen columns) · STD
- [ ] **W-22** Context menu on query-result grids · CORE
- [ ] **W-23** Selection summary: count, sum, average, min, max · STD
- [ ] **W-24** Find in the grid · STD · needs C-12
- [ ] **W-25** Grid display settings: NULL text, date format, grid font, row height, stripes · STD · needs C-11
- [ ] **W-26** Highlight rules · ADV · needs C-12

### Editing

- [ ] **W-27** Undo and redo of pending edits · CORE · needs C-10
- [ ] **W-28** Paste rows from the clipboard · STD · needs C-03, C-10
- [ ] **W-29** Edit query results that read one keyed table · STD · needs C-21
- [ ] **W-30** Type editors: date and time picker, enum menu, JSON check, boolean toggle · STD

### SQL editor

- [ ] **W-31** Completion: tables, columns, aliases, schemas, functions, keywords · CORE · needs C-08
- [ ] **W-32** Formatter · CORE · needs C-07
- [ ] **W-33** Replace, and regular expressions in Find · CORE
- [ ] **W-34** Open and save .sql files, drop a file on the editor, recent files · CORE
- [ ] **W-35** Query history with search, pins and retention · CORE · needs C-06
- [ ] **W-36** Saved queries in folders · CORE · needs C-06
- [ ] **W-37** Snippets with tab stops · STD · needs C-15
- [ ] **W-38** Run a whole script with an error policy, one entry per result · CORE · needs C-09
- [ ] **W-39** Word wrap, bracket matching, the current-statement band, Go to Error · STD
- [ ] **W-40** Vim mode · STD
- [ ] **W-41** Code folding · STD

### Structure

- [ ] **W-42** Structure view: columns, indexes, foreign keys, comments, the CREATE statement · CORE · needs C-05
- [ ] **W-43** Table designer: create and alter columns, indexes and foreign keys, with the SQL reviewed · CORE · needs C-05
- [ ] **W-44** ER diagram · STD · needs C-14

### Import and export

- [ ] **W-45** Export a table or a result to CSV, JSON, XLSX, SQL INSERT, Markdown, HTML and XML, with progress and Stop · CORE · needs C-02
- [ ] **W-46** CSV import into a table with a column mapping · CORE · needs C-03
- [ ] **W-47** Import SQL File and Export Database · CORE · needs C-04

### NoSQL

- [ ] **W-48** Redis key tab: the value by type, length, TTL, Load More (opening a key does nothing today) · CORE
- [ ] **W-49** MongoDB: documents as JSON with a tree view · STD
- [ ] **W-50** Cassandra paging past the first page (the FFI refuses offsets; page by paging state) · CORE

### Workspace

- [ ] **W-51** Open Quickly: objects, saved and past queries, commands · STD · needs C-13
- [ ] **W-52** Settings: editor font family, grid font, NULL display, history, AI and MCP pages · CORE
- [ ] **W-53** A toast when a long query finishes in a background tab · STD
- [ ] **W-54** Every string localizable, the editor's menu and find bar included; Vietnamese first · STD
- [ ] **W-55** Editor colour schemes · STD
- [ ] **W-56** Grid accessibility: row header peers, and a workaround for the empty `ColumnHeaders` in Windows App SDK 2.6.4 · CORE

### AI, MCP, account, integration

- [ ] **W-57** AI assistant: providers, chat with schema context, Explain, Review, Optimize, Fix, AI policy per connection · STD · needs C-17
- [ ] **W-58** MCP server with an External Clients level per connection · ADV · needs C-18
- [ ] **W-59** Account page, license ask, and the paid-feature gate on the macOS license (D-02) · STD · needs C-19
- [ ] **W-60** `tablepro://` and database URL links · STD
- [ ] **W-61** File associations for .sql, SQLite and DuckDB files · STD
- [ ] **W-62** Launch arguments and the `tablepro` CLI (the execution alias ignores arguments today) · STD · needs C-20

## Phase 3: Standard features both apps lack

The Windows box assumes its Phase 2 base. Linux-only items have no Windows box.

### Connections

- **S-01** SOCKS5 and HTTP proxy with remote DNS · STD · macOS: yes
  - [ ] core: a `TransportKind` beside DirectTcp, SshForward and LocalSocket
  - [ ] Linux
  - [ ] Windows
- **S-02** Cloud IAM sign-in: AWS RDS and Aurora tokens, Google Cloud SQL IAM · STD · macOS: yes
  - [ ] core: an `AuthMode` beside Password and Kerberos
  - [ ] Linux
  - [ ] Windows
- **S-03** Microsoft Entra ID for SQL Server (core ADR 0005) · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-04** Startup SQL per connection · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-05** Password from a command, an environment variable or a file; 1Password, Vault and AWS Secrets Manager after · ADV · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-06** Reusable SSH profiles · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-07** Encrypted connection export with secrets · STD · macOS: paid
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-08** Kerberos for PostgreSQL and MySQL; an SPN override for SQL Server outside the client's realm (a tiberius change) · ADV · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-09** Pre-connect and post-disconnect scripts; a tunnel command (kubectl port-forward, AWS SSM) · ADV · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows

### Grid and editing

- **S-10** Saved filter presets and a default filter per table · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-11** Foreign key value picker in the cell editor · STD · macOS: yes
  - [ ] Linux
  - [ ] Windows
- **S-12** Edit binary values from and to a file; array and spatial values · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-13** A clock in the grid's cell editor (Row Details has one) · STD
  - [ ] Linux
- **S-14** Display As: UUID forms, Unix timestamps, JSON inside text; MessagePack, Protobuf and PHP after · ADV · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-15** Search a value across every table · ADV · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows

### SQL editor

- **S-16** Query parameters (`:name`, `?`) with a prompt, LIKE and IN expansion · STD · macOS: yes
  - [ ] core: parameter scan in `sql_syntax`, binding per driver
  - [ ] Linux
  - [ ] Windows
- **S-17** EXPLAIN as a tree and a diagram, with EXPLAIN ANALYZE where the engine has it · STD · macOS: yes
  - [ ] core: a plan model parsed per engine
  - [ ] Linux
  - [ ] Windows
- **S-18** Result tabs: keep earlier results, pin one, compare two · STD · macOS: yes
  - [ ] Linux
  - [ ] Windows
- **S-19** Split editor or tab groups · STD · macOS: no
  - [ ] Linux
  - [ ] Windows
- **S-20** Inline diagnostics: syntax errors, unknown tables and columns · ADV · macOS: partly
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-21** Shortcut customization with conflicts and reset · STD · macOS: yes
  - [ ] Linux
  - [ ] Windows
- **S-22** Commands in Open Quickly (Linux finds objects and queries only) · STD · macOS: partly
  - [ ] Linux

### Structure and objects

- **S-23** Create and edit views, routines and triggers; refresh materialized views · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-24** Check constraints and partitions in the structure tab · STD · macOS: partly
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-25** Drag to reorder columns, with the ALTER previewed · STD
  - [ ] Linux
  - [ ] Windows
- **S-26** Users, roles and privileges for MySQL, MariaDB, PostgreSQL and SQL Server · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-27** PostgreSQL enum, composite and domain types; extensions · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-28** Rename and drop views, routines and triggers from the sidebar; Copy Name · CORE
  - [ ] Linux

### Admin

- **S-29** Process list with cancel and terminate · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-30** Server variables and status · STD · macOS: partly
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-31** Maintenance: VACUUM, ANALYZE, REINDEX, OPTIMIZE, CHECK, REPAIR, SQLite integrity check · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows

### Import, export, transfer

- **S-32** Import JSON, JSON Lines and XLSX; CSV into a new table; lift Linux's 64 MiB CSV limit · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-33** Export Parquet and JSON Lines files · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-34** Copy rows to another connection with a column mapping · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-35** Backup and restore through the engines' tools (pg_dump and pg_restore, mysqldump, mongodump). Flatpak needs `flatpak-spawn --host` or bundled tools; MSIX needs them on PATH · STD · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-36** Reusable export presets · STD · macOS: no
  - [ ] core
  - [ ] Linux
  - [ ] Windows

### NoSQL

- **S-37** Redis: edit values and TTL, create, rename and delete keys, a namespace tree · STD · macOS: yes
  - [ ] core: `write_batch` returns `Unsupported(Tables)` today
  - [ ] Linux
  - [ ] Windows
- **S-38** Redis Cluster and Sentinel; Valkey tested · ADV · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **S-39** MongoDB: index management, a document tree editor, validation rules · STD · macOS: partly
  - [ ] core
  - [ ] Linux
  - [ ] Windows

### Visualization

- **S-40** Charts from a result: bar, line, area, scatter · STD · macOS: paid
  - [ ] Linux
  - [ ] Windows
- **S-41** Map view for geometry columns · ADV · macOS: yes
  - [ ] core
  - [ ] Linux
  - [ ] Windows

### Workspace

- **S-42** An app theme override and custom themes (Linux follows the system; Windows has Light, Dark, System) · STD · macOS: yes
  - [ ] Linux
  - [ ] Windows
- **S-43** French, Korean, Turkish, Simplified and Traditional Chinese, which macOS ships · STD
  - [ ] Linux
  - [ ] Windows
- **S-44** GNOME Shell search provider for connections · STD
  - [ ] Linux

## Phase 4: Advanced tier

macOS has every item here, most as paid features, and the same license gates them on Linux and Windows (D-02). Linux and Windows have none; Linux's account page lists all 10 paid features as absent.

- **A-01** Compare & Sync: schema diff and row diff between connections, a sync script, saved comparisons · paid
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-02** Server Dashboard: sessions, metrics, slow queries, locks and blocking chains, replication status, saved-query tiles
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-03** Table Health: bloat, unused and redundant indexes, missing keys, XID age, stale statistics, a fix script
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-04** Query Insights: most run, slowest, got slower, failures · paid
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-05** Data Rewind: restore values from before a save, kept 7 days · paid
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-06** AI agent mode: tool calls with approval, `@` context, slash commands, saved conversations, AI rules per connection
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-07** More AI providers: Gemini, xAI, OpenRouter, Copilot, Bedrock, llama.cpp (Linux has Anthropic, OpenAI and OpenAI-compatible)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-08** MCP client: the assistant calls outside MCP servers
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-09** MCP server parity: 47 tools, resources, prompts, subscriptions, scoped tokens, pairing, an activity log, client setup snippets (Linux has 11 tools and one token)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-10** Linked SQL folders with Git status, commit, pull and push · paid
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-11** Environment variables in connection fields · paid
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-12** Masking rules across the grid, copies, exports, AI and MCP
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-13** Generate test rows: up to 1M, foreign-key aware, seeded
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-14** Join builder from foreign keys
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-15** ER diagram editing (add keys and columns) and Mermaid, DOT and PDF export
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-16** Data dictionary export to Markdown and HTML
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-17** Copy tables and databases across connections and engines, with type translation
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-18** Routine debugger for PL/pgSQL
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-19** Live messages: PostgreSQL LISTEN/NOTIFY, Redis channels
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **A-20** Data Files: open CSV, JSON and Excel without importing, through the DuckDB driver
  - [ ] core
  - [ ] Linux
  - [ ] Windows

## Phase 5: Engines

The core has 9 drivers; macOS has 48 engine types. Linux and Windows link drivers at compile time ([core ADR 0025](core/docs/decisions/0025-linux-and-windows-link-their-drivers.md)), so each engine is a core crate on a client library that meets [adding-drivers.md, The client library](linux/docs/adding-drivers.md#1-the-client-library): maintained on crates.io, TLS through aws-lc-rs, a stream or Unix socket transport for SSH, and a way to stop a statement.

Microsoft's mssql-tds is checked again each release as a SQL Server client. Today its TLS on Linux goes through OpenSSL and it takes no outside pull requests, so tiberius stays.

### On the existing drivers

- **E-01** MariaDB as its own entry on Windows
  - [ ] Windows
- **E-02** Test and list Redshift, CockroachDB, YugabyteDB, TiDB, OceanBase, Databend and Valkey (untested today)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **E-03** MongoDB sharded clusters and Amazon Keyspaces tested
  - [ ] core

### New drivers, by survey demand

- **E-04** Oracle · STD · blocked: the oracle crate has one maintainer, no release since 2025-01-02, and needs the proprietary Oracle client; checked again each release
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **E-05** Snowflake, over the SQL REST API · STD
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **E-06** BigQuery, over REST · STD
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **E-07** Trino and Presto, over HTTP · STD
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **E-08** libSQL/Turso and Cloudflare D1, over HTTP · ADV
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **E-09** DynamoDB · ADV
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **E-10** Elasticsearch and OpenSearch · ADV
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **E-11** Kafka, Neo4j, InfluxDB, etcd, Typesense and the rest of macOS's registry, on user demand
  - [ ] core
- **E-12** Dropped: engines added after install on Windows. Linux and Windows link drivers for good (D-03, [core ADR 0025](core/docs/decisions/0025-linux-and-windows-link-their-drivers.md))

## Phase 6: Quality bars

Linux already holds each bar; these bring Windows to it, plus one shared item.

- [ ] **Q-01** Large-catalog case on Windows: 100 schemas of 500 tables and one database of 50,000; the sidebar, its search and completion within time bounds
- [ ] **Q-02** 1,000,000-row paging and export on Windows, with bounds on time and resident memory
- [ ] **Q-03** The value corpus on Windows: dates at their extremes, decimals, JSON, UUIDs, Unicode and binary read back correctly per engine
- [ ] **Q-04** Kill-during-save recovery test on Windows
- [ ] **Q-05** Windows manual pass: Narrator, the keyboard alone, high contrast, 200% text
- [ ] **Q-06** Cold start and memory budgets in CI on Linux and Windows (survey reason 1); the first Windows launch took 16.7 s with JIT
- [ ] **Q-07** On Windows, offer the crash report on the next launch, as Linux does
- [ ] **Q-08** Security review of the Windows surfaces in `.oss-scanner/threat_model.md` before the first release, as Linux had before beta.1

## Phase 7: Sync and teams

A TablePro sync service on every platform (D-01). macOS keeps iCloud beside it, and the user picks one. It syncs connections and groups, secrets encrypted end to end, saved queries and settings, and Team Library and Team Catalog; iCloud Sync, Team Library and Team Catalog are 3 of the 10 paid features.

- **T-01** Design ADR: the data model, conflict rules (field by field, as core ADR 0010 merges CloudKit records), end-to-end encryption of secrets and key recovery, whether query history syncs, and iCloud beside the service on macOS
  - [ ] core
- **T-02** The service: storage per account and team, the sync API, the entitlement check (core ADR 0016)
  - [ ] server
- **T-03** Sync client in the core: pull, push, merge, an offline queue, and the device list
  - [ ] core
- **T-04** Connections, groups, tags, colours and SSH profiles, without their secrets
  - [ ] Linux
  - [ ] Windows
- **T-05** Secrets encrypted on the device before they leave it, never readable on the server
  - [ ] core
  - [ ] Linux
  - [ ] Windows
- **T-06** Saved queries, snippets, favourites and settings
  - [ ] Linux
  - [ ] Windows
- **T-07** Team Library and Team Catalog: shared connections and queries with roles, as on macOS
  - [ ] core
  - [ ] server
  - [ ] Linux
  - [ ] Windows
- **T-08** macOS on the service: everything T-04 to T-07 sync, beside iCloud, a setting to pick one, and a move from iCloud to the service
  - [ ] macOS

## Phase 8: Beyond the market

Survey features no client covers on every platform, and the macOS app lacks them too, so each has a macOS box. All but G-06 and G-12 were taken (D-05).

- **G-01** SQL notebooks: SQL and Markdown cells with results (only VS Code mssql since Azure Data Studio retired)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-02** Scheduled jobs: export, backup or run SQL on a schedule, with a notification (Navicat, DBeaver PRO, TablePlus 27.2)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-03** Go to definition, find usages and rename in SQL (DataGrip, Navicat 18, dbForge)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-04** Object dependencies: uses and used by (DataGrip, DBeaver, SSMS, pgAdmin)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-05** Schema in version control: compare a database against SQL files or migrations (SSMS, VS Code mssql, dbForge, DBeaver PRO)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-06** Not taken (D-05): a visual MongoDB aggregation pipeline builder (Navicat)
- **G-07** Column profiling: nulls, distinct values, distribution (Navicat 17)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-08** Pivot tables on a result (dbForge, Navicat)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-09** Edit tables with no primary key through `ctid` or `rowid`, with a warning (DBeaver, DataGrip)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-10** Server log viewer and live trace such as Extended Events (SSMS, Querious, MySQL Workbench)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-11** Run a query every N seconds and chart it (DbVisualizer)
  - [ ] core
  - [ ] Linux
  - [ ] Windows
  - [ ] macOS
- **G-12** Not taken (D-05): a browser-hosted edition (CloudBeaver, DbGate, pgAdmin server mode)

## Decisions

Answered by the maintainer on 2026-11-13.

| ID | Question | Decision |
|---|---|---|
| D-01 | Sync and team features on Linux and Windows | A TablePro sync service on every platform, with iCloud kept beside it on macOS ([Phase 7](#phase-7-sync-and-teams)). It reverses the Linux roadmap's earlier "no cloud sync through a TablePro service" |
| D-02 | Paid features on Linux and Windows | One license and one feature gate on all three platforms |
| D-03 | Engines added after install on Windows | No. Linux and Windows link drivers at compile time for good ([core ADR 0025](core/docs/decisions/0025-linux-and-windows-link-their-drivers.md)) |
| D-04 | The bar for the first public Windows release | Phase 0 plus every CORE item in Phase 2, with no public build before |
| D-05 | Which survey gaps to take | All but G-06 and G-12 ([Phase 8](#phase-8-beyond-the-market)) |
| D-06 | Which comes first | Linux 0.1.0, then Phase 1 and Windows ([Order](#order)) |
| D-07 | An Android app | Not now |

## Out of scope

- Drivers added after install on Linux and Windows ([core ADR 0025](core/docs/decisions/0025-linux-and-windows-link-their-drivers.md))
- Embedded scripting: JavaScript, Python, Lua. SQL is enough, and a scripting engine widens the attack surface
- AppImage and Snap ([Linux ADR 0018](linux/docs/decisions/0018-ppa-copr-and-flathub-later.md), [0041](linux/docs/decisions/0041-beta-repositories-and-release-packages.md))
- KDE-native styling: the Linux app runs with the Adwaita style everywhere
- An Android app, for now (D-07)
- G-06 and G-12 (D-05)

## Sources

- Code inventories of `apple/`, `linux/`, `windows/` and `core/` at `8581bd6c7`, and the docs site clone (last commit 2026-10-28, behind the app: Neo4j, InfluxDB, Qdrant, Memcached, StarRocks, masking, Table Health, Live Messages, result tabs and account sign-in have no page yet).
- Survey, from official feature pages and 2025-2026 release notes:
  - DataGrip: https://www.jetbrains.com/help/datagrip/2026.3/release-notes-datagrip.html
  - DBeaver: https://dbeaver.com/edition/, https://dbeaver.io/news/
  - TablePlus: https://tableplus.com/osx/changelog
  - Navicat: https://www.navicat.com/en/navicat-18-highlights
  - Beekeeper Studio: https://www.beekeeperstudio.io/features
  - DbVisualizer: https://www.dbvis.com/whatsnew
  - pgAdmin: https://www.pgadmin.org/news/
  - SSMS 22: https://learn.microsoft.com/ssms/release-notes-22
  - VS Code mssql: https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/mssql/mssql-extension-visual-studio-code
  - DbGate: https://www.dbgate.io/features
  - Postico 2: https://releases.eggerapps.at/postico2/changelog
  - Sequel Ace: https://github.com/Sequel-Ace/Sequel-Ace/releases
  - Also HeidiSQL, dbForge (search summaries only, devart.com refuses fetches), MySQL Workbench, Antares, Querious, Chat2DB.
- Reasons users switch: about 20 Hacker News threads and GitHub trackers, for example https://news.ycombinator.com/item?id=39660592, https://news.ycombinator.com/item?id=46078571, https://github.com/TablePlus/TablePlus/issues/2669.
