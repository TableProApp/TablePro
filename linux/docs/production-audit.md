# Production-readiness audit

> Historical record, written on 2026-04-26 at 28 commits and not updated since. It describes the app as it was then. [ROADMAP.md](../ROADMAP.md) has the current state; its release criteria come from [What "production-ready" means here](#what-production-ready-means-here).

**Date**: 2026-04-26
**Branch**: `linux`
**Commits**: 28
**State**: demo-grade

This document captures the full gap analysis between the current build and what "shippable on Flathub for real users" requires. It set the phase boundaries [ROADMAP.md](../ROADMAP.md) had then.

The intent is **realism, not pessimism**. The current build is a strong demo. It is also nowhere near beta-ship-able. Both can be true.

---

## What we have today

Functional path:
- Three drivers: PostgreSQL, SQLite, MySQL
- Connect dialog with engine picker
- Saved connections (JSON + libsecret) with delete + reconnect
- Table list sidebar with search filter
- Browse with `GtkColumnView` + `SignalListItemFactory` virtualization (100k rows scroll smoothly)
- Pagination via OFFSET/LIMIT (1000 rows/page)
- Modal Insert / Edit / Delete row dialogs (parameterized SQL)
- True in-place cell edit with snapshot-on-edit-start + force-cancel-on-recycle
- SQL editor with GtkSourceView 5 + Run + result grid
- Connection deduplication
- Disconnect button with state-driven header

Engineering:
- Relm4 SimpleComponent architecture
- All async via `sender.command` with auto-cancellation
- Typed errors with user-friendly message layer
- 31 unit tests (sql_dialect, grid, error_text, drivers, storage)
- CI: clippy `-D warnings`, fmt check, tests
- 4 ADRs documenting stack picks
- 5 pattern docs (state-management, storage, error-handling, testing, adding-drivers)

That puts the project at a developer-demo level: a contributor on the same machine can showcase the basics without the app crashing.

---

## What "production-ready" means here

A user on Fedora 41 or Ubuntu 24.04:

1. Installs `com.tablepro.linux` from Flathub via `flatpak install`
2. Connects to their everyday Postgres, MySQL, or SQLite database
3. Browses tables containing real-world data (dates, decimals, JSON, UUIDs, NULLs) and sees correct values
4. Runs typical queries against tables of arbitrary size (1M+ rows) without OOM or freeze
5. Edits data in-place; the changes commit correctly even when the connection or app misbehaves
6. Trusts the app with credentials (TLS, SSH tunnel, no plaintext leak)
7. Can recover when the network blips or the database restarts
8. Has reasonable accessibility (screen reader, keyboard nav, font scaling)
9. Does not see English error messages they cannot understand (i18n infrastructure, even if shipping en-only)
10. Uses the app daily for one week and does not file an unrecoverable-failure bug

The current build meets none of (3), (4), (6), (7), (8), (9), (10), and partially (5).

---

## Gap by category

### 1. Type system

**Current**: `core::Value` enum has Null, Bool, Int, Float, Text, Bytes — six variants.

**Production needs**: ~15-20 variants.

| Missing | Impact |
|---|---|
| `Date`, `Time`, `DateTime`, `TimestampTz` | Dates serialize as Text; lose timezone, lose ordering, can't be edited type-aware |
| `Decimal` (arbitrary precision) | NUMERIC(38,10) → f64 → silent precision loss. Financial data corrupts. |
| `Uuid` | UUID column → Text → string comparison instead of binary; works but slow + UI shows raw text |
| `Json` / `Jsonb` | No syntax highlighting, no validation, edits as raw text — JSON corrupts on edit |
| `Array<T>` | PG arrays render as `{a,b,c}` text — un-editable as structured data |
| `Interval`, `Range`, `Inet`, `Cidr` | Lost in Text representation |
| `Enum` | Renders text, no dropdown — user can type invalid value |

Per-type editor widgets also needed:
- Date picker for date / time / datetime
- Number spinner with column-type bounds (INT2/INT4/INT8 ranges, REAL/DOUBLE precision)
- JSON editor with syntax highlighting + bracket matching + validation
- Boolean toggle (instead of typing "true"/"false")
- File chooser for BLOB
- Tag input for arrays

### 2. Result scaling

**Current**: `fetch_rows` returns `QueryResult { columns: Vec<ColumnInfo>, rows: Vec<Vec<Value>> }` — full materialization.

**Production gaps**:
- 1M+ rows: 1M Vec<Value>s in memory → likely OOM or seconds-of-jank at fetch
- Wide tables (200 cols × 100k rows): 20M Value allocations
- OFFSET pagination at offset 1M+: Postgres re-scans linearly → seconds-to-minutes per page
- No streaming: sqlx supports `fetch` returning a Stream, we ignore it
- No background fetch: UI freezes if query takes >1 second
- Single connection at a time per app: can't browse table while running SQL editor query
- No query plan analysis (EXPLAIN integration)
- No keyset pagination for large offsets

### 3. Connection management

**Current**: `connection_holder` is a `OnceLock<RwLock<Option<Arc<dyn Connection>>>>` static. One connection at a time globally. Switching DBs replaces it.

**Production gaps**:
- Multi-tab: open table A, table B, plus SQL editor for connection X simultaneously
- Multi-window: each window with its own connection
- Multi-connection: simultaneously connected to PG and SQLite
- Connection pooling configuration (sqlx pool size hardcoded to 4)
- Per-connection statement timeout, application_name, search_path
- Connection state visualization (connected/disconnected/transaction-active)

The architectural fix is a `DatabaseService` actor (Relm4 Worker) owning a HashMap<ConnectionId, Pool>. The current static singleton blocks every multi-connection feature.

### 4. Driver depth

**Have** (3): Postgres, SQLite, MySQL.

**Production parity** requires 8-12 drivers depending on target audience. Each is 150-300 lines + integration tests + per-engine quirks (MSSQL pagination is `OFFSET ... ROWS FETCH NEXT`, ClickHouse is push-down query language, MongoDB is documents not rows, Redis is K/V not relational).

**Driver-level features absent across all current drivers**:
- TLS configuration UI: `use_tls: bool` field exists, no cert path / verify mode / SNI
- SSH tunnelling
- Connection pooling parameters
- Query cancellation API
- Server version detection
- Driver capability detection (LISTEN/NOTIFY for PG, COPY FROM, etc.)
- Transaction control (BEGIN/COMMIT/ROLLBACK from UI)
- Stored procedure invocation (esp. MSSQL/Oracle)
- Prepared statement caching
- Statement timeout

### 5. Reliability

**Have**:
- Parameterized SQL ✓
- Typed-error → user-friendly message ✓
- Force-cancel mid-edit on widget recycle ✓
- Auto-cancellation of in-flight commands on component shutdown ✓

**Missing**:
- Connection lost mid-query: no detection, no reconnect, query hangs
- Idle disconnect: PG kills idle connections after `idle_in_transaction_session_timeout`; we don't reconnect
- Cancel running query: no UI button, no plumbing (sqlx supports it)
- Network blip: no retry
- Concurrent edits across two windows: last-write-wins, no detection
- Crash recovery: editor content lost on crash
- No "are you sure?" beyond DELETE row (DROP TABLE in SQL editor runs immediately)
- No read-only mode toggle
- Bulk operation safeguards (TRUNCATE, mass UPDATE without WHERE)

### 6. Security

**OK**:
- Parameterized SQL everywhere — no injection
- libsecret for passwords — no plaintext credentials on disk
- No password ever logged

**Production gaps**:
- TLS UI absent (only boolean field)
- SSH tunnel absent
- App-level encryption of connection JSON (currently plain JSON in `~/.config/`)
- Audit log of write operations
- Read-only mode (prevent UPDATE/DELETE/DROP entirely)
- Bulk operation guard (TRUNCATE, UPDATE without WHERE)
- Flatpak sandbox is permissive (`--filesystem=home`, `--share=network`) — necessary but should narrow where possible
- No certificate pinning for cloud-managed databases

### 7. Distribution

**Manifest exists**: `flatpak/com.tablepro.linux.json` skeleton + desktop file from Phase 0.

**Reality**:
- Manifest never built locally with `flatpak-builder`
- `cargo-sources.json` for offline build: not generated
- `com.tablepro.linux.metainfo.xml`: missing (Flathub blocker — AppStream metadata is required)
- Icon set: 0 icons. Need 16/32/48/64/128/256/512 PNG + scalable SVG
- Screenshots: 0. Flathub requires 4-5 high-res
- Long description, short description: missing
- License declaration in metainfo (SPDX): missing
- ContentRating: missing
- D-Bus name registration verification: missing
- Reproducible build verified: no
- Submission to Flathub: not started
- AppImage build: not built
- `.deb` / `.rpm` / AUR PKGBUILD: not packaged
- Auto-update via Flathub: works for free once published
- Version-bumping process: ad-hoc commits

### 8. Internationalization

**Current**: 100% English hardcoded. No `gettext`. No format strings extracted. No locale detection.

**For real product**: every user-visible string needs `gettext!()` or equivalent, `.po` files, build pipeline integration with `meson` or `cargo-i18n`, locale detection from `LANG` env, RTL layout testing for Arabic / Hebrew. Even if we ship English-only, the infrastructure must exist.

### 9. Accessibility

**Untested**:
- Screen reader (Orca / GNOME a11y)
- Keyboard-only flow (we rely on mouse for sidebar table click, popover open, etc.)
- Focus indicators
- High contrast mode
- Font scaling (`gsettings text-scaling-factor`)
- Color blindness (we use color-only signals: orange Connect, red Delete)
- ARIA-equivalent labels via GTK4 `Accessible` interface

GTK4 gives us 70% for free, but custom widgets (`gtk::EditableLabel` cells, popovers) need explicit testing.

### 10. Testing

**Numbers**: 31 unit tests (sql_dialect 10, grid 6, error_text 3, drivers 7, storage 5).

**Production gaps**:
- 0 integration tests against real DBs (1 ignored testcontainers test exists)
- 0 UI tests (Relm4 components untested)
- 0 end-to-end smoke test
- 0 performance benchmarks
- 0 fuzz tests for SQL parsing
- 0 multi-driver matrix tests
- 0 multi-distro CI (Ubuntu only)
- 0 multi-DE testing (GNOME only, KDE/Plasma untested)
- 0 multi-runtime testing (X11 vs Wayland)
- 0 memory leak / Valgrind runs
- 0 cargo-audit / cargo-deny in CI
- 0 code coverage reporting

### 11. UX completeness

**Have**: connect, browse, paginate, in-place edit, modal CRUD, SQL editor, search tables, disconnect.

**Missing for "I'd use this daily" baseline (TablePro/DBeaver level)**:
- Multi-tab queries (open 3 tables + 2 SQL editors simultaneously)
- Multi-window
- ORDER BY wired to `GtkColumnView` header click → server sort
- Where-filter UI for browse
- Multi-row select + bulk delete
- Copy result as INSERT / CSV / JSON / Markdown
- Export grid to CSV / XLSX / JSON / SQL
- Import CSV / SQL dump
- Schema browser: views, indexes, FKs, triggers, functions, sequences
- Schema editor (CREATE/ALTER/DROP via UI)
- ER diagram
- Query history (FTS5 search)
- Saved queries / snippets
- SQL autocomplete (tables, columns, keywords, schema-aware)
- SQL formatter
- Multi-statement execution
- Run-selection only
- Vim mode in editor
- Keyboard shortcut reference dialog
- Right-click context menus everywhere
- Toast notifications for success/error
- Loading spinners
- Empty states with actions
- Recent files / connections
- Drag-reorder columns persisted per table
- Resize columns persisted per table

### 12. Architecture for sustained development

**Per ADRs**: no plugin system, static drivers. Every new database engine ships in main binary. Acceptable design choice but caps the ecosystem.

**Service layer absent**: `App` directly calls `connection_holder::get()` and spawns commands. A `DatabaseService` worker would centralize: connection lifecycle, retry, cancellation, metrics, instrumentation. Without it, multi-tab and multi-connection cannot be built cleanly.

**App is a god-component**: ~900 lines, 25+ AppMsg variants. For multi-tab + multi-window, will need split into `WorkspaceComponent`, `ConnectionsComponent`, `EditorComponent`, `SchemaBrowserComponent`.

### 13. Observability

**Have**: `tracing` + `tracing-subscriber` with default text formatter. Can ship to journald.

**Production**:
- Structured JSON logs (for log aggregation)
- Log level configurable via `RUST_LOG` env (works) and via Settings UI (no)
- Log rotation
- Crash dumps with symbols (Sentry-style, optional, opt-in)
- Anonymous error reporting with explicit user opt-in
- "Report bug" UI helper that auto-attaches relevant logs
- No metrics (query duration histograms, connection count gauges)
- No remote log shipping infrastructure

### 14. Documentation

**Internal docs** ✓:
- README, ARCHITECTURE, CONTRIBUTING, ROADMAP
- 4 ADRs (no-plugin, rust-gtk4-libadwaita, relm4, libsecret)
- 5 pattern docs (state-management, storage, error-handling, testing, adding-drivers)
- This file (production-audit)

**End-user docs missing**:
- User manual
- Per-database connection guide (PG cert auth, MySQL SSL, SQLite WAL)
- Keyboard shortcut reference
- Troubleshooting (common errors, env issues)
- FAQ
- Video walkthroughs
- Marketing site
- Privacy policy / data handling

---

## Critical path to Beta

Ordered by dependency. Each item gates the next.

1. **Type system expansion** — without Date / Decimal / Uuid / Json, real data corrupts. Foundation.
2. **Streaming results** — without it, browsing real tables OOMs.
3. **DatabaseService actor + multi-connection** — without it, multi-tab is impossible and the test surface stays narrow.
4. **TLS UI + SSH tunnelling** — security baseline; without it, users on managed databases (RDS, Aiven, Cloud SQL) cannot connect.
5. **Cancel + reconnect** — reliability baseline; without it, any network blip is unrecoverable.
6. **Integration tests per driver** — without them, every Phase 5 driver addition risks regressions in the existing three.
7. **AppStream metainfo + icons + screenshots** — Flathub blocker.
8. **Where-filter + sort + multi-row select** — daily-driver UX baseline.
9. **Export to CSV/JSON/SQL** — minimum exit functionality (users need to share results).
10. **Schema browser** — without it, app is a glorified `SELECT *` runner.
11. **Crash reporter + structured logs** — observability baseline.
12. **i18n setup** — even shipping English-only requires the infrastructure for future translations.
13. **Accessibility audit pass** — Orca testing, keyboard nav, focus indicators.
14. **Connection groups + import/export** — power-user UX.
15. **Query history with FTS5** — already designed in ROADMAP, easy win at this point.

That's roughly 12-14 weeks of focused full-time engineering, plus 2-3 weeks slack for discovery. **3-4 months realistic.**

---

## Effort tiers

| Tier | What it covers | Cumulative effort (FT) |
|---|---|---|
| **Demo** (current) | Compile and run on dev machine; 3 drivers; basic CRUD; single connection | done |
| **Beta** | Flathub published; full type system; multi-tab; integration tests; accessibility; i18n; TLS UI | **~3 months** |
| **GA** | Above + SSH tunnelling; schema browser/editor; ER diagram; query history; vim mode; keyboard shortcuts; multi-DE; full a11y; marketing assets | **~9 months** |
| **Parity (DBeaver-class)** | Above + 12+ drivers; SQL formatter; query plan visualization; replication monitoring; sync/diff tools | **~24 months** |

Currently at **Demo**. Beta is the right "production-ready ship-able" target; the project should aim for that and not skip ahead.

---

## What this document does not say

- **Which features matter most** — that depends on target audience (Postgres-only devs vs polyglot DBAs vs analysts). The ROADMAP makes a defensible default ordering; product strategy can override.
- **Solo vs team feasibility** — these timelines assume one focused full-time engineer. Solo + part-time = 3-4x calendar.
- **When to ship** — shipping Beta on a smaller solid surface beats shipping GA on a feature-rich fragile surface. The ROADMAP's choice to do hardening before driver expansion reflects this.
- **Cost** — engineering time is the dominant cost. Flathub publishing is free. Distribution adds no revenue without a business model.

This audit is a snapshot at 2026-04-26 and is not re-run.
