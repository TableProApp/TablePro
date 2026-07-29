# Roadmap

## Where we are (2026-07-27)

**Phase 0 is complete. Phase 1 is complete. Large parts of Phase 2 and Phase 3 are already in the tree.**

The app connects to PostgreSQL, MySQL, SQLite, and Microsoft SQL Server; browses tables in a virtualized `GtkColumnView`; supports in-place cell edit with transactional save; hosts an `AdwTabView` workspace (editor / table / structure); filters rows; tunnels over SSH via `russh`; stores passwords in the Secret Service; and records query history in SQLite + FTS5. Drivers ship with testcontainers integration tests. Relm4 architecture is intact.

This is **past demo-grade**, but still **not beta-shippable**. The gap between "works on the developer's machine" and "I would install this from Flathub and use it daily" remains. See [`docs/production-audit.md`](docs/production-audit.md) for the detailed gap analysis. Remaining big-ticket items:

| Concern | Status |
|---|---|
| Type system | Done. `Value` covers Null/Bool/Int/Float/Text/Bytes/Date/Time/DateTime/TimestampTz/Decimal/Uuid/Json |
| Result scaling | Streams via sqlx `fetch` with `MAX_QUERY_ROWS` cap; full result still held in the grid model |
| Connection management | `DatabaseService` + `AdwTabView` workspace tabs done; one active connection at a time, multi-window still open |
| Network security | SSH tunnelling + TLS toggle present; cert-path / verify-mode UI still thin |
| Distribution | Flatpak manifest + metainfo + desktop + icon present; never built end-to-end on CI |
| Internationalization | gettext + `tr!` macro + `po/` template; the template has 227 strings against 390 in the app, and `POTFILES.in` is stale |
| Accessibility | Untested with Orca / keyboard nav |
| Integration tests | Postgres and MySQL suites run in CI; the MSSQL suite exists but no CI job runs it; SQLite has none |
| Recovery | `connection_monitor` ping + reconnect loop; cancel drops the client future, the server-side query keeps running |

**What "production-ready" means for this project**: a user on Fedora 41 or Ubuntu 24.04 can install from Flathub, connect to their everyday Postgres or MySQL database, browse and edit data correctly across all native types, run SQL queries, see schema, and trust the app to handle errors gracefully.

## Phase legend

Phases are ordered by **maturity**, not feature count. Each phase has a single concrete exit criterion.

---

## Phase 0 — Foundation ✅

**Status**: complete.

- [x] Cargo workspace with `app`, `core`, `storage`, `ssh`, `drivers/{postgres,sqlite,mysql,mssql}`
- [x] `core::DatabaseDriver`, `core::Connection`, `core::DriverRegistry` traits
- [x] `storage::connections` (JSON, atomic writes, schema versioning)
- [x] `storage::secrets` (Secret Service via `oo7`)
- [x] CI (`build-linux.yml`: fmt, clippy `-D warnings`, build, unit tests + driver integration)
- [x] `rustfmt.toml`, `clippy.toml`, `rust-toolchain.toml`
- [x] Flatpak manifest skeleton (not yet validated end-to-end — see Phase 3)
- [x] Architecture decision records for stack picks

Exit criterion: a fresh contributor can `cargo run -p tablepro-app` and reach a working window in under 15 minutes. **Met.**

---

## Phase 1 — Demo MVP ✅

**Status**: complete.

- [x] Drivers wired: PostgreSQL / SQLite / MySQL via `sqlx`, MSSQL via `tiberius`
- [x] `AdwNavigationSplitView` shell with header bar + Connect/Open/Edit/Disconnect
- [x] Multi-driver Connect dialog with engine picker + per-driver form
- [x] Saved connection list with delete + reconnect
- [x] Browse paginated table results in `GtkColumnView` (100k rows scroll smoothly)
- [x] Sidebar table search (case-insensitive substring filter)
- [x] SQL editor pane (GtkSourceView 5 + Run button)
- [x] Modal Insert / Edit / Delete row dialogs (parameterized SQL)
- [x] **True in-place cell edit** with snapshot-on-edit-start + force-cancel-on-recycle
- [x] Connection deduplication by (driver, host, port, db, user)
- [x] PG `fetch_columns` correctly populates `primary_key`
- [x] All `unsafe set_data` confined to grid cell metadata, contained
- [x] All async work via `sender.command` with auto-cancellation on shutdown
- [x] Typed error → user-friendly message layer

Exit criterion: a developer can demo the basic flows (connect, browse, edit, query) without crashes on their own machine. **Met.**

---

## Phase 2 — Production hardening (in progress)

**Goal**: handle real-world data and real-world failure modes correctly.

### Type system expansion ✅

