# Architecture

TablePro Linux is a layered Rust workspace with strict, one-directional dependencies. The shape is chosen so that adding a database engine touches one crate, replacing the GUI framework would touch one crate, and the domain layer never imports either.

## Crate layout

```
linux/
├── Cargo.toml                     workspace manifest
├── flatpak/                       Flatpak manifest, icons, .desktop file
└── crates/
    ├── app/                       binary, GTK4 entry point, Relm4 components
    ├── core/                      domain types and traits, no GUI deps
    ├── storage/                   libsecret, gio::Settings, file persistence
    └── drivers/
        ├── postgres/              sqlx-postgres impl
        ├── mysql/                 sqlx-mysql impl
        ├── sqlite/                sqlx-sqlite impl
        └── ...                    one crate per database engine
```

## Dependency graph

```
                       ┌─────────┐
                       │   app   │  binary, all GUI code
                       └────┬────┘
                  ┌─────────┼──────────────────┐
                  ▼         ▼                  ▼
             ┌────────┐ ┌─────────┐   ┌──────────────────┐
             │  core  │ │ storage │   │   drivers/*      │
             └────────┘ └────┬────┘   └─────────┬────────┘
                             │                   │
                             └────►  ┌────────┐  ◄
                                     │  core  │
                                     └────────┘
```

Rules, enforced by review:

- `core` depends on **no other workspace crate**. Only the standard library and small utility crates (`async-trait`, `serde`, `thiserror`).
- `storage` depends on `core` only.
- Each `drivers/<engine>` crate depends on `core` only. **Drivers never depend on each other.**
- `app` depends on `core`, `storage`, and every `drivers/*`. It is the only crate that knows about every driver.
- No reverse dependencies. `core` never imports anything from `drivers/*` or `app`.

Consequences:

- Adding a driver does not touch `core`, `storage`, or any other driver.
- Replacing the GUI framework would require rewriting only `app`.
- Drivers can be unit-tested against `core` traits without pulling GTK.
- The build graph is shallow — incremental rebuilds stay fast.

## Composition root

The driver registry is built once in `app::main` before the GTK application starts running:

```rust
fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(drivers_postgres::PgDriver));
    r.register(Arc::new(drivers_mysql::MysqlDriver));
    r.register(Arc::new(drivers_sqlite::SqliteDriver));
    r
}
```

Adding a new driver = adding one workspace member + one `register` call. There is no runtime discovery, no ABI versioning, no plugin manifest. The trade-off is documented in [docs/decisions/0001-no-plugin-system.md](docs/decisions/0001-no-plugin-system.md).

## Async architecture

Two runtimes coexist:

- **glib's main context** runs the UI. Single-threaded. Owns all GTK widgets.
- **tokio runtime** owned by Relm4 runs all DB driver work and other async tasks.

Bridging uses Relm4's built-in primitives instead of hand-rolled channels:

- `sender.command(move |out, shutdown| shutdown.register(async move { ... out.send(...) }).drop_on_shutdown())` — a component-scoped tokio task that cancels when the component drops. The `out` sender feeds `CmdOutput` back into the component's update loop on the GTK thread. Used for every per-tab fetch (browse rows, schema introspection, save transaction).
- `relm4::spawn(async move { ... })` — fire-and-forget tokio task with no component lifetime tie. Used for storage writes (`touch_last_opened`, `query_history::record`, column-width persistence) and other side-effect work.
- `sender.input(AppMsg::...)` from inside an async block routes back into the component's `update` on the GTK thread. Combined with `sender.command`, this is how a "fetch-then-render" round trip lands its result on the right widget.

`main.rs` builds a tiny `tokio::runtime::Builder::new_multi_thread().worker_threads(1)` runtime exclusively to `block_on` the history-DB init / prune at startup, then `shutdown_timeout`s it before `RelmApp::run` takes over. The query-history sqlx pool is stored in a `OnceLock` and reused from Relm4's runtime afterward.

## UI architecture: Relm4

