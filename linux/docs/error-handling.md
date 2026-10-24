# Error handling

Errors are typed enums, built with `thiserror` wherever they cross a crate boundary. No TablePro crate depends on `anyhow`: the caller matches on the enum, and the app decides what to say from it, never from the message.

## Errors by layer

| Crate | Error types | Notes |
|---|---|---|
| `tablepro-core` | `DriverError`, `ConfigError`, `TransportError`, `SshFailure`, `CertificateFileProblem`, `SecretError` | The contract every driver, transport and keyring speaks. |
| `tablepro-net` | `tls::TlsSetupError` | Wraps a `ConfigError`, a rustls error or a PEM encoding error while a TLS config is built; drivers turn it into `DriverError`. |
| `tablepro-ssh` | `SshFailure`, inside `TransportError::Ssh` | Classified from OpenSSH's exit status and stderr. |
| `drivers/<engine>` | `DriverError` only | The client library's error never leaves the crate. |
| `tablepro-storage` | `StorageError`, `SettingsError`, `KeyringError`, `CredentialError` | `KeyringError::Secret` wraps core's `SecretError`. |
| `tablepro-session` | `ConnectError`, `OperationError`, `ClaimError` | `ConnectError::Driver` and `OperationError::Driver` carry the driver's error unchanged. |
| `tablepro` (the app) | Small enums per module (`StartupError`, `LoggingError`, `AcquireError`, ...) | User-facing text comes from `crates/app/src/ui/error_text/`. |

## `DriverError`

`DriverError` is `#[non_exhaustive]`, `Clone` and `PartialEq`, so a result can be stored, compared in tests and sent across threads. Each variant has one meaning:

