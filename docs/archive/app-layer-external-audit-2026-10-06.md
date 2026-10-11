# App layer external audit and UX lane plan

Reviewed 2026-10-06. This is a source review and action plan. It does not
record a runtime pass, and it does not change B3/B4 acceptance or authorize a
release.

## Scope and evidence

| Source | Pin | Method |
| --- | --- | --- |
| BookiE `linux/crates/app` | branch `b3/clickhouse-nested-xlsx-consumer` at `2931da3ba` | Read-only source audit; `cargo build -p tablepro-app` succeeded; app not launched |
| [TableProApp/TablePro](https://github.com/TableProApp/TablePro/tree/976cf4798053715eef90ed8eb47eebcc4718c590) | `976cf4798053715eef90ed8eb47eebcc4718c590` (2026-10-06) | Tree listing, `docs/features/*.mdx`, Swift view folders. No clone or build |
| [t8y2/dbx](https://github.com/t8y2/dbx/tree/d9338d1a3594e5b36fdfeb7d0b67d10e686adbfc) | `d9338d1a3594e5b36fdfeb7d0b67d10e686adbfc` (2026-10-06), Apache-2.0 | Shallow clone in a scratch directory. Nothing built or run |

Linux status values in this file come from source and grep checks. Every GUI
flow still lacks installed acceptance in
[manual verification](../manual-verification-0.2-features.md). The
[September adoption matrix](upstream-adoption.md) is partly stale: Jump to
Column and XLSX export now exist.

Paths below are relative to `linux/crates/app/src` unless stated.

## Finding: the app is usable, the first hour is not

Browse, edit and commit; the SQL editor with sessions, parameters, files,
history and favorites; structure editing; CSV import; and seven export formats
are wired end to end. Every GUI database path goes through `PolicyGuard` via
`services/database_service.rs:346-395`, with one exception listed below.

The blockers are in the first hour of use, not in the data paths.

### Ranked gaps for "connect and start using"

| # | Gap | Evidence |
| --- | --- | --- |
| G1 | A saved connection cannot be edited. The dialog supports a bound id but is always opened with `None` | `ui/app/connection.rs:39`, `ui/connect_dialog/mod.rs:49,451`, row actions in `ui/connection_row.rs:92-127` |
| G2 | A failed connect shows a modal with Close only. No Retry, no Edit. Startup restore fails the same way | `ui/app/connection.rs:370-381`, `ui/app/status_pages.rs:50-60` |
| G3 | A connect in progress cannot be cancelled | `ui/app/status_pages.rs:21-38` |
| G4 | TLS defaults to VerifyFull, which is correct. A local container then fails with a handshake error and no hint | `ui/connect_dialog/mod.rs:215`, `ui/error_text.rs:31` |
| G5 | SQLite path and TLS CA are text entries with no file picker and no "create new" | `ui/connect_dialog/mod.rs:216,679` |
| G6 | The SQL editor has no find or replace. `Ctrl+F` is bound to the browse filter and shows a toast in editor tabs | no `SearchContext` in `ui/`; `ui/app/shortcuts.rs:103`; `ui/app/browse.rs:341-345` |
| G7 | No database or schema switcher. Core has no `list_databases` | `core/src/connection.rs:115-135` |
| G8 | A second launch exits silently instead of raising the window | `lib.rs` single-instance block |
| G9 | Plain `cargo run` shares config, keyring schema and lock with an installed build. `TABLEPRO_PROFILE` is compile-time and not in the README | `storage/src/paths.rs:5-18`, `config.rs:3` |
| G10 | No read-only value viewer or row inspector for long, JSON or binary values in editor results | `ui/grid/context_menu.rs:319-357`, `ui/grid/display.rs:83` |
| G11 | Multi-statement results use one switcher button per statement and do not scale | `ui/editor/outcomes.rs:206-231` |
| G12 | Sidebar is a flat tables/views list. Other objects only appear in the Catalog window | `ui/sidebar_row.rs:11-14`, `ui/app/init_sidebar.rs:140-160` |
| G13 | Export covers loaded rows or the current page only | `ui/export_dialog.rs:184-187` |
| G14 | No column hide/reorder and no find in grid | no grep hit; TablePro #32, #33, #35 |
| G15 | Thin preferences: no theme override, null style, font family or vim mode | `services/preferences.rs:17-33` |

Smaller items: the connect dialog preselects ClickHouse because drivers sort
alphabetically (`ui/connect_dialog/mod.rs:164`); Test Connection feedback is a
transient raw toast (`:546-556`); `Ctrl+/` is bound both to the shortcuts
window and to editor comment toggle (`ui/app/shortcuts.rs:96`,
`ui/editor/mod.rs:485-500`) and needs a live check.

### Guard coverage of the connect dialog

Test Connection and the real Connect both list tables (and Connect lists
views) on the raw driver connection returned by `establish`
(`ui/connect_dialog/mod.rs:516-525`, `:843-850`). That connection is not yet
registered with `DatabaseService` and is never handed to a consumer, but
`PolicyGuard` audits metadata reads (`policy/src/guard/connection.rs:14`), so
these two reads leave no audit record. This is pre-handout bootstrap, not a
bypass. Whether bootstrap reads need a guard belongs to the B4 session
ownership work, so no UX packet changes it.

## What to adopt from TablePro

TablePro's window is: connections rail, sidebar (tables/favorites, tree),
tab strip, editor over results, trailing inspector pane, and a results status
bar. Of 87 cataloged UI functions, about 22 exist on Linux, 33 are partial,
28 are missing and 4 are excluded (AI, Apple services, license-gated charts).

Adopt, in this order of value against cost. Each keeps policy, bounded fetches
and owning-connection identity.

| Rank | Function | GTK route | Cost |
| --- | --- | --- | --- |
| 1 | Editor find and replace | `GtkSourceSearchContext` under a `GtkSearchBar`; focus-aware `Ctrl+F`/`Ctrl+H` | S |
| 2 | Find in loaded rows, then "search all rows" as a governed filter rule | `GtkSearchBar` over the page model | S-M |
| 3 | Column visibility and saved order | `GtkColumnViewColumn::set_visible`, popover checklist, persist with `services/column_widths.rs` | M |
| 4 | Database/schema switcher (`Ctrl+K`) | Header `GtkMenuButton` with searchable `GtkListView`; switch through transport | M, needs core |
| 5 | Row inspector side pane | `AdwOverlaySplitView` trailing pane; table info with no selection | M |
| 6 | FK picker and navigate to referenced row | Paginated `GtkListView` popover; open filtered browse tab | M-L |
| 7 | Enum, set and boolean pickers | Extend `CellEditorKind` in `ui/grid/types.rs` | S |
| 8 | Statement navigation, run and advance, current-statement band | `GtkSourceMark`/tag over existing `statement_cursor.rs` boundaries | S-M |
| 9 | Preview tabs | Flag per `AdwTabPage`, promote on double-click/sort/filter/edit | S |
| 10 | MRU tab switcher on `Ctrl+Tab` | MRU list in `ui/app/workspace_tabs.rs` | S |
| 11 | Open Quickly scopes, tables and commands | Extend `ui/quick_switcher_dialog.rs` | S |
| 12 | Named and pinnable result tabs, Fetch All | `AdwTabView` in `ui/editor/outcomes.rs` | M |
| 13 | Server output (NOTICE, PRINT) | Outcome page; needs a core trait hook | M, needs core |
| 14 | History as a docked drawer | Move `ui/history_dialog.rs` content into a `GtkPaned` | S-M |
| 15 | Paste TSV into grid | Pure parser, stage through `services/change_tracker.rs` | M, B3-adjacent |
| 16 | Page-size menu, jump to page, estimated count | `GtkMenuButton`, `GtkSpinButton` | S-M |
| 17 | Context-sensitive header bar actions | `gio::Menu` rebuilt on tab switch | S |
| 18 | Appearance: color scheme, editor scheme, font | `AdwStyleManager`, `GtkSourceStyleSchemeChooserWidget`, `GtkFontDialogButton` | S |
| 19 | Schema tree sidebar with richer context menu | `GtkTreeListModel` + `GtkTreeExpander` | M-L |
| 20 | Vim mode | `GtkSourceVimIMContext` plus a preference | S |

Not for 0.2: code folding (no GtkSourceView 5 API), ER diagram, map mode,
visual EXPLAIN diagram, move tab to new window (needs cross-window session
sharing), connections rail (conflicts with one connection per window; needs a
decision first). Excluded: AI, iCloud, Handoff, license, runtime plugins.

## What to learn from dbx

dbx is Tauri 2 with Vue 3 over a 27-crate Rust workspace. It has about 25k
stars and near-daily releases since April 2026. Its UI is monolithic
(`DataGrid.vue` 708 KB, `queryStore.ts` 472 KB), but its seams are good.

Adopt these patterns:

1. **One backend facade for the UI.** All frontend calls go through
   `apps/desktop/src/lib/backend/api.ts`. About 222 UI spec files mock it, so
   UI work never waits on the backend.
2. **Pure logic beside the widget.** `lib/dataGrid/` holds about 90 small
   tested modules (sort, clipboard, selection, transpose, widths). Our
   `services/` already does this. Keep doing it for every new UI feature.
3. **Typed action registry.** `lib/editor/shortcutRegistry.ts` drives
   shortcuts, Quick Open and the tab switcher from one table of action ids.
4. **Cancel answers `{requested, terminal}`.** The UI shows "stopping" and
   "stopped" as different states. This matches our operation control.
5. **Large values as preview plus byte count**, fetched in full on demand.
6. **Versioned error envelope** with stable code and an
   `operation_outcome: not_started | unknown` field that forbids automatic
   replay.
7. **Per-engine edit adapter** (`relational | document | unsupported`)
   instead of engine checks inside the grid.

Do not adopt:

- Cells as `serde_json::Value`, binary as `"0x…"` text and BLOB previews as
  strings. ADR 0007 forbids losing the binary/text distinction.
- Grid edits and user WHERE input spliced into SQL text with embedded
  literals (`crates/dbx-sql-data/src/data_grid_sql.rs`). We bind values and
  quote identifiers.
- Regex production-safety and a "write unlock" toggle in place of policy.
- Passwords crossing the UI boundary as plain strings.
- Commands taking about 15 positional primitives. Use typed request structs.
- Web views, runtime plugins and JDBC sidecars.

## Making UI work parallel to B3

The friction point today is that widgets match directly on
`tablepro_core::Value` (`ui/grid/column.rs:196-212`, 14 files under `ui/`),
and `AppMsg` is a single enum of about 150 variants. Every B3 change and every
UI feature meet in the same files.

### File ownership

Commits since 2026-09-15 that touched `crates/app` show these B3-hot files.
UX packets do not edit them without coordinating with the B3 owner:

`browse_tab/value_parse.rs`, `browse_tab/row_ops.rs`, `grid/display.rs`,
`grid/column.rs`, `grid/export.rs`, `export_dialog.rs`, `import_dialog.rs`,
`ui/app/import.rs`, `services/change_tracker.rs`, `tests/support/*_contract.rs`.

Shared, high churn, keep edits small: `ui/app/mod.rs`, `ui/app/msg.rs`,
`editor/mod.rs`, `editor/statement_cursor.rs`, `ui/app/connection.rs`,
`connect_dialog/mod.rs`.

Safe for UX work: `welcome_view.rs`, `connection_row.rs`,
`connect_dialog/form.rs`, `connect_dialog/identity.rs`, `ssh_section.rs`,
`preferences.rs`, `quick_switcher*`, `saved_queries_dialog.rs`,
`history_dialog.rs`, `activity_dialog.rs`, `explain_dialog.rs`,
`catalog_dialog.rs`, `editor/completion.rs`, `editor/schema.rs`,
`sidebar_row.rs`, `ui/app/init_sidebar.rs`, `structure_tab/*`,
`ui/app/shortcuts.rs`, `ui/app/status_pages.rs`.

### Foundation packets

These are small and make later UX work cheaper. They are not prerequisites
for Phase 1.

| ID | Deliverable | Owner |
| --- | --- | --- |
| UX-F1 | A `CellView` display model and one `cell_view(&Value, &ColumnInfo)` mapping in `ui/grid/`. Widgets render `CellView` only. `grid/display.rs` already holds most of the text logic; this names it as the boundary | B3 owns the mapping and its ADR 0007 tests; UX owns widgets |
| UX-F2 | A fake `tablepro_core` connection in a test-support location, wrapped by the real `PolicyGuard`, serving canned pages, slow pages, errors and cancellation | UX; used by the gtk-widgets tier |
| UX-F3 | New features add `AppMsg::<Feature>(<Feature>Msg)` and an `ui/app/<feature>.rs` impl file instead of new top-level variants | UX convention, recorded in [code conventions](../code-conventions.md) when first used |
| UX-F4 | One action table in `ui/app/shortcuts.rs` that feeds accelerators, the shortcuts dialog and Open Quickly commands | UX |

## Action plan

### Phase 0: use it today (no code)

1. Start the [manual connection fixture](../../tests/manual-connections/README.md).
2. Build an isolated development profile so tests never touch daily data:
   `cd linux && TABLEPRO_PROFILE=development cargo run -p tablepro-app`.
   Use a plain `cargo run -p tablepro-app` only for real daily connections.
3. Set TLS to **Disabled** for fixture connections.
4. Keep a dogfood log of every friction point with steps. New items join this
   table as UX packets, not as B3/B4 tasks.

### Phase 1: first hour fixed (S-sized, safe files)

Status on branch `ux/phase1-first-hour` (from `origin/linux` at `cffde8ff2`).
Each packet has unit tests; the GTK widget test and the second-launch check
ran on the Arch runner under Xvfb with a D-Bus session. None of this is
installed-Wayland acceptance.

| ID | Packet | Gap | Status |
| --- | --- | --- | --- |
| UX-1 | Edit saved connection from the welcome row; password, TLS, timeouts and single-hop SSH prefill; jump chains refused with a message | G1 | Done, `56990e9f2` |
| UX-2 | Connect failure offers Try Again and Edit Connection; startup restore failure uses the same alert | G2 | Done, `c1da1e39a` |
| UX-3 | Cancel button on the connecting toast; abandoning the connect drops its tunnel | G3 | Done for saved connections; the connect dialog's own Connect button has no cancel yet |
| UX-4 | PostgreSQL default driver, file pickers for SQLite/DuckDB and the CA, TLS handshake hint | G4, G5 | Done, `d8cb8464d` |
| UX-5 | Editor find and replace; `Ctrl+F` routes by tab type | G6 | Done, `b00c5601a`; widget test registered in `isolated-tests.json` |
| UX-6 | Second launch raises the running window; development profile documented | G8, G9 | Done, `209ca7fc7` |

Known limits: editing a connection with an SSH jump chain is refused until the
form can edit chains; replace-all and find use GtkSourceView search with the
default case-insensitive setting and no regex toggle; the second launch logs a
cosmetic GLib warning about D-Bus unregistration.

### Phase 2: daily workflows (two to three weeks)

| ID | Packet | Source rank | Notes |
| --- | --- | --- | --- |
| UX-7 | Read-only value viewer and row inspector pane | TablePro 5, G10 | Consumes UX-F1; no edit path changes |
| UX-8 | Column visibility and order | TablePro 3, G14 | Persistence beside column widths |
| UX-9 | Find in loaded rows | TablePro 2, G14 | Pure matcher over the page model |
| UX-10 | Named, pinnable result tabs | TablePro 12, G11 | `outcomes.rs` only |
| UX-11 | Statement navigation and current-statement band | TablePro 8 | Coordinate with `statement_cursor.rs` churn |
| UX-12 | Preview tabs and MRU switcher | TablePro 9, 10 | `workspace_tabs.rs` |
| UX-13 | Appearance preferences and vim mode | TablePro 18, 20, G15 | `preferences.rs` |
| UX-14 | History drawer and Open Quickly scopes/commands | TablePro 11, 14 | Uses UX-F4 |
| UX-15 | Database/schema switcher | TablePro 4, G7 | Needs a core `list_databases` capability per driver and an ADR 0008 check on session ownership. Plan with B4 before starting |

### Phase 3: depth (after B3 settles the grid and export paths)

Schema tree sidebar, FK navigation, enum/set pickers, paste TSV, full-table and
streaming export, server output, page-size and estimated counts. Each touches
B3-hot files or core contracts and is scheduled with that owner.

## Rules for every UX packet

- Follow `CLAUDE.md`: no comments, function and file size guards, a regression
  test in the lowest tier that reproduces the change, changelog entry under
  `[Unreleased]`.
- Logic goes in a pure function or `services/` module with unit tests. Widget
  code stays thin. GTK-only checks list manual steps and light/dark
  screenshots.
- No new database path outside `PolicyGuard`. No SQL built from UI text.
- A UX packet does not close any B3, B4 or B7 acceptance item. B7
  qualification still needs installed Arch and Debian/GNOME runs at a frozen
  SHA.

## Test infrastructure and later work

### Arch runner VM (done)

A lab Arch Linux VM (10 vCPU, 28 GB RAM, 300 GB disk) has the GTK 4.22 /
libadwaita 1.9 / GtkSourceView 5.20 stack that Debian 13 lacks, Rust 1.98 and
stable, Docker, Xvfb, a D-Bus session and Weston. A full debug build takes about
two minutes. The lab repository holds a provisioning script and a run script
that pushes a checkout's HEAD and runs a command there with a shared target
cache. One lab node was left alone: it crashed under sustained full-core load.

### Open items

| Item | Notes |
| --- | --- |
| File-size guard failing on `origin/linux` | `crates/drivers/postgres/tests/support/enum_contract_parts/scalar_consumers.rs` is 1384 lines against a 1369 ceiling after PR #84, so `scripts/preflight.sh` stops at that guard. B3 owns the fix |
| Translations template is stale | `scripts/update-translations.py` rewrites about 2,400 lines of `po/tablepro.pot`; run it once on its own commit, not inside feature commits |
| Cross-client value comparison | Build further lab VMs holding several database engines with seeded data, install DBeaver and dbx there (or on the runner), and compare what BookiE shows for the same values. Uses ADR 0007 outcomes as the oracle; feeds B3 evidence, not the UX lane. Schedule after UX Phase 2 |
| Installed-desktop checks | Wayland and light/dark screenshots of the UX-1 to UX-6 flows still need the Arch/Omarchy installed pass in [manual verification](../manual-verification-0.2-features.md) |
