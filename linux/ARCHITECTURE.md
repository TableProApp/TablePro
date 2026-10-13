# Architecture

TablePro Linux is a layered Rust workspace with strict, one-directional dependencies. The shape is chosen so that adding a database engine touches one crate, replacing the GUI framework would touch one crate, and the domain layer never imports either.

## Crate layout

```
linux/
├── meson.build                    build entry point; owns install and the build-time config
├── Cargo.toml                     workspace manifest
├── data/                          desktop entry, D-Bus service, AppStream metainfo, icons, GResource
├── build-aux/flatpak/             Devel Flatpak manifest and krb5.conf
├── po/                            translation catalogue
└── crates/
    ├── app/                       binary, GTK4 entry point, Relm4 components
    ├── core/                      domain types and the driver contract, no GUI deps
    ├── net/                       direct TCP transport and rustls client configs
    ├── ssh/                       system OpenSSH transport and the askpass helper
    ├── session/                   connect, sessions, health monitor, operation runner
    ├── storage/                   secrets, settings, file persistence
    ├── test-fixtures/             dev-only container fixtures with a generated PKI
    ├── test-support/              dev-only fakes and the conformance suites
    └── drivers/
        ├── postgres/              tokio-postgres
        ├── mysql/                 sqlx-mysql, MySQL and MariaDB
        ├── sqlite/                sqlx-sqlite
        ├── mssql/                 tiberius
        └── clickhouse/            clickhouse over hyper
```

## Dependency graph

| Crate | Depends on |
|---|---|
| `core` | no workspace crate |
| `net`, `ssh`, `storage` | `core` |
| `drivers/postgres`, `drivers/mysql`, `drivers/mssql`, `drivers/clickhouse` | `core`, `net` |
| `drivers/sqlite` | `core` |
| `session` | `core`, `net`, `ssh`, `storage` |
| `app` | every crate above |

Rules, enforced by review:

- `core` depends on **no other workspace crate**. It holds the domain types and the driver contract, and no I/O beyond the traits.
- `net`, `ssh` and `storage` depend on `core` only.
- Each `drivers/<engine>` crate depends on `core`, and on `net` when it speaks TLS or dials TCP. **Drivers never depend on each other, on `session` or on `ssh`.**
- `session` depends on `core`, `net`, `ssh` and `storage`, and on no driver: it reaches drivers through `DriverRegistry`.
- `app` depends on all of them. It is the only crate that names every driver.
- `test-support` and `test-fixtures` are dev-dependencies, with one exception: `session` takes `test-support` as an optional dependency behind its `fakes` feature, which only `app`'s dev-dependencies turn on.

Consequences:

- Adding a driver does not touch `core`, `session`, `storage` or any other driver.
- Replacing the GUI framework would require rewriting only `app`.
- Drivers are tested against `core` traits without pulling GTK.

## Composition root

The driver registry is built once, by `build_registry` in `crates/app/src/lib.rs`, before the GTK application starts running:

