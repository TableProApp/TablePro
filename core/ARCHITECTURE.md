# Architecture

The shared core is the Rust workspace's UI-free crates under `core/crates`: the domain types and the driver contract, one crate per database engine, the network and SSH transports, sessions, storage, the MCP server, the AI client, and the library other languages load. Each platform's app builds on them with a native UI: the GTK app in `linux/` directly, the Windows app in `windows/` through `ffi`, and the Swift app through `ffi` one slice at a time ([ADR 0001](docs/decisions/0001-shared-core.md), [ADR 0010](docs/decisions/0010-macos-on-the-core.md)). `linux/ARCHITECTURE.md` covers the Linux app.

## Crate layout

```
Cargo.toml, Cargo.lock             the workspace, at the top of the repository, with rust-toolchain.toml,
                                   rustfmt.toml, clippy.toml, deny.toml and .config/nextest.toml
core/crates/
├── core/                          domain types and the driver contract, no GUI deps
├── net/                           direct TCP transport and rustls client configs
├── ssh/                           system OpenSSH transport and askpass helper (Unix); in-process transport on russh
├── session/                       connect, sessions, health monitor, operation runner
├── storage/                       saved connections, history, drafts, credentials, file persistence
├── foreign-import/                connections and saved queries read from other apps' files, and their review
├── ai/                            the AI assistant's providers, prompts and replies
├── account/                       the TablePro account: sign-in, device, entitlement and the feature gate
├── mcp/                           the MCP server: transport, token and tools
├── cli/                           the tablepro command line: parsing, the MCP client and the output formats
├── ffi/                           the library C# and Swift load: one UniFFI API and the grid's C ABI
├── bindgen/                       uniffi-bindgen-swift, which writes the Swift bindings from a built ffi
├── test-fixtures/                 dev-only container fixtures with a generated PKI
├── test-support/                  dev-only fakes and the conformance suites
└── drivers/
    ├── postgres/                  tokio-postgres
    ├── mysql/                     sqlx-mysql, MySQL and MariaDB
    ├── sqlite/                    sqlx-sqlite
    ├── duckdb/                    duckdb, with DuckDB compiled in
    ├── mssql/                     tiberius
    ├── clickhouse/                clickhouse over hyper
    ├── cassandra/                 scylla, Cassandra and ScyllaDB
    ├── redis/                     redis-rs
    └── mongodb/                   the mongodb crate
```

## Dependency graph

| Crate | Depends on |
|---|---|
| `core` | no workspace crate |
| `net`, `storage` | `core` |
| `ssh` | `core`, and `net` with its `in-process` feature |
| `foreign-import` | `core`, `storage` |
| `drivers/postgres`, `drivers/mysql`, `drivers/mssql`, `drivers/clickhouse`, `drivers/cassandra`, `drivers/redis`, `drivers/mongodb` | `core`, `net` |
| `drivers/sqlite`, `drivers/duckdb` | `core` |
| `session` | `core`, `net`, `ssh`, `storage` |
| `mcp` | `core`, `session`, `storage` |
| `cli` | no workspace crate |
| `ai` | `core`, `net` |
| `account` | `core`, `storage` |
| `ffi` | `core`, `session`, `ssh`, `storage`, and every driver behind its default `engines` feature |
| An app, such as `linux/crates/app` | every crate above, and its platform crate |

Rules, enforced by review:

- `core` depends on **no other workspace crate**. It holds the domain types and the driver contract, and no I/O beyond the traits and the file identity the file engines share.
- `net` and `storage` depend on `core` only, and `ssh` on `core` and, for the in-process transport's first dial, `net`.
- `foreign-import` depends on `core` and `storage`. It reads other apps' files and never a platform service: a keychain or an installed-app lookup comes in through `ForeignHost`.
- Each `drivers/<engine>` crate depends on `core`, and on `net` when it speaks TLS or dials TCP. **Drivers never depend on each other, on `session` or on `ssh`.**
- `session` depends on `core`, `net`, `ssh` and `storage`, and on no driver outside its tests: it reaches drivers through `DriverRegistry`, and SSH through the `SshTunnels` the app passes in. Its Docker tests take `tablepro-driver-postgres`, `tablepro-driver-redis` and `tablepro-driver-mongodb` as dev-dependencies.
- `mcp` depends on `core`, `session` and `storage`, and on no driver outside its tests. It reaches the windows and the user through the `McpHost` trait the app implements.
- `cli` depends on no workspace crate: it speaks to the app's MCP server over HTTP and reaches the port, the token and the app's state through the `Host` trait the app implements ([0017](docs/decisions/0017-command-line.md)).
- `ai` depends on `core` and `net`. It speaks the providers' protocols and builds the prompts from what the app hands it; the app decides what a prompt may carry.
- `account` depends on `core` and `storage`. It reaches the browser, the keyring and the machine ID through what the app passes in ([0016](docs/decisions/0016-tablepro-accounts.md)).
- `ffi` stands in for an app outside Rust: it names every driver and passes the host's services in. No other core crate depends on it.
- No core crate depends on a GUI toolkit or on a platform crate. An app, or `ffi` for one outside Rust, is the only crate that names every driver.
- `test-support` and `test-fixtures` are dev-dependencies, with one exception: `session` takes `test-support` as an optional dependency behind its `fakes` feature, which only an app's dev-dependencies turn on.

Consequences:

- Adding a driver does not touch `core`, `session`, `storage` or any other driver, unless it is the first engine of its data model ([Linux ADR 0021](../linux/docs/decisions/0021-engines-without-sql.md)).
- Drivers are tested against `core` traits without pulling a GUI.

## Platforms

Every core crate builds for Linux, Windows (x64 and Arm64) and macOS; `.github/workflows/core.yml` checks them and runs `tablepro-core`'s tests on Windows and macOS. What a platform does its own way reaches the core in one of two forms.

A value or a trait the app passes in:

| Seam | Linux app | An app through `ffi` |
|---|---|---|
| `StoragePaths` | `tablepro_linux_platform::storage_paths`, GLib's XDG directories | `HostConfig.storage_dir`, one folder for every root |
| `SecretVault` and `SecretItems`, labelled through `SecretLabeler` and `SecretItemLabeler` | `tablepro_linux_platform::SecretStore`, the Secret Service through oo7 | `Core::with_system_secrets`, the platform's store the core reaches itself (below); `HostSecrets`, a callback interface, for a host with a store of its own |
| `SshTunnels` | `tablepro_ssh::SshServices`, the system OpenSSH client | `tablepro_ssh::InProcessSsh`, behind `tablepro-session`'s `in-process-ssh` feature ([ADR 0009](docs/decisions/0009-in-process-ssh-on-windows.md)) |
| `ProcessHold` | `gio::Application::hold` | none |
| `RefreshTokenVault`, `BrowserLauncher`, `MachineId` and `AppClient` (`tablepro-account`) | the keyring through `SecretStore`, `gtk::UriLauncher`, `MachineId::derive` of what `tablepro_linux_platform::read_machine_id` reads, `AppClient::LINUX` | none yet |
| `Host` (`tablepro-cli`) | `LinuxHost` in the app crate: the port and switch from GSettings, the token read from the keyring, `NameHasOwner` for a running app, each connection's peer checked by `Host::verify_peer` through `tablepro_net::loopback_peer_is_ours` | none yet |
| `ForeignAppDirs` and `ForeignHost` (`tablepro-foreign-import`) | `tablepro_linux_platform::foreign_app_dirs`, the host's XDG directories inside a Flatpak, and `PlainHost`: no other app's keychain | none yet |

A `cfg` split inside a crate:

| What | Linux | macOS | Windows |
|---|---|---|---|
| `FileIdentity` and the descriptors that hold a file (`tablepro-core`) | device and inode, `/proc/self/fd` | device and inode, `/dev/fd` read with fstat | volume and file index; a claim alone holds the file |
| The private safe write (`tablepro-storage`) | temporary 0600 file, fsync, rename, directory fsync | the same | temporary file, fsync, rename |
| `TCP_USER_TIMEOUT` (`tablepro-net`) | set | not set | not set |
| SQLite | the distribution's | bundled | bundled |
| DuckDB's file lock while a file is replaced | fcntl | fcntl | LockFileEx |
| SQL Server integrated login | MIT Kerberos, behind the `kerberos` feature | the system's GSS framework, behind the `kerberos` feature | SSPI, NTLM only (winauth) |
| `ffi`'s system secret store | none | none | Credential Manager, generic credentials named `TablePro/connection/<id>/<kind>` |
| OpenSSH transport, askpass helper | yes | yes | not built |
| The in-process SSH transport's agent | `SSH_AUTH_SOCK` | `SSH_AUTH_SOCK` | `SSH_AUTH_SOCK`, else `\\.\pipe\openssh-ssh-agent`, then Pageant |
| A server's own Unix-domain socket (`tablepro_net::LocalSocketTransport`, `NetworkOption::LocalSocket`) | yes | yes | not built: no engine offers one |
| MySQL's and MongoDB's relay for an in-process route (`tablepro_net::PrivateListener`) | a Unix socket in a 0700 directory | the same | a loopback port that serves this process, from `GetExtendedTcpTable` |
| Cassandra's loopback relay | serves this user, from `/proc/net/tcp` | serves no one | serves this process, from `GetExtendedTcpTable` |

