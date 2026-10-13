# Error handling

Errors are typed enums, built with `thiserror` wherever they cross a crate boundary. There is no `anyhow` in the workspace: the caller matches on the enum, and the app decides what to say from it, never from the message.

## Errors by layer

| Crate | Error types | Notes |
|---|---|---|
| `tablepro-core` | `DriverError`, `ConfigError`, `TransportError`, `SshFailure`, `CertificateFileProblem` | The contract every driver and transport speaks. |
| `tablepro-net` | `tls::TlsSetupError` | Wraps a `ConfigError` or a rustls error while a TLS config is built; drivers turn it into `DriverError`. |
| `tablepro-ssh` | `SshFailure`, inside `TransportError::Ssh` | Classified from OpenSSH's exit status and stderr. |
| `drivers/<engine>` | `DriverError` only | The client library's error never leaves the crate. |
| `tablepro-storage` | `StorageError`, `SettingsError`, `KeyringError`, `CredentialError` | |
| `tablepro-session` | `ConnectError`, `OperationError`, `ClaimError` | `ConnectError::Driver` and `OperationError::Driver` carry the driver's error unchanged. |
| `tablepro` (the app) | Small enums per module (`StartupError`, `LoggingError`, `AcquireError`, ...) | User-facing text comes from `crates/app/src/ui/error_text/`. |

## `DriverError`

`DriverError` is `#[non_exhaustive]`, `Clone` and `PartialEq`, so a result can be stored, compared in tests and sent across threads. Each variant has one meaning:

| Variant | Meaning |
|---|---|
| `Transport(TransportError)` | The route failed: name resolution, refused, unreachable, a connect or SSH timeout, or an `SshFailure`. |
| `Auth { diagnostics }` | The server refused the credentials, with its own explanation when it gave one. |
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
| `Busy` | The server has no room for another connection, or the pool had no free slot in time. |
| `EditorSessionBusy` | The tab's session is already running a statement. |
| `Config(ConfigError)` | The settings cannot be used: a bad host, port, path, TLS option, auth mode or missing database name. |
| `Decode { column, detail }` | The driver could not read a value. A bug on our side, not the server's. |
| `Protocol(String)` | The server or the client library said something the driver did not expect. |
| `Unsupported { feature }` | The engine has no such feature. |

Rules:

- Add a variant only when the app has to act on it differently from every existing one. A new message is not a reason.
- Never wrap a `Box<dyn Error>` or the client library's error. Keep what the app needs: a code, a phase, a path.
- The `#[error]` text is for logs. The UI writes its own sentence from the variant.

## `ErrorCategory`

`DriverError::category()` (and `TransportError::category()`, `SshFailure::category()`) sorts every error into the kind of problem it is. The app branches on the category, so an error a driver adds later still lands in a branch that says what to do next.

| Category | Variants | What the app does |
|---|---|---|
| `Configuration` | `Config`, `Unsupported`; SSH setup failures | Names the setting to change. The session stops retrying until the user changes something. |
| `Network` | `Transport` (resolution, refused, unreachable); a rejected SSH forward | Names the host and port. A session retries on a backoff. |
| `Tls` | `Tls` | One sentence per `TlsFailure`, with a remedy button where one exists. The session stops retrying. |
| `Authentication` | `Auth`, `IntegratedAuth`; SSH auth and host-key failures | Says the login or the host key was refused, with the server's reason. Never echoes what was typed. The session stops retrying. |
| `ReadOnly` | `ReadOnly` | Says who refused: this connection's setting, or the server. |
| `Server` | `Server` | The server's own words, code, detail and hint. |
| `Interrupted` | `Cancelled` | "Stopped." |
| `Timeout` | `Timeout`, `TransportError::Timeout` | One sentence per `TimeoutPhase`. |
| `ConnectionLost` | `ConnectionLost` | Says the connection closed. The session reconnects on a backoff. |
| `WriteOutcome` | `RolledBack`, `RowGuardFailed`, `CommitOutcomeUnknown`, `PartiallyApplied` | Says what is in the database now. Only `RolledBack` and `RowGuardFailed` may say nothing changed. |
| `File` | the four file variants | Names the path. A connect that failed on the file is not retried. |
| `Busy` | `Busy`, `EditorSessionBusy` | Says to try again shortly, or to wait for the tab's statement. |
| `Internal` | `GuardUnsupported`, `Decode`, `Protocol`; `SshFailure::Protocol` | Says what the driver could not do: check a save, read a value, read the reply. |