| Variant | Meaning |
|---|---|
| `Transport(TransportError)` | The route failed: name resolution, refused, unreachable, a connect or SSH timeout, or an `SshFailure`. |
| `Auth { diagnostics }` | The server refused the credentials, with its own explanation when it gave one. |
| `LoginRefused(ServerDiagnostics)` | The server turned the login away for a reason other than the password, such as PostgreSQL's pg_hba.conf rules. The app offers no new password for it. |
| `IntegratedAuth(String)` | A Kerberos login failed before the server saw it. |
| `Tls { failure, detail }` | The handshake failed; `TlsFailure` says why. |
| `Server(ServerDiagnostics)` | The server refused the statement. |
| `ReadOnly(ReadOnlyRefusal)` | A write on a read-only connection: `ClientGuard` (the driver refused before sending) or `ServerRejected` (the server refused). |
| `Cancelled` | The caller stopped it. |
| `Timeout { phase, server_cancelled }` | A bound passed. `server_cancelled` says the server confirmed it stopped the statement. |
| `ConnectionLost { during }` | The connection went away; `LossPhase` says while doing what. |
| `RolledBack`, `RowGuardFailed`, `CommitOutcomeUnknown`, `PartiallyApplied` | What a failed save left in the database ([adding-drivers.md](adding-drivers.md#5-writes-and-the-writeledger)). |
| `GuardUnsupported` | The engine reports no row count, so a guarded write cannot run. |
| `FileNotFound`, `FileAccessDenied`, `NotADatabase`, `FileIo` | A file engine's file. |
| `Busy(BusyReason)` | Something was busy: `NoFreeConnection` (the server has no room for another connection, or the pool had no free slot in time) or `FileLocked` (another connection held the database file's lock past the lock timeout). |
| `EditorSessionBusy` | The tab's session is already running a statement. |
| `Config(ConfigError)` | The settings cannot be used: a bad host, port, path, TLS option, auth mode or missing database name. |
| `Decode { column, detail }` | The driver could not read a value. A bug on our side, not the server's. The detail is for the log. |
| `Protocol(String)` | The server or the client library said something the driver did not expect. The text is for the log. |
| `Unsupported { feature }` | The engine has no such feature. `UnsupportedFeature` names it, and the app writes the sentence. |

Rules:

- Add a variant only when the app has to act on it differently from every existing one. A new message is not a reason.
- Never wrap a `Box<dyn Error>` or the client library's error. Keep what the app needs: a code, a phase, a path.
- The `#[error]` text is for logs. The UI writes its own sentence from the variant.
- A variant carries no English meant for the user. What the app needs to say goes in as a value it can render: an `UnsupportedFeature`, an `io::ErrorKind`, a line and column. A library message that is English only, such as sqlparser's or serde_json's, is not kept.

## `ErrorCategory`

`DriverError::category()` (and `TransportError::category()`, `SshFailure::category()`) sorts every error into the kind of problem it is. The app branches on the category, so an error a driver adds later still lands in a branch that says what to do next.

| Category | Variants | What the app does |
|---|---|---|
| `Configuration` | `Config`, `Unsupported`; SSH setup failures | Names the setting to change. The session stops retrying until the user changes something. |
| `Network` | `Transport` (resolution, refused, unreachable); an SSH forward that was rejected or could not open, or an SSH master that exited | Names the host and port. A session retries on a backoff. |
| `Tls` | `Tls` | One sentence per `TlsFailure`, with a remedy button where one exists. The session stops retrying. |
| `Authentication` | `Auth`, `LoginRefused`, `IntegratedAuth`; SSH auth and host-key failures, and a cancelled SSH prompt | Says the login or the host key was refused, with the server's reason. Never echoes what was typed. The session stops retrying. |
| `ReadOnly` | `ReadOnly` | Says who refused: this connection's setting, or the server. |
| `Server` | `Server` | The server's own words, code, detail and hint. |
| `Interrupted` | `Cancelled` | "Stopped." |
| `Timeout` | `Timeout`, `TransportError::Timeout` | One sentence per `TimeoutPhase`. |
| `ConnectionLost` | `ConnectionLost` | Says the connection closed. The session reconnects on a backoff. |
| `WriteOutcome` | `RolledBack`, `RowGuardFailed`, `CommitOutcomeUnknown`, `PartiallyApplied` | Says what is in the database now. Only `RolledBack` and `RowGuardFailed` may say nothing changed. |
| `File` | the four file variants | Names the path. A connect that failed on the file is not retried. |
| `Busy` | `Busy`, `EditorSessionBusy` | Says to try again shortly, that another program or tab holds the file's lock, or to wait for the tab's statement. |
| `Internal` | `GuardUnsupported`, `Decode`, `Protocol`; `SshFailure::Protocol` and `SshFailure::Internal` | Says what the driver could not do: check a save, read a value, read the reply. |

## `ServerDiagnostics`

A server error keeps the shape the server sent it in. `ServerCode` holds each engine's own numbering, because the number is what tells a missing password apart from a missing table:

| `ServerCode` | Engine | Shown as |
|---|---|---|
| `SqlState(String)` | PostgreSQL | SQLSTATE 23505 |
| `MySql { number, sqlstate }` | MySQL, MariaDB | MySQL error 1062 |
| `Tds { number, state, class }` | SQL Server | SQL Server error 2627 |
| `ClickHouse { code }` | ClickHouse | ClickHouse code 62 |
| `Sqlite { primary, extended }` | SQLite | SQLite error 2067 |
| `Cql { code }` | Cassandra, ScyllaDB | CQL error 0x2200 |
| `Redis { prefix }` | Redis | the error reply's first word, such as WRONGTYPE |
| `Mongo { code, name }` | MongoDB | MongoDB error 11000 |

`ServerCode` is closed: an engine with its own numbering adds a variant, and its label in `crates/app/src/ui/error_text/driver.rs`.

`ServerDiagnostics` also carries `severity`, `detail`, `hint`, `position`, `where_context`, `schema`, `table`, `column` and `constraint`. PostgreSQL fills most of them; the other engines mostly leave them empty. `position` counts characters from the start of the statement the user wrote: a driver that wraps the statement corrects it (the PostgreSQL cursor flight subtracts its `DECLARE` prefix).

A driver maps the codes the app acts on to their own variants and passes everything else through as `Server`. Each engine page has its driver's table, and the places where it can only read the message, as SQL Server's TLS failures through tiberius: [PostgreSQL](drivers/postgresql.md#stops-and-timeouts), [MySQL and MariaDB](drivers/mysql.md#stops-and-timeouts), [SQLite](drivers/sqlite.md#stops-and-timeouts), [SQL Server](drivers/sql-server.md#stops-and-timeouts), [ClickHouse](drivers/clickhouse.md#stops-and-timeouts), [Cassandra and ScyllaDB](drivers/cassandra.md#stops-and-timeouts), [Redis](drivers/redis.md#server-codes), [MongoDB](drivers/mongodb.md#server-codes).

## `TimeoutPhase`

`Timeout` and `TransportError::Timeout` name the phase that ran out, because each phase has a different cause and a different fix:

| Phase | Bound | Meaning |
|---|---|---|
| `Connect` | `LivenessPolicy::connect_timeout`, 10 s | No TCP connection, or the socket did not open. |
| `Login` | `login_timeout`, 15 s | Connected, but the login or TLS handshake did not finish. |
| `SshHandshake` | `ssh_handshake_timeout`, 20 s, paused while a prompt is open | OpenSSH did not authenticate in time. |
| `SshChannelOpen` | `ssh_channel_open_timeout`, 10 s | `ssh -O forward` did not answer in time. |
| `LockWait` | `WorkspaceSettings::lock_timeout`, 10 s | Another session holds a lock this statement needs. |
| `Statement` | The call's deadline, or the workspace statement timeout of 60 s | The statement ran too long. `server_cancelled` says whether the server confirmed the stop. |
| `Probe` | `probe_timeout`, 5 s | The server did not answer a liveness check. |

## `TlsFailure` and its remedies

Drivers classify a handshake failure with `tablepro_net::tls::classify`, which walks the error's sources to the rustls error. SQL Server reads rustls's message text instead, because tiberius keeps only the text. Where the driver can tell, a failure before the server agreed to TLS is `ServerRefusedTls`, never a certificate problem.

| `TlsFailure` | Cause | What the app offers |
|---|---|---|
| `UnknownIssuer` | The certificate's issuer is not in the trust set. | **Choose CA Certificate…**, which opens the connect dialog at the CA file row. |
| `NameMismatch` | The certificate is for another name. | **Set TLS Server Name**, which opens the connect dialog at the server name row, where the route shows that row; MySQL over a direct route checks the host it dials and offers only **Edit Connection…**. |
| `Expired`, `NotYetValid`, `Revoked` | The certificate itself is bad. | Nothing: the server's certificate has to be replaced. |
| `ServerRefusedTls` | The server does not speak TLS on this port. | The message; turn TLS off or use the TLS port. |
| `ServerRequiresTls` | TLS was off and the server insists on it. | The message; turn TLS on. |
| `HandshakeRejected` | The server ended the handshake, for example over the client certificate. | The server's reason. |
| `CaFileInvalid`, `ClientIdentityInvalid` | A file the user chose cannot be used. | The message names the file. |
| `Other` | Anything else. | The rustls message. |

The buttons are `TlsRemedy` in `crates/app/src/ui/error_text/tls_remedy.rs`: the toast button when the connect dialog's Test fails, and the Edit button on the window's connect failed page. Which certificates each engine trusts, and how to choose a CA file under Flatpak, is in [ARCHITECTURE.md](../ARCHITECTURE.md#trust).

## Mapping errors in a driver

- Map by the engine's code, not by message text. Where the client library keeps nothing but the text, say so in a comment and pin the text with a test.
- Keep the server's diagnostics: `DriverError::reported(ServerDiagnostics)`, and `DriverError::auth(Some(diagnostics))` for a refused login.
- An error the engine raised to acknowledge our stop is the stop: `Cancelled`, or `Timeout { server_cancelled: true }` ([adding-drivers.md](adding-drivers.md#ownedcalls) has how `run_read` and `run_write` tell).
- A `ConnectionLost` goes through `Transport::explain_closed_stream`, so an SSH master that exited is reported as that.
- A dead route is reported only once a check outside the pool confirms it ([adding-drivers.md](adding-drivers.md#deciding-that-the-link-is-lost)).

## User-facing text

`crates/app/src/ui/error_text/` turns errors into sentences: `driver_message` for a `DriverError`, `connect_error_message` and `operation_error_message` for the session's errors, and an SSH module for `SshFailure`. Every string goes through `crate::i18n`. Never show `Debug` or the `#[error]` text of an error, on its own or inside a sentence.

The only text shown as it came is what another party wrote, inside a sentence that says whose it is: a server's `ServerDiagnostics`, the Secret Service's reply (the `service_message` of `SecretError::Backend`), OpenSSH's stderr, and the Kerberos library's report. A core crate's own detail is a value the app words, never English text: `SshFailure` carries exit statuses, I/O error kinds and `SshRuntimeDirProblem`. The TLS library's text is logged, and the `TlsFailure` alone picks the sentence. The detail of an `Internal` error is logged at `trace` when it is shown, since it can quote what the server sent.

## Logging

Logging goes through `tracing`. `crates/app/src/logging.rs` installs a `tracing_subscriber` fmt layer that writes to **stderr**, which the GNOME session journals for both Flatpak and system installs. Panics land in the same stream, so a panic and the lines around it stay in order. There is no journald writer.

- The filter comes from `RUST_LOG`. Without it, a development build logs at `debug` and an installed one at `info`. A `RUST_LOG` that does not parse falls back to that default and logs a warning saying so.
- `TABLEPRO_LOG_FORMAT=json` writes one JSON object per line; `text`, the default, writes plain lines.

```sh
RUST_LOG=debug meson devenv -C _build ./crates/app/tablepro
RUST_LOG=tablepro=trace,info TABLEPRO_LOG_FORMAT=json meson devenv -C _build ./crates/app/tablepro
journalctl --user -f -t tablepro
```

Levels: `error!` for what the user must see or a broken contract, `warn!` for recoverable but suspicious, `info!` for lifecycle events, `debug!` for internal flow, `trace!` for query text and wire detail.

Never log a password, a secret, a key or a bound value. sqlx's own statement logging is turned off in the MySQL and SQLite drivers, and a test in each crate (`tests/statement_logging.rs`) proves no statement text reaches the subscriber.

The libraries under the drivers log what a database was sent or answered: tokio-postgres the text of every statement at `debug`, through `log`, which `tracing-subscriber` forwards; sqlx every statement, and a slow one as a warning; tiberius rows at `trace` and server messages as errors; the clickhouse crate exceptions that quote the query; scylla the server's error messages, which can quote a statement; the mongodb crate the commands it sends once its tracing feature is on, and its DNS resolver the names it looks up; deadpool the errors of the connections it recycles; sqlparser, also through `log`, the text of every statement, filter and default it parses, and the literals in it, at `debug`. So the subscriber drops every event whose target starts with `tokio_postgres`, `deadpool`, `tiberius`, `sqlx`, `clickhouse`, `scylla`, `redis`, `mongodb`, `hickory_net`, `hickory_proto`, `hickory_resolver` or `sqlparser`, at every level. That filter sits beside the `RUST_LOG` one, so no directive turns them back on, however specific. A driver logs what it needs from their errors itself. A new driver's client library, or any other library that logs SQL text, joins `SILENCED_LIBRARIES` in `logging.rs`.

## Crashes

A panic on the GTK thread ends the process: GTK calls the app back through C, which a panic cannot unwind, so it aborts. A panic on a runtime thread is caught there (`session/src/runtime/catch_panic.rs`, and tokio's own `JoinError`) and ends one task, which the UI shows as a failure.

- `crates/app/src/crash_report.rs` installs a panic hook in `run()`, right after logging. It runs the default hook first, so stderr and the journal keep the usual line.
- For a panic on the GTK thread it then appends a report to `StoragePaths::crashes_dir()` (`$XDG_STATE_HOME/<dir>/crashes`): the version, application ID, profile, debug or release build, the time, the message and place, and a backtrace captured whatever `RUST_BACKTRACE` says. The file is 0600 in a 0700 directory, written through `tablepro_storage::fs::append_private_blocking`. One file per process, named `crash-<UTC time>-<pid>.txt`; the second panic Rust raises when the first cannot unwind goes in the same file.
- At the next launch the primary instance looks for the newest report it has not announced, off the GTK thread, and records its name in `crashes/announced`. The first window shows a toast, "TablePro quit unexpectedly last time", whose Show Report button opens the folder with the report selected. The toast moves with the window from page to page until it is dismissed or times out. Only the 20 newest reports are kept.
- Nothing leaves the machine: the user decides whether to attach the report to an issue.
- Still open: pending grid and Structure edits live only in memory and are lost with the process. Editor text and the tab list are saved 500 ms after a change.

## `unwrap`, `expect` and `panic!`

The workspace lints deny `unwrap_used`, `expect_used`, `panic`, `todo` and `unimplemented`. `clippy.toml` allows `unwrap`, `expect` and `panic!` in tests; `todo!` and `unimplemented!` are denied there too. Return a real error instead. The one accepted use outside tests is in a `const`, where the compiler proves the value, as `RowLimit::EDITOR_DEFAULT` does.

## Patterns refused in review

- A `String` or `Box<dyn Error>` as an error type in a public function.
- A client library's error in a public signature of a driver crate.
- `match error { _ => "Something went wrong" }`. Match the category, then the variant.
- A retry loop around an error the category says retrying cannot fix: `Configuration`, `Authentication`, `File`, `WriteOutcome`.
- Treating `CommitOutcomeUnknown` or `PartiallyApplied` as a failure that changed nothing.