Each boundary error has a stable `code()`, such as `driver.timeout` or `ssh.host_key_changed`, so a UI outside Rust can word it from the code and the variant's fields. The core holds no translation; `linux/docs/error-handling.md` has the error types and how the Linux app words them.

## Bindings

`ffi` is the library an app outside Rust loads: the Windows app as a DLL, the Apple apps as a static library in an XCFramework, built without the `engines` feature by `apple/scripts/build-core.sh`. Core ADRs 0002, on the bindings, 0003, on result windows, and 0009, on the macOS slices, hold the reasons.

- One UniFFI API. `Core` lists the engines with the family each is listed under, opens a file, connects a saved connection or tests one from a form, and parses a connection URL with `tablepro_core::connection_url`, refusing one that needs a setting its record has no field for. Its `ConnectionLibrary` reads and changes the saved connections, groups, favourites and tags in `connections.json` and stores their secrets, and gives the Apple apps the library's CloudKit records and merges a pull into it (`tablepro_storage::cloudkit`). A `DatabaseSession` reads the catalog one level at a time, writes a table's sorted page at an offset and counts the table, writes a query re-run with a sort (`docs/decisions/0007-sorting-a-result.md`), reports and waits on the session's health, and opens a `QueryEditor`. `QueryEditor::run` returns a `QueryRun` at once; the app drains its events after a `RunListener` call, which comes only when no earlier one is waiting to be drained, and the last says which transaction the editor is left in. Each result set is a `ResultSet`, whose `sorted` gives the rows it holds in a column's order.
- The grid reads a `ResultSet` through the C ABI in `src/window_abi.rs`: `tablepro_cursor_fetch` packs the display text of one visible range, and `tablepro_cursor_free` ends the cursor.
- The library owns one tokio runtime. Each async export runs on it and is aborted when the foreign side drops the call; a `CancelToken` stops it sooner, since UniFFI cannot cancel.
- A result set takes rows as the driver reads them. Each column keeps a kind byte, a raw `i64` and the exact text `tablepro_core::export::value_text` writes, or a binary value's bytes, in chunks of 65,536 rows. A window only cuts and copies.
- A `CoreError` carries the `code()` of each error from the outermost in; the innermost decides.

How the bindings are generated, and where they live: `windows/AGENTS.md`, Bindings, for C#, and `apple/AGENTS.md`, Repository map, for Swift.

## Driver layer

How an app reaches a database: the contract in `tablepro-core`, a transport that carries the bytes, TLS each driver builds from the connection's trust settings, and a session that watches the link.

### The contract

`DatabaseDriver` describes an engine before any connection exists, through `DriverCapabilities`, and opens a `Connection`. The `Connection` serves the workspace from a pool; every call takes `CallOptions` (a deadline and a cancel token) and runs on a task the connection owns (`OwnedCalls`), so a stop reaches the server instead of leaving the statement running. Saves report what they left in the database through a `WriteLedger`. Each editor tab gets an `EditorSession` of its own that streams results into a `ResultSink`. [docs/adding-drivers.md](../linux/docs/adding-drivers.md) is the full contract, [ADR 0016](../linux/docs/decisions/0016-driver-contract-v2.md) the reasons for it, and the engine pages say how each driver meets it: [PostgreSQL](../linux/docs/drivers/postgresql.md), [MySQL and MariaDB](../linux/docs/drivers/mysql.md), [SQLite](../linux/docs/drivers/sqlite.md), [DuckDB](../linux/docs/drivers/duckdb.md), [SQL Server](../linux/docs/drivers/sql-server.md), [ClickHouse](../linux/docs/drivers/clickhouse.md), [Cassandra and ScyllaDB](../linux/docs/drivers/cassandra.md), [Redis](../linux/docs/drivers/redis.md), [MongoDB](../linux/docs/drivers/mongodb.md). An engine without SQL says so through `DriverCapabilities::data_model`: the workspace lists a key-value engine's keys and opens them in key tabs ([ADR 0021](../linux/docs/decisions/0021-engines-without-sql.md)), and opens a document engine's collections in table tabs whose statements are the engine's shell calls ([ADR 0026](../linux/docs/decisions/0026-documents-in-the-table-tab.md)).

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