## `ServerDiagnostics`

A server error keeps the shape the server sent it in. `ServerCode` holds each engine's own numbering, because the number is what tells a missing password apart from a missing table:

| `ServerCode` | Engine | Shown as |
|---|---|---|
| `SqlState(String)` | PostgreSQL | SQLSTATE 23505 |
| `MySql { number, sqlstate }` | MySQL, MariaDB | MySQL error 1062 |
| `Tds { number, state, class }` | SQL Server | SQL Server error 2627 |
| `ClickHouse { code }` | ClickHouse | ClickHouse code 62 |
| `Sqlite { primary, extended }` | SQLite | SQLite error 2067 |

`ServerDiagnostics` also carries `severity`, `detail`, `hint`, `position`, `where_context`, `schema`, `table`, `column` and `constraint`. PostgreSQL fills most of them; the other engines mostly leave them empty. `position` counts characters from the start of the statement the user wrote: a driver that wraps the statement corrects it (the PostgreSQL cursor flight subtracts its `DECLARE` prefix).

A driver maps the codes the app acts on to their own variants and passes everything else through as `Server`:

| Meaning | PostgreSQL | MySQL, MariaDB | SQL Server | ClickHouse | SQLite |
|---|---|---|---|---|---|
| `Auth` | 28P01, 28000 | 1045 | 18456, 18452, 18486-18488 | 192, 193, 194, 516; 497 at login | |
| `ReadOnly` (server) | 25006 | 1792 | 3906 | 164, 392 | 8 (`SQLITE_READONLY`) |
| Statement `Timeout` | 57014 with "statement timeout" | 3024 (MySQL), 1969 (MariaDB) | | 159 | |
| `LockWait` timeout | 55P03 | 1205 | 1222 | | |
| `Cancelled` | 57014 after our cancel request | 1317 | attention acknowledged | 394 after our KILL | 9 (`SQLITE_INTERRUPT`) after our stop |
| `Busy` | 53300 | 1040 | 17809 | 202, 203 | 5, 6 (`SQLITE_BUSY`, `SQLITE_LOCKED`) |
| `ConnectionLost` | 57P01, 57P02, 57P03 | 1053, 1927, 4031 | | | |

The engine pages ([PostgreSQL](drivers/postgresql.md), [MySQL and MariaDB](drivers/mysql.md), [SQLite](drivers/sqlite.md), [SQL Server](drivers/sql-server.md), [ClickHouse](drivers/clickhouse.md)) give each driver's mapping, and the places where a driver can only read the message, as SQL Server's TLS failures through tiberius.

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
| `NameMismatch` | The certificate is for another name. | **Set TLS Server Name**, which opens the connect dialog at the server name row. |
| `Expired`, `NotYetValid`, `Revoked` | The certificate itself is bad. | Nothing: the server's certificate has to be replaced. |
| `ServerRefusedTls` | The server does not speak TLS on this port. | The message; turn TLS off or use the TLS port. |
| `ServerRequiresTls` | TLS was off and the server insists on it. | The message; turn TLS on. |
| `HandshakeRejected` | The server ended the handshake, for example over the client certificate. | The server's reason. |
| `CaFileInvalid`, `ClientIdentityInvalid` | A file the user chose cannot be used. | The message names the file. |
| `Other` | Anything else. | The rustls message. |

The buttons are `TlsRemedy` in `crates/app/src/ui/error_text/tls_remedy.rs`, shown on the connect failure's toast. Which certificates each engine trusts, and how to choose a CA file under Flatpak, is in [ARCHITECTURE.md](../ARCHITECTURE.md#trust).

