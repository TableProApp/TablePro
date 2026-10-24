# Architecture

TablePro Linux is a layered Rust workspace with strict, one-directional dependencies. The shape is chosen so that adding a database engine touches one crate, replacing the GUI framework would touch one crate, and the domain layer never imports either.

## Crate layout

```
linux/
├── meson.build                    build entry point; owns install and the build-time config
├── Cargo.toml                     workspace manifest
├── about.toml                     cargo-about settings for the third-party license notices
├── data/                          desktop entry, D-Bus service, AppStream metainfo and screenshots, GSettings schema, man page, icons, GResource, licenses
├── build-aux/flatpak/             Devel Flatpak manifest, lint exceptions and krb5.conf
├── build-aux/debian/, rpm/        .deb and .rpm packaging
├── build-aux/packaging/, tests/   scripts that build, check and smoke-test the packages, and their tests
├── build-aux/about/               templates that turn Cargo.lock into data/licenses
├── po/                            translation catalogue
└── crates/
    ├── ai/                        the AI assistant's providers, prompts and replies, no GUI deps
    ├── app/                       binary, the GTK application, its windows and views
    ├── core/                      domain types and the driver contract, no GUI deps
    ├── mcp/                       the MCP server: transport, token and tools, no GUI deps
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
        ├── duckdb/                duckdb, with DuckDB compiled in
        ├── mssql/                 tiberius
        ├── clickhouse/            clickhouse over hyper
        ├── cassandra/             scylla, Cassandra and ScyllaDB
        ├── redis/                 redis-rs
        └── mongodb/               the mongodb crate
```

## Dependency graph

| Crate | Depends on |
|---|---|
| `core` | no workspace crate |
| `net`, `ssh`, `storage` | `core` |
| `drivers/postgres`, `drivers/mysql`, `drivers/mssql`, `drivers/clickhouse`, `drivers/cassandra`, `drivers/redis`, `drivers/mongodb` | `core`, `net` |
| `drivers/sqlite`, `drivers/duckdb` | `core` |
| `session` | `core`, `net`, `ssh`, `storage` |
| `mcp` | `core`, `session`, `storage` |
| `ai` | `core`, `net`, `storage` |
| `app` | every crate above |

Rules, enforced by review:

- `core` depends on **no other workspace crate**. It holds the domain types and the driver contract, and no I/O beyond the traits.
- `net`, `ssh` and `storage` depend on `core` only.
- Each `drivers/<engine>` crate depends on `core`, and on `net` when it speaks TLS or dials TCP. **Drivers never depend on each other, on `session` or on `ssh`.**
- `session` depends on `core`, `net`, `ssh` and `storage`, and on no driver outside its tests: it reaches drivers through `DriverRegistry`. Its Docker tests take `tablepro-driver-postgres`, `tablepro-driver-redis` and `tablepro-driver-mongodb` as dev-dependencies.
- `mcp` depends on `core`, `session` and `storage`, and on no driver outside its tests. It reaches the windows and the user through the `McpHost` trait the app implements.
- `ai` depends on `core`, `net` and `storage`. It speaks the providers' protocols and builds the prompts from what the app hands it; the app decides what a prompt may carry.
- `app` depends on all of them. It is the only crate that names every driver.
- `test-support` and `test-fixtures` are dev-dependencies, with one exception: `session` takes `test-support` as an optional dependency behind its `fakes` feature, which only `app`'s dev-dependencies turn on.

Consequences:

- Adding a driver does not touch `core`, `session`, `storage` or any other driver, unless it is the first engine of its data model ([ADR 0021](docs/decisions/0021-engines-without-sql.md)).
- Replacing the GUI framework would require rewriting only `app`.
- Drivers are tested against `core` traits without pulling GTK.

## Composition root

The driver registry is built once, by `build_registry` in `crates/app/src/lib.rs`, before the GTK application starts running:

```rust
fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(tablepro_driver_cassandra::CassandraDriver));
    r.register(Arc::new(tablepro_driver_clickhouse::ClickhouseDriver));
    r.register(Arc::new(tablepro_driver_duckdb::DuckDbDriver));
    r.register(Arc::new(tablepro_driver_mssql::MssqlDriver));
    r.register(Arc::new(tablepro_driver_mysql::MysqlDriver));
    r.register(Arc::new(tablepro_driver_postgres::PgDriver));
    r.register(Arc::new(tablepro_driver_sqlite::SqliteDriver));
    r
}
```

Adding a new driver = adding one workspace member + one `register` call. There is no runtime discovery, no ABI versioning, no plugin manifest. The trade-off is documented in [docs/decisions/0001-no-plugin-system.md](docs/decisions/0001-no-plugin-system.md).

## Async architecture

The GTK main loop owns every widget and runs on the main thread. Everything else runs on one tokio runtime, `AppRuntime`, which `run()` builds before GTK starts: multi-threaded, two to four workers named `tablepro-rt`. Code reaches it only through `Tasks` (`tablepro_session::runtime`), which `AppServices` hands to every window:

- `spawn_task` for async work, `spawn_blocking_task` for a blocking call such as a durable write, and `spawn_owned` for a loop that stops when its handle drops.
- Once the main loop returns, `AppRuntime::shutdown` gives the work still in flight two seconds.

