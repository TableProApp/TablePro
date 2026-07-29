# Roadmap

## Where we are (2026-04-26)

**Phase 0 and Phase 1 are complete in spirit but not in production sense.**

The current build connects to PostgreSQL / MySQL / SQLite, browses tables with a virtualized 100k-row grid, supports in-place cell edit, has a SQL editor, and persists connections to JSON + libsecret. 31 unit tests, CI green, Relm4 architecture clean.

This is **demo-grade**. It is not beta-shippable. The gap between "works on the developer's machine" and "I would install this from Flathub and use it daily" is substantial — see [`docs/production-audit.md`](docs/production-audit.md) for the detailed gap analysis. The big-ticket missing pieces:

| Concern | Status |
|---|---|
| Type system | 6 of ~20 needed types (no Date / Time / Decimal / Uuid / Json) |
| Result scaling | Materializes full result into memory; OOM at 1M+ rows |
| Connection management | One global connection at a time; no multi-tab, no multi-window |
| Network security | TLS UI absent, SSH tunnelling absent |
| Distribution | Flatpak manifest never built; no AppStream metainfo, icons, or screenshots |
| Internationalization | 100% English hardcoded |
| Accessibility | Untested with Orca / keyboard nav |
| Integration tests | One ignored testcontainers test; zero per-driver matrix |
| Recovery | No reconnect on connection loss; no cancel running query |

**What "production-ready" means for this project**: a user on Fedora 41 or Ubuntu 24.04 can install from Flathub, connect to their everyday Postgres or MySQL database, browse and edit data correctly across all native types, run SQL queries, see schema, and trust the app to handle errors gracefully. Demo-grade does not meet this bar.

## Phase legend

Phases are ordered by **maturity**, not feature count. Each phase has a single concrete exit criterion.

---

## Phase 0 — Foundation ✅

**Status**: complete.

- [x] Cargo workspace with `app`, `core`, `storage`, `drivers/{postgres,sqlite,mysql}`
- [x] `core::DatabaseDriver`, `core::Connection`, `core::DriverRegistry` traits
- [x] `storage::connections` (JSON, atomic writes, schema versioning)
- [x] `storage::secrets` (libsecret via `oo7`)
- [x] CI on Ubuntu 24.04 (build, clippy `-D warnings`, fmt check, tests)
- [x] `rustfmt.toml`, `clippy.toml`, `rust-toolchain.toml`
- [x] Flatpak manifest skeleton (not yet validated end-to-end — see Phase 3)
- [x] Architecture decision records for stack picks

Exit criterion: a fresh contributor can `cargo run -p tablepro-app` and reach a working window in under 15 minutes. **Met.**

---

## Phase 1 — Demo MVP ✅

**Status**: complete.

- [x] Three drivers wired (PostgreSQL, SQLite, MySQL) via `sqlx`
- [x] `AdwNavigationSplitView` shell with header bar + Connect/Open/Edit/Disconnect
- [x] Multi-driver Connect dialog with engine picker + per-driver form
- [x] Saved connection list popover with delete + reconnect
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

This is where the project sits today. The app is interesting but **not production-ready**.

---

## Phase 2 — Production hardening (4 weeks)

**Goal**: handle real-world data and real-world failure modes correctly.

### Type system expansion (~1.5 weeks)

- [ ] Add to `core::Value`: `Date`, `Time`, `DateTime`, `TimestampTz`, `Decimal`, `Uuid`, `Json`
- [ ] Map driver-specific types: PG `numeric`/`uuid`/`jsonb`/`timestamptz`, MySQL `datetime`/`json`, SQLite `julianday`/text variants
- [ ] Add `chrono` and `rust_decimal` and `serde_json` to workspace
- [ ] Update `RowObject` to handle full `Value` set (already typed as `Vec<Value>`, just needs the new variants)
- [ ] `value_to_display_text` / `value_to_edit_text` per type with locale-aware formatting

### Streaming results (~1 week)

- [ ] Replace `fetch_rows` materialization with sqlx `fetch` stream
- [ ] Backpressure model: read up to `PAGE_SIZE` rows, hold the stream open for next-page reads
- [ ] Memory-bounded grid: drop rows outside viewport (already virtualized in GTK, but model holds all rows)
- [ ] Cancellation: drop the stream when user navigates away

### Multi-connection / multi-tab architecture (~1 week)

- [ ] `DatabaseService` actor (worker component) owning `Vec<Arc<dyn Connection>>` keyed by connection id
- [ ] Replace `connection_holder` static singleton with service handle
- [ ] App state: `active_connections: HashMap<ConnectionId, ConnectionState>`
- [ ] `AdwTabView` for multiple open tables / queries within one connection
- [ ] Multi-window: each window holds its own active connection via `gtk::Application::add_window`

### Security baseline (~1 week)

- [ ] TLS configuration UI: cert path, verify mode, SNI override
- [ ] SSH tunnelling via `russh` crate (host, port, key path, optional jump host)
- [ ] Read-only mode toggle per connection (blocks UPDATE/DELETE/DROP from UI)
- [ ] Cancel running query (button + Esc shortcut + `Connection::cancel` driver method)
- [ ] Connection lost recovery: detect disconnect, show modal, retry button
- [ ] Statement timeout configurable per connection

### Integration tests (~0.5 weeks)

- [ ] Per-driver `tests/integration.rs` using `testcontainers-rs`
- [ ] Each driver: connect, list_tables, fetch_columns (with PK detection), fetch_rows pagination, execute_params CRUD, query
- [ ] Run in CI gated behind `--ignored` to avoid Docker dependency in fast-checks job