```rust
fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(drivers_clickhouse::ClickhouseDriver));
    r.register(Arc::new(drivers_mssql::MssqlDriver));
    r.register(Arc::new(drivers_mysql::MysqlDriver));
    r.register(Arc::new(drivers_postgres::PgDriver));
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

- `sender.command(move |out, shutdown| shutdown.register(async move { ... out.send(...) }).drop_on_shutdown())`: a component-scoped tokio task that cancels when the component drops. The `out` sender feeds `CmdOutput` back into the component's update loop on the GTK thread. Used for every per-tab fetch (browse rows, schema introspection, save transaction).
- `relm4::spawn(async move { ... })`: a fire-and-forget tokio task with no component lifetime tie. Used for storage writes (`touch_last_opened`, `query_history::record`, column-width persistence) and other side-effect work.
- `sender.input(AppMsg::...)` from inside an async block routes back into the component's `update` on the GTK thread. Combined with `sender.command`, this is how a "fetch-then-render" round trip lands its result on the right widget.

`main.rs` builds a tiny `tokio::runtime::Builder::new_multi_thread().worker_threads(1)` runtime exclusively to `block_on` the history-DB init / prune at startup, then `shutdown_timeout`s it before `RelmApp::run` takes over. The query-history sqlx pool is stored in a `OnceLock` and reused from Relm4's runtime afterward.

## UI architecture: Relm4

The `app` crate uses [Relm4](https://relm4.org) for component-based UI structure.

- **Component**: a unit of UI with explicit `Init`, `Input`, `Output`, `CmdOutput` types. State is private. All transitions go through `update`.
- **AsyncComponent**: same shape, but `init` and `update` may be `async`. Used for components that load data on creation.
- **Factory**: drives a list / grid of homogeneous child components from a model. Used for the table sidebar and similar lists.
- **CmdOutput**: how a component receives async results. The tokio bridge sends `CmdOutput` messages back into the component's update loop.

See [docs/state-management.md](docs/state-management.md) for the patterns and naming we use.

## Driver layer

How the app reaches a database: the contract in `tablepro-core`, a transport that carries the bytes, TLS each driver builds from the connection's trust settings, and a session that watches the link.

### The contract

`DatabaseDriver` describes an engine before any connection exists, through `DriverCapabilities`, and opens a `Connection`. The `Connection` serves the workspace from a pool; every call takes `CallOptions` (a deadline and a cancel token) and runs on a task the connection owns (`OwnedCalls`), so a stop reaches the server instead of leaving the statement running. Saves report what they left in the database through a `WriteLedger`. Each editor tab gets an `EditorSession` of its own that streams results into a `ResultSink`. [docs/adding-drivers.md](docs/adding-drivers.md) is the full contract, [ADR 0016](docs/decisions/0016-driver-contract-v2.md) the reasons for it, and the engine pages say how each driver meets it: [PostgreSQL](docs/drivers/postgresql.md), [MySQL and MariaDB](docs/drivers/mysql.md), [SQLite](docs/drivers/sqlite.md), [SQL Server](docs/drivers/sql-server.md), [ClickHouse](docs/drivers/clickhouse.md).

### Connecting

`DriverConnector` in `tablepro-session` turns a saved connection into a connected one:

1. It checks the request against the driver's capabilities: the auth mode, the TLS settings for the route, a required database name.
2. It builds the transport: `SshSession::connect` and then `SshSession::forward` for an SSH connection, or a `DirectTcpTransport`.
3. It calls `DatabaseDriver::connect` with `ConnectOptions`: the `NetworkTarget` (transport, credentials, database, TLS settings) or the `FileEndpoint`, the `WorkspaceSettings`, the `LivenessPolicy` and the app's version.
4. It reads the first catalogue, the schemas and the default schema's objects, under the metadata deadline.

The cancel token is checked between stages, and a stage that finishes after a cancel closes what it built, because a driver blocked in a login cannot always be interrupted.

### Transports

`Transport` (`crates/core/src/transport.rs`) is how a driver reaches a server without knowing whether the route is direct or through SSH:

- `service_endpoint()`: the host and port the user typed, which TLS verifies and Kerberos names.
- `kind()` and `route()`: `DirectTcp` with a TCP endpoint, or `SshForward` with the Unix socket the forward listens on.
- `open()`: a new byte stream to the server.
- `reroute(endpoint)`: the same kind of route to another endpoint, for SQL Server's login routing.
- `explain_closed_stream()`: why a stream closed, when the transport knows better than "connection lost", as when the SSH master exited.

| | `DirectTcpTransport` (`tablepro-net`) | `SshForwardTransport` (`tablepro-ssh`) |
|---|---|---|
| `open` | Resolves the name, then tries each address in turn under the connect timeout | Connects to the forward's Unix socket under the connect timeout |
| Socket options | `TCP_NODELAY`; keepalive after 30 s idle, every 10 s, 3 probes; `TCP_USER_TIMEOUT` 45 s | OpenSSH's own: `ServerAliveInterval=15`, `ServerAliveCountMax=3` |
| `reroute` | A new direct transport | A new forward on the same master |
| `explain_closed_stream` | Nothing to add | The master's exit, or the "open failed" line ssh printed |

PostgreSQL, SQL Server and ClickHouse open every stream through `open()`. sqlx dials its own sockets, so the MySQL driver passes it the route instead: host and port, or the forward's socket path. Nothing relays bytes between the two. The socket options above apply only to streams `open()` makes, so a direct MySQL connection has no keepalive and finds a dead peer through the probe and its deadlines.

SSH runs the system OpenSSH client ([ADR 0013](docs/decisions/0013-openssh-client-transport.md)): one ControlMaster (`ssh -M -N -T`) per connection, with the user's `~/.ssh/config` applied, and one `ssh -O forward` Unix socket per server it reaches. The sockets live under `$XDG_RUNTIME_DIR/app/<app id>/ssh/` in directories only the user can open, with mode 0600. Every prompt (host key, password, passphrase, keyboard-interactive) reaches the app through the `tablepro-askpass` helper, and the 20 s handshake timeout pauses while a prompt is open. Under Flatpak, `ssh` comes from the GNOME runtime, and a `ProxyCommand` or `Match exec` that runs a host program, the host's `/etc/ssh` and FIDO keys kept in files do not work.

### Trust

A connection's `TlsConfig` holds the `TlsMode`, an optional CA file, an optional client certificate and key, and an optional server name:

- `Disable`: no TLS.
- `Require`: encrypted, and the certificate is not checked.
- `VerifyFull`: the certificate must chain to a trusted root and carry the server name.

The name checked is `NetworkTarget::tls_server_name()`: the override when one is set, otherwise the host the user typed, never the address of a local SSH forward. `TlsConfig::validate` refuses a mode, file or override the driver cannot use on that route, and the connect dialog reads the chosen files up front, so a file with no certificate is named before anything connects.

Each engine's TLS stack takes trust in its own form, so the driver builds it:

| Engine | `VerifyFull` trusts | Client certificate | A failure is classified from |
|---|---|---|---|
| PostgreSQL | The system store (rustls-platform-verifier), plus the CA file | Yes | The rustls error |
| ClickHouse | The system store (rustls-platform-verifier), plus the CA file | Yes, as the login, with no password sent | The rustls error |
| MySQL, MariaDB | The system store and the CA file as one PEM bundle (`tablepro_net::tls::mysql_ca_bundle_pem`), plus the Mozilla roots compiled into sqlx | Yes | The rustls error |
| SQL Server | The system store (loaded by tiberius), plus the CA file | No | rustls's message text, because tiberius keeps nothing else |
| SQLite | No TLS | | |

PostgreSQL and ClickHouse get their rustls `ClientConfig` from `tablepro_net::tls::build_client_config`. Every engine uses the aws-lc-rs provider ([ADR 0009](docs/decisions/0009-crypto-provider-and-sources.md)). A CA file is added to the engine's roots, never in place of them. `docs/error-handling.md` lists [what each TLS failure means and what the app offers](docs/error-handling.md#tlsfailure-and-its-remedies).

On Linux the system store is the distribution's CA bundle. Under Flatpak it is the runtime's bundle: a CA added on the host with `update-ca-certificates` or `update-ca-trust` is not visible in the sandbox (freedesktop-sdk issue 1905).

#### Choosing a CA file under Flatpak

- For a server whose certificate comes from a private CA, choose the CA's PEM file in the connection's TLS settings, whatever the host trusts.
- The development manifest grants `--filesystem=home`, so a file under your home folder is read at its real path.
- A file chosen from outside the home folder comes back from the file chooser portal as a path under `/run/user/<uid>/doc/`. It works for as long as the portal keeps the grant. If it goes, the connect fails naming the CA file, and choosing the file again fixes it. Keeping a copy of the CA in your home folder avoids this.
- The file is read at every connect, so a replaced CA applies on the next connect.

### Liveness and deadlines

`LivenessPolicy::DESKTOP` bounds every phase of a connection:

| Bound | Value |
|---|---|
| TCP connect, per address | 10 s |
| Login, including TLS | 15 s |
| TCP keepalive | after 30 s idle, every 10 s, 3 probes |
| `TCP_USER_TIMEOUT` | 45 s |
| Probe | 5 s |
| Wait for a pool slot | 5 s |
| Cancel grace, after a stop | 5 s |
| SSH handshake, paused while a prompt is open | 20 s |
| SSH forward request | 10 s |
| SSH keepalive | every 15 s, 3 missed |
| Close | 10 s |

`DefaultDeadlines` in `tablepro-session` sets each operation's deadline: metadata 15 s, a page or a count 60 s, row changes 120 s, schema changes none. A call returns within its deadline plus the cancel grace.

### Sessions and health

A window holds one `Session`. Every use of its connection goes through the `OperationRunner`, which adds no timer of its own: the deadline travels in `CallOptions` so the driver stops the statement on the server. The session's monitor probes every 30 s and calls the connection lost after three failed probes in a row, or as soon as `Connection::lost()` fires, which a driver resolves only when the link is gone, never for one dead backend in its pool. It then reconnects on a backoff from 5 s to 60 s. A failure that a retry cannot fix (authentication, TLS, configuration, a host key to review) parks the session until the user acts. A read that failed because its connection was lost runs once more on the replacement link; a save never does.

The session's `SchemaCatalog` holds what the window knows about the database: the schemas, each scope's objects and each table's columns. Callers that ask for the same thing at once share one fetch, a fetch runs as its own task so a view that closes does not stop it, and a failed refresh keeps the list it had. A reconnect commits the catalog the new connection read and marks the rest stale; `invalidate_table` does the same for one table after a schema change. The sidebar follows the default schema's list through a watch the window drops before the session closes. The editor's completion reads the catalog when it opens: the default schema's objects, a named schema's objects after `schema.`, and the columns of the tables the statement names.

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

Each tab is a gtk-rs widget with a composite template, which the `AdwTabView` adopts. `App` keeps a `HashMap<Uuid, WorkspaceTab>` keyed by the tab's UUID; the canonical display order comes from `tab_view.pages()` (drag-reorderable). The UUID is stashed on the `AdwTabPage` via `glib::Quark` qdata so close / right-click actions can recover it.

App routing is hub-and-spoke: a tab emits signals, and the closures App connects tag them with the tab's UUID and re-emit them as `AppMsg` inputs. App's `update` looks up the slot and calls back into the tab. This keeps the tabs ignorant of each other and gives App one place to enforce cross-tab invariants (reload the tabs on a table whose schema changed, close all tabs for a dropped table, etc.).

A browse or structure tab reads its own data through the session. A `RequestSequencer` keeps one request of each kind current: a new page stops the one it replaces, and a reply to a replaced request is dropped. A page and a count wait for the table's columns from the catalog. A read that failed is asked again once the session reconnects, while a tab whose reads all landed keeps its rows. Closing a tab stops its reads, so the server drops the statement.

Reopening a closed tab uses a 10-deep `VecDeque<ClosedTabDescriptor>` snapshot taken in `finish_close_workspace_tab` before the slot is dropped. The stack clears on disconnect because descriptors reference tables in the active connection.

## Per-tab pending-change registries

Each window owns two registries holding the in-flight edit state for its tabs, keyed by the same UUID as the workspace slot. App creates them, registers a tracker when it opens a tab, passes the handle into the tab's init, and unregisters it when the tab closes or the connection goes away:

| Registry | Handle | What it tracks | Materialised by |
|---|---|---|---|
| `ChangeTrackerRegistry` | `TabTrackerHandle` | Row-level INSERT / UPDATE / DELETE for Table tabs | `TabTrackerHandle::change_set` → `TrackedChanges` |
| `StructureTrackerRegistry` | `StructureTrackerHandle` | The table's definition, the user's `TableDraft` and the `TableChanges` between them, for Structure tabs | `PendingStructure::plan` through the connection's `DdlDialect` → `DdlPlan` |

A handle is a newtype over `Rc<RefCell<_>>`. Every method borrows only for its own body, calls no GTK and no callbacks, and returns owned data (`CellOverlay`, `RowState`, `TrackerDelta`), so a grid bind that runs while a tab is applying a change never meets a held borrow. A row edit goes in as a `TrackerEdit` and comes back as a `TrackerDelta`: the rows to rebind, the draft rows the list store gains, loses or updates, and the new pending count. The tab applies it to its `gio::ListStore` after the call returns. Every pending change carries a `Touch` from the tracker's counter. An `UndoOp` holds the pending state on both sides of a step, touch included, so undo after A, B, C shows B, not the fetched value. `change_set` emits one change per row in touch order, and `plan_save` keeps that order: a row deleted and replaced by a draft with the same unique value saves, because its DELETE runs first. `App::dirty_tabs` reads both registries for the close prompts, the teardown guard and the `•` title prefix. CI fails on a `thread_local!` under `crates/app/src/services`, since a process-wide registry would share one window's unsaved edits with every other window.

The Structure tab is **definition + draft**, not a per-change log. The `TableDefinition` one read returned is what the tab plans against; `diff_table` turns the draft into `TableChanges`, and the engine's `DdlDialect` plans them into statements in its own order. Discard copies the definition back over the draft, and is the only restore point. The tracker holds the latest `PendingStructure`, so the close prompt and the save dispatcher read the same change without the tab, and the save plans it again with the dialect of the connection that runs it ([ADR 0010](docs/decisions/0010-ddl-plans-and-table-definitions.md)).

## Persistence

| Data | Backend | Path / table |
|---|---|---|
| Saved connections | JSON, `g_file_set_contents_full` CONSISTENT + DURABLE, 0600 | `$XDG_CONFIG_HOME/tablepro/connections.json` |
| Connection passwords + SSH secrets | libsecret via `oo7` (Secret Service / KWallet) | keyring item per connection UUID |
| Workspace tabs, one file per session | JSON, durable write, debounced 500 ms, off the GTK thread | `$XDG_STATE_HOME/tablepro/workspaces/<connection id>.json`, `file-<sha256 of the URI>.json` for an unsaved file |
| Editor tab text | one file per tab, debounced 500 ms | `$XDG_DATA_HOME/tablepro/drafts/<workspace name>/` |
| Query history | SQLite + FTS5 virtual table, 0600 | `$XDG_STATE_HOME/tablepro/history.db` |
| Application preferences | GSettings | schema `app.tablepro.TablePro` |
| Window size / maximized | GSettings | schema `app.tablepro.TablePro` |
| Per-table column widths | JSON, durable write | `$XDG_CONFIG_HOME/tablepro/column_widths.json` |
| Single-instance lock | `flock` on an empty file | `$XDG_RUNTIME_DIR/app/<app-id>/tablepro.lock` |

`WorkspaceStore` reads a session's file once its session is adopted, and the window writes the tab list only after that read, so a write never lands on tabs not yet restored. A file that cannot be read, that another version wrote, or that is over 1 MiB is left as it is and nothing is written over it until the user picks Reset on the toast, which moves it aside as `<name>.json.corrupt-<seconds>`. Every open tab is saved and restored, with no cap on the count. Writes go through one task that keeps the newest record per file. Editor records carry a draft id, never the text, and the editor's `content-changed` signal carries no text either: the tab label reads at most 200 characters.

A restore deletes the drafts no saved or open tab names, except while a moved-aside copy of the session's file is there, since that copy may name them. A draft that cannot be read is moved aside as `<id>.sql.corrupt-<seconds>`, which the cleanup never deletes, and its tab opens empty with a toast. A disconnect writes the open tabs' text before their buffers go.

`SavedConnection::last_opened_at: Option<DateTime<Utc>>` is stamped on each successful connect via `touch_last_opened`. The welcome view sorts by recency-first with alphabetical tiebreaker; never-opened entries fall to the bottom.

## Build & CI

Meson is the build system and Cargo is the Rust compiler; see [ADR 0006](docs/decisions/0006-meson-cargo-build.md). `meson setup _build && meson compile -C _build` produces `tablepro` and `tablepro-askpass`, and `meson test -C _build` runs the `unit`, `gtk` and `data` suites.

The floor is GNOME 50 (GTK 4.22, libadwaita 1.9, GtkSourceView 5.18, GLib 2.88); see [ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md). The host runner image (`ubuntu-24.04`) ships GLib 2.80, well below that, so the system-deps check fails there.

`.github/workflows/build-linux.yml` runs the **Fast checks** job inside a `container: ubuntu:26.04`, which ships GLib 2.88 and the meson, appstream and desktop-file-utils packages the data suite needs. The container is minimal, so the install step pulls `ca-certificates`, `curl` and `git` before rust-toolchain and Swatinem can run. The **integration** job stays on the host runner because the driver crates depend only on `tablepro-core` and `tablepro-net` and don't pull libadwaita.

## Out of scope

- **Plugin system**. Drivers are static. The macOS plugin model does not transfer.
- **In-process scripting**. No embedded JavaScript / Python / Lua. SQL is enough.
- **Cross-platform builds**. Linux only. macOS / iOS have their own targets.
- **Hot reload**. Compile-time only. Use `cargo watch` during development.