- [x] Add to `core::Value`: `Date`, `Time`, `DateTime`, `TimestampTz`, `Decimal`, `Uuid`, `Json`
- [x] Map driver-specific types across PG / MySQL / SQLite / MSSQL
- [x] `chrono`, `rust_decimal`, `serde_json` in the workspace
- [x] `RowObject` / display helpers consume the full `Value` set

### Streaming results (partial)

- [x] sqlx `fetch` stream into a bounded collector (`MAX_QUERY_ROWS`)
- [ ] Backpressure model: hold the stream open for next-page reads
- [ ] Memory-bounded grid: drop rows outside viewport (GTK virtualizes paint; model still holds all loaded rows)
- [ ] Cancellation: drop the stream when user navigates away

### Multi-connection / multi-tab architecture (partial)

- [x] `DatabaseService` owning active connection(s)
- [x] `AdwTabView` for multiple open tables / queries within one connection
- [x] Workspace tab persistence (`workspace_state.json`)
- [ ] Switch the active connection without reconnecting (`DatabaseService` has no `set_active`)
- [ ] Multi-window: each window holds its own active connection via `gtk::Application::add_window`

### Security baseline (partial)

- [x] TLS toggle on connect options
- [x] SSH tunnelling via `russh` (host, port, key / password auth)
- [ ] SSH jump host
- [x] Read-only mode toggle per connection
- [x] Cancel running query: button + Esc shortcut
- [ ] `Connection::cancel` driver method, so cancelling stops the server-side query instead of dropping the client future
- [x] Connection lost recovery: ping monitor + reconnect loop
- [ ] Statement timeout configurable per connection
- [ ] TLS cert path / verify mode / SNI override UI

### Integration tests (partial)

- [x] `tests/integration.rs` using `testcontainers-rs` for Postgres, MySQL, MSSQL
- [ ] SQLite suite (the crate has no `tests/` directory)
- [x] Connect, list_tables, fetch_columns (PK detection), pagination, value round-trip, bad SQL
- [x] CI integration job gated behind `--include-ignored`, for Postgres and MySQL
- [ ] Run the MSSQL suite in CI
- [x] `smoke_local` test + `scripts/smoke-postgres.sh` for a Docker-free driver check

**Exit criterion**: Connect to a 10M-row Postgres table, scroll, edit a date column, lose network mid-query, see a recoverable error, reconnect via the same UI flow.

---

## Phase 3 — Beta release (in progress)

**Goal**: shippable to Flathub. A user installs and uses for real work.

### Browse UX (partial)

- [x] Where-filter UI (`filter_strip`) with per-column operators
- [x] ORDER BY wired to `GtkColumnView` header click → server sort
- [x] Multi-row select via shift-click + Ctrl-click
- [x] Bulk delete with confirmation
- [x] Right-click context menu (copy cell, copy row as INSERT, copy column, set NULL, delete row)
- [x] Save column widths per (connection, table)
- [ ] Save column order per (connection, table)

### Export / import (~1 week)

- [ ] Export current grid to CSV / JSON / SQL INSERT / Markdown
- [ ] Export with options: include headers, quote style, line endings, UTF-8 BOM toggle
- [ ] Import CSV → table (with column mapping dialog)
- [ ] Run SQL file (load + execute via SQL editor)

### Schema browser (partial)

- [x] Structure tab: columns, indexes, foreign keys (edit + DDL diff)
- [x] Column metadata: type, nullable, default
- [ ] Column comments (`ColumnInfo` has no `comment` field and no driver reads one)
- [ ] Sidebar tabs: Views, Triggers, Functions, Sequences
- [ ] Click view → SELECT * FROM view (re-uses browse view)
- [ ] Click index → show CREATE INDEX DDL + which columns
- [ ] Click FK → highlight columns + jump to referenced table

### Query history + saved queries (partial)

- [x] SQLite FTS5 store at `$XDG_CONFIG_HOME/tablepro/history.db`
- [x] SQL editor runs recorded with timestamp, duration, success, connection name
- [ ] Record the SQL the app runs outside the editor (Structure tab DDL saves, grid row saves)
- [x] History pane with full-text search
- [ ] Saved queries: name + SQL, organized by connection

### Connection management (partial)

- [ ] Connection groups (folders in saved-connections list)
- [ ] Color tags per connection
- [ ] Import / export connections to JSON file
- [ ] Clone connection
- [ ] "Test connection" button in dialog before save

### Distribution scaffolding (~1 week)

- [x] `com.tablepro.linux.metainfo.xml` skeleton
- [x] App icon: scalable SVG
- [ ] Icon set: 16/32/48/64/128/256/512 PNG
- [ ] 4–5 high-resolution screenshots showing key flows
- [ ] Long description + short description polish in metainfo
- [x] ContentRating (`oars-1.1` in the metainfo)
- [ ] `cargo-sources.json` generation via `flatpak-builder-tools/cargo`
- [ ] CI job: `flatpak-builder` builds the manifest end-to-end on each PR
- [ ] Submit to Flathub `flathub/flathub` PR → review → first publish