Views cross between the two through `crate::runtime` (`spawn_and_deliver`, `spawn_held`, the input queues and `WatchForwarder`), and `crates/app/clippy.toml` bans the ways around it; [state-management.md](docs/state-management.md#rules-for-every-view) has the rules every view follows.

One second runtime remains. Relm4 runs a component's commands (`sender.command`, `oneshot_command`) on a runtime of its own, built the first time one runs, with one worker since nothing sets `RELM_THREADS`. The saved-queries dialog still loads through commands, so that runtime starts when it opens.

## The application

`TableProApplication` (`crates/app/src/application/`) is an `adw::Application` subclass. `run()` builds it with the `AppServices` every window shares: the driver registry, the connector and its deadlines, the liveness policy, the `SessionRegistry`, the settings, the storage, the saved connection list and its editor, the SSH services, the credential sources, the file revealer, `Tasks`, the process hold, the open-sessions record and the query history.

- **One process per profile.** GApplication owns the application id on the session bus. A second launch parses its own options, sends the running process an activate, or an open with the files it was given, and exits. With `--new-window` (`-n`), `handle_local_options` sends `app.new-window` instead. The development profile has an id of its own and runs beside the stable app.
- **Startup**, in the primary process only, adds the app actions (`new-window`, `quit`, `preferences`, `about`, `focus-tab`) and installs the application accelerators from the accelerator table, opens the query history, checks the askpass helper, ends SSH masters a crashed instance left running, starts the [MCP server](#mcp-server) when its preference is on, and starts `SessionSignals`, which tells every session about network changes and a resume from suspend.
- **Windows.** `open_window` builds a `SessionWindow` for a `WindowLaunch`: the picker, a saved connection, a file, or a session to restore. The application keeps each window in its `WindowRegistry` by window id, and a window reaches the others through its `WindowHost`, which holds the application weakly.
- **Holds.** A `ProcessHold` keeps the process alive while work that must finish runs: a session closing, a save, a durable write, a file being resolved. The app's `GioProcessHold` is `gio::Application::hold`, so the process ends once the last window and the last hold are gone.
- **Quit.** `request_quit` runs `QuitSequence`, which asks each window in turn through its close prompts and never calls `g_application_quit`. A second Quit while a window asks brings that window forward. At logout, `query-end` brings forward the first window that holds the session back.

### Restoring sessions and opening files

`OpenSessions` (`crates/app/src/workspace/open_sessions.rs`) records the session each window adopts, a file or a saved connection, and drops it on a disconnect or a closed window. With the `restore-session` key on (the default, under Preferences), the first activate of a launch reads the record under a hold, opens a window for each session in it with `WindowLaunch::Restore`, then opens the files handed over while it read, or the picker when that opens nothing. A restored saved connection is looked up in the list again, and one deleted since says so in a toast. With the key off, the first activate opens the picker.

A quit freezes the record before it asks the first window, so each window it closes stays on it, and writes it before the process may end. An approved quit then empties the list in memory; a cancelled one keeps only the windows still showing or connecting their session. Shutdown freezes it too: windows that go with the process are not the user closing them. An approved quit can leave the process running while a session closes, and an activate that reaches it then restores the record as a new launch would.

Files come from Open With in a file manager or from the command line (`HANDLES_OPEN`). They wait until the restore has read the record, since a file's window adds to it. Each file is resolved off the GTK thread, its path made canonical and matched against the saved connections, then it opens in the window that has it open, in the active window while that shows only the picker, or in a new window.

## Windows and sessions

Each window is a `SessionWindow` (`crates/app/src/ui/session_window/`) for one connection session ([ADR 0012](docs/decisions/0012-window-per-session.md)). Its `SessionPage` is the picker of saved connections, the connect while it runs, the failure when it fails, or the session's `Workspace`. Every picker's `WelcomeView` binds the one `SavedConnectionList` that `AppServices` builds, which follows the list the `ConnectionStore` publishes after each write, so a save, a connect's last-opened stamp, an edit or a delete in any window reaches every picker. A row's menu and its `picker` actions name the connection by id and read it from the list again when they run. Every page past the picker holds the `SessionClaim` on the session's key, so leaving the page releases it.

- A connect claims the key in the `SessionRegistry` before it starts, so a second window asking for the same database brings the first forward. The connect runs on `Tasks` under a cancel token, and a result for an attempt the user cancelled or replaced is closed instead of adopted.
- Adopting a connected session starts its `Session`, attaches it to the claim, which `SessionSignals` hears through the registry, records the key in `OpenSessions` and builds the `Workspace`.
- A workspace never moves to another session. Disconnect asks the close prompts, then `tear_down` writes what the workspace shows, takes its editor sessions, shuts the workspace down, drops the claim and the record's key, and closes the session and those editor sessions under one hold before the window returns to the picker. An approved close runs the same teardown.
- The close prompts (`CloseGuards`) belong to the window, so a tab's close, the close button and Ctrl+W ask on every page, one prompt at a time. While the workspace has something a logout would lose, a `WindowInhibitor` holds logout back, and suspend too while a save or an export runs.
- The window's actions (`disconnect`, `reconnect`, `close-current` and the rest) go on its own action map, which GTK exports as `win`.
- When a run, a save or an export ends in a tab the user is not looking at, the window's `WorkNotifier` sends a desktop notification through `GApplication`: one per tab, with no time threshold, as GNOME Console does. A tab counts as looked at while the window is active and the tab is in front. The notification names the tab and the connection only, since it can show on the lock screen, so an editor tab goes by its number rather than its script. Clicking it runs `app.focus-tab`, which brings the tab forward in its window. It is withdrawn once the tab is in front of an active window, when the tab closes, and when the session goes. A save that settles while a close prompt covering its tab decides is not notified: the prompt waited for it in front of the user, and then closes the tab or asks about it again.
- The window's content is the page itself, never a wrapper, and is at least 360 by 294 pixels. Each page has its own header bars and its own `AdwToastOverlay`, and the window's toasts go to the page on screen. The main menu comes from `data/resources/gtk/menus.ui`, which `GtkApplication` loads at startup.

The `Workspace` (`crates/app/src/ui/workspace/`) shows one session: the sidebar of its objects, the tab view and the banners. Its template puts the `AdwTabOverview` at the root, as libadwaita expects, around an `AdwBreakpointBin` with an `AdwOverlaySplitView`: the sidebar and the tabs each have their own header bar. Below 600sp the sidebar collapses into an overlay, and below 450sp an `AdwTabButton` takes the tab bar's place. The `show-sidebar` window action and F9 show and hide the sidebar. It adds its own actions to the window and removes them when it shuts down, follows the session's health and object list through `WatchForwarder`s, and tells the window what it shows through its `title-changed`, `dirty-changed`, `saves-in-flight-changed`, `work-completed` and `tabs-changed` signals. Its `WorkspaceHandle` runs the saves and tells the close prompts what closing any part of it would lose. Its `ExportLedger` writes exports off the GTK thread: the rows are encoded on the runtime and GIO writes them. An export takes the rows a grid holds, or every row of a table or an editor statement, streamed through `Connection::stream_read` on a read-only connection of its own with no deadline. `ReplaceFileWriter` removes a file the export made when it stops or fails. An existing regular file gets a temporary file beside it, renamed over it at the end, so a stopped export leaves it as it was. GLib truncates a symbolic link's target, a hard-linked file or a file in a folder that refuses the temporary file when the export opens it, and a stopped export then says that file is incomplete. [Workspace tab system](#workspace-tab-system) covers its tabs, and [Sessions and health](#sessions-and-health) the `Session` itself.

## UI architecture

The application, its windows, the workspace and every view a rewrite has reached are gtk-rs subclasses. A widget with a layout has a CompositeTemplate `.ui` file under `data/resources/ui/`, compiled into the GResource: the session window and its pages, the workspace, the browse, structure and SQL editor tabs, the browse tab's filter strip and its rule rows, its pager (`PagerBar`) and its pending-changes bar (`PendingChangesBar`), the results pane, the SQL editor's find bar, the picker's welcome view, the query history dialog and its rows, the export operations button, and the connect and preferences dialogs with their sections. A subclass keeps its state in its `imp` struct and reports through signals. The window and the workspace take input through their input queues; a browse or structure tab handles its input in `send` at once, and one that arrives while another is being handled waits for it.

A few views are still [Relm4](https://relm4.org) components ([ADR 0003](docs/decisions/0003-relm4-architecture.md)): the saved-queries and CSV import dialogs. Their output reaches the workspace through `connect_receiver`, which puts it on the workspace's input queue. The two patterns coexist until a rewrite turns each component into a subclass.

See [docs/state-management.md](docs/state-management.md) for the patterns and naming we use.

### Keyboard shortcuts

Every key the app binds or relies on is one `Accelerator` in `ACCELERATORS` (`crates/app/src/application/accelerators.rs`): the action it fires, its triggers, its `AcceleratorScope` and where the shortcuts dialog lists it.

- **Application** keys go in with `set_accels_for_action` at startup. GtkWindow runs them in the capture phase, before the focused widget, so none of them is a key a text field or a list uses.
- **Local** keys are a `local_shortcut_controller(owner)` on the owner's widget, firing the owner's action group through `NamedAction`: `browse` on a table tab and its column view, `editor` on the SQL editor's source view and, for find and replace, on the whole editor tab, `structure`, `filter`, the sidebar's list, which opens the selected table's menu, the query history's list, which opens the focused row's menu, and a picker row, which opens its menu. A disabled action lets its key go on. Bubble phase leaves a text field inside the owner its own Ctrl+Z and Ctrl+C; the source view's keys run in the capture phase, because GtkTextView binds Ctrl+/ itself.
- **Component** keys are bound by a component's own controller (the grid cell keys, the cell editors), which reads them from the table through `component_trigger` or `component_matches`.
- **Stock** keys belong to GTK or libadwaita: GtkListBase's selection and movement, AdwTabView's tab switching, AdwApplication's Ctrl+?. The workspace removes AdwTabView's Ctrl+Home and Ctrl+End pairs so the lists and the editor in its tabs keep them.

`data/resources/shortcuts-dialog.ui` lists every listed entry under an id made from its action, and `shortcuts_dialog_matches_accelerator_table` holds the two in step both ways. Menus show a Local or Component key through `menu_item`, and `describe_icon_button` puts a button's key on its accessible node instead of in its tooltip.

## Driver layer

How the app reaches a database: the contract in `tablepro-core`, a transport that carries the bytes, TLS each driver builds from the connection's trust settings, and a session that watches the link.

### The contract

`DatabaseDriver` describes an engine before any connection exists, through `DriverCapabilities`, and opens a `Connection`. The `Connection` serves the workspace from a pool; every call takes `CallOptions` (a deadline and a cancel token) and runs on a task the connection owns (`OwnedCalls`), so a stop reaches the server instead of leaving the statement running. Saves report what they left in the database through a `WriteLedger`. Each editor tab gets an `EditorSession` of its own that streams results into a `ResultSink`. [docs/adding-drivers.md](docs/adding-drivers.md) is the full contract, [ADR 0016](docs/decisions/0016-driver-contract-v2.md) the reasons for it, and the engine pages say how each driver meets it: [PostgreSQL](docs/drivers/postgresql.md), [MySQL and MariaDB](docs/drivers/mysql.md), [SQLite](docs/drivers/sqlite.md), [DuckDB](docs/drivers/duckdb.md), [SQL Server](docs/drivers/sql-server.md), [ClickHouse](docs/drivers/clickhouse.md), [Cassandra and ScyllaDB](docs/drivers/cassandra.md), [Redis](docs/drivers/redis.md), [MongoDB](docs/drivers/mongodb.md). An engine without SQL says so through `DriverCapabilities::data_model`: the workspace lists a key-value engine's keys and opens them in key tabs ([ADR 0021](docs/decisions/0021-engines-without-sql.md)), and opens a document engine's collections in table tabs whose statements are the engine's shell calls ([ADR 0026](docs/decisions/0026-documents-in-the-table-tab.md)).

### SQL scripts

`tablepro_core::sql_syntax::script` reads a script the way the engine's own client does. `ScriptPlan::build(text, grammar, settings)` lexes the text once and returns its tokens, its statements, its batches, and a `ScriptDiagnostic` for a string, quoted name, comment or dollar quote left open. Ranges are in bytes; `text_offsets` maps them to the characters GTK counts.

A driver names its grammar through `SqlDialect::grammar`. The rules for each `SqlGrammar` are one table in core (`crates/core/src/sql_syntax/script/script_rules.rs`), so the editor's runs, completion and formatting, the drivers' own splitting and read-only guards, and the history's credential check all read a script the same way. `LexicalSettings` holds what a session can change: whether a backslash escapes in a plain string.

| Grammar | Splits at | Kept whole across `;` | Beyond standard quotes and comments |
|---|---|---|---|
| PostgreSQL | `;` | dollar-quoted bodies, the `BEGIN ... END` body of a `CREATE FUNCTION` or `PROCEDURE`, parentheses | `E'...'` escapes, nested block comments, backslash escapes only with `standard_conforming_strings` off |
| MySQL, MariaDB | `;`, or the delimiter a `DELIMITER` line sets | nothing | backtick names, `"` strings, `#` comments, `--` only before whitespace, a control character or the end of the text, backslash escapes |
| SQLite | `;` | a `CREATE TRIGGER` body, as `sqlite3_complete` reads it | `[name]` and backtick names |
| DuckDB | `;` | `$tag$ ... $tag$` strings | `E'...'` escapes, nested block comments |
| SQL Server | a `GO` line, with an optional count | the whole batch, whatever `;` it holds | `[name]` with `]]` inside, nested block comments |
| ClickHouse | `;` | heredocs, `$tag$ ... $tag$` | backslash escapes in every quote, `//`, `# ` and `#!` comments, nested block comments |
| CQL | `;` | `BEGIN ... APPLY BATCH`, as cqlsh keeps it, and `$$ ... $$` function bodies | `''` inside a string and no backslash escapes, `//` comments, a line comment that also ends at a carriage return |

A failed statement stops the rest of a script, except on SQL Server, where each `GO` batch runs on its own as in sqlcmd (`BatchErrorPolicy::ContinueNextBatch`). The editor sends one statement, or one `GO` batch, per run; [docs/state-management.md](docs/state-management.md#the-sql-editor) has the run.

**MySQL stored programs need `DELIMITER`.** The mysql client splits at every `;` outside a quote or a comment, `BEGIN ... END` included, and the plan does the same: `CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END` is three statements, and the server refuses the first. A trigger, procedure, function or event whose body holds a `;` goes between `DELIMITER` lines, as in the mysql client:

```sql
DELIMITER //
CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//
DELIMITER ;
```

A `DELIMITER` or `\d` line that starts a line outside a statement is a directive and is never sent. The MySQL driver honours the same lines when a whole script reaches it, and sends text without them as one multi-statement batch, which the server parses itself.

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

PostgreSQL, SQL Server and ClickHouse open every stream through `open()`. sqlx dials its own sockets, so the MySQL driver passes it the route instead: host and port, or the forward's socket path. Nothing relays bytes between the two. scylla dials only a TCP address, so each Cassandra session dials a relay on `127.0.0.1` that serves only this user and carries every connection it accepts over `open()` ([ADR 0023](docs/decisions/0023-loopback-relay-for-cql.md)). The mongodb crate dials its own sockets as well, and gets the host and port on a direct route; it does no TLS over a Unix socket, so through SSH the MongoDB driver listens on a private Unix socket of its own and relays each connection the crate opens there to a stream from `open()`, with its own TLS around it. The socket options above apply only to streams `open()` makes, so a direct MySQL or MongoDB connection has no keepalive and finds a dead peer through the probe and its deadlines.

SSH runs the system OpenSSH client ([ADR 0013](docs/decisions/0013-openssh-client-transport.md)): one ControlMaster (`ssh -M -N -T`) per connection, with the user's `~/.ssh/config` applied, and one `ssh -O forward` Unix socket per server it reaches. The sockets live under `$XDG_RUNTIME_DIR/app/<app id>/ssh/` in directories only the user can open, with mode 0600. Only Flatpak creates `app/<app id>`, so a host install makes the missing levels with mode 0700, each opened without following a symlink and checked to be the user's; with `XDG_RUNTIME_DIR` unset, GLib puts the same layout under the cache directory. Every prompt (host key, password, passphrase, keyboard-interactive) reaches the app through the `tablepro-askpass` helper, and the 20 s handshake timeout pauses while a prompt is open. Under Flatpak, `ssh` comes from the GNOME runtime, and a `ProxyCommand` or `Match exec` that runs a host program, the host's `/etc/ssh` and FIDO keys kept in files do not work.

### Trust

A connection's `TlsConfig` holds the `TlsMode`, an optional CA file, an optional client certificate and key, and an optional server name:

- `Disable`: no TLS.
- `Require`: encrypted, and the certificate is not checked.
- `VerifyFull`: the certificate must chain to a trusted root and carry the server name.

A CA file goes only with `VerifyFull`, the one mode that checks the certificate. libpq and the mysql client verify against a CA file given with their require mode, so taking one with `Require` and ignoring it would leave a user who expects a check with none. `validate` refuses the pair, the connect dialog shows the CA row only for Verify full, and a saved or imported connection that holds the pair, from a build that allowed it, loads as `VerifyFull` with its CA file: a server the file does not vouch for then fails to connect instead of connecting unchecked.

The name checked is `NetworkTarget::tls_server_name()`: the override when one is set, otherwise the host the user typed, never the address of a local SSH forward. `TlsConfig::validate` refuses a mode, file or override the driver cannot use on that route, and the connect dialog reads the chosen files up front, so a file with no certificate is named before anything connects. A CA, certificate or key file is read only when it is a regular file of at most 1 MiB, and drivers read it on the blocking pool, so a device or a pipe named in an imported connection can neither fill memory nor hold a connect.

Each engine's TLS stack takes trust in its own form, so the driver builds it:

| Engine | `VerifyFull` trusts | Client certificate | A failure is classified from |
|---|---|---|---|
| PostgreSQL | The system store (rustls-platform-verifier), plus the CA file | Yes | The rustls error |
| ClickHouse | The system store (rustls-platform-verifier), plus the CA file | Yes, as the login, with no password sent | The rustls error |
| MySQL, MariaDB | The system store and the CA file as one PEM bundle (`tablepro_net::tls::ca_bundle_pem`), plus the Mozilla roots compiled into sqlx | Yes | The rustls error |
| Redis | The system store (rustls-platform-verifier), plus the CA file | Yes | The rustls error |
| MongoDB, direct | The system store and the CA file as one PEM bundle (`ca_bundle_pem`), written to a private file the mongodb crate reads once as its only roots | Yes | The rustls error |
| MongoDB, through SSH | The system store (rustls-platform-verifier), plus the CA file | Yes | The rustls error |
| SQL Server | The system store (loaded by tiberius), plus the CA file | No | rustls's message text, because tiberius keeps nothing else |
| Cassandra, ScyllaDB | The system store (rustls-platform-verifier), plus the CA file, checked against the server name and not the relay's address (`FixedNameVerifier`) | Yes, with the password login | The rustls error |
| SQLite | No TLS | | |
| DuckDB | No TLS | | |

PostgreSQL, ClickHouse, Redis and MongoDB through SSH get their rustls `ClientConfig` from `tablepro_net::tls::build_client_config`, and Cassandra from `build_client_config_checking`, which checks a name it is given in place of the one the client dials. Every engine uses the aws-lc-rs provider ([ADR 0009](docs/decisions/0009-crypto-provider-and-sources.md)). A CA file is added to the engine's roots, never in place of them. `docs/error-handling.md` lists [what each TLS failure means and what the app offers](docs/error-handling.md#tlsfailure-and-its-remedies).

On Linux the system store is the distribution's CA bundle. Under Flatpak it is the runtime's bundle: a CA added on the host with `update-ca-certificates` or `update-ca-trust` is not visible in the sandbox (freedesktop-sdk issue 1905).

#### Choosing a CA file under Flatpak

- For a server whose certificate comes from a private CA, set Encryption to Verify full and choose the CA's PEM file, whatever the host trusts.
- The development manifest grants the home folder and the mount points of removable drives (`/media`, `/run/media` and `/mnt`), so a file under any of them is read at its real path.
- A file chosen from anywhere else comes back from the file chooser portal as a path under `/run/user/<uid>/doc/`. It works for as long as the portal keeps the grant. If it goes, the connect fails naming the CA file, and choosing the file again fixes it. Keeping a copy of the CA in your home folder avoids this.
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

A window holds one `Session`. Every use of its connection goes through the `OperationRunner`, which adds no timer of its own: the deadline travels in `CallOptions` so the driver stops the statement on the server. The session's monitor probes every 30 s, retries an unanswered probe after 10 s, and calls the connection lost after three unanswered probes in a row, when a probe finds the link gone, or as soon as `Connection::lost()` fires, which a driver resolves only when the link is gone, never for one dead backend in its pool. It then reconnects on a backoff from 5 s to 60 s. A failure that a retry cannot fix (authentication, TLS, configuration, a host key to review) parks the session until the user acts. A read that failed because its connection was lost runs once more on the replacement link, as does one stopped when the reconnect closed the connection it ran on; a save never does.

The application tells each session what its connection cannot see. When `GNetworkMonitor` reports a change, and when a window adopts a session, it asks whether that session's server, or its first SSH hop, is reachable; a file, a socket and a loopback server are never asked about. A session that loses a server the network cannot reach waits offline, checking every 60 s, and reconnects as soon as the server is reachable again. While a session is open, a 5 s timer compares `CLOCK_BOOTTIME` with `CLOCK_MONOTONIC`, and after a suspend each server is checked again and a session that slept more than 30 s probes its connection. A session parked on an SSH host key keeps the error that parked it, and its banner's Review Key shows the fingerprint. Trusting it retries with ssh's question about that one key answered yes, so ssh still checks the key and writes known_hosts; a changed key is first removed with `ssh-keygen -R`, since ssh never accepts one. When the review cannot accept the key, because ssh's configuration takes keys only from known_hosts or the key is revoked, its dialog offers Retry for after the user fixes the key outside TablePro.

The session's `SchemaCatalog` holds what the window knows about the database: the schemas, each scope's objects and each table's columns. Callers that ask for the same thing at once share one fetch, a fetch runs as its own task so a view that closes does not stop it, and a failed refresh keeps the list it had. A reconnect commits the catalog the new connection read and marks the rest stale; `invalidate_table` does the same for one table after a schema change. The sidebar shows every schema's tables and views in one `GtkListView` that recycles its rows, a section per schema with the default one first and the engine's own last, and one menu whose items carry the table they act on. Its rows come from a `SidebarIndex`, sorted by collation key and given its search keys on a blocking thread, behind a `GListModel` and `GtkSectionModel` that makes a row's object only when the list view asks for it. Each search, and each new list, picks the rows it keeps on a blocking thread too, and the list takes them in one change unless a newer search or list overtook them. It follows every schema's list through a watch the window drops before the session closes, and reads that list again when a reconnect commits the default schema's; a refresh that fails keeps the list and says so in a toast. The editor's completion reads the catalog when it opens: the default schema's objects, a named schema's objects after `schema.`, and the columns of the tables the statement names. Its candidates are built with that read on the runtime, and its `ProposalList` ranks them for the typed word and makes a proposal only for a row GtkSourceView shows. Either list thus costs the GTK thread the rows on screen, not the catalog, which the large-catalog case checks with 50,000 tables ([testing.md](docs/testing.md#large-catalog-case)).

## Workspace tab system

The session drives a single `AdwTabView` hosting heterogeneous tabs. The `Workspace` owns the strip; tabs are typed via the `WorkspaceTab` enum:

```rust
pub enum WorkspaceTab {
    Editor(EditorTabSlot),       // SQL editor, free-form query
    Structure(StructureTabSlot), // a new table's draft, or an existing table's definition
    Table(TableTabSlot),         // one (schema, table) in the browse grid
    Diagram(DiagramTabSlot),     // one schema's ER diagram
    Key(KeyTabSlot),             // one key of a key-value engine
}
```

A table's structure opens in a Structure tab of its own. Saving a new table closes its Structure tab and opens a Table tab on it. A schema's ER diagram opens in a Diagram tab, one per schema: it reads each table's columns, foreign keys and indexes on one connection lease, two tables at a time, and draws the cards and lines on a canvas of its own (`crates/app/src/ui/diagram/`), with a focusable `DiagramNode` where each card is so the keyboard and a screen reader reach the tables. Its record keeps the schema and where the user moved tables, so a restore reads the tables again, lays them out and puts the moved ones back.

Each tab is a gtk-rs widget with a composite template, which the `AdwTabView` adopts. The workspace keeps a `HashMap<Uuid, WorkspaceTab>` keyed by the tab's UUID; the canonical display order comes from `tab_view.pages()` (drag-reorderable). A `TabIndex` maps each `AdwTabPage` to its tab's UUID, so close and right-click actions can recover it. `TabFactory` builds every tab from a `TabSpec`, whether the sidebar, the overview's new-tab button, a restore or a reopen asks for it. Every tab's title comes from its `TabIdentity` through `resolve_tab_title`, and the window's from the tab in front through `resolve_window_title`. A tab that closing would lose something in shows `document-modified-symbolic` as its page icon, as GNOME Text Editor does; its title never changes for it.

Routing is hub-and-spoke: a tab emits signals, and the closures the workspace connects tag them with the tab's UUID and queue them as `WorkspaceInput`. The workspace looks up the slot and calls back into the tab. This keeps the tabs ignorant of each other and gives the workspace one place to enforce cross-tab invariants (reload the tabs on a table whose schema changed, close all tabs for a dropped table, etc.). A reply a tab's request brings back after a disconnect reaches a closed queue and is dropped.

A browse or structure tab reads its own data through the session, one request of each kind at a time, and keeps what it shows through a failed read; [state-management.md](docs/state-management.md#rules-for-every-view) has the rules.

Reopening a closed tab uses a 10-deep `VecDeque<ClosedTabDescriptor>` snapshot taken in `finish_close_workspace_tab` before the slot is dropped. The stack goes with the workspace on disconnect because descriptors reference tables in its session.

## Per-tab pending-change registries

Each workspace owns two registries holding the in-flight edit state for its tabs, keyed by the same UUID as the workspace slot. The workspace creates them, registers a tracker when it opens a tab, passes the handle into the tab's init, and unregisters it when the tab closes or the connection goes away:

| Registry | Handle | What it tracks | Materialised by |
|---|---|---|---|
| `ChangeTrackerRegistry` | `TabTrackerHandle` | Row-level INSERT / UPDATE / DELETE for Table tabs | `TabTrackerHandle::change_set` → `TrackedChanges` |
| `StructureTrackerRegistry` | `StructureTrackerHandle` | The table's definition, the user's `TableDraft` and the `TableChanges` between them, for Structure tabs | `PendingStructure::plan` through the connection's `DdlDialect` → `DdlPlan` |

A handle is a newtype over `Rc<RefCell<_>>`. Every method borrows only for its own body, calls no GTK and no callbacks, and returns owned data (`CellOverlay`, `RowState`, `TrackerDelta`), so a grid bind that runs while a tab is applying a change never meets a held borrow. A row edit goes in as a `TrackerEdit` and comes back as a `TrackerDelta`: the rows to redraw, the draft rows the list store gains or loses, and the new pending count. The tab applies it to its `gio::ListStore` after the call returns. A grid row is a `RowObject` whose identity is fixed when it is made: a saved row's key and cells as fetched, or a draft's id, whose cells live only in the tracker. A tracked change bumps the row's `revision` property, and each cell bound to the row listens for it and draws again in place, so the store never swaps a row and its selection and focus stay put. The tab finds the row through a `GridRowIndex` of weak references keyed like the tracker. A grid cell resolves its row through its column view cell when an event fires, so an edit, a menu action or a toggle reaches the row it was made on even after rows above it came or went. Every pending change carries a `Touch` from the tracker's counter. An `UndoOp` holds the pending state on both sides of a step, touch included, so undo after A, B, C shows B, not the fetched value. `change_set` emits one change per row in touch order, and `plan_save` keeps that order: a row deleted and replaced by a draft with the same unique value saves, because its DELETE runs first. `WorkspaceHandle::dirty_tabs` reads both registries, with each editor's open transaction, for the close prompts, the teardown guard and the tabs' unsaved icon. CI fails on a `thread_local!` under `crates/app/src/services`, since a process-wide registry would share one window's unsaved edits with every other window.

The Structure tab is **definition + draft**, not a per-change log. The `TableDefinition` one read returned is what the tab plans against; `diff_table` turns the draft into `TableChanges`, and the engine's `DdlDialect` plans them into statements in its own order. Discard copies the definition back over the draft, and is the only restore point. The tracker holds the latest `PendingStructure`, so the close prompt and the save dispatcher read the same change without the tab, and the save plans it again with the dialect of the connection that runs it ([ADR 0010](docs/decisions/0010-ddl-plans-and-table-definitions.md)). A save that loses something, or that has several statements on an engine that applies DDL one statement at a time, first shows the user its `ChangeReview` and runs only the statements reviewed, whether the tab's Save or a close prompt asked for it ([state-management.md](docs/state-management.md#rules-for-every-view)).

## Persistence

[docs/storage.md](docs/storage.md) says which store holds which data and where each file goes. This section covers how the workspace writes and restores its own files.

Workspace tabs are one JSON file per session in `$XDG_STATE_HOME/tablepro/workspaces/`, named by the connection id, or `file-<sha256 of the URI>.json` for a file. Their writes are debounced 500 ms and run off the GTK thread, and so are the editor drafts', one file per tab. `WorkspaceStore` reads a session's file once its session is adopted, and the window writes the tab list only after that read, so a write never lands on tabs not yet restored. A file that cannot be read, that another version wrote, or that is over 1 MiB is left as it is and nothing is written over it until the user picks Reset on the toast, which moves it aside as `<name>.json.corrupt-<seconds>`. Every open tab is saved and restored, with no cap on the count. Writes go through one task that keeps the newest record per file. Editor records carry a draft id, never the text, and the editor's `content-changed` signal carries no text either: the tab label reads at most 200 characters.

`OpenSessions` writes the record of open sessions off the GTK thread, holding the process until each write lands; [Restoring sessions and opening files](#restoring-sessions-and-opening-files) says when it changes. A record that cannot be read is moved aside as `open-sessions.json.corrupt-<seconds>`.

A restore deletes the drafts no saved or open tab names, except while a moved-aside copy of the session's file is there, since that copy may name them. A draft that cannot be read is moved aside as `<id>.sql.corrupt-<seconds>`, which the cleanup never deletes, and its tab opens empty with a toast. A disconnect writes the open tabs' text before their buffers go.

`SavedConnection::last_opened_at` is stamped through `touch_last_opened` each time a window adopts a saved connection's session. Every picker shows the list in one order (`saved_connection_order::sort`): ungrouped connections first, then each group by name. Inside each block the connection opened last comes first, ties sort by name, and never-opened connections go to the end of their block.

## MCP server

`tablepro-mcp` serves the Model Context Protocol over stateless Streamable HTTP with `rmcp`, on `127.0.0.1` alone ([ADR 0022](docs/decisions/0022-ai-assistant-and-mcp-server.md)). `McpServer` accepts at most 32 connections at once and checks every request's `Authorization: Bearer` token in constant time before rmcp reads the body; rmcp refuses a `Host` that is not a loopback name and any `Origin`. The token is an `AccessToken` of 32 random bytes kept in the keyring through `TokenVault`.

The app's `McpService` (`crates/app/src/services/mcp_service.rs`) follows the `mcp-server-enabled` and `mcp-server-port` keys on the GTK thread and starts, stops and moves the server on the runtime. Every change takes one lock in turn, so a stop has freed the port before the next start binds it. Its status, a `watch` of `McpStatus`, drives the Preferences page.

A tool reads the saved connections from the `ConnectionStore` on each call, so an External Clients level changed a moment ago applies, and leaves a Blocked one out as if it did not exist. It reaches a connection through `McpHost`, which the app's `GtkMcpHost` answers on the GTK thread: the `Session` the registry holds for the saved connection's key, a window opened for it the way the picker opens one, and the write approval, which `confirm_until` shows in that window with Safe Mode's dialog and takes down when the client goes away. `ExternalAccess::gate` decides each statement from the level, the session's Safe Mode level and `statement_access`. A read streams through `Connection::stream_read` on a read-only connection, cut at the row limit by the sink; a write runs on an editor session of its own, opened for the one statement. Both go into the query history through `HistoryService::record`, under the editor's rules.

## AI assistant

`tablepro-ai` speaks Anthropic's Messages API and OpenAI's Chat Completions protocol, which OpenAI, Ollama and other self-hosted servers speak ([ADR 0022](docs/decisions/0022-ai-assistant-and-mcp-server.md)). `AiClient` is one hyper client over rustls with the platform verifier from `tablepro-net`, as the drivers use; it follows no redirect, and `Endpoint::new` refuses to send a key over plain http to a host other than this computer. Replies stream as server-sent events through `sse-stream`; a reply is capped at 512 KiB and a silence of 300 seconds ends it. Keys are keyring items through `ApiKeyVault`. The prompts (`chat_system_prompt`, `action_message`, `completion_message`) take a `SchemaContext`, which names tables and columns and never holds a row; catalog names go in double quotes on one line, and the user's SQL goes in a fence no backtick run in it can close. Thinking blocks are never sent back, so an edited or retried conversation is never refused.

The app's `AiService` (`crates/app/src/services/ai_service.rs`) reads the provider, model and address from GSettings and the key from the keyring, and runs every request on the runtime. Each window's `AssistantAccess` (`crates/app/src/ui/assistant/assistant_access.rs`) is the gate: it reads the connection's `AiPolicy` from the saved connections before every request, asks once under Ask Each Time, naming the provider's host, and keeps the answer until the window's session ends. The pane, the editor's Explain, Review, Optimize and Fix, and the suggestions while typing all go through it; the context comes from the session's catalog through the completion's reader (`schema_reader.rs`), so it shares the sidebar's reads.

## Build & CI

Meson is the build system and Cargo is the Rust compiler; see [ADR 0006](docs/decisions/0006-meson-cargo-build.md). `meson setup _build && meson compile -C _build` produces `tablepro` and `tablepro-askpass`, and `meson test -C _build` runs the `unit`, `gtk`, `data` and `packaging` suites.

The platform floor is GNOME 50 ([ADR 0015](docs/decisions/0015-gnome-50-platform-floor.md)), and `meson.build` refuses to configure below it. [docs/testing.md](docs/testing.md#ci) names the CI workflows.

## Out of scope

- **Plugin system**. Drivers are static. The macOS plugin model does not transfer.
- **In-process scripting**. No embedded JavaScript / Python / Lua. SQL is enough.
- **Cross-platform builds**. Linux only. macOS / iOS have their own targets.
- **Hot reload**. Compile-time only. Use `cargo watch` during development.