## Mapping errors in a driver

- Map by the engine's code, not by message text. Where the client library keeps nothing but the text, say so in a comment and pin the text with a test.
- Keep the server's diagnostics: `DriverError::reported(ServerDiagnostics)`, and `DriverError::auth(Some(diagnostics))` for a refused login.
- An error the engine raised to acknowledge our stop is the stop: `Cancelled`, or `Timeout { server_cancelled: true }`. `EngineStop::acknowledged` is where `OwnedCalls::run_read` learns which errors those are; `run_write` passes the result through, so a write maps its own.
- A `ConnectionLost` goes through `Transport::explain_closed_stream`, so an SSH master that exited is reported as that.
- A dead route is reported only once a check outside the pool confirms it ([adding-drivers.md](adding-drivers.md#deciding-that-the-link-is-lost)).

## User-facing text

`crates/app/src/ui/error_text/` turns errors into sentences: `driver_message` for a `DriverError`, `connect_error_message` and `operation_error_message` for the session's errors, and an SSH module for `SshFailure`. Every string goes through `crate::i18n`. Never show `Debug` or the `#[error]` text of an error on its own.

## Logging

Logging goes through `tracing`. `crates/app/src/logging.rs` installs a `tracing_subscriber` fmt layer that writes to **stderr**, which the GNOME session journals for both Flatpak and system installs. Panics land in the same stream, so a panic and the lines around it stay in order. There is no journald writer and no panic hook.

- The filter comes from `RUST_LOG`. Without it, a development build logs at `debug` and an installed one at `info`. A `RUST_LOG` that does not parse falls back to that default and logs a warning saying so.
- `TABLEPRO_LOG_FORMAT=json` writes one JSON object per line; `text`, the default, writes plain lines.

```sh
RUST_LOG=debug ./_build/crates/app/tablepro
RUST_LOG=tablepro=trace,info TABLEPRO_LOG_FORMAT=json ./_build/crates/app/tablepro
journalctl --user -f -t tablepro
```

Levels: `error!` for what the user must see or a broken contract, `warn!` for recoverable but suspicious, `info!` for lifecycle events, `debug!` for internal flow, `trace!` for query text and wire detail.

Never log a password, a secret, a key or a bound value. sqlx's own statement logging is turned off in the MySQL and SQLite drivers, and a test in each crate (`tests/statement_logging.rs`) proves no statement text reaches the subscriber.

The libraries under the drivers log what a database was sent or answered: tokio-postgres the text of every statement at `debug`, through `log`, which `tracing-subscriber` forwards; sqlx every statement, and a slow one as a warning; tiberius rows at `trace` and server messages as errors; the clickhouse crate exceptions that quote the query; deadpool the errors of the connections it recycles; sqlparser, also through `log`, the text of every statement, filter and default it parses, and the literals in it, at `debug`. So the subscriber drops every event whose target starts with `tokio_postgres`, `deadpool`, `tiberius`, `sqlx`, `clickhouse` or `sqlparser`, at every level. That filter sits beside the `RUST_LOG` one, so no directive turns them back on, however specific. A driver logs what it needs from their errors itself. A new driver's client library, or any other library that logs SQL text, joins `SILENCED_LIBRARIES` in `logging.rs`.

## `unwrap`, `expect` and `panic!`

The workspace lints deny `unwrap_used`, `expect_used`, `panic`, `todo` and `unimplemented`; `clippy.toml` allows them in tests only. Return a real error instead. The one accepted use outside tests is in a `const`, where the compiler proves the value, as `RowLimit::EDITOR_DEFAULT` does.

## Patterns refused in review

- A `String` or `Box<dyn Error>` as an error type in a public function.
- A client library's error in a public signature of a driver crate.
- `match error { _ => "Something went wrong" }`. Match the category, then the variant.
- A retry loop around an error the category says retrying cannot fix: `Configuration`, `Authentication`, `File`, `WriteOutcome`.
- Treating `CommitOutcomeUnknown` or `PartiallyApplied` as a failure that changed nothing.