### Observability (~0.5 weeks)

- [x] Structured logging via `tracing-subscriber` (env-filter)
- [ ] JSON log layer, env-toggleable (the `json` feature is not enabled, so `.json()` is not compiled in)
- [ ] Crash reporter: panic hook captures backtrace, writes to log, optional anonymous upload (with explicit opt-in)
- [ ] "Help → Report bug" UI helper that opens the issue tracker pre-filled with sanitized log excerpt

**Exit criterion**: app published to Flathub stable channel; user installs via `flatpak install com.tablepro.linux`; runs against their Postgres + MySQL daily for one week without unrecoverable failure.

---

## Phase 4 — Beta polish (3 weeks)

**Goal**: shipped beta, accepting external bug reports, ready for first wave of public users.

### Internationalization setup (partial)

- [x] `gettext` integration via `gettext-rs`
- [x] `tr!` macro + locale bind in `i18n::init`
- [x] `po/` scaffolding: `tablepro.pot`, `POTFILES.in`, `LINGUAS`
- [x] Locale detection: `setlocale(LC_ALL, "")` in `i18n::init`
- [ ] Extract all user-facing strings: 218 of the app's 390 `tr!` strings are missing from the template, and 55 of its 227 entries no longer exist in the source
- [ ] Refresh `POTFILES.in`: it lists 3 files that no longer exist and misses 17 that call `tr!`
- [ ] Build pipeline integrates `.po` → `.mo` compilation
- [ ] Ship English-only at first; structure ready for translators

### Accessibility audit (~1 week)

- [ ] Test screen-reader flow with Orca on GNOME 47
- [ ] Keyboard-only flow: tab order, focus indicators, escape close, enter commit
- [ ] High contrast mode rendering
- [ ] Font scaling honored (`gsettings text-scaling-factor`)
- [ ] No color-only UI signals (Connect button has icon + text, Delete has icon + label)
- [ ] Set `Accessible` properties on custom widgets (cells, popover content)

### Multi-DE / multi-distro testing (~0.5 weeks)

- [ ] KDE Plasma 6 visual smoke test (Adwaita styling acceptable; do not adopt KDE styling)
- [ ] Wayland-specific bug fixes (HiDPI fractional scaling, drag handles)
- [ ] X11 fallback works on older distros
- [ ] Manual install + smoke on Fedora 41, Ubuntu 24.04, Arch (latest), Debian 12/13

### Distribution variants (~0.5 weeks)

- [ ] AppImage build via `appimagetool` (portable use case)
- [ ] `.deb` build for Debian / Ubuntu (community-maintained or official)
- [ ] `.rpm` build for Fedora (community-maintained or official)
- [ ] AUR PKGBUILD for Arch (community-maintained, mirror in repo)

### Documentation (~0.5 weeks)

- [ ] User manual at `docs/user/` (Mintlify) — getting started, connection setup per database, keyboard shortcuts, FAQ
- [ ] Marketing page on the existing TablePro Mintlify site for Linux
- [ ] CHANGELOG.md for the Linux subproject
- [ ] Issue templates: bug report, feature request

**Exit criterion**: Beta release announced on the marketing site, on Flathub stable, on r/linux. Issue tracker active. First 10 external bug reports triaged.

---

## Phase 5 — GA expansion (6+ months, ongoing)

**Goal**: General Availability. Feature set covers what a daily Postgres/MySQL user expects, plus genuine multi-engine support.

### Additional drivers (parallelizable, ~1 week each)

- [ ] ClickHouse via official `clickhouse` crate (or `clickhouse-arrow`)
- [x] MSSQL via `tiberius`
- [ ] Oracle via `oracle` crate (ODPI-C)
- [ ] Redis via `fred`
- [ ] MongoDB via official `mongodb` crate
- [ ] DuckDB via `duckdb` crate
- [ ] Cassandra/Scylla via `scylla`
- [ ] DynamoDB via `aws-sdk-dynamodb`
- [ ] BigQuery (HTTP, third-party crate)
- [ ] Cloudflare D1 (HTTP)

### Editor maturation (~3 weeks total)

- [ ] Schema-aware SQL autocomplete (tables, columns, keywords) using cached `current_columns`
- [ ] SQL formatter (multiple dialect support)
- [ ] Multi-statement execution
- [ ] Run-selection-only
- [ ] Find / replace within editor
- [ ] Multi-cursor editing
- [ ] Vim mode (custom impl on top of GtkSourceView 5)
- [ ] Snippets

### Schema editor (~2 weeks)