The `app` crate uses [Relm4](https://relm4.org) for component-based UI structure.

- **Component**: a unit of UI with explicit `Init`, `Input`, `Output`, `CmdOutput` types. State is private. All transitions go through `update`.
- **AsyncComponent**: same shape, but `init` and `update` may be `async`. Used for components that load data on creation.
- **Factory**: drives a list / grid of homogeneous child components from a model. Used for the table sidebar and similar lists.
- **CmdOutput**: how a component receives async results. The tokio bridge sends `CmdOutput` messages back into the component's update loop.

See [docs/state-management.md](docs/state-management.md) for the patterns and naming we use.

## Driver contract

Every driver crate exports a single zero-sized struct that implements `core::DatabaseDriver`. The trait is async (via `async_trait`), small, and stable.

```rust
#[async_trait::async_trait]
pub trait DatabaseDriver: Send + Sync {
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    fn default_port(&self) -> u16;
    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError>;
}
```

A `Connection` exposes the operations that `app` needs: list tables, fetch rows, run a query, etc. The full surface is defined in `core::connection`.

The full step-by-step guide for adding a driver lives in [docs/adding-drivers.md](docs/adding-drivers.md).

## Workspace tab system

The active connection drives a single `AdwTabView` hosting heterogeneous tabs. The `App` component owns the strip; tabs are typed via the `WorkspaceTab` enum:

```rust
pub enum WorkspaceTab {
    Editor(EditorTabSlot),     // SQL editor, free-form query
    Structure(StructureTabSlot), // New-Table draft only (Edit promotes to Table)
    Table(TableTabSlot),       // (schema, table) entity with Data / Structure
                               // sub-views toggled via AdwViewSwitcher
}
```

Each tab is a Relm4 `Controller<T>` whose widget the `AdwTabView` adopts. `App` keeps a `HashMap<Uuid, WorkspaceTab>` keyed by the tab's UUID; the canonical display order comes from `tab_view.pages()` (drag-reorderable). The UUID is stashed on the `AdwTabPage` via `glib::Quark` qdata so close / right-click actions can recover it.

App routing is hub-and-spoke: every per-tab event becomes an output that App's `forward(...)` closure tags with the tab's UUID and re-emits as an `AppMsg::*ForTab(id, ...)`. App's `update` looks up the slot and dispatches back to the controller's input. This keeps the per-tab controllers ignorant of each other and gives App one place to enforce cross-tab invariants (refetch siblings after Save, close all tabs for a dropped table, etc.).

Reopening a closed tab uses a 10-deep `VecDeque<ClosedTabDescriptor>` snapshot taken in `finish_close_workspace_tab` before the slot is dropped. The stack clears on disconnect because descriptors reference tables in the active connection.

## Per-tab pending-change registries

Two parallel thread-local registries hold the in-flight edit state for each tab, keyed by the same UUID as the workspace slot:

| Registry | What it tracks | Materialised by |
|---|---|---|
| `services::change_tracker` | Row-level INSERT / UPDATE / DELETE for browse tabs | `BrowseTab::commit_save` → `Vec<(String, Vec<Value>)>` |
| `services::structure_tracker` | Column / index / FK / table-rename DDL for structure tabs | `sql_ddl::materialize_ops` → `Vec<String>` |

Both registries live in `thread_local!` `RefCell<HashMap<Uuid, _>>` because relm4 + GTK is single-threaded on the UI side, and a single map keyed by tab UUID is simpler than passing trackers through every component handler. Helpers (`with_tab`, `with_tab_ref`, `open_tab`, `close_tab`, `any_pending_globally`) are the only public surface.

A `Table` tab owns BOTH a row tracker and a DDL tracker against the same UUID. `close_workspace_tab_by_id` closes both registries; the close-with-pending dialog ORs both `has_pending()` flags and may dispatch up to two save transactions, gated through a `close_after_save: HashMap<Uuid, u32>` counter.

The Structure tab is **snapshot + diff**, not per-op log. `original_*` snapshots capture the load-time schema; the diff against the live model produces ops via `sql_ddl::diff_to_ops`. Discard restores the snapshot. There is no per-op undo — Discard is the only restore point. The tracker just caches the most recent diff so out-of-band callers (close prompt, save dispatcher) read the same op list without re-deriving.

## Persistence

| Data | Backend | Path / table |
|---|---|---|
| Saved connections | JSON, atomic temp-file rename | `$XDG_CONFIG_HOME/tablepro/connections.json` |
| Connection passwords + SSH secrets | libsecret via `oo7` (Secret Service / KWallet) | keyring item per connection UUID |
| Per-connection workspace tabs | JSON, atomic temp-file rename, debounced 500 ms | `$XDG_DATA_HOME/tablepro/workspace.json` |
| Query history | SQLite + FTS5 virtual table | `$XDG_DATA_HOME/tablepro/history.db` |
| Application preferences | JSON, atomic temp-file rename | `$XDG_CONFIG_HOME/tablepro/preferences.json` |
| Window size / position | JSON | `$XDG_CONFIG_HOME/tablepro/window.json` |
| Per-table column widths | JSON | `$XDG_CONFIG_HOME/tablepro/column_widths.json` |

Forward compat: `WorkspaceTabRecord` uses `#[serde(other)] Unknown` so an old binary reading a newer file silently skips unknown variants instead of failing the whole load. `clamp_connection` runs on load to migrate legacy variants (`Browse`, `Structure { schema, table }`) into the unified `Table` shape.

`SavedConnection::last_opened_at: Option<DateTime<Utc>>` is stamped on each successful connect via `touch_last_opened`. The welcome view sorts by recency-first with alphabetical tiebreaker; never-opened entries fall to the bottom.

## Build & CI

The host runner image (`ubuntu-24.04`) ships glib 2.80, but the workspace pins `libadwaita = { version = "0.9", features = ["v1_6", "gtk_v4_6"] }` and `relm4 = { ..., features = ["gnome_47"] }`. Both `v1_6` and `gnome_47` transitively require `gio-2.0 >= 2.82` via `gio-sys`, so `cargo clippy --all-targets` fails the system-deps check on the host runner.

`.github/workflows/build-linux.yml` runs the **Fast checks** job inside a `container: ubuntu:25.10` (glib 2.84). The container is minimal so the install step has to pull `ca-certificates` + `curl` + `git` before rust-toolchain and Swatinem can run; full list of `-dev` packages stays the same. The **integration** job stays on the host runner because the driver crates depend only on `tablepro-core` and don't pull libadwaita.

Bumping libadwaita past 1.6 (or relm4 past `gnome_47`) means revisiting whether 25.10 still satisfies the new glib floor.

## Out of scope

- **Plugin system**. Drivers are static. The macOS plugin model does not transfer.
- **In-process scripting**. No embedded JavaScript / Python / Lua. SQL is enough.
- **Cross-platform builds**. Linux only. macOS / iOS have their own targets.
- **Hot reload**. Compile-time only. Use `cargo watch` during development.
