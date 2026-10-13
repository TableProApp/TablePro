# SQL Server

Driver id `mssql`, crate `crates/drivers/mssql`. It runs on tiberius 0.13.0 from crates.io (`tds73`, `rustls`, `chrono`, and `integrated-auth-gssapi` behind the crate's `kerberos` feature) with a deadpool 0.13 pool. The integration suite runs against SQL Server 2022. The contract it implements is in [adding-drivers.md](../adding-drivers.md).

The driver needs SQL Server 2016 or later: every column read joins `sys.masked_columns`, and dropping a table uses `DROP TABLE IF EXISTS`.

## Connections

| Connection | Used for | Session |
|---|---|---|
| Workspace pool, 4 connections (`WORKSPACE_POOL_MAX_SIZE`) | The sidebar, the grid, counts, saves | `SET LOCK_TIMEOUT 10000; SET XACT_ABORT ON;` |
| One connection per call | `stream_read` (exports), and `probe` when every pool slot is busy | Workspace, or none for the probe |
| One connection per editor tab | `EditorSession` | The server's defaults: whatever the user sets is theirs |

- `XACT_ABORT ON` rolls a transaction back on any error, so a failed statement never leaves one open on a pooled connection. `LOCK_TIMEOUT` makes a blocked edit report the lock (error 1222) instead of running into the statement deadline.
- A pool member is handed out again only when `@@TRANCOUNT` is 0.
- tiberius's own 30 s command timeout is off: each call is bounded by its own deadline, and an editor query may run longer.

Every login gets its stream from the transport, so a direct route and an SSH forward behave the same. A stream must open within the connect timeout and the TDS login finish within the login timeout.

## Routing

An Azure SQL gateway or an availability group listener can answer a login with a routing token that names another server. The driver follows it once: it asks the transport for a route to the new host and port (`Transport::reroute`, a new forward on the same SSH master when the connection goes through SSH) and logs in there, checking TLS and building the Kerberos SPN against the new host. A second routing answer is refused, so a gateway that keeps redirecting cannot loop.

## TLS

TLS is negotiated inside the TDS pre-login exchange, after the server has said what encryption it supports.

| `TlsMode` | tiberius setting | Certificate check |
|---|---|---|
| `Disable` | `EncryptionLevel::NotSupported` | None. A server that requires encryption is reported as `ServerRequiresTls`. |
| `Require` | `EncryptionLevel::Required` with `trust_cert` | None |
| `VerifyFull` | `EncryptionLevel::Required` | The system's CA store, loaded by tiberius, plus the connection's CA file (`trust_cert_ca`). The name is the host, or the override (`hostname_in_certificate`). |

- A server that will not encrypt when asked to is reported as `ServerRefusedTls`.
- No client certificate: SQL Server logins are not authenticated by one, so a TLS setting that carries one is refused.
- tiberius takes no rustls `ClientConfig` and keeps only the text of a rustls error, so the driver classifies TLS failures from that text (`UnknownIssuer`, `NameMismatch`, `Expired` and so on). This is coarser than the other engines, which read the rustls error itself, and a phrase rustls changes in a later release falls back to `TlsFailure::Other`.
- The CA file is checked before the login, because tiberius reads it during the handshake and would report a bad file as an I/O error.

## Authentication

- **Password**: a SQL Server login.
- **Windows (Kerberos)**: only in a build with the `kerberos` feature, which links MIT Kerberos. The driver sends no username or password and uses the ticket the user already holds from `kinit`, for the SPN `MSSQLSvc/<host>:<port>` built from the host and port the user typed, never from a local SSH forward. The Kerberos calls block, so the login runs on Tokio's blocking pool and the login timeout ends it. The README's [SQL Server section](../../README.md#sql-server-with-windows-integrated-auth) has the realm and SPN rules.

### Kerberos inside Flatpak

The sandbox has no `/etc/krb5.conf` of the host, and its `/tmp` is private, so a FILE ticket cache from `kinit` on the host is invisible:

- A build with `-Dflatpak=true` and Kerberos installs `build-aux/flatpak/krb5.conf` into the app's `sysconfdir`. It uses the KCM credential cache and finds the realm and the KDC through DNS.
- The development manifest grants the KCM socket, `/run/.heim_org.h5l.kcm-socket`, so a host that runs `sssd-kcm` shares its tickets with the app.
- A FILE cache works only when `KRB5CCNAME` points at a file the sandbox can read, such as one under the home folder.

Running from source remains the supported path for Kerberos today.

## Read-only

`ReadOnlyEnforcement::LoginPrivileges`. SQL Server has no read-only session or transaction mode, so the login's permissions are the only guarantee, and the connect dialog says so. Use a login granted only `SELECT` for a read-only connection. The driver adds guards against accidents, not against intent:

- Saves are refused before anything is sent (`ReadOnly(ClientGuard)`).
- A generated read on a read-only connection runs inside `BEGIN TRANSACTION` and `ROLLBACK TRANSACTION`, so a filter fragment that writes is undone. A fragment that ends the guard's transaction itself (errors 266, 3902, 3903) is reported as refused by read-only mode, never as a success.
- An export, on any connection, refuses user SQL that is not one batch of statements starting with `SELECT`, `WITH` or a parenthesis, or that contains a word that writes or runs code (`INSERT`, `EXEC`, `MERGE`, `INTO` and the like), and runs inside the same rolled-back transaction.
- An editor session has no guard: it runs whatever the login may run.

## Stops and timeouts

tiberius borrows its client for the whole of a request, so nothing outside the task that owns the client can stop one. The stop is a TDS attention, sent by that task on the request's own connection (`Client::cancel_query`): `StopDelivery::InBand`. When the stop fires, the task:

1. gives the request a quarter of the cancel grace to reach a point between TDS tokens, because a request half read finishes cleanly if given a moment;
2. sends the attention and waits up to half of the grace for the server's acknowledgement;
3. on a workspace connection, rolls back any transaction the request left open (`IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION`), because an attention does not end one. An editor session keeps the user's transaction.

The connection is reused only when the attention was acknowledged at a token boundary. One stopped in the middle of a token, or whose attention got no acknowledgement or something else back, is closed. During a save the attention is never sent while `COMMIT TRANSACTION` is in flight.

tiberius 0.13 stops reading at the first end of message, so an attention sent while SQL Server is still waiting on the request, as in a `WAITFOR`, is never acknowledged, and the connection is closed. A pooled connection is replaced; an editor session ends and the tab opens a new one on its next run. The fix is tiberius-rs/tiberius#459. Until a release has it, `.config/nextest.toml` holds the three tests that need it out of the default run:

- `cancellation::editor_waitfor_cancel_then_select1_same_client`
- `cancellation::pooled_query_bound_waitfor_deadline_server_cancelled_client_reused`
- `conformance_engine::suite::editor_cancel_reports_cancelled_and_session_stays_ready`

SQL Server has no session statement timeout. A workspace call's deadline is the nearer of the caller's and the workspace's 60 s, enforced by the attention; a schema change keeps only the caller's.

| Server answer | Reported as |
|---|---|
| Attention acknowledged | `Cancelled`, or `Timeout { server_cancelled: true }` when the deadline asked for it |
| 1222 | `Timeout { phase: LockWait }` |
| 3906 | `ReadOnly(ServerRejected)` |
| 18456, 18452, 18486, 18487, 18488 | `Auth` |
| 17809 | `Busy` |
| A GSSAPI failure | `IntegratedAuth` |

## Writes

`WriteAtomicity::Transactional` for row and schema changes. A save is `BEGIN TRANSACTION`, each step, then `COMMIT TRANSACTION`:

- A statement with parameters runs through tiberius's `execute`; one without runs through `sp_executesql` with the statement alone, because SQL Server refuses `CREATE VIEW` or `CREATE TRIGGER` next to an empty parameter list.
- The affected-row count includes rows a trigger touched, so a save proves it hit the right row with a probe before the statement rather than with that count.
- A `COMMIT` the server answers with an error rolled back; one whose connection dropped is `CommitOutcomeUnknown` with no token. There is nothing to ask the server afterwards (`CommitResolutionSupport::Unavailable`).
- SQL Server cannot suspend foreign keys for one batch, so a batch that asks for it is refused before anything is sent.

## Editor sessions

- A script runs one `GO` batch at a time, as sqlcmd and SSMS do, including `GO <count>`. Each batch goes as a SQL batch, not through `sp_executesql`, so a `USE` or a `SET` in it lasts for the rest of the session. A failed batch does not stop the next one. Text the splitter cannot finish goes to the server whole, so the error is the server's own.
- Rows past the row limit are counted and dropped, never decoded.
- When the grid stops reading, the driver sends an attention instead of reading millions of unwanted rows.
- The transaction state comes from `@@TRANCOUNT` and `XACT_STATE()`, so a transaction an error has doomed reads as `Failed`.