- [x] Create / alter / drop table via Structure tab + DDL materialization
- [x] Add / remove columns
- [ ] Rename columns (`build_rename_column` exists but has no caller; needs a `RenameColumn` op in `diff_to_ops` / `materialize_ops`)
- [x] Add / remove indexes
- [x] Add / remove foreign keys
- [ ] Drag-drop column reordering with ALTER TABLE preview

### ER diagram (~3 weeks)

- [ ] Cairo-based custom widget rendering tables as cards
- [ ] Foreign key edges with arrowheads
- [ ] Pan / zoom / save layout
- [ ] Auto-layout via dot graph algorithm

### Type-aware widgets (~2 weeks)

- [ ] Date / time picker for date columns
- [ ] Number spinner with bounds (INT2/INT4/INT8 ranges)
- [ ] JSON editor with syntax highlighting + validation
- [ ] Boolean toggle
- [ ] File chooser for BLOB columns

### Real product infrastructure

- [ ] Marketing site updates per release
- [ ] Support channel: GitHub Discussions or Discourse
- [ ] Email support (paid tier?) — depends on business model decision
- [ ] Pricing page (free, paid, enterprise — depends on model)
- [ ] Donation links if open source
- [ ] Telemetry (anonymous, opt-in) for usage analytics

**No fixed exit criterion**. This phase ends when the team decides parity is "enough" and shifts to maintenance + driver additions on demand.

---

## Phase 6 — Parity ambitions (year+)

**Goal**: feature-competitive with DBeaver / DataGrip on the engines we support.

### Maybe (open questions)

- [ ] Real-time monitoring (active connections, locks, slow queries)
- [ ] Server admin tools (vacuum, reindex, ANALYZE)
- [ ] Backup / restore UI
- [ ] Replication monitoring
- [ ] Multi-tab query results comparison
- [ ] Diff tool: schema diff between two connections
- [ ] Data sync between two connections
- [ ] Cron-style scheduled queries
- [ ] Reporting / dashboard builder (probably out of scope; focus on the IDE shape)

These are ambitions, not commitments. Phase 6 should only start after Phase 5 has stabilized for at least 6 months.

---

## Out of scope (firm)

| Item | Reason |
|---|---|
| Plugin system at runtime | [decision 0001](docs/decisions/0001-no-plugin-system.md) — drivers are static |
| Cross-platform builds (Windows / macOS) | Separate apps in the monorepo for those platforms |
| Embedded scripting (JS / Python / Lua) | SQL is enough; adds attack surface |
| Hot-reload of drivers | Compile-time only; use `cargo watch` during dev |
| Cloud sync of connections (proprietary backend) | Out of scope unless business model demands it |
| Snap distribution | Decided to skip; Flathub + AppImage cover the audience |
| KDE-native styling | Run as Adwaita on KDE; users wanting native KDE have other options |

---

## Phase B — Repository restructure (deferred)

Once Beta has shipped (end of Phase 4) and is stable for at least 6 weeks, the top-level repository layout migrates:

```
apps/macos/        (move from TablePro/, TableProTests/, Plugins/, Libs/, LocalPackages/)
apps/ios/          (move from TableProMobile/)
apps/linux/        (move from linux/)
packages/          (move from Packages/TableProCore/)
```

This is a separate undertaking and is not blocking any phase. It moves only after Linux is stable and there is a real cost to the current flat layout.

---

## Realistic timeline

| Stage | Effort | Calendar |
|---|---|---|
| Phase 0 + 1 | done | done |
| Phase 2 remainder (streaming backpressure, driver-side query cancel, multi-window, TLS UI polish) | ~2 weeks FT | next |
| Phase 3 remainder — Beta release | ~3 weeks FT | following |
| Phase 4 — Beta polish | 3 weeks FT | after Beta |
| **Beta on Flathub** | **~8 weeks FT from this revision** | **after Phase 4** |
| Phase 5 — GA expansion | 6 months FT | rolling |
| Phase 6 — Parity ambitions | 12+ months FT | optional |

At 50% effort (part-time), double everything. At 25% effort (side project), 4x.

---

## What changed in this revision (2026-07-27)

The previous "Where we are (2026-04-26)" section still described the project as Phase 0/1 demo-grade with a type system of 6 variants, no multi-tab, no SSH, and a single ignored integration test. The tree has moved on:

- Four drivers (including MSSQL), full `Value` set, `DatabaseService`, workspace tabs, Structure tab + DDL, filters, SSH, read-only mode, query history, connection monitor, gettext scaffolding, and CI integration jobs are all present.
- Phase 2 and Phase 3 checklists were marked to match the code. Unchecked items are the real remaining work.
- Timeline shortened: Beta is roughly 8 weeks of focused work from this baseline, not 11 weeks from a stale Phase 1.

This revision does not claim Beta readiness. It stops the roadmap from under-selling what already ships.