A failed statement stops the rest of a script, except on SQL Server, where each `GO` batch runs on its own as in sqlcmd (`BatchErrorPolicy::ContinueNextBatch`). The editor sends one statement, or one `GO` batch, per run; [docs/state-management.md](../linux/docs/state-management.md#the-sql-editor) has the run.

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
2. It builds the transport: the app's `SshTunnels` opens a session and forwards through it for an SSH connection, or a `DirectTcpTransport`.
3. It calls `DatabaseDriver::connect` with `ConnectOptions`: the `NetworkTarget` (transport, credentials, database, TLS settings) or the `FileEndpoint`, the `WorkspaceSettings`, the `LivenessPolicy` and the app's version.
4. It reads the first catalogue, the schemas and the default schema's objects, under the metadata deadline.

The cancel token is checked between stages, and a stage that finishes after a cancel closes what it built, because a driver blocked in a login cannot always be interrupted.

### Transports

`Transport` (`crates/core/src/transport.rs`) is how a driver reaches a server without knowing whether the route is direct or through SSH:

- `service_endpoint()`: the host and port the user typed, which TLS verifies and Kerberos names.
- `kind()` and `route()`: `DirectTcp` with a TCP endpoint, or `SshForward` with the Unix socket an OpenSSH forward listens on, or `InProcess` for an in-process channel, which has no address.
- `open()`: a new byte stream to the server.
- `reroute(endpoint)`: the same kind of route to another endpoint, for SQL Server's login routing.
- `explain_closed_stream()`: why a stream closed, when the transport knows better than "connection lost", as when the SSH master exited.

| | `DirectTcpTransport` (`tablepro-net`) | `SshForwardTransport` (`tablepro-ssh`) | `InProcessForward` (`tablepro-ssh`, `in-process`) |
|---|---|---|---|
| `open` | Resolves the name, then tries each address in turn under the connect timeout | Connects to the forward's Unix socket under the connect timeout | Opens a `direct-tcpip` channel under the channel open timeout |
| Socket options | `TCP_NODELAY`; keepalive after 30 s idle, every 10 s, 3 probes; `TCP_USER_TIMEOUT` 45 s | OpenSSH's own: `ServerAliveInterval=15`, `ServerAliveCountMax=3` | The first hop's dial is a `DirectTcpTransport`'s; SSH keepalives every 15 s, 3 unanswered end the session |
| `reroute` | A new direct transport | A new forward on the same master | A forward on the same session |
| `explain_closed_stream` | Nothing to add | The master's exit, or the "open failed" line ssh printed | Why the session ended |

PostgreSQL, SQL Server and ClickHouse open every stream through `open()`. sqlx dials its own sockets, so the MySQL driver passes it the route instead: host and port, or the forward's socket path; an in-process route has neither, so the driver relays it through a `tablepro_net::PrivateListener` of its own. scylla dials only a TCP address, so each Cassandra session dials a relay on `127.0.0.1` that serves only this user, or on Windows this process, and carries every connection it accepts over `open()` ([ADR 0023](../linux/docs/decisions/0023-loopback-relay-for-cql.md)). The mongodb crate dials its own sockets as well, and gets the host and port on a direct route; it does no TLS over a Unix socket, so through SSH the MongoDB driver listens on a `PrivateListener` of its own and relays each connection the crate opens there to a stream from `open()`, with its own TLS around it. The socket options above apply only to streams `open()` makes, so a direct MySQL or MongoDB connection has no keepalive and finds a dead peer through the probe and its deadlines.

The Windows app runs SSH in process on russh ([ADR 0009](docs/decisions/0009-in-process-ssh-on-windows.md)): one session per connection, its jump hosts each carried over the one before, with known_hosts, the agent and every prompt handled in the core. The Linux app runs the system OpenSSH client ([ADR 0013](../linux/docs/decisions/0013-openssh-client-transport.md)): one ControlMaster (`ssh -M -N -T`) per connection, with the user's `~/.ssh/config` applied, and one `ssh -O forward` Unix socket per server it reaches. The sockets live under `$XDG_RUNTIME_DIR/app/<app id>/ssh/` in directories only the user can open, with mode 0600. Only Flatpak creates `app/<app id>`, so a host install makes the missing levels with mode 0700, each opened without following a symlink and checked to be the user's; with `XDG_RUNTIME_DIR` unset, GLib puts the same layout under the cache directory. Every prompt (host key, password, passphrase, keyboard-interactive) reaches the app through the `tablepro-askpass` helper, and the 20 s handshake timeout pauses while a prompt is open. Under Flatpak, `ssh` comes from the GNOME runtime, and a `ProxyCommand` or `Match exec` that runs a host program, the host's `/etc/ssh` and FIDO keys kept in files do not work.

### Trust

A connection's `TlsConfig` holds the `TlsMode`, an optional CA file, an optional client certificate and key, and an optional server name:

- `Disable`: no TLS.
- `Prefer`: TLS when the server offers it, otherwise plain, and the certificate is not checked, as libpq's `prefer` and the mysql client's `PREFERRED` do. Only PostgreSQL and MySQL offer it, since only their protocols ask for TLS before going on without it.
- `Require`: encrypted, and the certificate is not checked.
- `VerifyFull`: the certificate must chain to a trusted root and carry the server name.
- `Strict`: TLS before the first protocol byte, checked as `VerifyFull`. Only SQL Server offers it (TDS 8.0); Microsoft's drivers refuse to combine strict encryption with an unchecked certificate, so there is no unchecked variant.

A new connection starts on the mode the engine's own client starts on, which `DriverCapabilities::new_connection_tls` gives from the driver's `TlsCapabilities::default_mode` and `tls_ports`, the port and the network options ([ADR 0014](docs/decisions/0014-tls-mode-of-a-new-connection.md) has the table). An app keeps a new connection's mode on that default until the user picks one; a saved connection keeps its own.

A CA file goes only with the modes that check the certificate, `VerifyFull` and `Strict`. libpq and the mysql client verify against a CA file given with their require mode, so taking one with `Require` and ignoring it would leave a user who expects a check with none. `validate` refuses the pair, so a saved or imported connection that holds it fails to connect instead of connecting unchecked, and the connect dialog shows the CA row only for the modes that check.

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

PostgreSQL, ClickHouse, Redis and MongoDB through SSH get their rustls `ClientConfig` from `tablepro_net::tls::build_client_config`, and Cassandra from `build_client_config_checking`, which checks a name it is given in place of the one the client dials. Every engine uses the aws-lc-rs provider ([ADR 0009](../linux/docs/decisions/0009-crypto-provider-and-sources.md)). A CA file is added to the engine's roots, never in place of them. `docs/error-handling.md` lists [what each TLS failure means and what the app offers](../linux/docs/error-handling.md#tlsfailure-and-its-remedies).

Where each platform's system store comes from: `linux/ARCHITECTURE.md`, Trust.

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

The app tells each session what its connection cannot see. When the network changes, and when a window adopts a session, it asks whether that session's server, or its first SSH hop, is reachable; a file, a socket and a loopback server are never asked about. A session that loses a server the network cannot reach waits offline, checking every 60 s, and reconnects as soon as the server is reachable again. After a suspend each server is checked again, and a session that slept more than 30 s probes its connection. A session parked on an SSH host key keeps the error that parked it, with the fingerprint for the app to show. Trusting it retries with ssh's question about that one key answered yes, so ssh still checks the key and writes known_hosts; a changed key is first removed with `ssh-keygen -R`, since ssh never accepts one.

The session's `SchemaCatalog` holds what the window knows about the database: the schemas, each scope's objects and each table's columns. Callers that ask for the same thing at once share one fetch, a fetch runs as its own task so a view that closes does not stop it, and a failed refresh keeps the list it had. A reconnect commits the catalog the new connection read and marks the rest stale; `invalidate_table` does the same for one table after a schema change.