**Exit criterion**: Connect to a 10M-row Postgres table, scroll, edit a date column, lose network mid-query, see a recoverable error, reconnect via the same UI flow.

---

## Phase 3 — Beta release (4 weeks)

**Goal**: shippable to Flathub. A user installs and uses for real work.

### Browse UX (~1 week)

- [ ] Where-filter UI: per-column filter row above grid with operators (=, !=, LIKE, NULL, IN)
- [ ] ORDER BY wired to `GtkColumnView` header click → server sort
- [ ] Multi-row select via shift-click + Ctrl-click
- [ ] Bulk delete with confirmation
- [ ] Right-click context menu (copy cell, copy row as INSERT, copy column, set NULL, delete row)
- [ ] Save column widths and order per (connection, table)

### Export / import (~1 week)

- [ ] Export current grid to CSV / JSON / SQL INSERT / Markdown
- [ ] Export with options: include headers, quote style, line endings, UTF-8 BOM toggle
- [ ] Import CSV → table (with column mapping dialog)
- [ ] Run SQL file (load + execute via SQL editor)

### Schema browser (~1 week)

- [ ] Sidebar tabs: Tables, Views, Indexes, Foreign Keys, Triggers, Functions, Sequences
- [ ] Click view → SELECT * FROM view (re-uses browse view)
- [ ] Click index → show CREATE INDEX DDL + which columns
- [ ] Click FK → highlight columns + jump to referenced table
- [ ] Column metadata: type, nullable, default, comment

### Query history + saved queries (~0.5 weeks)

- [ ] SQLite FTS5 store at `$XDG_DATA_HOME/tablepro/history.db`
- [ ] Every executed query recorded with timestamp, duration, success, connection name
- [ ] History pane with full-text search
- [ ] Saved queries: name + SQL, organized by connection

### Connection management (~0.5 weeks)

- [ ] Connection groups (folders in saved-connections list)
- [ ] Color tags per connection
- [ ] Import / export connections to JSON file
- [ ] Clone connection
- [ ] "Test connection" button in dialog before save

### Distribution scaffolding (~1 week)

- [ ] `com.tablepro.linux.metainfo.xml` (AppStream metadata, screenshots refs, license SPDX)
- [ ] App icon set: 16/32/48/64/128/256/512 PNG + scalable SVG
- [ ] 4–5 high-resolution screenshots showing key flows
- [ ] Long description + short description in metainfo
- [ ] ContentRating
- [ ] `cargo-sources.json` generation via `flatpak-builder-tools/cargo`
- [ ] CI job: `flatpak-builder` builds the manifest end-to-end on each PR
- [ ] Submit to Flathub `flathub/flathub` PR → review → first publish

### Observability (~0.5 weeks)

- [ ] Structured JSON logging via `tracing-subscriber` JSON layer (env-toggleable)
- [ ] Crash reporter: panic hook captures backtrace, writes to log, optional anonymous upload (with explicit opt-in)
- [ ] "Help → Report bug" UI helper that opens the issue tracker pre-filled with sanitized log excerpt

**Exit criterion**: app published to Flathub stable channel; user installs via `flatpak install com.tablepro.linux`; runs against their Postgres + MySQL daily for one week without unrecoverable failure.

---

## Phase 4 — Beta polish (3 weeks)

**Goal**: shipped beta, accepting external bug reports, ready for first wave of public users.

### Internationalization setup (~1 week)

- [ ] `gettext` integration via `gettext-rs` or `cargo-i18n`
- [ ] Extract all user-facing strings to `.pot` template
- [ ] Locale detection from `LANG` env
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
- [ ] Manual install + smoke on Fedora 41, Ubuntu 24.04, Arch (latest), Debian 12

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

- [x] ClickHouse via the official `clickhouse` crate
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

- [ ] Create / alter / drop table via UI
- [ ] Add / remove / rename columns
- [ ] Add / remove indexes
- [ ] Add / remove foreign keys
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
| Phase 0 + 1 (current) | done | done |
| Phase 2 — Production hardening | 4 weeks FT | Sprint 1 |
| Phase 3 — Beta release | 4 weeks FT | Sprint 2 |
| Phase 4 — Beta polish | 3 weeks FT | Sprint 3 |
| **Beta on Flathub** | **11 weeks total** | **~3 months from start of Phase 2** |
| Phase 5 — GA expansion | 6 months FT | rolling |
| Phase 6 — Parity ambitions | 12+ months FT | optional |

At 50% effort (part-time), double everything. At 25% effort (side project), 4x.

---

## What changed in this revision

The previous version of this file had Phase 0 and Phase 1 as 4–6 weeks and 2–3 months respectively, then Phase 2 "Parity push" at 3–4 months and Phase 3 "Polish + distribution" at 1–2 months. Total ~8–12 months.

That sequence underestimated production hardening. Adding more drivers ("parity push") before fixing type system, streaming, multi-connection, and security would have shipped a feature-rich-but-fragile app. The new sequence prioritizes hardening first, then ships Beta on a smaller-but-solid surface, then expands.

The `Phase 1 — MVP (2–3 months)` checklist with mostly-checked items in the old roadmap was misleading — it implied "MVP done means shippable," when in fact our MVP is demo-grade and Beta is 11 weeks of focused work away.

This revision makes that explicit: **Phase 1 is the demo state. Beta is Phases 2 + 3 + 4.**
